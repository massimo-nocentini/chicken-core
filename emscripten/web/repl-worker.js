/* repl-worker.js - run the WebAssembly csi in a Web Worker
 *
 * Copyright (c) 2026, The CHICKEN Team
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following
 * conditions are met:
 *
 *   Redistributions of source code must retain the above copyright notice, this list of conditions and the following
 *     disclaimer.
 *   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
 *     disclaimer in the documentation and/or other materials provided with the distribution.
 *   Neither the name of the author nor the names of its contributors may be used to endorse or promote
 *     products derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
 * OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/* The page (repl.js) owns one worker per csi session.  Messages:
 *
 *   page -> worker   init {args, csirc, files, sliceMs, wasmModule},
 *                    input {text, eof}, interrupt, lazy {cmd}, ack {bytes},
 *                    request {text} (to the notebook kernel),
 *                    writeFile {id, path, data},
 *                    writeFiles {id, files: [{path, data}]},
 *                    readFile {id, path}, listDir {id, path}
 *   worker -> page   ready, output {fd, text, idle}, state {state, lazy}, exit {code},
 *                    crash {message}, ack {id}, file {id, path, data},
 *                    dir {id, path, entries}, error {id, message}
 *
 * output's fd is 1 or 2, or 3 for the notebook kernel's events (one
 * JSON object per line); its idle (true, or absent) says that it ends
 * a batch written between slices, by JavaScript on its own (a timer,
 * the reporter of uncaught exceptions), with no state after it (the
 * REPL page prints its prompt again then; nb-kernel.js ignores it):
 * such a batch is one message per run of output on one fd, and only
 * the last one has idle.  state 5 (IDLE) means that the kernel
 * waits for a request.  lazy {cmd} gives the printer of a lazy stream
 * a command (repl-driver.js's LAZY_*), and state's lazy says whether
 * one is being printed; state 6 (PAUSED) means that it waits for one;
 * state 7 (AWAITING) means that js-await waits for a promise.
 *
 * writeFile and writeFiles create the directories of the files they
 * write, and are acknowledged once (ack {id}) when all are written, or
 * answered with error {id, message}: writeFiles writes the others of
 * its files then, and names those it could not write.  Packages
 * of compiled extensions go to /packages/repo (extensions, import
 * libraries, types and inline files) and /packages/share (include
 * files), which csi has on its repository and include paths from the
 * start (webrepl-main.c): written while csi runs, they are found by the
 * next import.
 *
 * Messages that arrive before "ready" are queued and replayed after it;
 * "ready" always precedes the first "state".  Output is credit based:
 * the page acks what it has rendered and csi is paused (between slices)
 * while more than HIGH characters are unacknowledged.
 *
 * The worker URL's ?v= query (the build id) is passed on to every script
 * and to the .wasm, so a rebuild never mixes cached files.  Its dir=
 * query names the directory of the modules of the architecture the
 * page chose (make wasm WASM_WEB_ARCHS=...), such as "wasm32/"; without
 * it they are beside this script.
 *
 * JavaScript of the user's runs here, in this global scope: js-eval and
 * the rest of (import js) (webjs.scm), and Scheme it calls back.  So
 * this script keeps its state in a closure, takes what it uses later
 * (postMessage, timers, the driver) before csi starts, takes the
 * page's messages with a listener of its own, which that code cannot
 * call, ignoring the events it dispatches itself (not isTrusted) and
 * any init after the first, and keeping the page's from the listeners
 * that code adds (registered first, it stops their propagation),
 * locks onmessage, and makes unreachable
 * what would let that code reach past the worker: postMessage (the
 * page), storage that outlives the session (IndexedDB, caches,
 * navigator.storage and storageBuckets, the file systems of
 * webkitRequestFileSystem and the rest), nested and shared workers,
 * BroadcastChannel and close (which would end the worker silently):
 * the names the browsers expose (Chromium's among them), not an
 * allow-list.  It can still reach the network (fetch and the rest, as
 * far as the server's policy allows), the worker's CPU and its memory;
 * replacing the built-ins' prototypes can break the session (Restart
 * mends it).  Its console writes to csi's
 * standard output (log, info, debug) and error (warn, error, trace),
 * even between evaluations, and an exception it leaves uncaught (in a
 * timer, a promise nobody waits for) is reported on standard error, as
 * "Uncaught Error: ...", instead of ending the session.
 *
 * That code finds Scheme in the global `scheme' (read-only: see
 * webjs-pre.js), and the notebook kernel's JavaScript cells are
 * evaluated here too, rewritten by js-lexer.js (imported first, for
 * repl-driver.js, and then made unreachable).  So that what a cell
 * leaves to run later writes in that cell, setTimeout, setInterval,
 * queueMicrotask and the reactions of promises (then, and so catch and
 * finally) keep the cell the function was registered in (webjs-pre.js's
 * attribute); with no cell running (the REPL, the idle kernel) they
 * are what they were.  Event listeners and the continuations of a
 * native await are not attributed: what they write after their cell
 * ended goes to the kernel's messages. */

