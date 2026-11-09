// sessions-harness.js - tests of the page's saved states (session-store.js)
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
// usage: node sessions-harness.js [WEB_DIR]
//
// The pure parts of session-store.js (names, transcripts, the input log
// and its replay plan, validation, the file format) and its store
// without IndexedDB (no IndexedDB, blocked site data, an open that never
// answers) and the cross-tab notice without BroadcastChannel.  The
// store over a real IndexedDB is tested in the browser
// (tests/wasm/page.spec.mjs).  session-store.js is read from WEB_DIR
// (build-wasm/web), else from emscripten/web.  Other arguments are
// ignored.  Exits with status 1 if any case fails.

'use strict';
const fs = require('fs');
const path = require('path');

const fromWeb = process.argv[2] ? path.join(path.resolve(process.argv[2]), 'session-store.js') : null;
const file = fromWeb && fs.existsSync(fromWeb) ? fromWeb
  : path.join(__dirname, '..', '..', 'emscripten', 'web', 'session-store.js');
const SS = require(file);
console.log('# ' + file);

let failures = 0, passes = 0;
async function check(name, f) {
  try {
    await f();
    passes++;
    console.log('ok - ' + name);
  } catch (e) {
    failures++;
    console.log('not ok - ' + name + '\n  ' + String((e && e.stack) || e).split('\n').join('\n  '));
  }
}
function assert(c, msg) { if (!c) throw new Error('assertion failed: ' + msg); }
const J = x => JSON.stringify(x);
function eq(a, b, msg) { if (J(a) !== J(b)) throw new Error(msg + ': got ' + J(a) + ', expected ' + J(b)); }
function throws(f, re, msg) {
  let e = null;
  try { f(); } catch (x) { e = x; }
  assert(e, msg + ': no exception');
  if (re) assert(re.test(e.message), msg + ': ' + e.message);
}
const L = SS.LIMITS;
const minimal = over => Object.assign({ format: 'chicken-repl-session', version: 1, minReader: 1, transcript: [],
                                        inputs: [], entry: '', uploads: [], home: [] }, over);

