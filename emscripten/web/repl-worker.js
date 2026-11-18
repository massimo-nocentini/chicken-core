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
 *   worker -> page   ready, output {fd, text}, state {state, lazy}, exit {code},
 *                    crash {message}, ack {id}, file {id, path, data},
 *                    dir {id, path, entries}, error {id, message}
 *
 * output's fd is 1 or 2, or 3 for the notebook kernel's events (one
 * JSON object per line); state 5 (IDLE) means that the kernel waits for
 * a request.  lazy {cmd} gives the printer of a lazy stream a command
 * (repl-driver.js's LAZY_*), and state's lazy says whether one is being
 * printed; state 6 (PAUSED) means that it waits for one.
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
 * it they are beside this script. */

'use strict';

const params = new URLSearchParams(self.location.search);
const V = params.get('v') || '';
const q = V ? '?v=' + encodeURIComponent(V) : '';
const D = params.get('dir') || '';
if (!/^([a-z0-9]+\/)?$/.test(D)) throw new Error('repl-worker.js: bad module directory "' + D + '"');
importScripts(D + 'chicken-repl.js' + q, 'repl-driver.js' + q);

// A zero-delay macrotask: setTimeout(f, 0) is clamped to 4 ms once nested.
const ch = new MessageChannel();
let job = null;
ch.port1.onmessage = () => { const j = job; job = null; if (j) j(); };
const schedule = f => { job = f; ch.port2.postMessage(0); };
const later = (f, ms) => setTimeout(f, ms);

const HIGH = 1 << 20;
let out = [], outLen = 0;               // [{fd, text}] in output order
let drv = null, queue = [], unacked = 0;

function addOut(fd, text) {
  const last = out[out.length - 1];
  if (last && last.fd === fd) last.text += text; else out.push({ fd, text });
  outLen += text.length;
  if (outLen > 65536) flushOut();
}

function flushOut() {
  for (const { fd, text } of out) {
    unacked += text.length;
    postMessage({ type: 'output', fd, text });
  }
  out = [];
  outLen = 0;
}

function writeFile(path, data) {
  const i = path.lastIndexOf('/');
  if (i > 0) drv.FS.mkdirTree(path.slice(0, i));
  drv.FS.writeFile(path, data);
}

function fsOp(m, f) {
  try { f(); }
  catch (e) {
    postMessage({ type: 'error', id: m.id, message: ChickenReplDriver.fsError(e) });
  }
}

function handle(m) {
  switch (m.type) {
  case 'input':     drv.feed(m.text, m.eof); break;
  case 'interrupt': drv.interrupt(); break;
  case 'lazy':      drv.lazy(m.cmd); break;
  case 'request':   drv.post(m.text); break;
  case 'ack':
    unacked = Math.max(0, unacked - m.bytes);
    if (unacked < HIGH / 2) drv.resumeOutput();
    break;
  case 'writeFile':
    fsOp(m, () => { writeFile(m.path, m.data); postMessage({ type: 'ack', id: m.id }); });
    break;
  case 'writeFiles':
    fsOp(m, () => {
      const bad = [];
      for (const f of m.files || []) {
        try { writeFile(f.path, f.data); } catch (e) { bad.push(f.path + ': ' + ChickenReplDriver.fsError(e)); }
      }
      if (bad.length) throw new Error('could not write ' + bad.slice(0, 3).join('; ') +
                                      (bad.length > 3 ? '; and ' + (bad.length - 3) + ' more' : ''));
      postMessage({ type: 'ack', id: m.id });
    });
    break;
  case 'readFile':
    fsOp(m, () => postMessage({ type: 'file', id: m.id, path: m.path, data: drv.FS.readFile(m.path) }));
    break;
  case 'listDir':
    fsOp(m, () => postMessage({ type: 'dir', id: m.id, path: m.path, entries: drv.FS.readdir(m.path) }));
    break;
  }
}

onmessage = async ({ data: m }) => {
  if (m.type !== 'init') {
    if (drv) handle(m); else queue.push(m);
    return;
  }
  try {
    drv = await ChickenReplDriver.start(createChickenRepl, {
      args: m.args, csirc: m.csirc, files: m.files, sliceMs: m.sliceMs,
      wasmModule: m.wasmModule,
      locateFile: (p, dir) => dir + D + p + q,
      schedule, later,
      canRun: () => unacked < HIGH,
      onOutput: addOut,
      onState: (st, lazy) => { flushOut(); postMessage({ type: 'state', state: st, lazy: !!lazy }); },
      onExit: code => { flushOut(); postMessage({ type: 'exit', code }); },
      onCrash: msg => { flushOut(); postMessage({ type: 'crash', message: msg }); },
      onDiag: t => console.warn(t),
    });
    if (!drv) { flushOut(); return; }       // startup exit/crash already reported
    postMessage({ type: 'ready' });
    drv.begin();
    const pending = queue;
    queue = [];
    for (const x of pending) handle(x);
  } catch (e) {
    flushOut();
    postMessage({ type: 'crash', message: ChickenReplDriver.describe(e) });
  }
};
