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
//   node wasm-package.js manifest --out OUT --name NAME [--version V]
//       [--first EGG] INFO.json ...
//     writes OUT/manifest.json for those builds (V defaults to the
//     version of the egg NAME, or of EGG, the first egg given as a
//     directory), and removes the other bundles of NAME in OUT.  The
//     builds must have the same eggs, in any order (in dependency
//     order, which may differ between architectures).
//
//   node wasm-package.js check --exports RUNTIME-EXPORTS --arch A FILE.so ...
//     checks side modules as bundle does, but each on its own and
//     against RUNTIME-EXPORTS alone (csc-wasm -shared, after linking).
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
//
// The checks of side modules (and of a file's path) are those of
// web/package-check.js, which the page (web/packages.js) makes too, before
// it writes a package's files; an SDK has it beside this file.

'use strict';
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');

const program = 'wasm-package';

// the checks of side modules, shared with the page (packages.js): in
// web/ of the source tree, beside this file in an SDK
const { Failure, fail, parseModule, isModule, checkModules, checkPath, checkPaths, SAFE } = require(
  [path.join(__dirname, 'package-check.js'), path.join(__dirname, 'web', 'package-check.js')]
    .find(f => fs.existsSync(f)) || path.join(__dirname, 'package-check.js'));

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
  for (const p of paths) {
    const bad = checkPath(p);
    if (bad) fail(o.files + ': ' + bad);
  }
  const clash = checkPaths(paths);
  if (clash) fail(o.files + ': ' + clash + ' (installed by two extensions?)');
  const files = paths.map(p => ({ path: p, data: fs.readFileSync(path.join(o.root, p)) }));
  if (!files.length) fail('the package has no files (no extension for the target?)');
  // what the main module exports and imports, with their kinds, as the
  // page has them; without it, the names of runtime-exports
  let exports = new Set(lines(o.exports));
  const mainImports = new Map();
  if (o.main && o.main.length) exports = new Map();
  for (const m of o.main || []) {
    const info = parseModule(fs.readFileSync(m));
    for (const e of info.exports) exports.set(e.name, e.kind);
    for (const i of info.imports)
      if (i.module === 'env' || i.module === 'wasi_snapshot_preview1') mainImports.set(i.name, i.kind);
  }
  // (every WebAssembly binary: load takes one for an extension, whatever its name)
  const modules = files.filter(f => isModule(f.data))
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
  const o = options(argv, { out: 'required', name: 'required', version: 'optional', first: 'optional' });
  if (!SAFE.test(o.name)) fail('bad --name ' + JSON.stringify(o.name));
  if (!o._.length) fail('no build records');
  const infos = o._.map(f => JSON.parse(fs.readFileSync(f, 'utf8')));
  // (in dependency order, which may differ between the builds)
  const eggs = infos[0].eggs;
  const key = es => JSON.stringify(es.map(e => [e.name, e.version, e.origin]).sort());
  for (const i of infos)
    if (key(i.eggs) !== key(eggs))
      fail('the builds have different eggs: ' + JSON.stringify(i.eggs) + ' and ' + JSON.stringify(eggs));
  const own = eggs.find(e => e.name === o.name) || eggs.find(e => e.name === o.first) ||
    eggs.find(e => e.origin === 'local') || {};
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

function check(argv) {
  const o = options(argv, { exports: 'required', arch: 'required' });
  if (!o._.length) fail('usage: check --exports RUNTIME-EXPORTS --arch A FILE.so ...');
  const exports = new Set(lines(o.exports));
  const problems = [];
  for (const f of o._) {
    let info;
    try { info = parseModule(fs.readFileSync(f)); }
    catch (e) { if (!(e instanceof Failure)) throw e; problems.push(f + ': ' + e.message); continue; }
    // (only the module's own exports may satisfy its GOT entries)
    problems.push(...checkModules([{ path: f, info }], { exports, mainImports: new Set(), arch: o.arch }));
  }
  // (one line each, for csc-wasm)
  if (problems.length) {
    for (const p of problems) console.error(p);
    process.exit(1);
  }
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
  const clash = checkPaths(p.files.map(f => f.path));
  if (clash) fail(clash);
  for (const f of p.files) {
    const bad = checkPath(f.path);
    if (bad) fail(bad);
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
    case 'check': check(argv); break;
    default: fail('usage: node wasm-package.js bundle|manifest|unpack|check ...');
    }
  } catch (e) {
    if (!(e instanceof Failure)) throw e;
    console.error(program + ': ' + e.message);
    process.exit(1);
  }
}