(async () => {
  await check('prompt regexes: plain and module prompts', () => {
    for (const p of ['#;3> ', '#;m:3> ', '#;srfi-1:12> ', 'abc\n#;1> ']) assert(SS.PROMPT_END.test(p), p);
    for (const p of ['#;3>', 'x> ', '#;3> x', '#;m 1:3> ']) assert(!SS.PROMPT_END.test(p), p);
    const parts = 'a#;1> b#;m:2> c'.split(SS.PROMPT_SPLIT);
    eq(parts, ['a', '#;1> ', 'b', '#;m:2> ', 'c'], 'split');
    eq(parts.filter((x, i) => i % 2), ['#;1> ', '#;m:2> '], 'prompts at odd indices');
  });

  await check('cleanName, nameKey, kindName', () => {
    eq(SS.cleanName('  a \t b\n\nc  '), 'a b c', 'whitespace');
    eq(SS.cleanName('a\u0000b\u0007c\u0085d'), 'abcd', 'controls');
    eq(SS.cleanName('x\u202ey\u2066z\u200f'), 'xyz', 'bidi');
    eq(SS.cleanName('é'), 'é', 'NFC');
    eq(SS.cleanName(null), '', 'null');
    eq(SS.cleanName(' \u202e '), '', 'nothing left');
    eq(Array.from(SS.cleanName('\u{1F600}'.repeat(200))).length, 120, 'code points');
    eq(SS.cleanName('a'.repeat(300)).length, 120, 'cap');
    eq(SS.nameKey(' FOO  Bar'), 'foo bar', 'key');
    eq(SS.nameKey('Foo'), SS.nameKey(' foo '), 'same key');
    eq(SS.kindName('console', 'Foo'), 'console\u0000foo', 'kindName');
  });

  await check('uniqueName', () => {
    eq(SS.uniqueName('Foo', new Set()), 'Foo', 'free');
    eq(SS.uniqueName('Foo', new Set(['foo'])), 'Foo (2)', '(2)');
    eq(SS.uniqueName('Foo', new Set(['foo', 'foo (2)'])), 'Foo (3)', '(3)');
    const long = 'x'.repeat(120);
    const u = SS.uniqueName(long, new Set([long]));
    assert(u.length <= 120 && u.endsWith(' (2)'), 'within the cap: ' + u.length);
    eq(SS.uniqueName('', new Set()), 'Untitled', 'empty');
  });

  await check('newId, fingerprint, fmtSize, sizeOf', () => {
    const ids = new Set();
    for (let i = 0; i < 200; i++) { const id = SS.newId(); assert(SS.ID_RE.test(id), id); ids.add(id); }
    eq(ids.size, 200, 'unique');
    eq(SS.fingerprint('hello'), SS.fingerprint('hello'), 'stable');
    assert(SS.fingerprint('hello') !== SS.fingerprint('hellp'), 'changes');
    assert(/^[0-9a-f]{8}$/.test(SS.fingerprint('')), 'hex');
    eq(SS.fingerprint(''), '811c9dc5', 'FNV offset basis');
    eq(SS.fmtSize(512), '512 B', 'B');
    eq(SS.fmtSize(12 * 1024), '12 KB', 'KB');
    eq(SS.fmtSize(3.4 * 1024 * 1024), '3.4 MB', 'MB');
    eq(SS.fmtSize(1.2 * 1024 * 1024 * 1024), '1.2 GB', 'GB');
    eq(SS.sizeOf('abc'), 6, 'string');
    eq(SS.sizeOf(new Uint8Array(1000)), 1000, 'bytes');
    assert(SS.sizeOf({ a: [new Uint8Array(1e6), 'x'.repeat(1e6)] }) > 3e6, 'nested');
    assert(SS.sizeOf([1, true]) >= 16, 'numbers');
  });

  await check('errorCode', () => {
    eq(SS.errorCode({ name: 'QuotaExceededError' }), 'quota', 'QuotaExceededError');
    eq(SS.errorCode({ name: 'Error', code: 22 }), 'quota', 'code 22');
    eq(SS.errorCode({ name: 'NS_ERROR_DOM_QUOTA_REACHED' }), 'quota', 'Firefox');
    eq(SS.errorCode({ name: 'UnknownError', message: 'Quota exceeded' }), 'quota', 'message');
    eq(SS.errorCode({ name: 'ConstraintError' }), 'name-taken', 'ConstraintError');
    eq(SS.errorCode({ name: 'DataCloneError' }), 'corrupt', 'DataCloneError');
    eq(SS.errorCode({ name: 'VersionError' }), 'readonly', 'VersionError');
    for (const n of ['InvalidStateError', 'UnknownError', 'SecurityError', 'NotAllowedError', 'AbortError', 'TransactionInactiveError'])
      eq(SS.errorCode({ name: n }), 'unavailable', n);
    eq(SS.errorCode(new Error('x')), 'error', 'other');
    eq(SS.errorCode(null), 'error', 'null');
    eq(SS.errorCode(new SS.StoreError('gone')), 'gone', 'StoreError');
  });

  await check('mergeChunks, trimTranscript, stripTrailingPrompt', () => {
    eq(SS.mergeChunks([['out', 'a'], ['out', ''], ['out', 'b'], ['err', 'c'], ['sys', ''], ['err', 'd']]),
       [['out', 'ab'], ['err', 'cd']], 'merge');
    const t = [['out', 'abcdef'], ['in', 'ghij'], ['out', 'klmno']];
    eq(SS.trimTranscript(t, 100), { chunks: t, cut: false }, 'fits');
    const r = SS.trimTranscript(t, 7);
    assert(r.cut, 'cut');
    eq(r.chunks.slice(1), [['in', 'ij'], ['out', 'klmno']], 'the tail');
    assert(r.chunks[0][0] === 'sys' && /not saved/.test(r.chunks[0][1]), 'the note');
    eq(r.chunks.slice(1).map(c => c[1]).join(''), 'ijklmno', 'exactly the last 7');
    eq(SS.stripTrailingPrompt([['out', 'x\n#;4> ']]), [['out', 'x\n']], 'prompt');
    eq(SS.stripTrailingPrompt([['in', 'x\n'], ['out', '#;m:4> ']]), [['in', 'x\n']], 'module prompt, chunk dropped');
    eq(SS.stripTrailingPrompt([['out', 'no prompt']]), [['out', 'no prompt']], 'no prompt');
    eq(SS.stripTrailingPrompt([['err', '#;4> ']]), [['err', '#;4> ']], 'not stdout');
    eq(SS.stripTrailingPrompt([['out', 'x\n#;4> '], ['sys', '\n; saved “a”\n'], ['sys', '; restored 1 file\n']]),
       [['out', 'x\n'], ['sys', '; saved “a”\n'], ['sys', '; restored 1 file\n']], 'prompt before notes');
    eq(SS.stripTrailingPrompt([['out', '#;1> '], ['sys', '\n']]), [], 'prompt and its line break');
    const orig = [['out', '#;1> ']];
    SS.stripTrailingPrompt(orig);
    eq(orig, [['out', '#;1> ']], 'a copy');
  });

  await check('the input log', () => {
    const l = SS.createInputLog();
    l.add('(define a 1)', true);
    eq(l.entries, [{ t: '(define a 1)', k: 'p', end: 'pending' }], 'pending');
    l.prompt();
    eq(l.entries[0].end, 'done', 'done at the prompt');
    l.add('(read-line)', true);
    l.add('an answer', false);
    l.interrupted();
    eq(l.entries.slice(1).map(e => [e.k, e.end]), [['p', 'interrupted'], ['o', 'interrupted']], 'the group interrupted');
    l.add('(+ 1 2)', true);
    eq(l.entries[3].end, 'pending', 'a later one unaffected');
    l.addEof();
    eq(l.entries[4], { eof: true, k: 'o', end: 'pending' }, 'eof');
    l.exited();
    eq(l.entries.slice(3).map(e => e.end), ['exit', 'exit'], 'exit');
    const s = l.snapshot();
    s[0].t = 'changed';
    eq(l.entries[0].t, '(define a 1)', 'snapshot is a copy');
    const plan = SS.planReplay(l.entries);
    eq(plan.send.map(e => e.t), ['(define a 1)'], 'plan sends the done ones');
    eq(plan.skipped, 4, 'and counts the others');
    // overflow
    const a = SS.createInputLog({ maxEntries: 3 });
    for (let i = 0; i < 4; i++) a.add('x', true);
    assert(a.broken && a.snapshot() === null && a.entries.length === 0, 'entries overflow');
    a.add('y', true);
    eq(a.entries.length, 0, 'nothing more recorded');
    a.reset();
    assert(!a.broken, 'reset');
    a.add('y', true);
    eq(a.entries.length, 1, 'recording again');
    const b = SS.createInputLog({ maxChars: 10 });
    b.add('12345', true);
    b.add('123456', true);
    assert(b.broken, 'chars overflow');
    const c = SS.createInputLog();
    c.add('x'.repeat(L.INPUT_MAX + 1), true);
    assert(c.broken && c.snapshot() === null, 'one huge input');
  });

  await check('checkConsole accepts and normalizes', () => {
    const { data, warnings } = SS.checkConsole(minimal({
      transcript: [['out', 'a'], ['out', 'b'], ['in', '(x)\n']],
      inputs: [{ t: '(x)', k: 'p', end: 'done' }, { eof: true, k: 'o', end: 'interrupted' }],
      entry: '(+ 1', uploads: [{ name: 'f.scm', data: new Uint8Array([1, 2]) }],
      home: [{ name: 'made.txt', data: new Uint8Array([104, 105]).buffer }],
      settings: { csirc: '(import srfi-1)', args: '-:s1m' },
    }));
    eq(warnings, [], 'no warnings');
    eq(data.transcript, [['out', 'ab'], ['in', '(x)\n']], 'transcript merged');
    eq(data.inputs.length, 2, 'inputs');
    eq(data.entry, '(+ 1', 'entry');
    assert(data.home[0].data instanceof Uint8Array && data.home[0].data.length === 2, 'ArrayBuffer wrapped');
    eq(data.settings, { csirc: '(import srfi-1)', args: '-:s1m' }, 'settings');
    eq(data.homeNote, null, 'homeNote');
    eq(data.transcriptCut, false, 'not cut');
    const s = SS.consoleSummary(data);
    eq([s.inputs, s.replayable, s.files], [2, 1, 2], 'summary');
  });

  await check('checkConsole refuses and warns', () => {
    throws(() => SS.checkConsole([]), /not a saved console session/, 'array');
    throws(() => SS.checkConsole(minimal({ format: 'x' })), /not a console session/, 'format');
    throws(() => SS.checkConsole(minimal({ version: 0 })), /version/, 'version 0');
    throws(() => SS.checkConsole(minimal({ version: '1' })), /version/, 'version "1"');
    throws(() => SS.checkConsole(minimal({ minReader: 2 })), /newer version/, 'minReader 2');
    const v2 = SS.checkConsole(minimal({ version: 2 }));
    assert(v2.warnings.some(w => /newer version/.test(w)), 'version 2 warns: ' + v2.warnings);
    const bad = SS.checkConsole(minimal({ transcript: [['out', 'a'], ['bogus', 'b'], ['err', 5], 'x', ['err', 'c']] }));
    eq(bad.data.transcript, [['out', 'a'], ['err', 'c']], 'bad pieces dropped');
    assert(bad.warnings.some(w => /^3 damaged transcript pieces/.test(w)), 'counted: ' + bad.warnings);
    const bi = SS.checkConsole(minimal({ inputs: [{ t: 'a', k: 'p', end: 'done' }, { t: 'b', k: 'q', end: 'done' }] }));
    assert(bi.data.inputs === null && bi.warnings.some(w => /inputs are damaged/.test(w)), 'bad input');
    const files = SS.checkConsole(minimal({ uploads: [
      { name: '../x', data: new Uint8Array(1) }, { name: 'a/b', data: new Uint8Array(1) },
      { name: '.csirc', data: new Uint8Array(1) }, { name: '', data: new Uint8Array(1) },
      { name: 'ok', data: [1, 2] }, { name: 'dup', data: new Uint8Array([1]) }, { name: 'dup', data: new Uint8Array([2]) },
    ] }));
    eq(files.data.uploads.map(f => [f.name, [...f.data]]), [['dup', [2]]], 'only the valid ones, the last dup');
    assert(files.warnings.some(w => /^5 damaged files/.test(w)), 'warned: ' + files.warnings);
    const many = [];
    for (let i = 0; i < L.FILES_COUNT + 3; i++) many.push({ name: 'f' + i, data: new Uint8Array(1) });
    const mc = SS.checkConsole(minimal({ uploads: many }));
    eq(mc.data.uploads.length, L.FILES_COUNT, 'FILES_COUNT');
    assert(mc.warnings.some(w => /f200, f201, f202/.test(w)), 'names the skipped: ' + mc.warnings);
    const big = new Uint8Array(L.FILE_MAX);
    const mb = SS.checkConsole(minimal({ uploads: [1, 2, 3, 4, 5].map(i => ({ name: 'b' + i, data: big })) }));
    eq(mb.data.uploads.length, 4, 'FILES_BYTES');
    const os = SS.checkConsole(minimal({ entry: 'x'.repeat(L.ENTRY_MAX + 1), settings: { csirc: 'y'.repeat(L.SETTING_MAX + 1), args: 3 } }));
    eq([os.data.entry, os.data.settings.csirc, os.data.settings.args], ['', '', ''], 'oversized fields');
  });

  await check('checkNotebookSave', () => {
    const ok = SS.checkNotebookSave({ format: 'chicken-notebook-save', version: 1, minReader: 1, notebook: '{}', uploads: [] });
    eq(ok.data.notebook, '{}', 'valid');
    throws(() => SS.checkNotebookSave({ format: 'chicken-notebook-save', version: 1, notebook: 5 }), /notebook/, 'non-string');
    throws(() => SS.checkNotebookSave({ format: 'chicken-notebook-save', version: 1, minReader: 2, notebook: '{}' }), /newer/, 'minReader 2');
    throws(() => SS.checkNotebookSave({ format: 'chicken-repl-session', version: 1, notebook: '{}' }), /not a saved notebook/, 'format');
  });

  await check('toFile and fromFile', () => {
    const all = new Uint8Array(256);
    for (let i = 0; i < 256; i++) all[i] = i;
    const rnd = new Uint8Array(1024 * 1024);
    for (let i = 0; i < rnd.length; i++) rnd[i] = (Math.random() * 256) | 0;
    const { data } = SS.checkConsole(minimal({ transcript: [['out', 'hi\n']], uploads: [{ name: 'all.bin', data: all }],
                                               home: [{ name: 'rnd.bin', data: rnd }] }));
    const text = SS.toFile('console', { name: 'Mine', created: '2026-01-01T00:00:00.000Z', modified: null }, data);
    assert(/"\$b64"/.test(text), 'base64');
    const r = SS.fromFile(text);
    eq([r.kind, r.name], ['console', 'Mine'], 'kind and name');
    eq([...r.data.uploads[0].data], [...all], 'bytes 0..255');
    assert(Buffer.from(r.data.home[0].data).equals(Buffer.from(rnd)), '1 MiB random');
    eq(r.data.transcript, [['out', 'hi\n']], 'transcript');
    const nb = JSON.stringify({ format: 'chicken-notebook', version: 1, meta: { title: 'Nb' }, cells: [] });
    const n = SS.fromFile(nb);
    eq([n.kind, n.name, n.data.format, n.data.notebook], ['notebook', 'Nb', 'chicken-notebook-save', nb], 'a notebook');
    eq(SS.toFile('notebook', {}, n.data), nb, 'notebook as is');
    throws(() => SS.fromFile('{x'), /not valid JSON/, 'invalid JSON');
    throws(() => SS.fromFile('{"format":"other"}'), /neither/, 'unknown format');
    throws(() => SS.fromFile(JSON.stringify(minimal({ uploads: [{ name: 'a', data: { $b64: '@@@' } }] }))), /bad base64/, 'bad base64');
    throws(() => SS.b64decode('abc'), /bad base64/, 'length');
    eq([...SS.b64decode(SS.b64encode(new Uint8Array([1, 2, 3, 4])))], [1, 2, 3, 4], 'round trip');
  });

  await check('cleanMeta', () => {
    const row = { v: 1, id: 'sabc', kind: 'console', name: 'Foo', kindName: 'console\u0000foo', created: '2026-01-01T00:00:00Z',
                  modified: 'bogus', rev: 2, size: 10, build: 'b', arch: 'wasm64', summary: { inputs: 1 } };
    const m = SS.cleanMeta(row);
    assert(!m.broken && m.name === 'Foo' && m.rev === 2 && m.modified === null && m.created === '2026-01-01T00:00:00.000Z', J(m));
    const n = SS.cleanMeta(Object.assign({}, row, { v: 2 }));
    assert(n.broken && /newer version/.test(n.reason) && n.id === 'sabc' && n.kind === 'console', J(n));
    const o = SS.cleanMeta({ v: 1, id: 'sbad', kind: 'console', name: 'bad', rev: 'x' });
    assert(o.broken && o.id === 'sbad', J(o));
    const p = SS.cleanMeta({ v: 1, id: 'sbad', kind: 'other', name: 'x', rev: 1, size: 1, summary: {} });
    assert(p.broken && p.kind === null, J(p));
    assert(SS.cleanMeta(null).broken, 'null');
    // the name limit counts code points, as cleanName does
    const emoji = SS.cleanName('\u{1F600}'.repeat(70));
    eq(Array.from(emoji).length, 70, 'cleanName keeps 70 emoji');
    const e = SS.cleanMeta(Object.assign({}, row, { name: emoji, kindName: SS.kindName('console', emoji) }));
    assert(!e.broken && e.name === emoji, J(e));
    const longest = SS.cleanName('\u{1F600}'.repeat(500));
    assert(!SS.cleanMeta(Object.assign({}, row, { name: longest })).broken, 'a name cut by cleanName is readable');
  });

  await check('openStore without IndexedDB', async () => {
    const t0 = Date.now();
    const a = await SS.openStore({ indexedDB: undefined });
    eq([a.mode, a.reason], ['none', 'this browser has no IndexedDB'], 'missing');
    const b = await SS.openStore({ get indexedDB() { throw Object.assign(new Error('denied'), { name: 'SecurityError' }); } });
    eq([b.mode, b.reason], ['none', 'site data is blocked for this page'], 'blocked');
    for (const s of [a, b]) {
      eq(await s.list('console'), [], 'list');
      let e = null;
      try { await s.put({ kind: 'console', name: 'x', data: {} }); } catch (x) { e = x; }
      assert(e && e.code === 'unavailable', 'put rejects: ' + (e && e.code));
      e = null;
      try { await s.get('sx'); } catch (x) { e = x; }
      assert(e && e.code === 'unavailable', 'get rejects');
    }
    const c = await SS.openStore({ indexedDB: { open() { return {}; } } }, { timeoutMs: 50 });
    eq([c.mode, c.reason], ['none', 'the browser did not open its storage in time'], 'hangs');
    const d = await SS.openStore({ indexedDB: { open() { throw new Error('no'); } } });
    eq(d.mode, 'none', 'open throws');
    // an open that fails
    const e = await SS.openStore({ indexedDB: { open() {
      const r = {};
      setTimeout(() => { r.error = Object.assign(new Error('broken'), { name: 'UnknownError' }); r.onerror({ preventDefault() {} }); }, 5);
      return r;
    } } });
    assert(e.mode === 'none' && /UnknownError: broken/.test(e.reason), 'error: ' + e.reason);
    assert(Date.now() - t0 < 4000, 'no long waits');
  });

  await check('cross-tab notice without BroadcastChannel', () => {
    const items = {}, listeners = [];
    const env = { localStorage: { setItem(k, v) { items[k] = v; } }, addEventListener(t, f) { listeners.push([t, f]); } };
    SS.broadcast(env, { op: 'put', id: 'sabc', rev: 3, kind: 'console' });
    const m = JSON.parse(items[SS.PING_KEY]);
    eq([m.v, m.op, m.id, m.rev, m.kind, m.from], [1, 'put', 'sabc', 3, 'console', SS.TAB], 'ping');
    assert(typeof m.t === 'number', 'time');
    assert(listeners.some(([t]) => t === 'storage'), 'listens to storage events');
    // a broken localStorage is no error
    SS.broadcast({ get localStorage() { throw new Error('denied'); }, addEventListener() {} }, { op: 'delete', id: 'x' });
  });

  console.log('# ' + passes + ' passed, ' + failures + ' failed');
  process.exit(failures ? 1 : 0);
})().catch(e => { console.log('not ok - ' + (e && e.stack || e)); process.exit(1); });
