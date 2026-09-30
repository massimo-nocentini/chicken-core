// wasm-arch.js - tell a wasm32 module from a wasm64 (memory64) one
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
// usage: node wasm-arch.js FILE.wasm ...
//
// Prints, for each module, "wasm64" if its linear memory is 64-bit
// (memory64, as emscripten's MEMORY64 makes it) and "wasm32" otherwise,
// read from the module's memory section: the limits flags have bit 2 set
// for a 64-bit memory.  Exits with status 1 if a module has no memory
// section of its own (emscripten modules define and export theirs).

'use strict';
const fs = require('fs');

function leb(b, pos) {
  let v = 0, shift = 0, byte;
  do { byte = b[pos.i++]; v += (byte & 0x7f) * 2 ** shift; shift += 7; } while (byte & 0x80);
  return v;
}

function arch(file) {
  const b = fs.readFileSync(file);
  if (b.readUInt32BE(0) !== 0x0061736d) throw new Error(file + ': not a wasm module');
  const pos = { i: 8 };
  while (pos.i < b.length) {
    const id = b[pos.i++], size = leb(b, pos), end = pos.i + size;
    if (id === 5) {                     // memory section
      if (leb(b, pos) < 1) break;
      return b[pos.i] & 0x04 ? 'wasm64' : 'wasm32';
    }
    pos.i = end;
  }
  throw new Error(file + ': no memory section');
}

let status = 0;
for (const f of process.argv.slice(2)) {
  try { console.log(arch(f)); }
  catch (e) { console.error('wasm-arch: ' + e.message); status = 1; }
}
process.exit(status);
