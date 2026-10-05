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
// usage: node [v8 flags] worker-harness.js WEB_DIR [--arch=A]
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
const { arch, sub } = moduleArch(fs.readFileSync(path.join(webDir, 'index.html'), 'utf8'));
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
  parentPort.on('message', d => onmessage({ data: d }));
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

// One worker.  `autoAck' acks every output message, as the page does
// after rendering it.
function session(init, { autoAck = true } = {}) {
  const s = { msgs: [], out: '', states: [], ready: false, exit: null, crash: null,
              markAt: 0, stateAt: 0, error: null, acked: 0 };
  s.w = new Worker(prelude, { eval: true, workerData: { dir: webDir, sub },
                              resourceLimits: { stackSizeMb: 1 } });
  s.w.on('error', e => { s.error = e; });
  s.w.on('message', m => {
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

const val = v => new RegExp('(^|> )' + v.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\n', 'm');

(async () => {
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

  await S.close();
  console.log('# ' + passes + ' passed, ' + failures + ' failed in ' +
              ((now() - t0) / 1000).toFixed(1) + ' s');
  process.exit(failures ? 1 : 0);
})();
