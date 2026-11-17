// wasm-package.js - check, bundle and describe packages of compiled extensions
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
// Run by "make wasm-package" (see Makefile.emscripten), with node:
//
//   node wasm-package.js bundle --name NAME --root DIR --files LIST --eggs LIST
//       --exports RUNTIME-EXPORTS --main MAIN.wasm --arch A --eh EH --abi ABI
//       --chicken VERSION --binary-version N --out OUT --info INFO.json
//     checks the side modules (.so) of one build of a package, then
//     writes OUT/NAME-A-EH-ABI.bundle and .bundle.gz and the record of
//     the build, INFO.json.  LIST (files.list of emscripten/wasm-eggs.scm
//     in shared mode) names the package's files, relative to DIR, in
//     dependency order; eggs.list its eggs.  Every import of a side
//     module must be satisfied when the page's csi (MAIN.wasm) loads
//     it: by what it exports (RUNTIME-EXPORTS, the main module's
//     share/chicken/runtime-exports), the JS library functions it
//     imports itself, the names the dynamic linker provides (memory,
//     the stack pointer ...) or, for a GOT entry, by another module of
//     the package.  It fails, listing them, if some are not, and if a
//     module is not a side module of A.
//
//   node wasm-package.js manifest --out OUT --name NAME [--version V] INFO.json ...
//     writes OUT/manifest.json for those builds (V defaults to the
//     version of the egg NAME, or of the first egg given as a
//     directory), and removes the other bundles of NAME in OUT.
//
//   node wasm-package.js unpack PACKAGE (--abi ABI | --arch A) DEST
//     writes the files of a build of PACKAGE (a manifest.json or the
//     directory holding it) below DEST, after checking their size and
//     SHA-256, as the page does under /packages.
//
// The format of manifest.json (formatVersion 1):
//   { "format": "chicken-wasm-package", "formatVersion": 1,
//     "name": NAME, "version": V,
//     "eggs": [{"name", "version", "origin": "local"|"cache"}, ...],
//     "builds": { ABI: { "arch", "eh", "chicken", "binaryVersion",
//                        "bundle" (the .bundle.gz), "rawBundle", "size",
//                        "gzSize",
//                        "files": [{"path", "offset", "size", "sha256"}, ...] } } }
// A file's path is relative to /packages (repo/X.so, share/F.scm), its
// offset and size index the raw bundle, the concatenation of the
// files; the gzipped bundle is the raw one compressed.
//
// As a module (tests): parseModule(bytes), readPackage(dir, {abi, arch}).

'use strict';
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');

const program = 'wasm-package';

class Failure extends Error {}
function fail(msg) { throw new Failure(msg); }

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
    name() { return Buffer.from(r.bytes(r.uleb())).toString('utf8'); },
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

// parseModule(bytes) -> {imports: [{module, name, kind, memory64?}],
// exports: [{name, kind}], dylink: bool}; kind is func, table, memory,
// global or tag.
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
        case 3: valtype(r); r.byte(); break;
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

// checkModules(modules, {exports, mainImports, arch}) -> problems: each
// module is {path, info: parseModule(...)}; GOT entries may also be
// resolved by another module of the package.
function checkModules(modules, { exports, mainImports, arch }) {
  const problems = [];
  const siblings = new Set();
  for (const m of modules) for (const e of m.info.exports) siblings.add(e.name);
  for (const m of modules) {
    if (!m.info.dylink) { problems.push(m.path + ': not a side module (no dylink section)'); continue; }
    const missing = [];
    for (const i of m.info.imports) {
      if (i.module === 'env' && i.kind === 'memory') {
        if (i.memory64 !== (arch === 'wasm64'))
          problems.push(m.path + ': built for ' + (i.memory64 ? 'wasm64' : 'wasm32') + ', not ' + arch);
        continue;
      }
      if (i.module === 'env' || i.module === 'wasi_snapshot_preview1') {
        if (LINKER_NAMES.has(i.name) || exports.has(i.name) || mainImports.has(i.name)) continue;
      } else if (i.module === 'GOT.mem' || i.module === 'GOT.func') {
        if (exports.has(i.name) || siblings.has(i.name) ||
            (i.module === 'GOT.func' && mainImports.has(i.name))) continue;
      }
      missing.push(i.module + '.' + i.name);
    }
    if (missing.length) problems.push(m.path + ': unresolved: ' + missing.join(' '));
  }
  return problems;
}

// ---- command line

