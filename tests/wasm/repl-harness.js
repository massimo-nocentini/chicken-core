// repl-harness.js - headless tests of the WebAssembly REPL through repl-driver.js
//
// Copyright (c) 2026, The CHICKEN Team
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following
// conditions are met:
//
//   Redistributions of source code must retain the above copyright notice, this list of conditions and the following
//     disclaimer.
//   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
//     disclaimer in the documentation and/or other materials provided with the distribution.
//   Neither the name of the author nor the names of its contributors may be used to endorse or promote
//     products derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
// OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
// AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
// OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
// usage: node [v8 flags] repl-harness.js WEB_DIR [--arch=A]
//
// WEB_DIR holds chicken-repl.js and chicken-repl.wasm (build-wasm/web).
// Runs the REPL core cases of the plan (README, WebAssembly section), and
// the J and R-JS cases of the JavaScript bridge (webjs.scm, the REPL's
// ,js), and exits with status 1 if any fails.  Run it once in default node and once
// with "--liftoff --no-wasm-tier-up --stack-size=900".
//
// With --arch=A, the modules tested are those of the architecture A of
// a page with several (make wasm WASM_WEB_ARCHS="wasm64 wasm32"), in
// WEB_DIR/A unless A is the page's own (its chicken-wasm-arch).

'use strict';
const fs = require('fs');
const path = require('path');

// gc(), for the cases of JavaScript's garbage collector (J17, J21), in
// every lane: as --expose-gc gives it
if (typeof gc !== 'function') {
  require('v8').setFlagsFromString('--expose-gc');
  globalThis.gc = require('vm').runInNewContext('gc');
}

const webDir = path.resolve(process.argv[2] || 'web');
// the page's own architecture and those it has (chicken-wasm-builds,
// "ARCH:EH" each); --arch=A selects the modules of A
const pageMeta = (html, name) => (new RegExp('<meta name="' + name + '" content="([^"]*)">').exec(html) || [])[1];
function moduleArch(html) {
  const own = pageMeta(html, 'chicken-wasm-arch');
  const want = (process.argv.find(a => /^--arch=/.test(a)) || '').slice(7) || own;
  const has = (pageMeta(html, 'chicken-wasm-builds') || own || '').split(/\s+/).map(w => w.split(':')[0]);
  if (!has.includes(want)) throw new Error('the page in ' + webDir + ' has no ' + want + ' build (only ' + has.join(', ') + ')');
  return { arch: want, sub: want === own ? '' : want + '/' };
}
// the architecture of the modules (make wasm WASM_ARCH=...)
const { arch, sub } = moduleArch(fs.readFileSync(path.join(webDir, 'index.html'), 'utf8'));
const modDir = path.join(webDir, sub);
const createChickenRepl = require(path.join(modDir, 'chicken-repl.js'));
const Driver = require(path.join(__dirname, '..', '..', 'emscripten', 'web', 'repl-driver.js'));
const { RUNNING, WAITING, BUSY, EXITED, SLEEPING, PAUSED, AWAITING, LAZY_NEXT, LAZY_GO, LAZY_PAUSE } = Driver;
const wasmModule = new WebAssembly.Module(fs.readFileSync(path.join(modDir, 'chicken-repl.wasm')));
console.log('# ' + arch + ' modules in ' + modDir);

let failures = 0, passes = 0;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const now = () => performance.now();

async function waitFor(what, pred, ms = 20000) {
  const t0 = now();
  for (;;) {
    const v = pred();
    if (v) return v;
    if (now() - t0 > ms) throw new Error('timed out after ' + ms + ' ms waiting for ' + what);
    await sleep(5);
  }
}