'use strict';

(() => {
  const params = new URLSearchParams(self.location.search);
  const V = params.get('v') || '';
  const q = V ? '?v=' + encodeURIComponent(V) : '';
  const D = params.get('dir') || '';
  if (!/^([a-z0-9]+\/)?$/.test(D)) throw new Error('repl-worker.js: bad module directory "' + D + '"');
  importScripts('js-lexer.js' + q, D + 'chicken-repl.js' + q, 'repl-driver.js' + q);

  // what the worker uses later, taken now: user JavaScript runs in this
  // global scope and may replace or delete any of it
  const Driver = self.ChickenReplDriver, createRepl = createChickenRepl, Lexer = self.ChickenJsLexer;
  const post = postMessage.bind(self);
  const setT = setTimeout, max = Math.max;
  const origWarn = console.warn.bind(console);
  const listen = addEventListener.bind(self);
  const getPrototypeOf = Object.getPrototypeOf, defineProperty = Object.defineProperty, ErrorC = Error;
  const apply = Reflect.apply;
  // (G, not self: a cell's top-level "const self" is a var, which
  // replaces the global self)
  const G = self, sT = setTimeout, sI = setInterval, qM = queueMicrotask, pThen = Promise.prototype.then;

  // A zero-delay macrotask: setTimeout(f, 0) is clamped to 4 ms once nested.
  const ch = new MessageChannel();
  let job = null;
  ch.port1.onmessage = () => { const j = job; job = null; if (j) j(); };
  const port2 = ch.port2;
  const schedule = f => { job = f; port2.postMessage(0); };
  const later = (f, ms) => setT(f, ms);

  const HIGH = 1 << 20;
  let out = [], outLen = 0;             // [{fd, text}] in output order
  let drv = null, queue = [], unacked = 0, bridge = null, flushing = false;

  function addOut(fd, text) {
    const last = out[out.length - 1];
    if (last && last.fd === fd) last.text += text; else out.push({ fd, text });
    outLen += text.length;
    if (outLen > 65536) flushOut();
  }

  // IDLE: output written between slices (see above), whose last
  // message ends the batch
  function flushOut(idle) {
    for (let i = 0; i < out.length; i++) {
      const { fd, text } = out[i];
      unacked += text.length;
      post(idle && i === out.length - 1 ? { type: 'output', fd, text, idle: true } : { type: 'output', fd, text });
    }
    out = [];
    outLen = 0;
  }

  // output that came between slices (JavaScript on its own): soon, once
  function flushSoon() {
    if (flushing) return;
    flushing = true;
    setT(() => { flushing = false; flushOut(true); }, 0);
  }

  // the worker's console writes to csi's standard ports, `scheme' is
  // the bridge's, and the functions to call later keep the cell they
  // come from (webjs-pre.js)
  function redirectConsole(M) {
    bridge = M.webjs;
    const b = bridge;
    for (const [name, fd] of [['log', 1], ['info', 1], ['debug', 1], ['warn', 2], ['error', 2], ['trace', 2]])
      console[name] = (...a) => b.console(fd, a);
    defineProperty(self, 'scheme', { value: b.scheme, writable: false, enumerable: false, configurable: false });
    self.setTimeout = function setTimeout(f, ...a) { return apply(sT, G, [b.attribute(f), ...a]); };
    self.setInterval = function setInterval(f, ...a) { return apply(sI, G, [b.attribute(f), ...a]); };
    self.queueMicrotask = function queueMicrotask(f) { return apply(qM, G, [b.attribute(f)]); };
    defineProperty(Promise.prototype, 'then', {
      value: function then(ok, ko) { return apply(pThen, this, [b.attributeReaction(ok), b.attributeReaction(ko)]); },
      writable: true, configurable: true, enumerable: false });
  }

  // an exception user JavaScript left uncaught; not an exit or a
  // continuation leaving JavaScript, which an event's dispatch or a
  // promise's executor caught on its way out
  function report(prefix, x) {
    if (bridge && bridge.isUnwind(x)) return;
    let text;
    try { text = Driver.describe(x); } catch (e) { text = 'an exception'; }
    addOut(2, prefix + text + '\n');
    flushSoon();
  }

  function writeFile(path, data) {
    const i = path.lastIndexOf('/');
    if (i > 0) drv.FS.mkdirTree(path.slice(0, i));
    drv.FS.writeFile(path, data);
  }

  function fsOp(m, f) {
    try { f(); }
    catch (e) {
      post({ type: 'error', id: m.id, message: Driver.fsError(e) });
    }
  }

  function handle(m) {
    switch (m.type) {
    case 'input':     drv.feed(m.text, m.eof); break;
    case 'interrupt': drv.interrupt(); break;
    case 'lazy':      drv.lazy(m.cmd); break;
    case 'request':   drv.post(m.text); break;
    case 'ack':
      if (typeof m.bytes === 'number' && m.bytes >= 0 && m.bytes < Infinity) {
        unacked = max(0, unacked - m.bytes);
        if (unacked < HIGH / 2) drv.resumeOutput();
      }
      break;
    case 'writeFile':
      fsOp(m, () => { writeFile(m.path, m.data); post({ type: 'ack', id: m.id }); });
      break;
    case 'writeFiles':
      fsOp(m, () => {
        const bad = [];
        for (const f of m.files || []) {
          try { writeFile(f.path, f.data); } catch (e) { bad.push(f.path + ': ' + Driver.fsError(e)); }
        }
        if (bad.length) throw new ErrorC('could not write ' + bad.slice(0, 3).join('; ') +
                                        (bad.length > 3 ? '; and ' + (bad.length - 3) + ' more' : ''));
        post({ type: 'ack', id: m.id });
      });
      break;
    case 'readFile':
      fsOp(m, () => post({ type: 'file', id: m.id, path: m.path, data: drv.FS.readFile(m.path) }));
      break;
    case 'listDir':
      fsOp(m, () => post({ type: 'dir', id: m.id, path: m.path, entries: drv.FS.readdir(m.path) }));
      break;
    }
  }

  let started = false;
  const onMsg = async e => {
    if (e.isTrusted === false) return;  // dispatched by user JavaScript
    // the page's, which no listener of user JavaScript sees (one that
    // writes would see the ack of what it wrote, and so on)
    e.stopImmediatePropagation();
    const m = e.data;
    if (m.type !== 'init') {
      if (drv) handle(m); else queue.push(m);
      return;
    }
    if (started) return;                // one csi per worker
    started = true;
    try {
      drv = await Driver.start(createRepl, {
        args: m.args, csirc: m.csirc, files: m.files, sliceMs: m.sliceMs,
        wasmModule: m.wasmModule,
        locateFile: (p, dir) => dir + D + p + q,
        schedule, later,
        canRun: () => unacked < HIGH,
        onModule: redirectConsole,
        jsLexer: Lexer,
        onOutput: addOut,
        onIdleOutput: flushSoon,
        onState: (st, lazy) => { flushOut(); post({ type: 'state', state: st, lazy: !!lazy }); },
        onExit: code => { flushOut(); post({ type: 'exit', code }); },
        onCrash: msg => { flushOut(); post({ type: 'crash', message: msg }); },
        onDiag: t => origWarn(t),
      });
      if (!drv) { flushOut(); return; }     // startup exit/crash already reported
      post({ type: 'ready' });
      // from now on the session reports what user JavaScript leaves
      // uncaught, instead of the page seeing the worker fail
      listen('error', e => {
        e.preventDefault();
        report('Uncaught ', e.error !== undefined && e.error !== null ? e.error : e.message);
      });
      listen('unhandledrejection', e => { e.preventDefault(); report('Uncaught (in promise) ', e.reason); });
      drv.begin();
      const pending = queue;
      queue = [];
      for (const x of pending) handle(x);
    } catch (e) {
      flushOut();
      post({ type: 'crash', message: Driver.describe(e) });
    }
  };
  listen('message', onMsg);
  defineProperty(self, 'onmessage', { value: null, writable: false, configurable: false });

  // gone from the global and every prototype on its chain (a name may
  // be missing, or be a plain global, as in node's harnesses)
  const unreach = (o, n) => {
    for (; o; o = getPrototypeOf(o)) try { delete o[n]; } catch (e) { /* not configurable */ }
  };
  for (const n of ['postMessage', 'indexedDB', 'caches', 'Worker', 'SharedWorker', 'BroadcastChannel',
                   'webkitRequestFileSystem', 'webkitRequestFileSystemSync', 'webkitResolveLocalFileSystemURL',
                   'webkitResolveLocalFileSystemSyncURL', 'close', 'ChickenReplDriver', 'ChickenJsLexer'])
    unreach(self, n);
  // the accessor (onmessage stays null, as the own value)
  unreach(getPrototypeOf(self), 'onmessage');
  if (typeof navigator === 'object' && navigator)
    for (const n of ['storage', 'storageBuckets']) unreach(navigator, n);
})();
