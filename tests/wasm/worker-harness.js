// worker-harness.js - run the real repl-worker.js in worker_threads, without a browser
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
// usage: node [v8 flags] worker-harness.js WEB_DIR [--arch=A] [--package=DIR]
//
// WEB_DIR is a built web directory (build-wasm/web).  Each session runs
// WEB_DIR/repl-worker.js, unmodified, in a worker_threads Worker with a
// 1 MB stack (about what browsers give workers), behind a small shim for
// the Web Worker globals it uses (self, location, importScripts,
// postMessage, onmessage).  The test plays the page: it sends the
// messages of repl-worker.js's protocol and acks the output it gets.
// Exits with status 1 if any case fails.
//
// With --arch=A, the modules tested are those of the architecture A of
// a page with several (make wasm WASM_WEB_ARCHS="wasm64 wasm32"), in
// WEB_DIR/A unless A is the page's own (its chicken-wasm-arch); then
// repl-worker.js gets that directory in its dir= query, as on the page.
//
// With --package=DIR (the packages lane of make wasm-check) only the
// package cases run: DIR is the package of the test eggs made by make
// wasm-package (holding manifest.json), whose build for the ABI of the
// modules tested (the page's chicken-wasm-builds) is written under
// /packages, as the page does, in init's files or with writeFiles.

'use strict';
const { Worker } = require('worker_threads');
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
const pageHtml = fs.readFileSync(path.join(webDir, 'index.html'), 'utf8');
const { arch, sub } = moduleArch(pageHtml);
const packageDir = (process.argv.find(a => /^--package=/.test(a)) || '').slice(10);
const wasmModule = new WebAssembly.Module(fs.readFileSync(path.join(webDir, sub, 'chicken-repl.wasm')));
console.log('# ' + arch + ' modules in ' + path.join(webDir, sub));

const prelude = `
  'use strict';
  const { parentPort, workerData } = require('worker_threads');
  const fs = require('fs'), path = require('path'), vm = require('vm');
  const dir = workerData.dir;
  globalThis.self = globalThis;
  self.location = { search: workerData.sub ? '?dir=' + encodeURIComponent(workerData.sub) : '' };
  globalThis.require = require;               // emscripten's node support
  delete globalThis.module;                   // eval workers define these:
  delete globalThis.exports;                  // UMD would pick CommonJS
  globalThis.__dirname = path.join(dir, workerData.sub);
  globalThis.onmessage = null;
  globalThis.importScripts = (...files) => files.forEach(p =>
    vm.runInThisContext(fs.readFileSync(path.join(dir, p.split('?')[0]), 'utf8'), { filename: p }));
  globalThis.postMessage = m => parentPort.postMessage(m);
  // the worker's message, error and unhandledrejection events, which
  // repl-worker.js listens to (the page's messages, and what user
  // JavaScript leaves uncaught), and dispatchEvent, whose events are
  // not isTrusted (Node's Event); every exception left uncaught is also
  // told to the harness ('__uncaught'), which only the cases that
  // expect one allow
  const listeners = {};
  globalThis.addEventListener = (t, f) => { (listeners[t] = listeners[t] || []).push(f); };
  const fire = (t, ev) => {
    const l = listeners[t] || [];
    for (const f of l) { f(ev); if (ev.stopped) break; }
    return l.length > 0;
  };
  globalThis.dispatchEvent = ev => { fire(ev.type, ev); return true; };
  const uncaught = (what, x) => parentPort.postMessage({ type: '__uncaught', message: what + String((x && x.stack) || x) });
  process.on('uncaughtException', e => {
    uncaught('', e);
    if (!fire('error', { error: e, message: String((e && e.message) || e), preventDefault() {} })) throw e;
  });
  process.on('unhandledRejection', r => {
    uncaught('(in promise) ', r);
    fire('unhandledrejection', { reason: r, preventDefault() {} });
  });
  // Node's MessagePort drains up to 1000 queued messages per wakeup, and
  // the worker's pump re-posts one per slice: a busy csi would starve the
  // parentPort (no Stop for ~50 s).  Browsers queue both as ordinary
  // tasks and interleave them, so give the worker a fair zero-delay
  // channel built on setImmediate, which lets the poll phase run.
  globalThis.MessageChannel = class {
    constructor() {
      const port1 = { onmessage: null };
      this.port1 = port1;
      this.port2 = { postMessage: d => setImmediate(() => port1.onmessage && port1.onmessage({ data: d })) };
    }
  };
  // (a listener that stops its propagation is the last to get it)
  parentPort.on('message', d => fire('message', { data: d, stopImmediatePropagation() { this.stopped = true; } }));
  importScripts('repl-worker.js');
`;

