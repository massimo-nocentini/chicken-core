// dylink.js - the check of side modules before a main module loads them
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
// An emscripten JS library, linked into the main modules (WASM_DYLINK)
// with emscripten/dylink-main.c.  chicken_dlcheck(path, msg, len)
// returns 1 if emscripten's dlopen can load the side module at path,
// else 0 with the reason in msg (len bytes at most): it must not try,
// as it fails only at the first call of a function the main module
// does not have (a stub stands for it), and an entry of the global
// offset table (GOT.mem, GOT.func) that nothing defines stays in the
// table, so that every later dlopen fails too.  An import is satisfied
// as emscripten's loader (libdylink.js) satisfies it: by a symbol of
// the main module (what it exports, its JS library functions) or of a
// module loaded before, by the module itself, by the linker (memory,
// stack pointer, bases of memory and table) or, if weak, by nothing.
// Anything else in the file (a module of another architecture, not a
// side module) is left to dlopen to report.

addToLibrary({
  $chickenWasmImportsExports__deps: ['$UTF8ArrayToString'],
  $chickenWasmImportsExports: (bin) => {
    var pos = 8, out = { imports: [], exports: new Set() };
    var u8 = () => {
      if (pos >= bin.length) throw new Error('truncated module');
      return bin[pos++];
    };
    // unsigned or signed LEB128 (the value of a signed one is not used)
    var leb = () => {
      var r = 0, m = 1, b;
      do { b = u8(); r += (b & 0x7f) * m; m *= 128; } while (b & 0x80);
      return r;
    };
    var name = () => {
      var n = leb(), s = UTF8ArrayToString(bin, pos, n);
      pos += n;
      return s;
    };
    var type = () => { var t = u8(); if (t == 0x63 || t == 0x64) leb(); };
    var limits = () => {
      var flags = u8();
      leb();
      if (flags & 1) leb();
      if (flags & 8) leb();
      return flags;
    };
    while (pos < bin.length) {
      var id = u8(), size = leb(), end = pos + size;
      if (id == 2) {
        for (var n = leb(); n > 0; n--) {
          var imp = { module: name(), name: name(), kind: u8() };
          switch (imp.kind) {
          case 0: leb(); break;                 // function
          case 1: type(); limits(); break;      // table
          case 2: imp.memory64 = !!(limits() & 4); break;
          case 3: type(); u8(); break;          // global
          case 4: u8(); leb(); break;           // tag
          default: throw new Error('unknown import kind ' + imp.kind);
          }
          out.imports.push(imp);
        }
      } else if (id == 7) {
        for (var n = leb(); n > 0; n--) {
          out.exports.add(name());
          u8();
          leb();
        }
        break;                                  // (sections are in order)
      }
      pos = end;
    }
    return out;
  },

  $chickenDlProblem__deps: ['$chickenWasmImportsExports', '$getDylinkMetadata',
                            '$resolveGlobalSymbol', '$GOT'],
  $chickenDlProblem: (bin) => {
    var weak = getDylinkMetadata(bin).weakImports;
    var m = chickenWasmImportsExports(bin);
    var linker = ['__indirect_function_table', '__stack_pointer', '__memory_base',
                  '__table_base', '__memory_base32', '__table_base32'];
    var missing = [];
    for (var i of m.imports) {
      var sym = i.name;
      if (i.module == 'env' && sym == 'memory') {
#if MEMORY64
        if (!i.memory64) return 'built for wasm32, not wasm64';
#else
        if (i.memory64) return 'built for wasm64, not wasm32';
#endif
        continue;
      }
      if (weak.has(sym) || m.exports.has(sym)) continue;
      if (i.module == 'env' || i.module == '{{{ WASI_MODULE_NAME }}}') {
        if (linker.includes(sym) || resolveGlobalSymbol(sym).sym) continue;
      } else if (i.module == 'GOT.mem' || i.module == 'GOT.func') {
        // (an entry that nothing defined has the address -1)
        if ((GOT[sym] && GOT[sym].value != -1) || resolveGlobalSymbol(sym, true).sym) continue;
      }
      missing.push(i.module == 'env' ? sym : i.module + '.' + sym);
    }
    return missing.length ? 'symbols missing from this program: ' + missing.join(' ') : null;
  },

  chicken_dlcheck__deps: ['$chickenDlProblem', '$FS', '$UTF8ToString', '$stringToUTF8'],
  chicken_dlcheck__sig: 'ippi',
  chicken_dlcheck: (path, msg, len) => {
    var problem;
    try {
      problem = chickenDlProblem(FS.readFile(UTF8ToString(path)));
    } catch (e) {
      return 1;                                 // (dlopen reports it)
    }
    if (!problem) return 1;
    stringToUTF8(problem, msg, len);
    return 0;
  },
});
