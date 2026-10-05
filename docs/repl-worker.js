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
 *                    input {text, eof}, interrupt, ack {bytes},
 *                    writeFile {id, path, data}, readFile {id, path},
 *                    listDir {id, path}
 *   worker -> page   ready, output {fd, text}, state {state}, exit {code},
 *                    crash {message}, ack {id}, file {id, path, data},
 *                    dir {id, path, entries}, error {id, message}
 *
 * Messages that arrive before "ready" are queued and replayed after it;
 * "ready" always precedes the first "state".  Output is credit based:
 * the page acks what it has rendered and csi is paused (between slices)
 * while more than HIGH characters are unacknowledged.
 *
 * The worker URL's ?v= query (the build id) is passed on to every script
 * and to the .wasm, so a rebuild never mixes cached files. */

'use strict';

const V = new URLSearchParams(self.location.search).get('v') || '';
const q = V ? '?v=' + encodeURIComponent(V) : '';
importScripts('chicken-repl.js' + q, 'repl-driver.js' + q);

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

function fsOp(m, f) {
  try { f(); }
  catch (e) {
    postMessage({ type: 'error', id: m.id, message: String((e && (e.message || e.code)) || e) });
  }
}

function handle(m) {
  switch (m.type) {
  case 'input':     drv.feed(m.text, m.eof); break;
  case 'interrupt': drv.interrupt(); break;
  case 'ack':
    unacked = Math.max(0, unacked - m.bytes);
    if (unacked < HIGH / 2) drv.resumeOutput();
    break;
  case 'writeFile':
    fsOp(m, () => { drv.FS.writeFile(m.path, m.data); postMessage({ type: 'ack', id: m.id }); });
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
      locateFile: (p, dir) => dir + p + q,
      schedule, later,
      canRun: () => unacked < HIGH,
      onOutput: addOut,
      onState: st => { flushOut(); postMessage({ type: 'state', state: st }); },
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
    postMessage({ type: 'crash', message: String((e && e.stack) || e) });
  }
};
