// in-worker.js - run a node-flavoured CHICKEN wasm tool inside a worker thread
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
// usage: node in-worker.js STACK_MB TOOL.js [ARG ...]
//
// Browser workers get a much smaller native stack than node's main thread
// (about 1 MB).  This runs TOOL.js (e.g. build-wasm/node/csi.js) in a
// worker_threads Worker limited to STACK_MB megabytes of stack, with
// ARG ... as its command line, and exits with the tool's exit status.

'use strict';
const { Worker } = require('worker_threads');
const path = require('path');

const [stackMb, tool, ...args] = process.argv.slice(2);
if (!tool) {
  console.error('usage: node in-worker.js STACK_MB TOOL.js [ARG ...]');
  process.exit(2);
}

const code = `
  const { workerData } = require('worker_threads');
  process.argv = [process.execPath, workerData.tool, ...workerData.args];
  require(workerData.tool);
`;
const w = new Worker(code, {
  eval: true,
  workerData: { tool: path.resolve(tool), args },
  resourceLimits: { stackSizeMb: Number(stackMb) || 1 },
});
w.on('error', e => { console.error('in-worker: ' + ((e && e.stack) || e)); process.exitCode = 1; });
w.on('exit', status => { if (process.exitCode === undefined || process.exitCode === 0) process.exitCode = status; });
