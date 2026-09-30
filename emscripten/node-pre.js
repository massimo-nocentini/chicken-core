// node-pre.js - --pre-js for the node flavour (-sNODERAWFS) of CHICKEN on wasm
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
// NODERAWFS (emscripten 6.0.10) opens a path with node's fs.openSync, which
// follows symbolic links, but gives the stream a node whose mode comes from
// lstat.  For a symbolic link to a directory, opendir() then succeeds while
// the first readdir() fails with ENOTDIR (getdents64 looks entries up
// under a "parent" that is not a directory), so `directory' and
// `find-files' see such a directory as empty.  Give the stream the mode of
// what was actually opened.  Runs after NODERAWFS installed itself into FS.

Module['preRun'] = [].concat(Module['preRun'] || [], () => {
  if (typeof FS != 'object' || typeof FS.open != 'function') return;
  const fs = require('fs');
  const open = FS.open;
  FS.open = (...args) => {
    const stream = open(...args);
    if (stream && stream.node && typeof stream.nfd == 'number' && FS.isLink(stream.node.mode))
      stream.node.mode = fs.fstatSync(stream.nfd).mode;
    return stream;
  };
});
