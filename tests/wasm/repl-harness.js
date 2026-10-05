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
// Runs the REPL core cases of the plan (README, WebAssembly section) and
// exits with status 1 if any fails.  Run it once in default node and once
// with "--liftoff --no-wasm-tier-up --stack-size=900".
//
// With --arch=A, the modules tested are those of the architecture A of
// a page with several (make wasm WASM_WEB_ARCHS="wasm64 wasm32"), in
// WEB_DIR/A unless A is the page's own (its chicken-wasm-arch).

'use strict';
const fs = require('fs');
const path = require('path');

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
const { RUNNING, WAITING, BUSY, EXITED, SLEEPING } = Driver;
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
    onState: st => s.states.push(st),
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

  if (S.crash) { failures++; console.log('not ok - crash: ' + S.crash); }
  if (/RangeError|RuntimeError|Aborted/.test(S.all)) {
    failures++;
    console.log('not ok - engine error in output');
  }
  console.log(`# ${passes} passed, ${failures} failed in ${((now() - t0) / 1000).toFixed(1)} s`);
  // Emscripten's node quit_ leaves process.exitCode set by (exit 7).
  process.exit(failures ? 1 : 0);
})();
