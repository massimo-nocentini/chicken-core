/* package-check.js - the checks of packages of compiled extensions
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

/* UMD: a CommonJS module in node, for emscripten/wasm-package.js (make
 * wasm-package, csc-wasm -shared), and the global ChickenPackageCheck in
 * the page, for packages.js.  So the page refuses exactly the side
 * modules that make wasm-package would.  No dependencies.
 *
 *   parseModule(bytes) -> {imports: [{module, name, kind, memory64?, type?}],
 *                          exports: [{name, kind}], dylink: bool}
 *     the imports, exports and dylink section of a WebAssembly binary
 *     (a Uint8Array or Buffer); throws a Failure if it is not one.
 *     KIND is func, table, memory, global or tag; TYPE, a global's
 *     value type (0x7f i32, 0x7e i64)
 *   isModule(bytes) -> whether they start as a WebAssembly binary does
 *     (what CHICKEN's load takes for a compiled extension, whatever its
 *     name)
 *   checkModules(modules, {exports, mainImports, arch}) -> [problem]
 *     whether csi of the architecture ARCH can load the side modules
 *     [{path, info: parseModule(...)}]: each import must be satisfied
 *     by what the main module exports (EXPORTS), the JS library
 *     functions it imports itself (MAIN-IMPORTS), the names the dynamic
 *     linker gives every side module (LINKER_NAMES) or, for a GOT
 *     entry, by another module of the package.  EXPORTS and MAIN-IMPORTS
 *     are a Set of names, or a Map of names to kinds: then the kind of
 *     an import must be the one of what satisfies it.  The linker's
 *     globals and the GOT entries must have the address type of ARCH,
 *     and every module must import the memory of ARCH
 *   checkPath(path) -> problem or null
 *     whether a file's path in a package is one the page writes: below
 *     repo/ or share/ of /packages, without "." or ".." components
 *   checkPaths(paths) -> problem or null
 *     whether the files of PATHS (all checkPath's) can be written
 *     together: no path twice, and none that is another's directory
 *   LINKER_NAMES, SAFE (a package's name), ABI_RE, Failure, fail(msg) */

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ChickenPackageCheck = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  class Failure extends Error {}
  function fail(msg) { throw new Failure(msg); }

  const utf8 = new TextDecoder('utf-8');

  // ---- WebAssembly binaries: the imports, exports and dylink section

  function reader(buf) {
    let pos = 0;
    const r = {
      get pos() { return pos; },
      set pos(p) { pos = p; },
      end: () => pos >= buf.length,
      byte() {
        if (pos >= buf.length) fail('truncated module');
        return buf[pos++];
      },
      // unsigned LEB128, as a Number (64-bit limits never come near 2^53)
      uleb() {
        let result = 0, mul = 1;
        for (;;) {
          const b = r.byte();
          result += (b & 0x7f) * mul;
          if (!(b & 0x80)) return result;
          mul *= 128;
        }
      },
      sleb() {
        let result = 0, mul = 1, b;
        do { b = r.byte(); result += (b & 0x7f) * mul; mul *= 128; } while (b & 0x80);
        if (b & 0x40) result -= mul;
        return result;
      },
      bytes(n) {
        if (pos + n > buf.length) fail('truncated module');
        const s = buf.subarray(pos, pos + n);
        pos += n;
        return s;
      },
      name() { return utf8.decode(r.bytes(r.uleb())); },
    };
    return r;
  }

  function limits(r) {
    const flags = r.byte();
    const min = r.uleb();
    const max = flags & 1 ? r.uleb() : undefined;
    if (flags & 8) r.uleb();              // custom page size
    return { flags, min, max, i64: !!(flags & 4) };
  }

  // a value or reference type
  function valtype(r) {
    const t = r.byte();
    if (t === 0x63 || t === 0x64) r.sleb(); // (ref null? heaptype)
    return t;
  }

  const KINDS = ['func', 'table', 'memory', 'global', 'tag'];
  function parseModule(buf) {
    const r = reader(buf);
    const magic = r.bytes(4);
    if (magic[0] !== 0 || magic[1] !== 0x61 || magic[2] !== 0x73 || magic[3] !== 0x6d)
      fail('not a WebAssembly module');
    r.bytes(4);                           // version
    const out = { imports: [], exports: [], dylink: false };
    while (!r.end()) {
      const id = r.byte();
      const size = r.uleb();
      const start = r.pos;
      if (id === 0) {
        const name = r.name();
        if (name === 'dylink.0' || name === 'dylink') out.dylink = true;
      } else if (id === 2) {
        for (let n = r.uleb(); n > 0; n--) {
          const module = r.name(), name = r.name(), k = r.byte();
          const imp = { module, name, kind: KINDS[k] || 'kind ' + k };
          switch (k) {
          case 0: r.uleb(); break;
          case 1: valtype(r); limits(r); break;
          case 2: imp.memory64 = limits(r).i64; break;
          case 3: imp.type = valtype(r); r.byte(); break;
          case 4: r.byte(); r.uleb(); break;
          default: fail('unknown import kind ' + k);
          }
          out.imports.push(imp);
        }
      } else if (id === 7) {
        for (let n = r.uleb(); n > 0; n--) {
          const name = r.name(), k = r.byte();
          r.uleb();
          out.exports.push({ name, kind: KINDS[k] || 'kind ' + k });
        }
      }
      r.pos = start + size;
    }
    return out;
  }

  // the names the dynamic linker (emscripten's libdylink.js) gives every
  // side module, besides the symbols of the main module (which exports
  // the tag of longjmp, __c_longjmp, as runtime-exports says)
  const LINKER_NAMES = new Set([
    'memory', '__indirect_function_table', '__stack_pointer', '__memory_base',
    '__table_base', '__memory_base32', '__table_base32',
  ]);
  // their kinds, and those of the address type of the architecture
  const LINKER_KINDS = { memory: 'memory', __indirect_function_table: 'table' };
  const ADDRESS_GLOBALS = new Set(['__stack_pointer', '__memory_base', '__table_base']);

  function isModule(b) {
    return b.length >= 4 && b[0] === 0 && b[1] === 0x61 && b[2] === 0x73 && b[3] === 0x6d;
  }

  // whether the Set or Map C has NAME (of kind KIND, for a Map)
  const kindOf = k => (k === 'function' ? 'func' : k);
  const offers = (c, name, kind) => (c instanceof Map ? c.has(name) && kindOf(c.get(name)) === kind : c.has(name));

  function checkModules(modules, { exports, mainImports, arch }) {
    const problems = [];
    const siblings = new Set();
    const addr = arch === 'wasm64' ? 0x7e : 0x7f;
    for (const m of modules) for (const e of m.info.exports) siblings.add(e.name);
    for (const m of modules) {
      if (!m.info.dylink) { problems.push(m.path + ': not a side module (no dylink section)'); continue; }
      const missing = [], wrong = [];
      let memory = false, otherArch = false;
      for (const i of m.info.imports) {
        if (i.module === 'env' && i.kind === 'memory') {
          memory = true;
          if (i.name !== 'memory') missing.push('env.' + i.name);
          else if (i.memory64 !== (arch === 'wasm64') && (otherArch = true))
            problems.push(m.path + ': built for ' + (i.memory64 ? 'wasm64' : 'wasm32') + ', not ' + arch);
          continue;
        }
        if (i.module === 'env' || i.module === 'wasi_snapshot_preview1') {
          if (LINKER_NAMES.has(i.name)) {
            const want = LINKER_KINDS[i.name] || 'global';
            if (i.kind !== want || (i.kind === 'global' && i.type !== (ADDRESS_GLOBALS.has(i.name) ? addr : 0x7f)))
              wrong.push(i.module + '.' + i.name + ' (' + i.kind + ')');
            continue;
          }
          if (offers(exports, i.name, i.kind) || offers(mainImports, i.name, i.kind)) continue;
          if (exports.has(i.name) || mainImports.has(i.name)) { wrong.push(i.module + '.' + i.name + ' (' + i.kind + ')'); continue; }
        } else if (i.module === 'GOT.mem' || i.module === 'GOT.func') {
          if (i.kind !== 'global' || i.type !== addr) { wrong.push(i.module + '.' + i.name + ' (' + i.kind + ')'); continue; }
          if (exports.has(i.name) || siblings.has(i.name) ||
              (i.module === 'GOT.func' && mainImports.has(i.name))) continue;
        }
        missing.push(i.module + '.' + i.name);
      }
      if (!memory) problems.push(m.path + ': imports no memory');
      if (wrong.length && !otherArch) problems.push(m.path + ': of the wrong kind or type: ' + wrong.join(' '));
      if (missing.length) problems.push(m.path + ': unresolved: ' + missing.join(' '));
    }
    return problems;
  }

  // (as the manifest has it: relative to /packages)
  function checkPath(p) {
    if (typeof p !== 'string' || !/^(repo|share)\/./.test(p) || p.length > 1024)
      return 'bad path ' + JSON.stringify(String(p).slice(0, 200)) + ' (not below repo/ or share/)';
    if (p.split('/').some(c => c === '' || c === '.' || c === '..') || /[\\\0]/.test(p))
      return 'bad path ' + JSON.stringify(p);
    return null;
  }

  function checkPaths(paths) {
    const all = new Set();
    for (const p of paths) {
      if (all.has(p)) return p + ' is there twice';
      all.add(p);
    }
    for (const p of paths)
      for (let i = p.indexOf('/'); i > 0; i = p.indexOf('/', i + 1))
        if (all.has(p.slice(0, i))) return p.slice(0, i) + ' is a file, and the directory of ' + p;
    return null;
  }

  const SAFE = /^[A-Za-z0-9._+-]+$/;
  const ABI_RE = /^[0-9a-f]{16}$/;

  return { Failure, fail, parseModule, isModule, checkModules, checkPath, checkPaths, LINKER_NAMES, SAFE, ABI_RE };
});