// One csi instance.  All output (both fds, in order) goes to `all';
// send() and mark() start a new window for expectOut().
async function session(opts = {}) {
  const s = {
    all: '', err: '', states: [], pumps: [], exit: null, crash: null,
    markAt: 0, stateAt: 0, pumpAt: 0,
    unacked: 0, high: Infinity,
  };
  s.drv = await Driver.start(createChickenRepl, {
    args: opts.args || ['-n'],
    csirc: opts.csirc,
    files: opts.files,
    sliceMs: opts.sliceMs,
    wasmModule: opts.noPrecompiled ? undefined : wasmModule,
    schedule: f => setImmediate(() => { s.pumps.push({ t: now(), later: 0 }); f(); }),
    later: (f, ms) => setTimeout(() => { s.pumps.push({ t: now(), later: ms }); f(); }, ms),
    canRun: () => s.unacked < s.high,
    onOutput: (fd, t) => { s.all += t; s.unacked += t.length; if (fd === 2) s.err += t; },
    onState: (st, lazy) => { s.states.push(st); s.lazy = lazy; },
    onExit: code => { s.exit = { code, out: s.all }; },
    onCrash: msg => { s.crash = msg; },
    onDiag: t => { s.diag = (s.diag || '') + t; },
  });
  current = s;
  s.mark = () => { s.markAt = s.all.length; s.stateAt = s.states.length; s.pumpAt = s.pumps.length; };
  s.since = () => s.all.slice(s.markAt);
  s.statesSince = () => s.states.slice(s.stateAt);
  s.send = (text, eof) => { s.mark(); s.drv.feed(text, eof); };
  s.interrupt = () => { s.mark(); s.drv.interrupt(); };
  s.expectOut = (re, ms) => waitFor('output ' + re, () => {
    if (s.crash) throw new Error('crash: ' + s.crash);
    return re.test(s.since());
  }, ms);
  // a state reported after the mark (so the input sent was processed)
  s.expectState = (st, ms) => waitFor('state ' + st, () =>
    s.states.length > s.stateAt && s.states[s.states.length - 1] === st && s.drv.state() === st, ms);
  // the next prompt after the mark, and WAITING
  s.prompt = async ms => { await s.expectOut(/#;\d+> $/, ms); await s.expectState(WAITING, ms); };
  if (s.drv) s.drv.begin();
  return s;
}

let current = null;                     // session shown on failure

async function check(name, f) {
  try {
    await f();
    passes++;
    console.log('ok - ' + name);
  } catch (e) {
    failures++;
    console.log('not ok - ' + name + '\n  ' + String((e && e.message) || e));
    if (current) console.log('  output since the last input:\n  | ' +
                             current.since().slice(-600).split('\n').join('\n  | '));
  }
}

// a result line; it may follow the prompt of an earlier form on the same line
const val = v => new RegExp('(^|> )' + v.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\n', 'm');

function assert(c, msg) { if (!c) throw new Error('assertion failed: ' + msg); }
const J = x => JSON.stringify(x);
function eq(a, b, what) { assert(J(a) === J(b), what + ': expected ' + J(b) + ', got ' + J(a)); }

(async () => {
  const t0 = now();
  let S;

  await check('1 ready, banner and first prompt', async () => {
    S = await session();
    assert(S.drv, 'start returned null: ' + (S.crash || JSON.stringify(S.exit)));
    await waitFor('banner', () => /CHICKEN/.test(S.all) && /#;1> $/.test(S.all), 30000);
    await S.expectState(WAITING);
    assert(now() - t0 < 30000, 'ready within 30 s');
  });
  if (!S || !S.drv) { console.log('cannot continue'); process.exit(1); }

  await check('2 (+ 1 2) gives 3, then WAITING', async () => {
    S.send('(+ 1 2)\n');
    await S.expectOut(val('3'));
    await S.prompt();
  });

  await check('3 import and string-intersperse', async () => {
    S.send('(import (chicken string)) (string-intersperse \'("a" "b") ",")\n');
    await S.expectOut(/"a,b"/);
    await S.prompt();
  });

  await check('4 error on stderr, then the REPL goes on', async () => {
    const e0 = S.err.length;
    S.send('(car 1)\n');
    await S.prompt();
    assert(/Error: \(car\) bad argument type/.test(S.err.slice(e0)), 'error text on stderr');
    S.send('(* 6 7)\n');
    await S.expectOut(val('42'));
    await S.prompt();
  });

  await check('5 a form split over two feeds', async () => {
    S.send('(define (f x)\n');
    await S.expectState(WAITING);
    assert(!/#;\d+> $/.test(S.since()), 'no new prompt inside a form');
    S.send('(* x 2))\n(f 21)\n');
    await S.expectOut(val('42'));
    await S.prompt();
  });

  await check('6 re-entering a continuation from an earlier prompt', async () => {
    S.send('(define k #f) (+ 1 (call-with-current-continuation (lambda (c) (set! k c) 1)))\n');
    await S.expectOut(val('2'));
    await S.prompt();
    S.send('(k 10)\n');
    await S.expectOut(val('11'));
    await S.prompt();
  });

  await check('7 read-line reads the next line fed', async () => {
    S.send('(import (chicken io)) (read-line)\n');
    await S.expectState(WAITING);
    S.send('hello world\n');
    await S.expectOut(/"hello world"/);
    await S.prompt();
  });

  await check('8 endless loop: BUSY slices, Stop, then the REPL goes on', async () => {
    S.send('(let loop () (loop))\n');
    await waitFor('two BUSY states', () => S.statesSince().filter(s => s === BUSY).length >= 2);
    const t = now();
    S.interrupt();
    await S.expectOut(/user interrupt/, 5000);
    assert(now() - t < 5000, 'interrupt within 5 s');
    await S.prompt();
    S.send('(+ 2 2)\n');
    await S.expectOut(val('4'));
    await S.prompt();
  });

  await check('9 streaming output of 200000 lines, bounded memory', async () => {
    S.send('(let loop ((i 0)) (when (< i 1000) (print i) (loop (+ i 1))))\n');
    await S.expectOut(val('999'));
    await S.prompt();
    const heap1 = S.drv.module.HEAPU8.length;
    S.send('(let loop ((i 0)) (when (< i 200000) (print i) (loop (+ i 1))))\n');
    await S.expectOut(/^199999\n#;\d+> $/m, 120000);
    await S.prompt();
    const lines = S.since().split('\n');
    assert(lines[0] === '0' && lines[199999] === '199999', 'all lines in order');
    const busy = S.statesSince().filter(s => s === BUSY).length;
    const heap2 = S.drv.module.HEAPU8.length;
    assert(heap2 <= 2 * heap1, `linear memory ${heap2} <= 2 x ${heap1}`);
    S.send('(import (chicken gc)) (let ((v (memory-statistics))) (print "stats " (and (vector? v) (> (vector-ref v 0) 0) (<= (vector-ref v 1) (vector-ref v 0)))))\n');
    await S.expectOut(val('stats #t'));
    await S.prompt();
    console.log(`#   ${busy} BUSY slices, linear memory ${heap1} -> ${heap2} bytes`);
  });

  await check('10 deep non-tail recursion (S17) in the REPL', async () => {
    S.send('(import (chicken fixnum)) (define (f n) (if (fx= n 0) 0 (fx+ 1 (f (fx- n 1))))) (f 1000000)\n');
    await S.expectOut(val('1000000'), 60000);
    await S.prompt();
  });

  await check('11 syntax and modules', async () => {
    S.send('(define-syntax swap! (syntax-rules () ((_ a b) (let ((t a)) (set! a b) (set! b t)))))\n');
    await S.prompt();
    S.send('(define p 1) (define q 2) (swap! p q) (list p q)\n');
    await S.expectOut(val('(2 1)'));
    await S.prompt();
    S.send('(module m (f) (import scheme) (define (f) 1))\n');
    await S.prompt();
    S.send('(import m) (f)\n');
    await S.expectOut(val('1'));
    await S.prompt();
  });

  await check('12 toplevel commands ,t and ,d', async () => {
    S.send(',t (+ 1 2)\n');
    await S.expectOut(/CPU time/);
    await S.prompt();
    assert(val('3').test(S.since()), ',t shows the value');
    S.send(",d 'a\n");
    await S.expectOut(/symbol/);
    await S.prompt();
  });

  await check('15 stale Stop after a finished evaluation is ignored', async () => {
    S.send('(let l ((i 0)) (if (< i 1000) (l (+ i 1))))\n');
    await S.prompt();
    S.interrupt();
    await S.expectState(WAITING);
    await sleep(50);
    S.send('(+ 1 1)\n');
    await S.expectOut(val('2'));
    await S.prompt();
    assert(!/user interrupt/.test(S.since()), 'no user interrupt');
  });

  await check('16 Stop while waiting inside a form', async () => {
    S.send('(define (g x\n');
    await S.expectState(WAITING);
    S.interrupt();
    await S.expectOut(/user interrupt/, 5000);
    await S.prompt();
    S.send('(+ 3 3)\n');
    await S.expectOut(val('6'));
    await S.prompt();
  });

  await check('17 sleep yields (no spinning); Stop during sleep', async () => {
    const t = now();
    S.send("(sleep 1) (print 'woke)\n");
    await waitFor('SLEEPING', () => S.statesSince().includes(SLEEPING), 2000);
    await S.expectOut(val('woke'), 3000);
    const dt = now() - t;
    assert(dt >= 950 && dt <= 2000, `woke after ${dt.toFixed(0)} ms`);
    await S.prompt();
    // pump runs while sleeping are at least 50 ms apart (the last, which
    // waits for the remainder of the second, may be shorter)
    const p = S.pumps.slice(S.pumpAt);
    const gaps = [];
    for (let i = 1; i < p.length; i++) if (p[i].later) gaps.push(p[i].t - p[i - 1].t);
    const tooShort = gaps.slice(0, -1).filter(g => g < 50);
    assert(gaps.length >= 5 && gaps.length <= 25, `${gaps.length} timed wakeups`);
    assert(tooShort.length === 0, 'gaps below 50 ms: ' + tooShort.map(g => g.toFixed(1)));
    console.log(`#   ${p.length} pump runs, ${gaps.length} timed wakeups, min gap ${Math.min(...gaps.slice(0, -1)).toFixed(1)} ms`);

    S.send('(sleep 30)\n');
    await waitFor('SLEEPING', () => S.statesSince().includes(SLEEPING), 2000);
    await sleep(200);
    const t2 = now();
    S.interrupt();
    await S.expectOut(/user interrupt/, 1000);
    assert(now() - t2 < 1000, 'reset within 1 s');
    await S.prompt();
  });

  await check('18 a user return-to-host is resumed', async () => {
    S.send("(import (chicken platform)) (return-to-host) (print 'back)\n");
    await S.expectOut(val('back'));
    await S.prompt();
    assert(S.statesSince().includes(BUSY), 'BUSY was reported');
  });

  await check('28 closing stdout or stderr: they work again at the next prompt', async () => {
    S.send('(import (scheme base)) (call-with-port (current-output-port) (lambda (p) (write "hi" p)))\n');
    await S.expectOut(/"hi"/);
    await S.prompt();
    S.send('(+ 2 2)\n');
    await S.expectOut(val('4'));
    await S.prompt();
    const e0 = S.err.length;
    S.send('(close-output-port (current-error-port))\n');
    await S.prompt();
    S.send('(display "e" (current-error-port)) (+ 3 3)\n');
    await S.expectOut(val('6'));
    await S.prompt();
    assert(/e$/.test(S.err.slice(e0)), 'stderr again: ' + JSON.stringify(S.err.slice(e0)));
  });

  await check('29 a lazy stream is printed element by element', async () => {
    S.send('(define (nats n) (delay (cons n (nats (+ n 1)))))\n' +
           '(define (take-s n s) (delay (let ((p (force s))) (if (or (zero? n) (null? p)) (quote ()) ' +
           '(cons (car p) (take-s (- n 1) (cdr p)))))))\n');
    await S.expectOut(/#;\d+> #;\d+> $/);
    await S.prompt();
    S.send('(take-s 5 (nats 0))\n');
    await S.expectOut(val('(0 1 2 3 4)'));
    await S.prompt();
    assert(S.lazy === false, 'not printing a stream at the prompt');
    // nested, improper, a promise that is no stream, an empty stream, and
    // a promise of a promise (as aux's streams make them)
    S.send('(delay (list (delay (list 1 "a")) (delay 3) (delay (quote ())) (delay (delay (cons 4 5)))))\n');
    await S.expectOut(val('((1 "a") #<promise 3> () (4 . 5))'));
    await S.prompt();
    // only the results: an error's arguments are written as they are
    const e0 = S.err.length;
    S.send('(error "no" (delay 1))\n');
    await S.prompt();
    assert(/no: #<promise>/.test(S.err.slice(e0)), 'error argument: ' + S.err.slice(e0));
  });

  await check('30 Pause, Next and Go on a lazy stream; Stop ends it, not as an error', async () => {
    const e0 = S.err.length;
    S.send('(nats 0)\n');
    await S.expectOut(/\(0 1 2/);
    S.drv.lazy(LAZY_PAUSE);
    await S.expectState(PAUSED);
    assert(S.lazy === true, 'printing a stream while paused');
    await sleep(100);
    const n0 = S.all.length;
    await sleep(200);
    assert(S.all.length === n0, 'no output while paused');
    S.mark();
    S.drv.lazy(LAZY_NEXT);
    await S.expectOut(/^ \d+$/);
    await S.expectState(PAUSED);
    await sleep(50);
    assert(/^ \d+$/.test(S.since()), 'one element per Next: ' + JSON.stringify(S.since()));
    S.mark();
    S.drv.lazy(LAZY_GO);
    await S.expectOut(/^( \d+){100}/);
    S.interrupt();
    await S.expectOut(/^\d* \.\.\.\)\n#;\d+> $/);
    await S.prompt();
    assert(S.lazy === false, 'the stream is over at the prompt');
    assert(S.err.length === e0, 'Stop is no error: ' + S.err.slice(e0));
    // Stop while paused, and a stop that comes between two streams
    S.send('(nats 0)\n');
    await S.expectOut(/\(0 1/);
    S.drv.lazy(LAZY_PAUSE);
    await S.expectState(PAUSED);
    S.interrupt();
    await S.expectOut(/ \.\.\.\)\n#;\d+> $/);
    await S.prompt();
    S.send('(take-s 3 (nats 7))\n');
    await S.expectOut(val('(7 8 9)'));
    await S.prompt();
  });

  await check('31 an error while forcing an element ends the stream as errors do', async () => {
    const e0 = S.err.length;
    S.send('(delay (cons 1 (delay (car (quote ())))))\n');
    await S.prompt();
    assert(/^\(1/.test(S.since()), 'the element before the error: ' + S.since());
    assert(/Error: \(car\) bad argument type/.test(S.err.slice(e0)), 'the error');
    assert(S.lazy === false, 'not printing a stream any more');
    S.send('(nats 0)\n');                // and Stop works as before
    await S.expectOut(/\(0 1 2/);
    const e1 = S.err.length;
    S.interrupt();
    await S.prompt();
    assert(S.err.length === e1, 'Stop is no error: ' + S.err.slice(e1));
  });

  await check('21 backpressure: canRun() false stops pumping, resumeOutput() restarts', async () => {
    S.high = 1 << 20;
    S.unacked = 0;
    S.send('(let loop ((i 0)) (when (< i 300000) (print i) (loop (+ i 1))))\n');
    await waitFor('blocked on unacked output', () => S.unacked >= S.high && S.drv.state() === BUSY, 60000);
    const n = S.pumps.length;
    await sleep(300);
    assert(S.pumps.length === n, 'no pump runs while blocked');
    assert(S.drv.state() === BUSY, 'still BUSY');
    assert(!/^299999$/m.test(S.since()), 'not finished while blocked');
    // ack everything, like the page does after rendering
    const ack = () => { S.unacked = 0; S.drv.resumeOutput(); };
    const timer = setInterval(ack, 20);
    ack();
    try {
      await S.expectOut(val('299999'), 120000);
      await S.prompt();
    } finally { clearInterval(timer); S.high = Infinity; }
  });

  await check('13 (exit 7) reports onExit(7), the driver is dead', async () => {
    const X = await session();
    await waitFor('prompt', () => /#;1> $/.test(X.all));
    X.send('(exit 7)\n');
    await waitFor('exit', () => X.exit);
    assert(X.exit.code === 7, 'exit code ' + X.exit.code);
    assert(X.drv.dead && X.drv.state() === EXITED, 'driver dead');
    X.drv.feed('(+ 1 2)\n');             // ignored, must not throw
  });

  await check('14 .csirc is loaded', async () => {
    const X = await session({ args: [], csirc: '(define from-rc 99)\n' });
    await waitFor('prompt', () => /#;1> $/.test(X.all));
    X.send('from-rc\n');
    await X.expectOut(val('99'));
  });

  await check('19 exit during startup (no precompiled module)', async () => {
    const X = await session({ args: ['-e', '(exit 5)'], noPrecompiled: true });
    assert(X.drv === null, 'start returned null');
    assert(X.exit && X.exit.code === 5, 'onExit(5), got ' + JSON.stringify(X.exit) + ' ' + X.crash);
  });

  await check('20 EOF flushes pending output before onExit(0)', async () => {
    const X = await session();
    await waitFor('prompt', () => /#;1> $/.test(X.all));
    X.send('(display "x")');
    await X.expectState(WAITING);
    X.drv.feed('', true);
    await waitFor('exit', () => X.exit);
    assert(X.exit.code === 0, 'exit code ' + X.exit.code);
    assert(/x/.test(X.exit.out.slice(X.markAt)), 'x flushed before exit');
  });

  await check('22 a script or -e that ends normally reports onExit(0)', async () => {
    const X = await session({ args: ['-n', '-s', '/home/web_user/x.scm'],
                              files: [{ path: '/home/web_user/x.scm', data: '(print "hi")\n' }] });
    assert(X.drv === null && X.exit && X.exit.code === 0,
           'onExit(0), got ' + JSON.stringify(X.exit) + ' ' + X.crash);
    assert(/hi\n/.test(X.all), 'script output');
    const Y = await session({ args: ['-n', '-e', '(+ 1 2)'] });
    assert(Y.exit && Y.exit.code === 0, '-e: onExit(0), got ' + JSON.stringify(Y.exit) + ' ' + Y.crash);
    const Z = await session({ args: ['-n', '-e', '(exit -1)'] });
    assert(Z.exit && !Z.crash, '(exit -1): onExit, got ' + JSON.stringify(Z.exit) + ' ' + Z.crash);
  });

  await check('23 an error in -e or .csirc prints its message, then onExit(70)', async () => {
    const X = await session({ args: ['-n', '-e', '(display "before") (car 1)'] });
    assert(X.exit && X.exit.code === 70, 'onExit(70), got ' + JSON.stringify(X.exit) + ' ' + X.crash);
    assert(/before/.test(X.all) && /Error: \(car\) bad argument type/.test(X.err), 'message: ' + JSON.stringify(X.all));
    assert(/Call history/.test(X.err), 'call history');
    const Y = await session({ args: [], csirc: '(car 1)\n' });
    assert(Y.exit && Y.exit.code === 70, 'csirc: onExit(70), got ' + JSON.stringify(Y.exit) + ' ' + Y.crash);
    assert(/Error: \(car\) bad argument type/.test(Y.err), 'csirc message: ' + JSON.stringify(Y.all.slice(-300)));
  });

  await check('24 a panic during startup is reported with its message', async () => {
    const X = await session({ args: ['-:s8m', '-n'] });
    assert(X.exit && X.exit.code !== 0, 'onExit(nonzero), got ' + JSON.stringify(X.exit) + ' ' + X.crash);
    assert(/exceeds the WebAssembly stack/.test(X.err), 'message: ' + JSON.stringify(X.all));
  });

  await check('25 NUL characters in input are read', async () => {
    S.send('(display (string-length "a\u0000b"))\n(+ 1 1)\n');
    await S.expectOut(/3/);
    await S.expectOut(val('2'));
    await S.prompt();
  });

  await check('26 read-string and read-bytevector on stdin', async () => {
    S.send('(import (chicken io)) (list (read-string 3) (read-line))\nh\u00e9llo\n');
    await S.expectOut(val('("h\u00e9l" "lo")'));
    await S.prompt();
    S.send('(read-bytevector 4)\n\u00e9xy\n');
    await S.expectOut(val('#u8(195 169 120 121)'));
    await S.prompt();
  });

  await check('27 a paste over 16 MB is read in full, without leaking', async () => {
    const heap = () => S.drv.module.HEAPU8.length;
    const big = ';' + 'x'.repeat(17e6) + '\n(+ 40 2)\n';
    // Two pastes to warm up: depending on how the input chunks meet the
    // GCs, the heap takes its final size in the first or the second
    // (on wasm64, 188 MB, or 205 MB and then 246 MB), then stays there.
    for (let i = 0; i < 2; i++) {
      S.send(big);
      await S.expectOut(val('42'), 180000);
      await S.prompt(180000);
    }
    const h1 = heap();
    for (let i = 0; i < 2; i++) {
      S.send(big);
      await S.expectOut(val('42'), 180000);
      await S.prompt(180000);
    }
    const h3 = heap();
    console.log(`#   linear memory ${h1} -> ${h3} bytes`);
    assert(h3 - h1 < 8e6, 'memory grew by ' + (h3 - h1) + ' bytes over two more pastes');
    // the heap doubles as it grows: about 90 MB on wasm32, 190-250 MB on wasm64
    assert(h3 < (arch === 'wasm64' ? 320e6 : 160e6), 'memory ' + h3);
  });

  // ---- J: the JavaScript bridge (webjs.scm), in sessions of its own
  // (an error of the bridge may name an engine error, a RangeError)

  let JS;
  const bridged = [];                   // the J sessions, checked at the end
  // evaluate SRC: its value is printed as V
  const ev = async (src, v, ms) => { JS.send(src + '\n'); await JS.expectOut(val(v), ms); await JS.prompt(ms); };
  // evaluate SRC: an error matching RE
  const fails = async (src, re, ms) => {
    const e0 = JS.err.length;
    JS.send(src + '\n');
    await JS.prompt(ms);
    assert(re.test(JS.err.slice(e0)), src + ': ' + JSON.stringify(JS.err.slice(e0)));
  };
  const stats = () => JS.drv.module.webjs.stats();

  await check('J1 wiring; js-call, js-ref and js-global', async () => {
    JS = await session();
    bridged.push(JS);
    await waitFor('prompt', () => /#;1> $/.test(JS.all));
    assert(typeof JS.drv.module._webjs_dispatch === 'function', '_webjs_dispatch exported');
    assert(typeof JS.drv.module._webrepl_js_wake === 'function', '_webrepl_js_wake exported');
    assert(typeof JS.drv.module.webjs.stats === 'function', 'the bridge of the module');
    const e0 = JS.err.length;
    JS.send('(import js (scheme base) (chicken base) (chicken condition) (chicken bytevector) (chicken number-vector))\n');
    await JS.prompt();
    assert(JS.err.length === e0, 'import: ' + JS.err.slice(e0));
    await ev('(js-call (js-global "Math.max") 1 5 3)', '5');
    await ev('(js-ref (js-global "Math") "PI")', '3.14159265358979');
    JS.send('(js-global "Math.nope")\n');
    await JS.prompt();
    assert(/^#;\d+> $/.test(JS.since()), 'nothing printed: ' + JSON.stringify(JS.since()));
  });
  if (!JS || !JS.drv) { console.log('cannot continue'); process.exit(1); }

  await check('J2 JavaScript values in Scheme', async () => {
    JS.send('(js-eval "undefined")\n');
    await JS.prompt();
    assert(/^#;\d+> $/.test(JS.since()), 'undefined prints nothing: ' + JSON.stringify(JS.since()));
    await ev('(js-undefined? (js-eval "undefined"))', '#t');
    await ev('(js-eval "null")', '#<js-null>');
    await ev('(js-eval "true")', '#t');
    await ev('(list (js-eval "42") (exact? (js-eval "42")))', '(42 #t)');
    await ev('(list (js-eval "-0") (js-eval "0.5"))', '(-0.0 0.5)');
    // (wasm32 prints 2^53 as 9.00719925474099e+15)
    await ev('(list (js-eval "2**53-1") (exact? (js-eval "2**53-1")) (inexact? (js-eval "2**53")) ' +
             '(= (js-eval "2**53") (expt 2 53)))', '(9007199254740991 #t #t #t)');
    await ev('(list (js-eval "NaN") (js-eval "-Infinity"))', '(+nan.0 -inf.0)');
    await ev('(js-eval "12345678901234567890n")', '12345678901234567890');
    await ev('(let ((s (js-eval "\'h\\\\u00e9\\\\ud800\'"))) (list (string-length s) (char->integer (string-ref s 2))))',
             '(3 65533)');
    await ev('(js-eval "[1,2]")', '#<js-object Array(2)>');
    await ev('(js-eval "(function max(){})")', '#<js-object function max>');
    await ev('(list (js-eval "new Map") (js-eval "Symbol(\'s\')"))', '(#<js-object Map> #<js-object Symbol(s)>)');
    await ev('(list (js-eval "({})") (js-eval "Math"))', '(#<js-object Object> #<js-object Math>)');
  });

  await check('J3 Scheme values in JavaScript; round trips', async () => {
    JS.send('(define probe (js-eval "x => typeof x + \':\' + (ArrayBuffer.isView(x) ? x.constructor.name + ' +
            '\'[\' + Array.from(x).join() + \']\' : Array.isArray(x) ? JSON.stringify(x) : String(x))"))\n');
    await JS.prompt();
    const cases = [['1', 'number:1'], ['1.5', 'number:1.5'], ['(- (expt 2 53) 1)', 'number:9007199254740991'],
                   ['(expt 2 60)', 'bigint:1152921504606846976'],
                   ['(- (expt 2 70))', 'bigint:-1180591620717411303424'], ['1/2', 'number:0.5'],
                   ['#t', 'boolean:true'], ['"s"', 'string:s'], ["'sym", 'string:sym'], ['#:kw', 'string:kw'],
                   ['#\\a', 'string:a'], ['(void)', 'undefined:undefined'], ['js-null', 'object:null'],
                   ['(vector 1 "a" (vector 2))', 'object:[1,\\"a\\",[2]]'],
                   ['(bytevector 1 2)', 'object:Uint8Array[1,2]'], ['(f64vector 1.5)', 'object:Float64Array[1.5]'],
                   ["'(1 2)", 'object:[object SchemeObject]'], ["'()", 'object:[object SchemeObject]']];
    for (const [v, r] of cases) await ev('(js-call probe ' + v + ')', '"' + r + '"');
    await ev('(substring (js-call probe car) 0 9)', '"function:"');
    JS.send('(define id (js-eval "x => x"))\n');
    await JS.prompt();
    await ev('(let ((l (list 1 2))) (eq? (js-call id l) l))', '#t');
    await ev("(eq? (js-call id '()) '())", '#t');
    await ev('(let ((c (make-property-condition (quote c))) (r (make-parameter 1))) ' +
             '(list (eq? (js-call id c) c) (eq? (js-call id r) r)))', '(#t #t)');
    JS.send('(define-record-type point (make-point x y) point? (x point-x) (y point-y))\n');
    await JS.prompt();
    await ev('(let ((p (make-point 1 2))) (list (eq? (js-call id p) p) (js-call probe p)))',
             '(#t "object:[object SchemeObject]")');
    await ev('(js-call id (expt 2 60))', '1152921504606846976');
    await ev('(list (js-call id 2.0) (exact? (js-call id 2.0)))', '(2 #t)');
  });

  await check('J4 objects, keys and conversions; argument errors', async () => {
    JS.send('(define obj (js-obj "a" 1 \'b "x" #:c #t))\n');
    await JS.prompt();
    await ev('(js-keys obj)', '("a" "b" "c")');
    await ev('(js->alist obj)', '(("a" . 1) ("b" . "x") ("c" . #t))');
    await ev('(begin (js-set! obj "d" 2) (js-ref obj \'d))', '2');
    await ev('(list (js-has? obj "d") (js-delete! obj "d") (js-has? obj "d"))', '(#t #t #f)');
    await ev('(js-ref (alist->js \'((x . 1))) "x")', '1');
    await ev('(js-invoke (js-new (js-global "Date") 0) "getTime")', '0');
    await ev('(js->list (js-eval "new Set([1,2,3])"))', '(1 2 3)');
    await ev('(js->vector (js-eval "\'ab\'"))', '#("a" "b")');
    await ev('(js-ref (js-eval "[1]") (js-global "Symbol.iterator"))', '#<js-object function values>');
    await ev('(js-ref (js-obj "length" 3) #:length)', '3');
    await ev("(let ((l '(2 3))) (eq? (js-ref (list->js (list 1 l)) 1) l))", '#t');
    await ev("(js-ref (list->js '(1 (2 3)) #t) 1)", '#<js-object Array(2)>');
    await ev('(list (js-typeof 1) (js-typeof (expt 2 60)) (js-typeof js-null) (js-typeof (js-global "Math.max")) ' +
             '(js-typeof car) (js-typeof (void)))',
             '("number" "bigint" "object" "function" "function" "undefined")');
    await ev('(list (js-object? js-null) (js-same? js-null js-null) (js-nullish? (void)))', '(#f #t #t)');
    await ev('(list (equal? (js-global "Math") (js-global "Math")) (js-same? (js-global "Math") (js-global "Math")))',
             '(#t #t)');
    await ev('(js-instanceof? (js-eval "[]") (js-global "Array"))', '#t');
    await ev('(js->string (js-eval "[1,2]"))', '"1,2"');
    await ev('(js->bytevector (js-eval "new Uint16Array([258])"))', '#u8(2 1)');
    await ev('(js->number-vector (js-eval "new Int16Array([-1])"))', '#s16(-1)');
    // vectors cross as copies
    JS.send('(define v (vector 3 1 2))\n');
    await JS.prompt();
    await ev('(begin (js-invoke (vector->js v) "sort") v)', '#(3 1 2)');
    await fails('(js-invoke v "sort")', /Error: \(js-invoke\) bad argument type - not a JavaScript object: #\(3 1 2\)/);
    await fails('(js-set! 1 "a" 2)', /Error: \(js-set!\) bad argument type - not a JavaScript object: 1/);
    await fails('(js-ref obj (list 1))', /Error: \(js-ref\) bad argument type - not a property key/);
    JS.send('(define cv (vector 1)) (vector-set! cv 0 cv)\n');
    await JS.prompt();
    await fails('(js-call id cv)', /Error: \(js-call\) circular structure/);
    await fails("(js-call id (let loop ((i 0) (v '#())) (if (= i 600) v (loop (+ i 1) (vector v)))))",
                /Error: \(js-call\) too deeply nested/);
    await fails('(list->js (let ((l (list 1))) (set-cdr! l l) l))', /bad argument type - not a proper list/);
    await fails("(alist->js (let ((l (list (cons 'a 1)))) (set-cdr! l l) l))",
                /Error: \(alist->js\) bad argument type - not a proper list/, 5000);
    await fails('(js-obj "a")', /Error: \(js-obj\) odd number of arguments/);
  });

  await check('J5 Scheme procedures called from JavaScript', async () => {
    await ev('(js->list (js-invoke (js-eval "[1,2,3]") "map" (lambda (x) (* x x))))', '(1 4 9)');
    await ev('(js->list (js-invoke (js-eval "[1,2,3]") "map" (lambda args (length args))))', '(3 3 3)');
    await ev('(js->list (js-invoke (js-eval "[3,1,2]") "sort" (lambda (a b) (- a b))))', '(1 2 3)');
    await ev('(js-call (js-eval "f => f(g => g(7))") (lambda (h) (+ 1 (js-call h (lambda (x) (* x 10))))))', '71');
    await ev('(js-call (js-eval "f => typeof f()") (lambda () (values)))', '"undefined"');
    await ev('(js-call (js-eval "f => f()") (lambda () (values 1 2)))', '1');
    JS.send('(define o2 (js-obj "n" 5)) (js-set! o2 "get" (js-method (lambda (this) (js-ref this "n"))))\n');
    await JS.prompt();
    await ev('(js-invoke o2 "get")', '5');
    // js-function: the same function each time, for removeEventListener
    JS.send('(define hits 0) (define p (lambda (e) (set! hits (+ hits 1)))) (define f (js-function p)) ' +
            '(define et (js-new (js-global "EventTarget")))\n');
    await JS.prompt();
    await ev('(begin (js-invoke et "addEventListener" "x" f) ' +
             '(js-invoke et "dispatchEvent" (js-new (js-global "Event") "x")) hits)', '1');
    await ev('(begin (js-invoke et "removeEventListener" "x" f) ' +
             '(js-invoke et "dispatchEvent" (js-new (js-global "Event") "x")) hits)', '1');
    await ev('(js-object? f)', '#t');
    await ev('(begin (js-set! o2 "f" f) (eq? (js-ref o2 "f") p))', '#t');
    const ids = stats().schemeIds;
    JS.send('(js-release! f)\n');
    await JS.prompt();
    assert(stats().schemeIds === ids - 1, 'released: ' + JSON.stringify(stats()));
    await fails('(js-invoke o2 "f" 1)', /Error: \(js-invoke\) Error: released Scheme procedure/);
    await fails('(js-call f 1)', /Error: \(js-call\) released JavaScript object/);
    await ev('f', '#<js-object released>');
  });

  await check('J6 JavaScript errors are (exn js) conditions', async () => {
    await fails('(js-eval "null.x")', /Error: \(js-eval\) TypeError: /);
    await ev('(handle-exceptions e (list ((condition-predicate \'js) e) (get-condition-property e \'js \'name) ' +
             '(string? (get-condition-property e \'js \'stack))) (js-eval "throw new RangeError(\'r\')"))',
             '(#t "RangeError" #t)');
    await ev('(handle-exceptions e (list (get-condition-property e \'exn \'message) ' +
             '(get-condition-property e \'js \'name) (get-condition-property e \'js \'error)) (js-eval "throw 42"))',
             '("42" #f 42)');
    await fails('(js-eval "(")', /Error: \(js-eval\) SyntaxError: /);
    // what a Content-Security-Policy without 'unsafe-eval' makes eval throw
    await fails('(js-eval "throw new EvalError(\'Refused to evaluate a string as JavaScript because unsafe-eval ' +
                'is not an allowed source of script in the following Content Security Policy directive\')")',
                /Error: \(js-eval\) EvalError: the server's Content-Security-Policy for repl-worker.js forbids eval: JavaScript cells, ,js and js-eval need script-src 'unsafe-eval' there/);
    await ev('(+ 1 2)', '3');
  });

  await check('J7 Scheme errors cross JavaScript and are raised again as themselves', async () => {
    await ev('(js->list (js-call (js-eval "f => { try { f() } catch (e) { return [e.name, e.schemeMessage, ' +
             'e instanceof Error] } }") (lambda () (error "bad" 42))))', '("SchemeError" "bad: 42" #t)');
    await ev("(call/cc (lambda (k) (with-exception-handler k (lambda () (js-call (js-eval \"f => f()\") " +
             "(lambda () (raise 'boom)))))))", 'boom');
    await ev("(let ((c (make-property-condition 'mine))) (eq? c (call/cc (lambda (k) (with-exception-handler k " +
             "(lambda () (js-call (js-eval \"f => { try { f() } catch (e) { throw e } }\") (lambda () (abort c)))))))))",
             '#t');
    await ev("(guard (e (#t (list 'caught e))) (js-call (js-eval \"f => f()\") (lambda () (raise 'x))))", '(caught x)');
    await fails('(js-call (js-eval "f => f()") (lambda () (car 5)))', /Error: \(car\) bad argument type: 5/);
  });

  await check('J8 continuations leaving a call from JavaScript', async () => {
    await ev("(begin (define r (call/cc (lambda (k) (js-invoke (js-eval \"[1,2,3,4]\") \"forEach\" " +
             "(lambda (x . _) (when (> x 2) (k x)))) 'none))) (list r (js-await (js-eval \"Promise.resolve(5)\"))))",
             '(3 5)');
    JS.send('(define count 0)\n');
    await JS.prompt();
    await ev("(begin (call/cc (lambda (k) (js-call (js-eval \"f => f()\") (lambda () (dynamic-wind void " +
             "(lambda () (k 'x)) (lambda () (set! count (+ count 1)))))))) count)", '1');
    await ev("(call/cc (lambda (k) (js-call (js-eval \"f => { try { f() } catch (e) { return 'swallowed' } }\") " +
             "(lambda () (k 'escaped)))))", 'escaped');
    JS.send('(define g-ran #f)\n');
    await JS.prompt();
    await ev("(call/cc (lambda (k) (js-call (js-eval \"(f, g) => { try { f() } finally { g() } }\") " +
             "(lambda () (k 'out)) (lambda () (set! g-ran #t)))))", 'out');
    await ev('g-ran', '#f');
    await ev("(call/cc (lambda (k) (js-call (js-eval \"f => f()\") (lambda () (js-call (js-eval \"g => g()\") " +
             "(lambda () (k 'two)))))))", 'two');
    await ev('(+ 1 2)', '3');
    JS.send('(define kk #f) (js-call (js-eval "f => f()") (lambda () (call/cc (lambda (k) (set! kk k))) 1))\n');
    await JS.expectOut(val('1'));
    await JS.prompt();
    await fails('(kk 2)', /Error: re-entry into a call from JavaScript that has returned/);
    JS.send('(import (chicken continuation))\n');
    await JS.prompt();
    await ev('(reset (+ 1 (js-call (js-eval "f => f()") (lambda () (shift k 10)))))', '10');
    eq(stats().depth, 0, 'no op left');
  });

  await check('J9 exit inside a call from JavaScript', async () => {
    for (const [src, code] of [
      ['(js-call (js-eval "f => { try { f() } catch (e) { return \'swallowed\' } }") (lambda () (exit 3)))', 3],
      ['(js-call (js-eval "f => [1].map(f)") (lambda (x) (exit 4)))', 4]]) {
      const X = await session();
      await waitFor('prompt', () => /#;1> $/.test(X.all));
      X.send('(import js) ' + src + '\n');
      await waitFor('exit', () => X.exit || X.crash);
      assert(!X.crash, 'crash: ' + X.crash);
      eq(X.exit.code, code, 'exit code');
      assert(!/swallowed/.test(X.all), 'no swallowed: ' + X.all.slice(-200));
    }
    current = JS;
  });

  await check('J10 nesting: 50 levels, and unbounded recursion is an error', async () => {
    JS.send('(define bounce (js-eval "(f, n) => f(n)")) (define (down2 n) (if (= n 50) n (js-call bounce down2 (+ n 1))))\n');
    await JS.prompt();
    await ev('(down2 0)', '50');
    JS.send('(define (down n) (js-call bounce down (+ n 1)))\n');
    await JS.prompt();
    const t = now();
    await fails('(down 0)', /RangeError: too many nested calls between Scheme and JavaScript/);
    assert(now() - t < 20000, 'within 20 s');
    await ev('(+ 1 2)', '3');
    eq(stats().depth, 0, 'no op left');
  });

  await check('J11 js-await', async () => {
    await ev('(js-await (js-eval "Promise.resolve(42)"))', '42');
    await fails('(js-await (js-eval "Promise.reject(new TypeError(\'no\'))"))', /Error: \(js-await\) TypeError: no/);
    JS.send('(js-await (js-eval "new Promise(r => setTimeout(() => r(\'late\'), 100))"))\n');
    await waitFor('AWAITING', () => JS.statesSince().includes(AWAITING));
    const t = now(), p0 = JS.pumps.length;
    await JS.expectOut(val('"late"'));
    assert(JS.pumps.length - p0 < 10, 'no busy pumping: ' + (JS.pumps.length - p0) + ' pumps in ' + (now() - t) + ' ms');
    await JS.prompt();
    await ev('(js-await 5)', '5');
    await ev('(js-await (js-eval "({then(r){ r(9) }})"))', '9');
    await ev('(js-await (js-obj "a" 1))', '#<js-object Object>');
    // what is no thenable is itself, a handle too
    await ev('(let ((o (js-obj "a" 1)) (f (js-function car))) (list (eq? o (js-await o)) (eq? f (js-await f))))',
             '(#t #t)');
    // a Scheme error crossing the promise is raised again as itself
    await ev("(let ((c (make-property-condition 'mine))) (eq? c (call/cc (lambda (k) (with-exception-handler k " +
             "(lambda () (js-await (js-call (js-async-function (lambda () (abort c)))))))))))", '#t');
    eq(stats().awaits, 0, 'no slot left');
  });

  await check('J12 Stop during js-await', async () => {
    JS.send('(js-await (js-eval "new Promise(() => {})"))\n');
    await waitFor('AWAITING', () => JS.drv.state() === AWAITING);
    JS.interrupt();
    await JS.expectOut(/\*\*\* user interrupt \*\*\*/, 5000);
    await JS.prompt();
    eq(stats().awaits, 0, 'the slot given up');
    await ev('(+ 1 2)', '3');
  });

  await check('J13 calls from JavaScript that wait: during js-await, at the prompt, not during sleep', async () => {
    JS.send("(define log '())\n");
    await JS.prompt();
    await ev('(begin (js-call (js-eval "f => setTimeout(() => f(\'t\'), 10)") (lambda (x) (set! log (cons x log)))) ' +
             '(js-await (js-eval "new Promise(r => setTimeout(r, 50))")) log)', '("t")');
    // at the prompt, with no input
    JS.send('(begin (js-call (js-eval "f => setTimeout(f, 20)") (lambda () (display "tick\\n"))) (void))\n');
    await JS.prompt();
    JS.mark();
    await JS.expectOut(/^tick\n$/, 2000);
    await JS.expectState(WAITING);
    JS.send('(define l2 #f)\n');
    await JS.prompt();
    await ev('(begin (js-call (js-eval "f => setTimeout(f, 10)") (lambda () (set! l2 \'ran))) (sleep 1) l2)', '#f');
    await ev('l2', 'ran');
    await ev('(js-await (js-call (js-eval "f => new Promise(r => setTimeout(() => r(f(20)), 0))") (lambda (x) (+ x 1))))',
             '21');
    // an error in a timer callback at the prompt
    const e0 = JS.err.length;
    JS.send("(begin (js-call (js-eval \"f => setTimeout(f, 10)\") (lambda () (car '()))) (void))\n");
    await JS.prompt();
    await waitFor('the error', () => /Error in a call from JavaScript: \(car\) bad argument type: \(\)/.test(JS.err.slice(e0)));
    await ev('(+ 1 2)', '3');
    // Stop in a call run at the prompt ends that call only
    JS.send('(begin (js-call (js-eval "f => setTimeout(f, 10)") (lambda () (let loop () (loop)))) (void))\n');
    await JS.prompt();
    await waitFor('BUSY', () => JS.statesSince().filter(s => s === BUSY).length >= 2);
    JS.interrupt();
    await JS.expectOut(/Error in a call from JavaScript: \*\*\* user interrupt \*\*\*\n/, 5000);
    await JS.expectState(WAITING);
    await ev('(+ 1 2)', '3');
    // a context of its own: not the caller's ports
    JS.send('(import (chicken port))\n');
    await JS.prompt();
    await ev('(with-output-to-string (lambda () (js-call (js-eval "f => setTimeout(f, 10)") (lambda () (display "out\\n"))) ' +
             '(js-await (js-eval "new Promise(r => setTimeout(r, 50))"))))', '""');
    assert(/^out\n/m.test(JS.since()), 'out on stdout: ' + JSON.stringify(JS.since()));
    // Stop in a call run by js-await interrupts the evaluation
    JS.send('(js-await (js-call (js-eval "f => new Promise(r => setTimeout(() => r(f()), 0))") (lambda () (let loop () (loop)))))\n');
    await waitFor('BUSY', () => JS.statesSince().filter(s => s === BUSY).length >= 2);
    JS.interrupt();
    await JS.expectOut(/\*\*\* user interrupt \*\*\*/, 5000);
    await JS.prompt();
    assert(!/Error in a call from JavaScript/.test(JS.since()), 'reported once: ' + JSON.stringify(JS.since()));
    eq([stats().queued, stats().running, stats().awaits], [0, 0, 0], 'nothing left');
    await ev('(js-await (js-call (js-async-function (lambda (x) (* x 2))) 21))', '42');
    await ev('(js-await (js-call (js-async-function (lambda () (js-await (js-eval "Promise.resolve(1)"))))))', '1');
    // a call queued during an evaluation (js-async-function): at the next prompt
    JS.send('(define l3 #f)\n');
    await JS.prompt();
    await ev('(begin (js-call (js-async-function (lambda () (set! l3 \'ran)))) l3)', '#f');
    await waitFor('the queued call', () => stats().queued === 0 && stats().running === 0);
    await ev('l3', 'ran');
    // released: its queued calls are rejected
    await ev('(let* ((f (js-async-function (lambda () 1))) (p (js-call f))) (js-release! f) ' +
             '(handle-exceptions e (get-condition-property e \'exn \'message) (js-await p)))',
             '"Error: released Scheme procedure"');
  });

  await check('J14 js-await inside a call from JavaScript', async () => {
    await fails('(js-call (js-eval "f => f()") (lambda () (js-await (js-eval "Promise.resolve(1)"))))',
                /Error: \(js-await\) cannot wait inside a call from JavaScript/);
    await ev('(js-call (js-eval "f => f()") (lambda () (js-await 5)))', '5');
  });

  await check('J15 reading stdin inside a call from JavaScript is an error', async () => {
    const t = now();
    await fails('(js-call (js-eval "f => f()") (lambda () (read-line)))',
                /cannot read standard input inside a call from JavaScript/, 2000);
    assert(now() - t < 2000, 'no spinning');
    await ev('(+ 1 2)', '3');
  });

  await check('J16 Stop inside a call from JavaScript interrupts the evaluation', async () => {
    globalThis.__stop = () => JS.drv.module._webrepl_interrupt();
    JS.send('(js-call (js-eval "f => { __stop(); let n = 0; for (let i = 0; i < 3; i++) { try { f() } catch (e) ' +
            '{ n++ } } globalThis.__n = n; return \'done\' }") (lambda () (let loop ((i 0)) (if (< i 1000000) ' +
            '(loop (+ i 1))))))\n');
    await JS.prompt();
    assert(/user interrupt/.test(JS.since()), 'interrupted: ' + JSON.stringify(JS.since()));
    assert(!/"done"/.test(JS.since()), 'no "done"');
    await ev('(js-eval "__n")', '3');
  });

  await check('J17 handles are released by the garbage collector and by js-release!', async () => {
    JS.send('(import (chicken gc))\n,ch\n');
    await JS.prompt();
    await JS.prompt();
    const b = stats().handles;
    JS.send('(begin (do ((i 0 (+ i 1))) ((= i 1000)) (js-eval "({})")) (void))\n');
    await JS.prompt();
    JS.send('(begin (gc #t) (void))\n');
    await JS.prompt();
    assert(stats().handles <= b + 1, 'released: ' + b + ' -> ' + JSON.stringify(stats()));
    JS.send('(define h (js-eval "({})"))\n');
    await JS.prompt();
    const h = stats().handles;
    JS.send('(js-release! h)\n');
    await JS.prompt();
    eq(stats().handles, h - 1, 'released at once');
    JS.send('(js-release! h)\n');
    await JS.prompt();
    eq(stats().handles, h - 1, 'a second release');
    await ev('h', '#<js-object released>');
    // the wrappers JavaScript's collector frees (FinalizationRegistry)
    // free their entries at the next op
    const ids = stats().schemeIds;
    JS.send('(define k0 (js-eval "f => 0")) (begin (do ((i 0 (+ i 1))) ((= i 100000)) (js-call k0 car)) (void))\n');
    await JS.prompt(60000);
    for (let i = 0; i < 5; i++) { gc(); await new Promise(r => setImmediate(r)); }
    JS.send('(begin (js-call k0 car) (gc #t) (void))\n');
    await JS.prompt();
    assert(stats().schemeIds < ids + 1000, 'wrappers freed: ' + JSON.stringify(stats()));
  });

  await check('J21 a Scheme object held only by a queued call or a settled promise is not freed', async () => {
    JS.send('(define got #f) (define g (js-function (lambda (x) (set! got x)))) ' +
            '(define mk (js-eval "v => new Promise(r => { globalThis.__r = () => r(v) })")) ' +
            '(js-set! (js-global) "__gc" (js-function (lambda () (gc #t)))) ' +
            '(js-set! (js-global) "__busy" (js-function (lambda () (let loop ((i 0)) (if (< i 3000000) (loop (+ i 1))))))) ' +
            '(js-call (js-eval "(f, x) => { globalThis.__q = () => f(x) }") g (list 1 2 3))\n');
    await JS.prompt();
    const collect = async () => { for (let i = 0; i < 5; i++) { gc(); await sleep(20); } };
    // queued while Scheme computes, its output held back (canRun): the
    // argument is held by the queue only
    JS.high = 0;
    JS.send('(let loop ((i 0)) (if (< i 3000000) (loop (+ i 1))))\n');
    await waitFor('held back', () => JS.drv.state() === BUSY);
    globalThis.__q();
    delete globalThis.__q;
    await collect();
    JS.high = Infinity;
    JS.drv.resumeOutput();
    await JS.prompt();
    await waitFor('the queued call', () => stats().queued === 0 && stats().running === 0);
    await ev('got', '(1 2 3)');
    // the value js-await waits for, once the promise is gone: held by
    // the slot only, while a call the wait runs computes, held back
    JS.send('(js-await (js-call mk (list 4 5)))\n');
    await waitFor('AWAITING', () => JS.drv.state() === AWAITING);
    globalThis.__gc();
    await sleep(100);
    await waitFor('AWAITING', () => JS.drv.state() === AWAITING);
    JS.high = 0;
    globalThis.__busy();
    await waitFor('held back', () => JS.drv.state() === BUSY);
    const r = globalThis.__r;
    delete globalThis.__r;
    r();
    await collect();
    JS.high = Infinity;
    JS.drv.resumeOutput();
    await JS.expectOut(val('(4 5)'));
    await JS.prompt();
    eq(stats().awaits, 0, 'no slot left');
  });

  await check('J22 re-entering a wait that has ended is an error', async () => {
    JS.send('(define kw #f)\n');
    await JS.prompt();
    await ev('(js-await (js-call (js-async-function (lambda () (call/cc (lambda (c) (set! kw c) 1))))))', '1');
    await fails('(kw 5)', /Error: \(js-await\) re-entry into a wait that has ended/, 3000);
    eq(stats().awaits, 0, 'no slot');
    await ev('(+ 1 2)', '3');
  });

  await check('J23 queued calls settle in the order they ran; user code never runs in a settlement', async () => {
    // g1 returns, then g2 raises: g1's promise settles first
    globalThis.__order = [];
    const e0 = JS.err.length;
    JS.send('(js-call (js-eval "(g1, g2) => setTimeout(() => { g1().then(() => __order.push(\'g1\')); ' +
            'g2().catch(() => __order.push(\'g2\')) }, 0)") (lambda () 1) (lambda () (raise \'no)))\n');
    // (the calls run at the prompt: their output may come after it)
    await waitFor('both settled', () => globalThis.__order.length === 2, 2000);
    eq(globalThis.__order, ['g1', 'g2'], 'order');
    await waitFor('the error', () => /Error in a call from JavaScript: uncaught exception: no/.test(JS.err.slice(e0)));
    await JS.expectState(WAITING);
    // a species getter of Promise and a setter on Error.prototype, the
    // user's, set by the calls themselves: neither runs when a call is
    // settled or a callback fails
    const species = Object.getOwnPropertyDescriptor(Promise, Symbol.species);
    globalThis.__break = () => {
      Object.defineProperty(Promise, Symbol.species, { get() { throw new Error('species') }, configurable: true });
      Object.defineProperty(Error.prototype, 'schemeMessage', { set(v) { throw new Error('setter') }, configurable: true });
    };
    const mend = () => {
      Object.defineProperty(Promise, Symbol.species, species);
      delete Error.prototype.schemeMessage;
    };
    try {
      JS.send('(js-call (js-eval "f => setTimeout(async () => { globalThis.__got = await f(41) }, 0)") ' +
              '(lambda (x) (js-call (js-global "__break")) (+ x 1)))\n');
      await waitFor('resolved', () => globalThis.__got === 42, 2000);
      mend();
      await JS.prompt();
      JS.send('(js-call (js-eval "f => setTimeout(async () => { try { await f() } catch (e) { globalThis.__msg = ' +
              'e.schemeMessage } }, 0)") (lambda () (js-call (js-global "__break")) (error "no")))\n');
      await waitFor('rejected', () => globalThis.__msg === 'no', 2000);
      mend();
      await JS.expectOut(/Error in a call from JavaScript: no\n/);
      await JS.expectState(WAITING);
      await ev('(js->list (js-call (js-eval "f => { try { f() } catch (e) { return [e.name, e.schemeMessage] } }") ' +
               '(lambda () (js-call (js-global "__break")) (error "bad" 42))))', '("SchemeError" "bad: 42")');
    } finally { mend(); }
    assert(!JS.crash, 'no crash: ' + JS.crash);
  });

  await check('J24 an error that cannot cross JavaScript still leaves the call', async () => {
    JS.send('(define f0 (js-function (lambda () (error "x")))) (define call0 (js-eval "f => f()"))\n');
    await JS.prompt();
    JS.send('(set! ##webjs#crossing-hook (lambda () (error "hook")))\n');
    await JS.prompt();
    await fails('(js-call call0 f0)', /Error: \(js-call\) Error: x/, 3000);
    JS.send('(set! ##webjs#crossing-hook (lambda () #f))\n');
    await JS.prompt();
    await ev('(js-call call0 (lambda () (+ 1 2)))', '3');
    eq(stats().depth, 0, 'no op left');
  });

  await check('J18 two modules in one realm keep their bridges apart', async () => {
    const A = JS, B = await session();
    bridged.push(B);
    await waitFor('prompt', () => /#;1> $/.test(B.all));
    assert(A.drv.module.webjs !== B.drv.module.webjs, 'a bridge each');
    A.send('(js-set! (js-global) "__fa" (lambda () (display "A\\n")))\n');
    await A.prompt();
    B.send('(import js) (js-set! (js-global) "__fb" (lambda () (display "B\\n")))\n');
    await B.prompt();
    A.send('(begin (js-eval "setTimeout(() => { __fa(); __fb(); }, 10)") (void))\n');
    await A.prompt();
    A.mark();
    B.mark();
    await A.expectOut(/^A\n$/, 2000);
    await B.expectOut(/^B\n$/, 2000);
    await sleep(50);
    assert(!/B/.test(A.since()) && !/A/.test(B.since()), 'each in its own: ' + J([A.since(), B.since()]));
    // B's op runs A's function, which A does not wait on: queued in A
    B.send('(js-eval "__fa()")\n');
    await B.expectOut(val('#<js-object Promise>'));
    await A.expectOut(/^A\nA\n$/, 2000);
    current = A;
  });

  await check('J20 the console writes to the standard ports, in order', async () => {
    globalThis.__wjs = JS.drv.module.webjs;
    JS.send('(begin (display "a") (js-eval "__wjs.console(1, [\'b\', 2, [1, \\"x\\"], {k: null}, 3n, undefined])") ' +
            '(display "c\\n") (void))\n');
    await JS.expectOut(/^ab 2 \[1,"x"\] \{"k":null\} 3n undefined\nc\n/);
    await JS.prompt();
    const e0 = JS.err.length;
    JS.send('(begin (js-eval "__wjs.console(2, [new Error(\'x\')])") (void))\n');
    await JS.prompt();
    assert(/^Error: x\n    at /.test(JS.err.slice(e0)), 'an error with its stack: ' + JSON.stringify(JS.err.slice(e0)));
    // between inputs: straight to the output
    JS.mark();
    JS.drv.module.webjs.console(1, ['idle']);
    assert(/^idle\n$/.test(JS.since()), 'idle: ' + JSON.stringify(JS.since()));
    // inside with-output-to-string, captured
    JS.send('(import (chicken port))\n');
    await JS.prompt();
    await ev('(with-output-to-string (lambda () (js-eval "__wjs.console(1, [\'in\'])")))', '"in\\n"');
  });

  await check('J19 redefining the exports and library procedures does not break the bridge', async () => {
    const X = await session();
    JS = X;
    bridged.push(X);
    await waitFor('prompt', () => /#;1> $/.test(X.all));
    X.send('(import js)\n');
    await X.prompt();
    X.send("(define (js-call . x) 'clobbered)\n");
    await X.prompt();
    await ev('(js-invoke (js-eval "[1,2]") "join" "-")', '"1-2"');
    // (before: csi's own named let needs reverse)
    X.send("(define (procs n) (let loop ((i 0) (l '())) (if (= i n) l (loop (+ i 1) (cons (lambda () i) l)))))\n");
    await X.prompt();
    X.send("(define (apply . x) 'x) (define (list? x) #f) (define (reverse x) x) (define (make-vector . x) 0)\n");
    await X.prompt();
    await ev("(js->list (list->js '(1 2)))", '(1 2)');
    await ev('(js->list (js-invoke (js-eval "[1,2,3]") "map" (lambda (x) (* x x))))', '(1 4 9)');
    // 200 procedures crossing: the table of Scheme objects grows
    await ev('(length (js->list (list->js (procs 200))))', '200');
  });

  // ---- R-JS: the REPL's ,js (webjs.scm), in a session of its own

  await check('R-JS1 ,js prints the value as JavaScript text', async () => {
    const X = await session();
    JS = X;
    bridged.push(X);
    await waitFor('prompt', () => /#;1> $/.test(X.all));
    await ev(',js 1 + 2', '3');
    await ev(",js 'a' + 'b'", '"ab"');
    X.send(',js undefined\n');
    await X.prompt();
    assert(/^#;\d+> $/.test(X.since()), 'undefined prints nothing: ' + JSON.stringify(X.since()));
    await ev(",js [1, 'x', {a: 1}]", '[1, "x", {a: 1}]');
  });

  await check('R-JS2 names persist across ,js lines and reach (import js)', async () => {
    for (const src of [',js const k = 5', ',js let s = k * 2', ',js class P {}']) {
      JS.send(src + '\n');
      await JS.prompt();
      assert(/^#;\d+> $/.test(JS.since()), src + ': nothing printed: ' + JSON.stringify(JS.since()));
    }
    await ev(',js [k, s, typeof P]', '[5, 10, "function"]');
    JS.send('(import js)\n');
    await JS.prompt();
    await ev('(js-global "k")', '5');
  });

  await check('R-JS3 a promise is waited for (AWAITING); Stop ends the wait', async () => {
    await ev(',js new Promise(r => setTimeout(() => r(7), 50))', '7');
    assert(JS.statesSince().includes(AWAITING), 'AWAITING: ' + JS.statesSince());
    JS.send(',js new Promise(() => {})\n');
    await waitFor('AWAITING', () => JS.drv.state() === AWAITING);
    JS.interrupt();
    await JS.expectOut(/\*\*\* user interrupt \*\*\*/, 5000);
    await JS.prompt();
    eq(stats().awaits, 0, 'the slot given up');
  });

  await check('R-JS4 a JavaScript error is reported with its stack; the REPL goes on', async () => {
    JS.send(",js function bad() { throw new Error('boom') }\n");
    await JS.prompt();
    await fails(',js bad()', /Error: Error: boom\n[\s\S]*JavaScript stack:[\s\S]*js\[\d+\]:1\t {2}bad\t<--\n/);
    assert(/#;\d+> $/.test(JS.since()), 'a prompt after it');
    await ev('(+ 1 2)', '3');
    await fails(',js null.x', /Error: TypeError/);
    // ,exn describes it
    JS.send(',exn\n');
    await JS.expectOut(/TypeError/);
    await JS.prompt();
  });

  await check('R-JS5 multi-line ,js: the lines entered with it, more while incomplete', async () => {
    JS.send(',js function f(x) {\n  return x * 2\n}\n');
    await JS.prompt();
    await ev(',js f(21)', '42');
    await ev(',js const a1 = 1\nconst b1 = a1 + 1\nb1', '2');
    JS.send(',js [1,\n');
    await JS.expectState(WAITING);
    await sleep(100);
    assert(!/#;\d+> /.test(JS.since()), 'no prompt while incomplete: ' + JSON.stringify(JS.since()));
    JS.send('2]\n');
    await JS.expectOut(val('[1, 2]'));
    await JS.prompt();
    // ",js" alone takes the next line, also with blanks after it
    for (const cmd of [',js\n', ',js \n', ',js\t \n']) {
      JS.send(cmd);
      await JS.expectState(WAITING);
      await sleep(50);
      assert(!/#;\d+> /.test(JS.since()), J(cmd) + ': no prompt before the next line: ' + J(JS.since()));
      JS.send('6 * 7\n');
      await JS.expectOut(val('42'));
      await JS.prompt();
    }
  });

  await check('R-JS9 ,js takes no line typed after it while csi was busy', async () => {
    JS.send('(let loop ((i 0)) (if (< i 3000000) (loop (+ i 1)) (quote busy-done)))\n');
    await waitFor('busy', () => JS.drv.state() === BUSY);
    // two submissions: two feeds
    JS.drv.feed(',js 1 + 1\n');
    JS.drv.feed('(+ 40 2)\n');
    await JS.expectOut(/busy-done\n[\s\S]*42\n#;\d+> $/, 20000);
    assert(val('2').test(JS.since()) && !/Error/.test(JS.since()), 'each its own: ' + J(JS.since()));
    await JS.prompt();
    // and one submission of two lines is one ,js source
    await ev(',js const t9 = 4\nt9 * 10', '40');
  });

  await check('R-JS6 ,? lists ,js', async () => {
    JS.send(',?\n');
    await JS.prompt();
    assert(/\n ,js SOURCE {8}evaluate /.test(JS.since()), 'listed: ' + JSON.stringify(JS.since().slice(-400)));
  });

  await check('R-JS8 top-level await is a helpful SyntaxError', async () => {
    await fails(',js await 1', /SyntaxError: await is not allowed at the top level of a JavaScript cell or a ,js line/);
    await ev(',js (async () => { const x = await Promise.resolve(3); return x })()', '3');
  });

  if (S.crash) { failures++; console.log('not ok - crash: ' + S.crash); }
  if (/RangeError|RuntimeError|Aborted/.test(S.all)) {
    failures++;
    console.log('not ok - engine error in output');
  }
  // (J10's RangeError is the bridge's own)
  for (const X of bridged) {
    if (X.crash) { failures++; console.log('not ok - crash of a J session: ' + X.crash); }
    if (/RuntimeError|Aborted/.test(X.all)) { failures++; console.log('not ok - engine error in a J session'); }
  }
  console.log(`# ${passes} passed, ${failures} failed in ${((now() - t0) / 1000).toFixed(1)} s`);
  // Emscripten's node quit_ leaves process.exitCode set by (exit 7).
  process.exit(failures ? 1 : 0);
})();