let failures = 0, passes = 0;
const now = () => performance.now();
const sleep = ms => new Promise(r => setTimeout(r, ms));
function assert(c, msg) { if (!c) throw new Error('assertion failed: ' + msg); }

async function waitFor(what, pred, ms = 20000) {
  const t0 = now();
  for (;;) {
    const v = pred();
    if (v) return v;
    if (now() - t0 > ms) throw new Error('timed out after ' + ms + ' ms waiting for ' + what);
    await sleep(5);
  }
}

let current = null;
// what the workers left uncaught ('__uncaught', see the prelude)
const uncaught = [];

// One worker.  `autoAck' acks every output message, as the page does
// after rendering it.
function session(init, { autoAck = true } = {}) {
  const s = { msgs: [], out: '', states: [], ready: false, exit: null, crash: null,
              markAt: 0, stateAt: 0, error: null, acked: 0 };
  s.w = new Worker(prelude, { eval: true, workerData: { dir: webDir, sub },
                              resourceLimits: { stackSizeMb: 1 } });
  s.w.on('error', e => { s.error = e; });
  s.w.on('message', m => {
    if (m.type === '__uncaught') { uncaught.push(m.message); return; }
    s.msgs.push(m);
    switch (m.type) {
    case 'ready':  assert(!s.states.length, 'ready precedes the first state'); s.ready = true; break;
    case 'output':
      s.out += m.text;
      if (autoAck) { s.acked += m.text.length; s.w.postMessage({ type: 'ack', bytes: m.text.length }); }
      break;
    case 'state':  s.states.push(m.state); break;
    case 'exit':   s.exit = m.code; break;
    case 'crash':  s.crash = m.message; break;
    }
  });
  s.post = m => s.w.postMessage(m);
  s.mark = () => { s.markAt = s.out.length; s.stateAt = s.states.length; };
  s.since = () => s.out.slice(s.markAt);
  s.send = t => { s.mark(); s.post({ type: 'input', text: t, eof: false }); };
  s.expectOut = (re, ms) => waitFor('output ' + re, () => {
    if (s.crash) throw new Error('crash: ' + s.crash);
    if (s.error) throw new Error('worker error: ' + s.error);
    return re.test(s.since());
  }, ms);
  s.prompt = async ms => {
    await s.expectOut(/#;\d+> $/, ms);
    await waitFor('WAITING', () => s.states.length > s.stateAt && s.states[s.states.length - 1] === 1, ms);
  };
  s.reply = (type, id, ms) => waitFor(type + ' reply ' + id,
    () => s.msgs.find(m => m.id === id && (m.type === type || m.type === 'error')), ms);
  s.close = () => s.w.terminate();
  s.post(Object.assign({ type: 'init', args: ['-n'], csirc: null, files: [], sliceMs: 50, wasmModule }, init));
  current = s;
  return s;
}

// UNCAUGHT: the case leaves exceptions uncaught in the worker (else
// any is a failure: a bug of repl-worker.js would be one)
async function check(name, f, { uncaught: allowed = false } = {}) {
  const u0 = uncaught.length;
  try {
    await f();
    if (!allowed && uncaught.length > u0)
      throw new Error('left uncaught in the worker: ' + uncaught.slice(u0).join('\n'));
    passes++;
    console.log('ok - ' + name);
  } catch (e) {
    failures++;
    console.log('not ok - ' + name + '\n  ' + String((e && e.message) || e));
    if (current) console.log('  output since the last input:\n  | ' +
                             current.since().slice(-600).split('\n').join('\n  | '));
  }
}

const val = v => new RegExp('(^|> )' + v.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\n', 'm');

// the files of the package's build for the modules tested, under
// /packages: the build of their ABI (the third field of their entry in
// chicken-wasm-builds)
function packageFiles(dir) {
  const entry = (pageMeta(pageHtml, 'chicken-wasm-builds') || '').split(/\s+/)
    .map(w => w.split(':')).find(f => f[0] === arch);
  if (!entry || !entry[2]) throw new Error('the page lists no ABI for ' + arch);
  const { readPackage } = require(path.join(__dirname, '..', '..', 'emscripten', 'wasm-package.js'));
  return readPackage(dir, { abi: entry[2] }).files.map(f => ({ path: '/packages/' + f.path, data: f.data }));
}

async function packageCases() {
  const t0 = now();
  const files = packageFiles(packageDir);
  const report = '(10 18 42 42 2 1)';
  let P;

  await check('P1 package files in init: import an extension of the package', async () => {
    P = session({ files });
    await waitFor('ready', () => P.ready || P.crash || P.error, 30000);
    assert(P.ready, 'ready: ' + (P.crash || P.error));
    await P.prompt(30000);
    P.send('(import wasm-egg-b) (egg-b-report)\n');
    await P.expectOut(val(report), 30000);
    await P.prompt();
  });
  if (!P || !P.ready) { console.log('cannot continue'); process.exit(1); }

  await check('P2 GC and continuations through the frames of a side module', async () => {
    P.send('(import wasm-egg-a (chicken gc)) (length (egg-a-walk (lambda (i v) (when (= i 500) (gc #t)) ' +
           '(make-string 100 #\\x)) 100000))\n');
    await P.expectOut(val('100000'), 30000);
    await P.prompt();
    P.send('(call-with-current-continuation (lambda (k) (egg-a-walk (lambda (i v) (if (= i 500) (k (quote escaped)) i)) 1000)))\n');
    await P.expectOut(val('escaped'));
    await P.prompt();
    P.send('(let* ((r #f) (n 0) (res (egg-a-walk (lambda (i v) (if (= i 3) (call-with-current-continuation (lambda (k) ' +
           '(set! r k) i)) i)) 5))) (set! n (+ n 1)) (if (< n 3) (r (* 10 n)) (list res n)))\n');
    await P.expectOut(val('((0 1 2 20 4) 3)'));
    await P.prompt();
  });

  await check('P3 an include file of the package, from /packages/share', async () => {
    P.send('(include "wasm-egg-a-shared.scm") egg-a-shared-value\n');
    await P.expectOut(val('7'));
    await P.prompt();
  });
  // An exit out of the callback leaves its C frames below and the
  // runtime's restart point in them: the REPL must still yield (to wait
  // for input) at its next prompt.  A sleep in a callback cannot yield.
  await check('P5 an error in Scheme called back from C is reported, and the REPL takes input again', async () => {
    P.send("(egg-a-call (lambda () (car '())))\n");
    await P.expectOut(/Error: \(car\) bad argument type/, 30000);
    await P.prompt(30000);
    P.send('(egg-a-call (lambda () 42))\n');
    await P.expectOut(val('42'), 30000);
    await P.prompt();
    P.send("(handle-exceptions e 'caught (egg-a-call (lambda () (car '()))))\n");
    await P.expectOut(val('caught'), 30000);
    await P.prompt();
    P.send("(call-with-current-continuation (lambda (k) (egg-a-call (lambda () (k 'escaped)))))\n");
    await P.expectOut(val('escaped'), 30000);
    await P.prompt();
    P.send("(egg-a-call (lambda () (sleep 1) 'slept)) (egg-a-call (lambda () (sleep 1) (egg-a-call (lambda () 'nested))))\n");
    await P.expectOut(/slept\n(#;\d+> )?nested\n/, 30000);
    await P.prompt();
  });
  await P.close();

  await check('P4 writeFiles after ready: acked once, then the package imports', async () => {
    const W = session({});
    try {
      await waitFor('ready', () => W.ready || W.crash, 30000);
      await W.prompt(30000);
      W.post({ type: 'writeFiles', id: 71, files });
      const r = await W.reply('ack', 71);
      assert(r.type === 'ack', 'acked, got ' + JSON.stringify(r));
      await sleep(100);
      assert(W.msgs.filter(m => m.id === 71).length === 1, 'one reply');
      W.send('(import wasm-egg-b) (egg-b-report)\n');
      await W.expectOut(val(report), 30000);
      await W.prompt();
    } finally { await W.close(); }
  });

  console.log('# ' + passes + ' passed, ' + failures + ' failed in ' +
              ((now() - t0) / 1000).toFixed(1) + ' s');
  process.exit(failures ? 1 : 0);
}

(async () => {
  if (packageDir) return packageCases();
  const t0 = now();
  let S;

  await check('1 init, ready, then state; banner and prompt', async () => {
    S = session({});
    await waitFor('ready', () => S.ready || S.crash || S.error, 30000);
    assert(S.ready, 'ready: ' + (S.crash || S.error));
    await S.prompt(30000);
    assert(/CHICKEN/.test(S.out), 'banner');
  });
  if (!S || !S.ready) { console.log('cannot continue'); process.exit(1); }

  await check('2 input (+ 1 2) gives 3', async () => {
    S.send('(+ 1 2)\n');
    await S.expectOut(val('3'));
    await S.prompt();
  });

  await check('3 endless loop, interrupt, then the REPL goes on', async () => {
    S.send('(let loop () (loop))\n');
    await waitFor('two BUSY states', () => S.states.slice(S.stateAt).filter(s => s === 2).length >= 2);
    const t = now();
    S.mark();
    S.post({ type: 'interrupt' });
    await S.expectOut(/user interrupt/, 5000);
    assert(now() - t < 5000, 'interrupt within 5 s');
    await S.prompt();
    S.send('(* 6 7)\n');
    await S.expectOut(val('42'));
    await S.prompt();
  });

  await check('4 readFile of a missing path gives an error reply', async () => {
    S.post({ type: 'readFile', id: 41, path: '/home/web_user/no-such-file' });
    const r = await S.reply('file', 41);
    assert(r.type === 'error' && r.message, 'error with a message, got ' + JSON.stringify(r));
  });

  await check('5 writeFile, listDir, readFile and load it with ,l', async () => {
    const data = new TextEncoder().encode('(define up-loaded 17)\n');
    S.post({ type: 'writeFile', id: 51, path: '/home/web_user/up.scm', data });
    assert((await S.reply('ack', 51)).type === 'ack', 'writeFile acked');
    S.post({ type: 'listDir', id: 52, path: '/home/web_user' });
    const d = await S.reply('dir', 52);
    assert(d.type === 'dir' && d.entries.includes('up.scm'), 'listed: ' + JSON.stringify(d.entries));
    S.post({ type: 'readFile', id: 53, path: '/home/web_user/up.scm' });
    const f = await S.reply('file', 53);
    assert(f.type === 'file' && Buffer.from(f.data).equals(Buffer.from(data)), 'same bytes back');
    S.send(',l up.scm\n');
    await S.prompt();
    S.send('(+ up-loaded 1)\n');
    await S.expectOut(val('18'));
    await S.prompt();
    // a relative path is relative to the working directory
    S.post({ type: 'writeFiles', id: 54, files: [{ path: 'rel.txt', data }] });
    assert((await S.reply('ack', 54)).type === 'ack', 'writeFiles of a relative path acked');
    S.post({ type: 'readFile', id: 55, path: '/home/web_user/rel.txt' });
    const r = await S.reply('file', 55);
    assert(r.type === 'file' && Buffer.from(r.data).equals(Buffer.from(data)), 'rel.txt in the home directory');
  });

  await check('6 output is paused without acks and resumes with them', async () => {
    const B = session({}, { autoAck: false });
    try {
      await waitFor('ready', () => B.ready || B.crash, 30000);
      await waitFor('first prompt', () => /#;1> $/.test(B.out), 30000);
      B.send('(let loop ((i 0)) (when (< i 300000) (print i) (loop (+ i 1))) ) (print "done")\n');
      let n = -1;                       // wait until the output stops growing
      for (let k = 0; k < 100 && n !== B.out.length; k++) { n = B.out.length; await sleep(300); }
      assert(!/done/.test(B.out), 'stalled before the end');
      assert(B.out.length >= (1 << 20) && B.out.length < (1 << 20) + 200000,
             'stalled just above 1 MB unacked (' + B.out.length + ' chars)');
      B.post({ type: 'ack', bytes: B.out.length });
      const acked = B.out.length;
      await waitFor('more output', () => B.out.length > acked, 5000);
      // keep acking until the end
      const t = setInterval(() => B.post({ type: 'ack', bytes: 1 << 30 }), 20);
      try { await waitFor('done', () => /done\n/.test(B.out), 60000); } finally { clearInterval(t); }
    } finally { await B.close(); }
  });

  await check('7 input sent before ready is evaluated after it', async () => {
    const E = session({});
    try {
      E.post({ type: 'input', text: '(* 7 6)\n', eof: false });
      assert(!E.ready, 'posted before ready');
      await waitFor('ready', () => E.ready || E.crash, 30000);
      await E.expectOut(val('42'), 30000);
    } finally { await E.close(); }
  });

  await check('8 exit during startup gives exit {code} and no ready', async () => {
    const X = session({ args: ['-n', '-e', '(exit 5)'] });
    try {
      await waitFor('exit', () => X.exit !== null || X.crash, 30000);
      assert(X.exit === 5 && !X.ready, 'exit 5 without ready, got ' + X.exit + ' ' + X.crash);
    } finally { await X.close(); }
  });

  await check('9 (exit 3) at the prompt gives exit {code 3}', async () => {
    S.send('(exit 3)\n');
    await waitFor('exit', () => S.exit !== null, 10000);
    assert(S.exit === 3, 'exit code ' + S.exit);
  });

  // the notebook kernel (webnb.scm; nb-kernel.js is its client)
  const nbArgs = ['-n', '-e', '(##webnb#kernel)'];
  const events = X => X.msgs.filter(m => m.type === 'output' && m.fd === 3)
    .map(m => m.text).join('').split('\n').filter(Boolean).map(l => JSON.parse(l));

  await check('W-NB1 a kernel request posted before ready is served after hello', async () => {
    const N = session({ args: nbArgs });
    try {
      N.post({ type: 'request', text: 'run 1 In[1]\n(* 6 7)' });
      assert(!N.ready, 'posted before ready');
      const done = await waitFor('done', () => {
        if (N.crash || N.exit !== null) throw new Error('kernel ended: ' + (N.crash || N.exit));
        return events(N).find(e => e.ev === 'done');
      }, 30000);
      assert(done.status === 'ok' && JSON.stringify(done.values) === '["42"]', 'done ' + JSON.stringify(done));
      const iReady = N.msgs.findIndex(m => m.type === 'ready');
      const iHello = N.msgs.findIndex(m => m.type === 'output' && m.fd === 3 && /"hello"/.test(m.text));
      assert(iReady >= 0 && iReady < iHello, 'ready before hello');
      assert(events(N).map(e => e.ev).join() === 'hello,start,done', 'events ' + events(N).map(e => e.ev));
      await waitFor('IDLE', () => N.states[N.states.length - 1] === 5);
      assert(!N.msgs.some(m => m.type === 'output' && m.fd !== 3), 'no banner, no prompt');
    } finally { await N.close(); }
  });

  await check('W-NB2 a kernel request then interrupt: the cell is interrupted', async () => {
    const N = session({ args: nbArgs });
    try {
      await waitFor('hello', () => events(N).find(e => e.ev === 'hello'), 30000);
      N.post({ type: 'request', text: 'run 1 In[1]\n(let loop () (loop))' });
      await waitFor('BUSY', () => N.states.filter(x => x === 2).length >= 2);
      N.post({ type: 'interrupt' });
      const done = await waitFor('done', () => events(N).find(e => e.ev === 'done'), 5000);
      assert(done.status === 'interrupted', 'status ' + done.status);
      N.post({ type: 'request', text: 'run 2 In[2]\n(+ 1 2)' });
      const d2 = await waitFor('done 2', () => events(N).find(e => e.ev === 'done' && e.rid === 2));
      assert(JSON.stringify(d2.values) === '["3"]', 'next cell ' + JSON.stringify(d2));
    } finally { await N.close(); }
  });

  // ---- W-J: the JavaScript bridge (webjs.scm) in the worker, where
  // user JavaScript shares the global scope with repl-worker.js
  let JW;
  const jsEv = async (src, v, ms) => { JW.send(src + '\n'); await JW.expectOut(val(v), ms); await JW.prompt(ms); };

  await check('W-J1 the worker\'s own state and postMessage are out of reach', async () => {
    JW = session({});
    await waitFor('ready', () => JW.ready || JW.crash || JW.error, 30000);
    await JW.prompt(30000);
    JW.send('(import js)\n');
    await JW.prompt();
    await jsEv('(js->list (js-eval "[typeof drv, typeof handle, typeof queue, typeof writeFile, typeof postMessage, ' +
               'typeof ChickenReplDriver, onmessage === null]"))',
               '("undefined" "undefined" "undefined" "undefined" "undefined" "undefined" #t)');
    await jsEv('(+ 1 2)', '3');
  });
  if (!JW || !JW.ready) { console.log('cannot continue'); process.exit(1); }

  await check('W-J2 an exception thrown in a timer is reported; the worker goes on', async () => {
    // (the report may come before the prompt or after it)
    JW.send('(js-eval "setTimeout(() => { throw new Error(\'boom\') }, 0)")\n');
    await JW.expectOut(/Uncaught Error: boom/, 1000);
    assert(!JW.error && !JW.crash, 'no worker error: ' + (JW.error || JW.crash));
    JW.send('(js-eval "Promise.reject(new Error(\'nope\')), 1")\n');
    await JW.expectOut(/Uncaught \(in promise\) Error: nope/, 1000);
    await waitFor('WAITING', () => JW.states[JW.states.length - 1] === 1);
    assert(!JW.error && !JW.crash, 'no worker error: ' + (JW.error || JW.crash));
    await jsEv('(+ 1 2)', '3');
  }, { uncaught: true });

  await check('W-J3 a Scheme error in a timer callback is printed; the worker goes on', async () => {
    JW.send("(js-call (js-eval \"f => setTimeout(f, 10)\") (lambda () (car '())))\n");
    await JW.expectOut(/Error in a call from JavaScript: \(car\) bad argument type: \(\)/, 2000);
    await sleep(100);
    assert(!JW.error && !JW.crash && JW.exit === null, 'alive: ' + (JW.error || JW.crash || JW.exit));
    assert(!/Uncaught/.test(JW.since()), 'no unhandled rejection: ' + JW.since());
    await jsEv('(+ 1 2)', '3');
  });

  await check('W-J4 the console writes to the standard ports, in order, also between inputs', async () => {
    JW.send('(begin (display "a") (js-eval "console.log(\'b\')") (display "c\\n") ' +
            '(js-eval "console.error(\'e\', 1, [1, \\"x\\"], {k: null})"))\n');
    await JW.expectOut(/^ab\nc\ne 1 \[1,"x"\] \{"k":null\}\n/);
    await JW.prompt();
    JW.send('(js-eval "setTimeout(() => console.log(\'idle\'), 20)")\n');
    await JW.prompt();
    JW.mark();
    await JW.expectOut(/^idle\n/, 500);
  });

  await check('W-J5 js-await reports state 7; an interrupt ends a wait that never settles', async () => {
    JW.send('(js-await (js-eval "new Promise(r => setTimeout(() => r(5), 200))"))\n');
    await JW.expectOut(val('5'));
    await JW.prompt();
    assert(JW.states.slice(JW.stateAt).includes(7), 'AWAITING: ' + JW.states.slice(JW.stateAt));
    JW.send('(js-await (js-eval "new Promise(() => {})"))\n');
    await waitFor('AWAITING', () => JW.states[JW.states.length - 1] === 7);
    JW.mark();
    JW.post({ type: 'interrupt' });
    await JW.expectOut(/user interrupt/, 5000);
    await JW.prompt();
    await jsEv('(+ 2 2)', '4');
  });

  await check('W-J6 replacing postMessage and onmessage does not cut the worker off', async () => {
    JW.send('(js-eval "self.postMessage = () => {}; try { onmessage = () => {} } catch (e) {} 1")\n');
    await JW.expectOut(val('1'));
    await JW.prompt();
    await jsEv('(* 6 7)', '42');
  });

  await check('W-J7 an ack that is no number is ignored', async () => {
    JW.post({ type: 'ack', bytes: NaN });
    JW.post({ type: 'ack', bytes: -Infinity });
    JW.send('(let loop ((i 0)) (when (< i 300000) (print "0123456") (loop (+ i 1)))) (print "end")\n');
    await JW.expectOut(/end\n#;\d+> $/, 60000);
    await JW.prompt();
  });

  await check('W-J9 user JavaScript cannot post as the page: its events and a second init are ignored', async () => {
    const m0 = JW.msgs.length;
    await jsEv('(js-eval "dispatchEvent(new MessageEvent(\'message\', {data: {type: \'listDir\', id: 777, path: \'/\'}})); ' +
               'dispatchEvent(new MessageEvent(\'message\', {data: {type: \'init\', args: [\'-n\', \'-e\', \'(exit 7)\']}})); 1")',
               '1');
    // (the page's own, but not the first)
    JW.post({ type: 'init', args: ['-n', '-e', '(exit 8)'], csirc: null, files: [], sliceMs: 50, wasmModule });
    await sleep(300);
    const forged = JW.msgs.slice(m0).filter(m => m.id === 777 || m.type === 'exit' || m.type === 'crash' || m.type === 'ready');
    assert(!forged.length, 'nothing for them: ' + JSON.stringify(forged));
    await jsEv('(+ 1 2)', '3');
    assert(JW.exit === null, 'the session goes on');
  });

  await check('W-NJ1 the global scheme is read-only; the lexer is out of reach', async () => {
    await jsEv('(js->list (js-eval "[typeof scheme, Object.getOwnPropertyDescriptor(self, \'scheme\').writable, ' +
               'typeof ChickenJsLexer]"))', '("object" #f "undefined")');
  });

  await check('W-NJ2 the timers and promise reactions of the REPL are what they were', async () => {
    JW.send('(js-eval "setTimeout((a, b) => console.log(a + b), 0, 1, 2)")\n');
    await JW.expectOut(val('3'), 2000);
    await waitFor('WAITING', () => JW.states[JW.states.length - 1] === 1);
    JW.send('(js-eval "clearTimeout(setTimeout(() => console.log(\'no\'), 10)), 1")\n');
    await JW.expectOut(val('1'));
    await JW.prompt();
    await sleep(100);
    assert(!/no\n/.test(JW.since()), 'cleared: ' + JW.since());
    JW.send('(js-eval "(async () => { await null; return 7 })().then(x => console.log(x)), 1")\n');
    await JW.expectOut(val('7'), 2000);
    await jsEv('(+ 1 2)', '3');
  });

  await check('W-RJS1 what JavaScript writes between slices comes as output {idle: true}', async () => {
    JW.send(",js setTimeout(() => console.log('t'), 20), 1\n");
    await JW.expectOut(val('1'));
    await JW.prompt();
    const m0 = JW.msgs.length;
    JW.mark();
    await JW.expectOut(/^t\n$/, 2000);
    const outs = JW.msgs.slice(m0).filter(m => m.type === 'output');
    assert(outs.length === 1 && outs[0].text === 't\n' && outs[0].idle === true, 'idle: ' + JSON.stringify(outs));
    // a slice's output is not
    JW.send('(display "s\\n")\n');
    await JW.prompt();
    assert(JW.msgs.slice(m0).every(m => m.type !== 'output' || m.text === 't\n' || m.idle === undefined),
           'not idle: ' + JSON.stringify(JW.msgs.slice(m0)));
    // one batch on both fds: only its last message ends it
    JW.send(",js setTimeout(() => { console.log('a'); console.warn('b'); console.log('c') }, 200), 1\n");
    await JW.expectOut(val('1'));
    await JW.prompt();
    const m1 = JW.msgs.length;
    JW.mark();
    await JW.expectOut(/^a\nb\nc\n$/, 2000);
    const batch = JW.msgs.slice(m1).filter(m => m.type === 'output');
    assert(JSON.stringify(batch.map(m => [m.fd, m.text, m.idle === true])) ===
           JSON.stringify([[1, 'a\n', false], [2, 'b\n', false], [1, 'c\n', true]]), 'the batch: ' + JSON.stringify(batch));
  });

  await check('W-RJS3 a listener of user JavaScript gets no message of the page', async () => {
    await jsEv(",js globalThis.heard3 = []; addEventListener('message', e => heard3.push(e.data)); 1", '1');
    await jsEv('(+ 1 2)', '3');
    await jsEv(',js heard3.length', '0');
    await jsEv(",js dispatchEvent(new MessageEvent('message', {data: 'own'})), heard3", '["own"]');
  });

  await check('W-RJS2 ,js reaches Scheme through the global scheme; Scheme errors pass through', async () => {
    await jsEv(",js scheme.eval('(+ 1 2)')", '3');
    await jsEv(",js scheme.list(1, 'a')", '(1 "a")');
    JW.send(",js scheme.call('car', 1)\n");
    await JW.prompt();
    assert(/Error: \(car\) bad argument type/.test(JW.since()), 'the REPL\'s error: ' + JSON.stringify(JW.since()));
    await jsEv('(+ 1 2)', '3');
  });

  await check('W-J8 exits through frames that catch: dispatchEvent, a promise executor', async () => {
    for (const [src, code] of [
      ['(let ((et (js-new (js-global "EventTarget")))) (js-invoke et "addEventListener" "x" (lambda (e) (exit 5))) ' +
       '(js-invoke et "dispatchEvent" (js-new (js-global "Event") "x")))', 5],
      ['(js-new (js-global "Promise") (lambda (res rej) (exit 6)))', 6]]) {
      const X = session({});
      try {
        await waitFor('ready', () => X.ready || X.crash, 30000);
        await X.prompt(30000);
        X.send('(import js) ' + src + '\n');
        await waitFor('exit', () => X.exit !== null || X.crash || X.error, 10000);
        assert(X.exit === code, 'exit ' + code + ', got ' + (X.exit !== null ? X.exit : X.crash || X.error));
        await sleep(100);
        assert(!/Uncaught/.test(X.out), 'nothing reported: ' + X.out.slice(-300));
      } finally { await X.close(); }
    }
    current = JW;
  }, { uncaught: true });              // (the exits, which the worker does not report)
  await JW.close();

  await S.close();
  console.log('# ' + passes + ' passed, ' + failures + ' failed in ' +
              ((now() - t0) / 1000).toFixed(1) + ' s');
  process.exit(failures ? 1 : 0);
})();