function options(argv, spec) {
  const o = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      if (!(k in spec)) fail('unknown option ' + a);
      if (i + 1 >= argv.length) fail('missing argument to ' + a);
      if (spec[k] === 'list') (o[k] = o[k] || []).push(argv[++i]);
      else o[k] = argv[++i];
    } else o._.push(a);
  }
  for (const k in spec)
    if (spec[k] === 'required' && o[k] === undefined) fail('missing --' + k);
  return o;
}

const lines = file => fs.readFileSync(file, 'utf8').split('\n').map(l => l.trim()).filter(Boolean);
const sha256 = data => crypto.createHash('sha256').update(data).digest('hex');
const SAFE = /^[A-Za-z0-9._+-]+$/;

function readEggs(file) {
  return lines(file).map(l => {
    const [name, version, origin] = l.split(/\s+/);
    return { name, version: version === '-' ? null : version, origin };
  });
}

function bundleName(name, arch, eh, abi) { return name + '-' + arch + '-' + eh + '-' + abi + '.bundle'; }

function writeAtomic(file, data) {
  fs.writeFileSync(file + '.tmp', data);
  fs.renameSync(file + '.tmp', file);
}

function bundle(argv) {
  const o = options(argv, { name: 'required', root: 'required', files: 'required', eggs: 'required',
                            exports: 'required', main: 'list', arch: 'required', eh: 'required',
                            abi: 'required', chicken: 'required', 'binary-version': 'required',
                            out: 'required', info: 'required' });
  for (const k of ['name', 'arch', 'eh', 'abi'])
    if (!SAFE.test(o[k])) fail('bad --' + k + ' ' + JSON.stringify(o[k]));
  const t0 = Date.now();
  const paths = lines(o.files);
  const seen = new Set();
  const files = paths.map(p => {
    if (path.isAbsolute(p) || p.split('/').includes('..') || !/^(repo|share)\//.test(p))
      fail(o.files + ': bad path ' + p);
    if (seen.has(p)) fail(o.files + ': ' + p + ' is installed twice (by two extensions)');
    seen.add(p);
    return { path: p, data: fs.readFileSync(path.join(o.root, p)) };
  });
  if (!files.length) fail('the package has no files (no extension for the target?)');
  const exports = new Set(lines(o.exports));
  const mainImports = new Set();
  for (const m of o.main || [])
    for (const i of parseModule(fs.readFileSync(m)).imports)
      if (i.module === 'env' || i.module === 'wasi_snapshot_preview1') mainImports.add(i.name);
  const modules = files.filter(f => f.path.endsWith('.so'))
    .map(f => ({ path: f.path, info: (() => {
      try { return parseModule(f.data); } catch (e) { fail(f.path + ': ' + e.message); }
    })() }));
  const problems = checkModules(modules, { exports, mainImports, arch: o.arch });
  if (problems.length)
    fail('the side modules of ' + o.name + ' (' + o.arch + ') cannot be loaded by the csi of this build:\n  ' +
         problems.join('\n  '));
  let offset = 0;
  const entries = files.map(f => {
    const e = { path: f.path, offset, size: f.data.length, sha256: sha256(f.data) };
    offset += f.data.length;
    return e;
  });
  const raw = Buffer.concat(files.map(f => f.data));
  const gz = zlib.gzipSync(raw, { level: 9 });
  const rawName = bundleName(o.name, o.arch, o.eh, o.abi);
  fs.mkdirSync(o.out, { recursive: true });
  writeAtomic(path.join(o.out, rawName), raw);
  writeAtomic(path.join(o.out, rawName + '.gz'), gz);
  const info = {
    abi: o.abi, eggs: readEggs(o.eggs),
    build: { arch: o.arch, eh: o.eh, chicken: o.chicken, binaryVersion: Number(o['binary-version']),
             bundle: rawName + '.gz', rawBundle: rawName, size: raw.length, gzSize: gz.length,
             files: entries },
  };
  writeAtomic(o.info, JSON.stringify(info, null, 1) + '\n');
  console.log(program + ': ' + o.name + ' ' + o.arch + ': ' + entries.length + ' files (' +
              modules.length + ' side modules checked), ' + raw.length + ' bytes, ' + gz.length +
              ' gzipped, in ' + rawName + '(.gz) (' + (Date.now() - t0) + ' ms)');
}

function manifest(argv) {
  const o = options(argv, { out: 'required', name: 'required', version: 'optional' });
  if (!SAFE.test(o.name)) fail('bad --name ' + JSON.stringify(o.name));
  if (!o._.length) fail('no build records');
  const infos = o._.map(f => JSON.parse(fs.readFileSync(f, 'utf8')));
  const eggs = infos[0].eggs;
  for (const i of infos)
    if (JSON.stringify(i.eggs) !== JSON.stringify(eggs))
      fail('the builds have different eggs: ' + JSON.stringify(i.eggs) + ' and ' + JSON.stringify(eggs));
  const own = eggs.find(e => e.name === o.name) || eggs.find(e => e.origin === 'local') || {};
  const version = o.version || own.version || '0';
  const builds = {};
  for (const i of infos) {
    if (builds[i.abi]) fail('two builds with the ABI ' + i.abi);
    builds[i.abi] = i.build;
  }
  const m = { format: 'chicken-wasm-package', formatVersion: 1, name: o.name, version, eggs, builds };
  writeAtomic(path.join(o.out, 'manifest.json'), JSON.stringify(m, null, 1) + '\n');
  // bundles of earlier builds of this package
  const keep = new Set(Object.values(builds).flatMap(b => [b.bundle, b.rawBundle]));
  for (const f of fs.readdirSync(o.out))
    if (f.startsWith(o.name + '-') && !keep.has(f) &&
        /^wasm(64|32)-[a-z]+-[0-9a-f]{16}\.bundle(\.gz)?$/.test(f.slice(o.name.length + 1)))
      fs.unlinkSync(path.join(o.out, f));
  console.log(program + ': ' + path.join(o.out, 'manifest.json') + ': ' + o.name + ' ' + version + ', ' +
              eggs.length + ' eggs, builds ' +
              Object.entries(builds).map(([abi, b]) => b.arch + ':' + b.eh + ':' + abi).join(' '));
}

// readPackage(dirOrManifest, {abi, arch}) -> {manifest, abi, build,
// files: [{path, data}]}, checking each file's size and SHA-256
function readPackage(where, { abi, arch } = {}) {
  const file = fs.statSync(where).isDirectory() ? path.join(where, 'manifest.json') : where;
  const dir = path.dirname(file);
  const m = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (m.format !== 'chicken-wasm-package' || m.formatVersion !== 1)
    fail(file + ': not a package manifest of format version 1');
  let key = abi;
  if (!key) {
    const ks = Object.keys(m.builds).filter(k => m.builds[k].arch === arch);
    if (ks.length !== 1) fail(file + ': ' + ks.length + ' builds for ' + arch);
    key = ks[0];
  }
  const b = m.builds[key];
  if (!b) fail(file + ': no build for the ABI ' + key);
  const rawFile = path.join(dir, b.rawBundle);
  const raw = fs.existsSync(rawFile) ? fs.readFileSync(rawFile)
    : zlib.gunzipSync(fs.readFileSync(path.join(dir, b.bundle)));
  if (raw.length !== b.size) fail(b.rawBundle + ': ' + raw.length + ' bytes, not ' + b.size);
  const files = b.files.map(f => {
    const data = raw.subarray(f.offset, f.offset + f.size);
    if (data.length !== f.size || sha256(data) !== f.sha256) fail(f.path + ': bad size or SHA-256');
    return { path: f.path, data };
  });
  return { manifest: m, abi: key, build: b, files };
}

function unpack(argv) {
  const o = options(argv, { abi: 'optional', arch: 'optional' });
  if (o._.length !== 2 || !(o.abi || o.arch)) fail('usage: unpack PACKAGE (--abi ABI | --arch A) DEST');
  const [where, dest] = o._;
  const p = readPackage(where, o);
  for (const f of p.files) {
    if (path.isAbsolute(f.path) || f.path.split('/').includes('..')) fail('bad path ' + f.path);
    const to = path.join(dest, f.path);
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.writeFileSync(to, f.data);
  }
  console.log(program + ': ' + p.files.length + ' files of ' + p.manifest.name + ' (' + p.build.arch +
              ':' + p.build.eh + ':' + p.abi + ') in ' + dest);
}

module.exports = { parseModule, checkModules, readPackage };

if (require.main === module) {
  const [cmd, ...argv] = process.argv.slice(2);
  try {
    switch (cmd) {
    case 'bundle': bundle(argv); break;
    case 'manifest': manifest(argv); break;
    case 'unpack': unpack(argv); break;
    default: fail('usage: node wasm-package.js bundle|manifest|unpack ...');
    }
  } catch (e) {
    if (!(e instanceof Failure)) throw e;
    console.error(program + ': ' + e.message);
    process.exit(1);
  }
}
