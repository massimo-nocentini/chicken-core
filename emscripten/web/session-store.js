/* session-store.js - saved console sessions and notebooks (index.html)
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

/* Named saved states of the page, kept in the browser: console sessions
 * (the REPL tab, repl.js) and notebooks (notebook.js), listed, saved and
 * opened by sessions.js.  UMD: a CommonJS module in node, the global
 * ChickenSessionStore in the page.  No DOM, no dependencies.
 *
 * Storage: IndexedDB, database "chicken-repl" (never localStorage, which
 * holds about 5 MB per origin and already has the notebook's autosave).
 * Two object stores, written together in one transaction, so a tab that
 * closes in the middle of a save leaves nothing partial:
 *
 *   states    {v: 1, id, kind: 'console'|'notebook', name, kindName,
 *              created, modified (ISO), rev (1, 2, ...), size, build,
 *              arch, summary}, small, so the list never reads payloads;
 *              index kindName (kind + NUL + the name in lower case),
 *              unique: one name per kind
 *   payloads  {id, v: 1, data}, data a structured clone (files are
 *             Uint8Array):
 *
 *   console   {format: 'chicken-repl-session', version: 1, minReader: 1,
 *              transcript: [[cls, text]] (cls out|err|in|sys, at most
 *              2,000,000 chars, the end kept), transcriptCut,
 *              inputs: [{t, k, end} | {eof: true, k, end}] | null,
 *              entry (the unsent line), uploads: [{name, data}],
 *              home: [{name, data}], homeNote, settings: {csirc, args},
 *              saved: {build, arch, eh}}
 *   notebook  {format: 'chicken-notebook-save', version: 1, minReader: 1,
 *              notebook (the chicken-notebook JSON text), uploads}
 *
 * A change a reader can ignore bumps version; one it cannot bumps
 * minReader, and this code refuses anything with minReader > READER
 * (shown as an unreadable saved state, never an error of the page).
 * Every save checks the state's rev inside its transaction, so a copy
 * another tab changed is never overwritten without asking; tabs tell
 * each other about changes over a BroadcastChannel (or, without one,
 * with a localStorage key).
 *
 * What a console session keeps: its transcript, the unsent line, the
 * inputs sent to that interpreter (each with how it ended: an input
 * typed at a prompt and what followed it until the next prompt form a
 * group, done only when csi is back at a prompt), the uploaded files,
 * the regular files at the top of csi's home directory, and the .csirc
 * and arguments it ran with (recorded only).  Opening one starts a fresh
 * csi and runs again the inputs that had finished.  Not kept (non-goals):
 * the interpreter's heap (a wasm memory snapshot only works for the
 * exact build, is at least 32 MiB and leaves Emscripten's file system,
 * the streams and the clocks behind), subdirectories of home, open ports
 * and threads, the input history (shared by the page), the Settings, and
 * any automatic copy of the console.  A notebook keeps its cells with
 * outputs (up to 1 MiB per cell) and the uploaded files, not its
 * kernel's state.
 *
 *   openStore(env?, {timeoutMs}?) -> Promise<Store>, never rejected;
 *     Store {mode: 'idb'|'readonly'|'none', reason, list(kind), get(id),
 *            put({kind, name, data, summary, id?, expectRev?, keepName?}),
 *            rename(id, name), remove(id), reinsert(removed), estimate(), onChange(f)}
 *   createInputLog(), planReplay(entries), checkConsole(obj),
 *   checkNotebookSave(obj), cleanMeta(row), toFile(kind, meta, data),
 *   fromFile(text), cleanName(s), nameKey(s), uniqueName(base, keys),
 *   and the helpers below. */

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ChickenSessionStore = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const DB_NAME = 'chicken-repl', DB_VERSION = 1, RECORD_V = 1;
  const CONSOLE_FORMAT = 'chicken-repl-session', NOTEBOOK_SAVE_FORMAT = 'chicken-notebook-save';
  const FORMAT_VERSION = 1;
  const READER = 1;                     // the highest minReader this code reads
  const MiB = 1024 * 1024;
  const LIMITS = Object.freeze({
    NAME_MAX: 120,
    TRANSCRIPT_MAX: 2000000, TRANSCRIPT_LEAN: 262144,   // chars
    INPUTS_MAX: 10000, INPUTS_CHARS: 4000000, INPUT_MAX: 1000000,
    ENTRY_MAX: 65536, SETTING_MAX: 65536,
    FILE_MAX: 16 * MiB, FILES_BYTES: 64 * MiB, FILES_COUNT: 200,
    NB_OUT_MAX: MiB, NOTEBOOK_MAX: 32000000,
    IMPORT_MAX: 100 * MiB,
    OPEN_TIMEOUT_MS: 5000,
  });
  const { NAME_MAX, TRANSCRIPT_MAX, INPUTS_MAX, INPUTS_CHARS, INPUT_MAX, ENTRY_MAX, SETTING_MAX,
          FILE_MAX, FILES_BYTES, FILES_COUNT, NOTEBOOK_MAX, OPEN_TIMEOUT_MS } = LIMITS;
  const CHANNEL = 'chicken-repl.saves', PING_KEY = 'chicken-repl.saves.ping';
  // csi's prompt, "#;3> ", or "#;mymod:3> " inside a module (csi.scm)
  const PROMPT_END = /#;(?:[^\s>]*:)?\d+> $/;
  const PROMPT_SPLIT = /(#;(?:[^\s>]*:)?\d+> )/;
  const ID_RE = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
  const KINDS = ['console', 'notebook'];
  const CLASSES = ['out', 'err', 'in', 'sys'];
  const ENDS = ['pending', 'done', 'interrupted', 'exit'];
  const FILE_NAME = /^[^/\\\x00]{1,255}$/;
  const NEWER = 'saved by a newer version of this page';

  // ---- names

  // C0 and C1 controls (whitespace ones become spaces) and the bidi controls
  const CONTROLS = /[\x00-\x08\x0e-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;
  function cleanName(s) {
    let t = String(s == null ? '' : s).replace(/[\t\n\v\f\r]/g, ' ').replace(CONTROLS, '');
    t = t.replace(/\s+/g, ' ').trim();
    try { t = t.normalize('NFC'); } catch (e) { /* lone surrogates: as is */ }
    const cps = Array.from(t);
    if (cps.length > NAME_MAX) t = cps.slice(0, NAME_MAX).join('').trim();
    return t;
  }
  const nameKey = s => cleanName(s).toLowerCase();
  const kindName = (kind, s) => kind + '\u0000' + nameKey(s);
  // base, else "base (2)", "base (3)", ...: the first whose key is not taken
  function uniqueName(base, taken) {
    const b = cleanName(base) || 'Untitled';
    const has = k => !!taken && taken.has(k);
    if (!has(nameKey(b))) return b;
    for (let n = 2; ; n++) {
      const suffix = ' (' + n + ')';
      const head = Array.from(b).slice(0, NAME_MAX - suffix.length).join('').trim();
      const c = head + suffix;
      if (!has(nameKey(c))) return c;
    }
  }

  // ---- small helpers

  function randomChars(n) {
    let r = '';
    try {
      const b = new Uint8Array(n);
      globalThis.crypto.getRandomValues(b);
      for (const x of b) r += (x % 36).toString(36);
    } catch (e) {
      while (r.length < n) r += Math.floor(Math.random() * 36).toString(36);
    }
    return r;
  }
  const newId = () => 's' + randomChars(8) + Date.now().toString(36);

  // approximate bytes: strings as UTF-16
  function sizeOf(x) {
    if (x == null) return 0;
    if (typeof x === 'string') return 2 * x.length;
    if (typeof x === 'number' || typeof x === 'boolean') return 8;
    if (x instanceof ArrayBuffer) return x.byteLength;
    if (ArrayBuffer.isView(x)) return x.byteLength;
    if (Array.isArray(x)) { let n = 0; for (const v of x) n += 16 + sizeOf(v); return n; }
    if (typeof x === 'object') { let n = 0; for (const k in x) n += 16 + 2 * k.length + sizeOf(x[k]); return n; }
    return 0;
  }
  function fmtSize(n) {
    n = Math.max(0, Number(n) || 0);
    if (n < 1024) return Math.round(n) + ' B';
    if (n < MiB) return Math.round(n / 1024) + ' KB';
    if (n < 1024 * MiB) return (n / MiB).toFixed(1) + ' MB';
    return (n / (1024 * MiB)).toFixed(1) + ' GB';
  }
  function fmtDate(d) {
    if (d == null) return '';
    const t = new Date(d);
    if (isNaN(t.getTime())) return '';
    try { return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(t); }
    catch (e) { return t.toLocaleString(); }
  }
  // FNV-1a, 32 bits, over the UTF-16 code units
  function fingerprint(str) {
    let h = 0x811c9dc5;
    const s = String(str);
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; }
    return h.toString(16).padStart(8, '0');
  }
  const isPlain = o => o != null && typeof o === 'object' && !Array.isArray(o) &&
    (Object.getPrototypeOf(o) === Object.prototype || Object.getPrototypeOf(o) === null);

  // ---- errors

  class StoreError extends Error {
    constructor(code, message, current) {
      super(message || code);
      this.name = 'StoreError';
      this.code = code;
      if (current !== undefined) this.current = current;
    }
  }
  const UNAVAILABLE = ['InvalidStateError', 'UnknownError', 'SecurityError', 'NotAllowedError', 'AbortError',
                       'TransactionInactiveError'];
  function errorCode(e) {
    if (e instanceof StoreError) return e.code;
    const name = e && e.name, message = String((e && e.message) || '');
    if (name === 'QuotaExceededError' || (e && e.code === 22) || name === 'NS_ERROR_DOM_QUOTA_REACHED' || /quota/i.test(message))
      return 'quota';
    if (name === 'ConstraintError') return 'name-taken';
    if (name === 'DataCloneError') return 'corrupt';
    if (name === 'VersionError') return 'readonly';
    if (UNAVAILABLE.includes(name)) return 'unavailable';
    return 'error';
  }
  const MESSAGES = {
    quota: 'browser storage is full', 'name-taken': 'the name is taken', corrupt: 'the data could not be stored',
    readonly: 'they were saved by a newer version of this page; reload the page to update it',
    unavailable: 'the browser storage is not available', gone: 'it was deleted', conflict: 'it was changed in another tab',
    exists: 'it exists already', error: 'the browser storage failed',
  };
  function storeError(e) {
    if (e instanceof StoreError) return e;
    const code = errorCode(e);
    const detail = e && e.message ? String(e.message).split('\n')[0].slice(0, 300) : '';
    const message = code === 'quota' || code === 'readonly' ? MESSAGES[code]
      : (MESSAGES[code] || MESSAGES.error) + (detail ? ' (' + (e.name ? e.name + ': ' : '') + detail + ')' : '');
    return new StoreError(code, message);
  }

  // ---- transcripts

  // without empty pieces, adjacent ones of a class joined
  function mergeChunks(chunks) {
    const r = [];
    for (const [cls, text] of chunks) {
      if (!text) continue;
      const last = r[r.length - 1];
      if (last && last[0] === cls) last[1] += text;
      else r.push([cls, text]);
    }
    return r;
  }
  // the last max chars, with a note when the start was cut
  function trimTranscript(chunks, max) {
    let total = 0;
    for (const c of chunks) total += c[1].length;
    if (total <= max) return { chunks: chunks.map(c => [c[0], c[1]]), cut: false };
    const kept = [];
    let left = max;
    for (let i = chunks.length - 1; i >= 0 && left > 0; i--) {
      const [cls, text] = chunks[i];
      if (text.length <= left) { kept.unshift([cls, text]); left -= text.length; }
      else { kept.unshift([cls, text.slice(text.length - left)]); left = 0; }
    }
    kept.unshift(['sys', '; … the start of this transcript was not saved\n']);
    return { chunks: mergeChunks(kept), cut: true };
  }
  // without the prompt at the end: the fresh interpreter shows its own
  function stripTrailingPrompt(chunks) {
    const r = chunks.map(c => [c[0], c[1]]);
    // (notes such as "; saved …" may follow the prompt)
    let i = r.length - 1;
    while (i >= 0 && r[i][0] === 'sys') i--;
    const last = r[i];
    if (last && last[0] === 'out') {
      const m = PROMPT_END.exec(last[1]);
      if (m) {
        last[1] = last[1].slice(0, m.index);
        // a note put the prompt on a line of its own: not now
        const next = r[i + 1];
        if (next && next[1].startsWith('\n') && (!last[1] || last[1].endsWith('\n'))) next[1] = next[1].slice(1);
        if (!last[1]) r.splice(i, 1);
        if (next && !next[1]) r.splice(r.indexOf(next), 1);
      }
    }
    return r;
  }

  // ---- the input log
  //
  // The inputs sent to one interpreter, each {t, k, end} (or {eof: true,
  // k, end}): k 'p' when typed at a prompt, 'o' otherwise (stdin for a
  // program, type-ahead, the rest of an incomplete form); end pending,
  // then done when csi is back at a prompt (prompt()), interrupted
  // (Stop, a crash) or exit.  An input at a prompt and those after it
  // until the next prompt so end together: a stopped (read-line) never
  // eats the next input when the session is replayed.  A log that grows
  // past its limits is dropped as a whole (broken): a partial one would
  // replay wrong.
  function createInputLog(opts) {
    const o = opts || {};
    const maxEntries = o.maxEntries || INPUTS_MAX, maxChars = o.maxChars || INPUTS_CHARS;
    let entries = [], chars = 0, broken = false;
    const settle = end => { for (const e of entries) if (e.end === 'pending') e.end = end; };
    function overflow() { broken = true; entries = []; chars = 0; }
    return {
      get entries() { return entries; },
      get broken() { return broken; },
      add(text, atPrompt) {
        if (broken) return;
        const t = String(text);
        if (t.length > INPUT_MAX || entries.length + 1 > maxEntries || chars + t.length > maxChars) return overflow();
        entries.push({ t, k: atPrompt ? 'p' : 'o', end: 'pending' });
        chars += t.length;
      },
      addEof() {
        if (broken) return;
        if (entries.length + 1 > maxEntries) return overflow();
        entries.push({ eof: true, k: 'o', end: 'pending' });
      },
      prompt() { settle('done'); },
      interrupted() { settle('interrupted'); },
      exited() { settle('exit'); },
      reset() { entries = []; chars = 0; broken = false; },
      snapshot() { return broken ? null : entries.map(e => Object.assign({}, e)); },
    };
  }
  function planReplay(entries) {
    const send = (entries || []).filter(e => e.end === 'done');
    return { send, skipped: (entries || []).length - send.length };
  }

  // ---- base64 (for Download and Import)

  const B64_CHUNK = 0x7ffe;             // a multiple of 3 near 0x8000
  function b64encode(u8) {
    if (!(u8 instanceof Uint8Array)) u8 = new Uint8Array(u8);
    if (typeof btoa !== 'function') return Buffer.from(u8.buffer, u8.byteOffset, u8.byteLength).toString('base64');
    const parts = [];
    for (let i = 0; i < u8.length; i += B64_CHUNK)
      parts.push(btoa(String.fromCharCode.apply(null, u8.subarray(i, i + B64_CHUNK))));
    return parts.join('');
  }
  function b64decode(s) {
    if (typeof s !== 'string' || s.length % 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(s)) throw new Error('bad base64');
    if (typeof atob !== 'function') return new Uint8Array(Buffer.from(s, 'base64'));
    let bin;
    try { bin = atob(s); } catch (e) { throw new Error('bad base64'); }
    const u8 = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    return u8;
  }

  // ---- validation of what is read back

  const listNames = names => names.slice(0, 5).join(', ') + (names.length > 5 ? ' and ' + (names.length - 5) + ' more' : '');
  // [{name, data: Uint8Array}], the last of a name winning; what is not
  // a valid file, or over the limits, is skipped with a warning
  function checkFiles(list, warnings) {
    if (list == null) return [];
    if (!Array.isArray(list)) { warnings.push('A damaged file list was skipped.'); return []; }
    const byName = new Map();
    let damaged = 0;
    for (const f of list) {
      let data = f && f.data;
      if (data instanceof ArrayBuffer) data = new Uint8Array(data);
      const name = f && f.name;
      if (typeof name !== 'string' || !FILE_NAME.test(name) || name === '.' || name === '..' || name === '.csirc' ||
          !(data instanceof Uint8Array)) { damaged++; continue; }
      byName.delete(name);
      byName.set(name, data);
    }
    if (damaged) warnings.push(damaged === 1 ? 'A damaged file was skipped.' : damaged + ' damaged files were skipped.');
    const r = [], skipped = [];
    let bytes = 0;
    for (const [name, data] of byName) {
      if (r.length >= FILES_COUNT || data.length > FILE_MAX || bytes + data.length > FILES_BYTES) { skipped.push(name); continue; }
      bytes += data.length;
      r.push({ name, data });
    }
    if (skipped.length) warnings.push('Files over the limits (' + FILES_COUNT + ' files, ' + fmtSize(FILE_MAX) +
                                      ' each, ' + fmtSize(FILES_BYTES) + ' in all) were skipped: ' + listNames(skipped) + '.');
    return r;
  }
  function checkHeader(obj, format, what) {
    if (!isPlain(obj)) throw new Error('it is not a saved ' + what);
    if (obj.format !== format) throw new Error(what === 'console session' ? 'it is not a console session' : 'it is not a saved notebook');
    if (!Number.isInteger(obj.version) || obj.version < 1) throw new Error('its format version is not valid');
    const minReader = obj.minReader == null ? 1 : obj.minReader;
    if (!Number.isInteger(minReader) || minReader < 1) throw new Error('its format version is not valid');
    if (minReader > READER) throw new Error('it was ' + NEWER + '; reload the page to update it');
    return obj.version > FORMAT_VERSION ? ['Saved by a newer version of this page; parts of it may be ignored.'] : [];
  }
  const shortString = (s, max) => (typeof s === 'string' && s.length <= max ? s : '');
  function checkEntry(e) {
    if (!isPlain(e) || (e.k !== 'p' && e.k !== 'o') || !ENDS.includes(e.end)) return null;
    if (e.eof === true && e.t == null) return { eof: true, k: e.k, end: e.end };
    if (typeof e.t === 'string' && e.t.length <= INPUT_MAX && e.eof == null) return { t: e.t, k: e.k, end: e.end };
    return null;
  }
  // a console session's payload -> {data, warnings}; throws Error(why)
  function checkConsole(obj) {
    const warnings = checkHeader(obj, CONSOLE_FORMAT, 'console session');
    let transcript = [], bad = 0;
    if (Array.isArray(obj.transcript)) {
      for (const c of obj.transcript) {
        if (Array.isArray(c) && c.length >= 2 && CLASSES.includes(c[0]) && typeof c[1] === 'string') transcript.push([c[0], c[1]]);
        else bad++;
      }
    } else if (obj.transcript != null) bad++;
    if (bad) warnings.push(bad === 1 ? 'A damaged transcript piece was skipped.' : bad + ' damaged transcript pieces were skipped.');
    const t = trimTranscript(mergeChunks(transcript), TRANSCRIPT_MAX);
    transcript = t.chunks;
    let inputs = null;
    if (Array.isArray(obj.inputs) && obj.inputs.length <= INPUTS_MAX) {
      inputs = [];
      for (const e of obj.inputs) {
        const c = checkEntry(e);
        if (!c) { inputs = null; break; }
        inputs.push(c);
      }
    }
    if (inputs === null && obj.inputs != null) warnings.push('Its inputs are damaged, so only the transcript can be opened.');
    const settings = isPlain(obj.settings) ? obj.settings : {};
    const saved = isPlain(obj.saved) ? obj.saved : {};
    const data = {
      format: CONSOLE_FORMAT, version: obj.version, minReader: obj.minReader == null ? 1 : obj.minReader,
      transcript, transcriptCut: !!obj.transcriptCut || t.cut,
      inputs,
      entry: shortString(obj.entry, ENTRY_MAX),
      uploads: checkFiles(obj.uploads, warnings),
      home: checkFiles(obj.home, warnings),
      homeNote: typeof obj.homeNote === 'string' && obj.homeNote.length <= 1000 ? obj.homeNote : null,
      settings: { csirc: shortString(settings.csirc, SETTING_MAX), args: shortString(settings.args, SETTING_MAX) },
      saved: { build: shortString(saved.build, 200), arch: shortString(saved.arch, 200), eh: shortString(saved.eh, 200) },
    };
    return { data, warnings };
  }
  // a saved notebook's payload -> {data, warnings}; its notebook text is
  // parsed (and sanitized) by notebook.js with ChickenNotebookLib.fromJson
  function checkNotebookSave(obj) {
    const warnings = checkHeader(obj, NOTEBOOK_SAVE_FORMAT, 'notebook');
    if (typeof obj.notebook !== 'string' || obj.notebook.length > NOTEBOOK_MAX) throw new Error('its notebook is missing or damaged');
    const data = { format: NOTEBOOK_SAVE_FORMAT, version: obj.version, minReader: obj.minReader == null ? 1 : obj.minReader,
                   notebook: obj.notebook, uploads: checkFiles(obj.uploads, warnings) };
    return { data, warnings };
  }
  // what the list shows of a console session
  function consoleSummary(d) {
    let chars = 0;
    for (const c of d.transcript) chars += c[1].length;
    return { inputs: d.inputs ? d.inputs.length : null, replayable: d.inputs ? planReplay(d.inputs).send.length : 0,
             files: d.uploads.length + d.home.length, chars, cut: !!d.transcriptCut };
  }

  const cleanDate = d => {
    if (typeof d !== 'string' && typeof d !== 'number') return null;
    const t = new Date(d);
    return isNaN(t.getTime()) ? null : t.toISOString();
  };
  // a states row -> its meta, or {id, broken: true, kind, reason}
  function cleanMeta(row) {
    const id = row && (typeof row.id === 'string' || typeof row.id === 'number') ? row.id : null;
    const kind = row && KINDS.includes(row.kind) ? row.kind : null;
    const broken = reason => ({ id, broken: true, kind, reason });
    if (!isPlain(row)) return broken('its record is damaged');
    if (typeof row.v === 'number' && row.v > RECORD_V) return broken(NEWER);
    if (row.v !== RECORD_V || typeof row.id !== 'string' || !ID_RE.test(row.id) || !kind ||
        typeof row.name !== 'string' || !row.name || Array.from(row.name).length > NAME_MAX ||
        !Number.isInteger(row.rev) || row.rev < 1 || typeof row.size !== 'number' || !(row.size >= 0) ||
        !isPlain(row.summary)) return broken('its record is damaged');
    return {
      v: RECORD_V, id: row.id, kind, name: row.name, kindName: kindName(kind, row.name),
      created: cleanDate(row.created), modified: cleanDate(row.modified), rev: row.rev, size: row.size,
      build: typeof row.build === 'string' ? row.build : '', arch: typeof row.arch === 'string' ? row.arch : '',
      summary: row.summary,
    };
  }
  // newest first, the unreadable ones last
  function sortMetas(list) {
    const t = m => (m.modified ? Date.parse(m.modified) : 0);
    return list.slice().sort((a, b) => (!!a.broken - !!b.broken) || (a.broken ? 0 : t(b) - t(a)));
  }

  // ---- files (Download, Import)

  // the text of a downloaded state: a console session as JSON with its
  // files in base64, a notebook as the plain .json that Import reads
  function toFile(kind, meta, data) {
    if (kind === 'notebook') return data.notebook;
    const obj = Object.assign({}, data, { name: meta.name, created: meta.created || null, modified: meta.modified || null });
    return JSON.stringify(obj, (k, v) => (v instanceof Uint8Array ? { $b64: b64encode(v) } : v));
  }
  function fromFile(text) {
    let obj;
    try { obj = JSON.parse(text); } catch (e) { throw new Error('it is not valid JSON'); }
    if (isPlain(obj) && obj.format === CONSOLE_FORMAT) {
      const files = l => (Array.isArray(l) ? l.map(f => (isPlain(f) && isPlain(f.data) && typeof f.data.$b64 === 'string'
        ? { name: f.name, data: b64decode(f.data.$b64) } : f)) : l);
      const decoded = Object.assign({}, obj, { uploads: files(obj.uploads), home: files(obj.home) });
      const { data, warnings } = checkConsole(decoded);
      return { kind: 'console', name: cleanName(obj.name), data, warnings };
    }
    if (isPlain(obj) && obj.format === 'chicken-notebook') {
      const title = isPlain(obj.meta) && typeof obj.meta.title === 'string' ? cleanName(obj.meta.title) : '';
      return { kind: 'notebook', name: title,
               data: { format: NOTEBOOK_SAVE_FORMAT, version: 1, minReader: 1, notebook: text, uploads: [] }, warnings: [] };
    }
    throw new Error('it is neither a console session nor a notebook');
  }

  // ---- cross-tab notices

  const TAB = newId();
  const chans = new WeakMap();          // env -> {bc, fns}
  function validMsg(m) {
    return isPlain(m) && m.v === 1 && ['put', 'delete', 'rename'].includes(m.op) &&
      (typeof m.id === 'string' || typeof m.id === 'number') && typeof m.from === 'string';
  }
  function channel(env) {
    let c = chans.get(env);
    if (c) return c;
    c = { bc: null, fns: new Set() };
    chans.set(env, c);
    const deliver = m => {
      if (!validMsg(m) || m.from === TAB) return;
      for (const f of c.fns) { try { f(m); } catch (e) { /* the listener's problem */ } }
    };
    try {
      if (typeof env.BroadcastChannel === 'function') {
        c.bc = new env.BroadcastChannel(CHANNEL);
        c.bc.onmessage = e => deliver(e.data);
        return c;
      }
    } catch (e) { c.bc = null; }
    try {
      env.addEventListener('storage', e => {
        if (e.key !== PING_KEY || !e.newValue) return;
        let m;
        try { m = JSON.parse(e.newValue); } catch (x) { return; }
        deliver(m);
      });
    } catch (e) { /* no notices then */ }
    return c;
  }
  function broadcast(env, msg) {
    const c = channel(env);
    const m = Object.assign({ v: 1 }, msg, { from: TAB });
    if (c.bc) { try { c.bc.postMessage(m); } catch (e) { /* closed */ } return; }
    try { env.localStorage.setItem(PING_KEY, JSON.stringify(Object.assign({}, m, { t: Date.now() }))); }
    catch (e) { /* no storage: no notices */ }
  }

  // ---- the store

  function migrate(db, oldVersion) {
    if (oldVersion < 1) {
      const states = db.createObjectStore('states', { keyPath: 'id' });
      states.createIndex('kindName', 'kindName', { unique: true });
      db.createObjectStore('payloads', { keyPath: 'id' });
    }
    // later versions: if (oldVersion < 2) ..., never dropping what is saved
  }

  function estimate(env) {
    try {
      const s = env.navigator && env.navigator.storage;
      if (!s || typeof s.estimate !== 'function') return Promise.resolve(null);
      return s.estimate().then(e => (e && typeof e.usage === 'number' && typeof e.quota === 'number'
                                     ? { usage: e.usage, quota: e.quota } : null), () => null);
    } catch (e) { return Promise.resolve(null); }
  }

  function noneStore(reason, env) {
    const no = () => Promise.reject(new StoreError('unavailable', reason));
    return {
      mode: 'none', reason,
      list: () => Promise.resolve([]), get: no, put: no, rename: no, remove: no, reinsert: no,
      estimate: () => estimate(env || {}), onChange: () => () => {},
    };
  }

  function idbStore(env, idb, db0, mode, reason) {
    let db = null, reopening = null;
    function adopt(d) {
      db = d;
      d.onversionchange = () => { try { d.close(); } catch (e) { /* closed */ } if (db === d) db = null; };
      d.onclose = () => { if (db === d) db = null; };
    }
    adopt(db0);
    // the database, opened again after another tab's upgrade closed it
    function ensureDb() {
      if (db) return Promise.resolve(db);
      if (!reopening) {
        reopening = new Promise((resolve, reject) => {
          let req, late = false;
          const fail = why => reject(new StoreError('unavailable', why));
          try { req = mode === 'readonly' ? idb.open(DB_NAME) : idb.open(DB_NAME, DB_VERSION); }
          catch (e) { fail('site data is blocked for this page'); return; }
          const timer = setTimeout(() => { late = true; fail('the browser did not open its storage in time'); }, OPEN_TIMEOUT_MS);
          req.onupgradeneeded = e => { try { migrate(req.result, e.oldVersion); } catch (x) { /* aborts the open */ } };
          req.onsuccess = () => {
            clearTimeout(timer);
            if (late) { try { req.result.close(); } catch (e) { /* closed */ } return; }
            adopt(req.result);
            resolve(db);
          };
          req.onerror = e => {
            if (e && e.preventDefault) e.preventDefault();
            clearTimeout(timer);
            const err = req.error;
            if (err && err.name === 'VersionError') reject(new StoreError('readonly', MESSAGES.readonly));
            else fail((err && err.name ? err.name + ': ' : '') + ((err && err.message) || 'the storage could not be opened'));
          };
        });
        const clear = () => { reopening = null; };
        reopening.then(clear, clear);
      }
      return reopening;
    }
    // runs body(tx, done, abort) in one transaction; resolves with what
    // done got when it commits, rejects with a StoreError when it aborts
    function txn(names, txMode, body) {
      return ensureDb().then(d => new Promise((resolve, reject) => {
        let tx, own = null, out;
        try {
          tx = txMode === 'readwrite' ? d.transaction(names, txMode, { durability: 'strict' }) : d.transaction(names, txMode);
        } catch (e) {
          if (e && e.name === 'InvalidStateError') db = null;   // closing: opened again next time
          reject(storeError(e));
          return;
        }
        const abort = (why, current) => {
          if (!own) own = typeof why === 'string' ? new StoreError(why, MESSAGES[why], current) : storeError(why);
          try { tx.abort(); } catch (e) { /* finished */ }
        };
        tx.oncomplete = () => resolve(out);
        tx.onabort = () => reject(own || storeError(tx.error || new Error('the transaction was aborted')));
        // a failed request: reported once, by onabort
        tx.onerror = e => { if (e && e.preventDefault) e.preventDefault(); abort(e && e.target && e.target.error); };
        const step = f => function () { try { f.apply(this, arguments); } catch (e) { abort(e); } };
        try { body(tx, v => { out = v; }, abort, step); } catch (e) { abort(e); }
      }));
    }
    const readonlyErr = () => Promise.reject(new StoreError('readonly', reason));
    const notify = msg => broadcast(env, msg);

    function list(kind) {
      return txn(['states'], 'readonly', (tx, done, abort, step) => {
        const r = tx.objectStore('states').getAll();
        r.onsuccess = step(() => {
          done(sortMetas((r.result || []).map(cleanMeta).filter(m => m.kind === kind || (m.broken && !m.kind))));
        });
      });
    }
    function get(id) {
      return txn(['states', 'payloads'], 'readonly', (tx, done, abort, step) => {
        const a = tx.objectStore('states').get(id), b = tx.objectStore('payloads').get(id);
        let row;
        a.onsuccess = step(() => { row = a.result; });
        b.onsuccess = step(() => done({ row, payload: b.result }));
      }).then(({ row, payload }) => {
        if (!row) throw new StoreError('gone', MESSAGES.gone);
        const meta = cleanMeta(row);
        if (meta.broken) throw new StoreError('corrupt', meta.reason);
        if (!isPlain(payload)) throw new StoreError('corrupt', 'its data is missing');
        if (typeof payload.v === 'number' && payload.v > 1) throw new StoreError('corrupt', NEWER);
        if (payload.v !== 1) throw new StoreError('corrupt', 'its data is damaged');
        return { meta, data: payload.data };
      });
    }
    function put(o) {
      if (mode !== 'idb') return readonlyErr();
      const name = cleanName(o && o.name);
      if (!name) return Promise.reject(new StoreError('error', 'it has no name'));
      if (!KINDS.includes(o.kind)) return Promise.reject(new StoreError('error', 'it is of no known kind'));
      const now = new Date().toISOString();
      let meta = null;
      return txn(['states', 'payloads'], 'readwrite', (tx, done, abort, step) => {
        const states = tx.objectStore('states'), payloads = tx.objectStore('payloads');
        const write = (id, rev, created, name) => {
          const kn = kindName(o.kind, name);
          const ix = states.index('kindName').get(kn);
          ix.onsuccess = step(() => {
            const row = ix.result;
            if (row && row.id !== id) { abort('name-taken', cleanMeta(row)); return; }
            meta = { v: RECORD_V, id, kind: o.kind, name, kindName: kn, created, modified: now, rev,
                     size: sizeOf(o.data), build: String(o.build || ''), arch: String(o.arch || ''),
                     summary: isPlain(o.summary) ? o.summary : {} };
            states.put(meta);
            payloads.put({ id, v: 1, data: o.data });
            done(meta);
          });
        };
        if (o.id != null && !o.insert) {
          const g = states.get(o.id);
          g.onsuccess = step(() => {
            const cur = g.result;
            if (!cur || cur.kind !== o.kind) { abort('gone'); return; }
            if (o.expectRev != null && cur.rev !== o.expectRev) { abort('conflict', cleanMeta(cur)); return; }
            // keepName: an update of the state this tab came from keeps the
            // name it has now (another tab may have renamed it: a rename
            // leaves rev alone, so this tab can have missed it)
            const kept = o.keepName && typeof cur.name === 'string' ? cleanName(cur.name) : '';
            write(o.id, Number.isInteger(cur.rev) ? cur.rev + 1 : 1, cleanDate(cur.created) || now, kept || name);
          });
        } else if (o.id != null) {
          const g = states.get(o.id);
          g.onsuccess = step(() => {
            if (g.result) { abort('exists'); return; }
            write(o.id, Number.isInteger(o.rev) && o.rev > 0 ? o.rev : 1, cleanDate(o.created) || now, name);
          });
        } else write(newId(), 1, now, name);
      }).then(m => {
        notify({ op: 'put', id: m.id, rev: m.rev, kind: m.kind });
        return m;
      });
    }
    // name and kindName only: rev and modified stay, so a tab that has the
    // state open does not see a conflict
    function rename(id, newName) {
      if (mode !== 'idb') return readonlyErr();
      const name = cleanName(newName);
      if (!name) return Promise.reject(new StoreError('error', 'it has no name'));
      return txn(['states'], 'readwrite', (tx, done, abort, step) => {
        const states = tx.objectStore('states');
        const g = states.get(id);
        g.onsuccess = step(() => {
          const cur = g.result;
          if (!cur) { abort('gone'); return; }
          const m = cleanMeta(cur);
          if (m.broken) { abort('corrupt'); return; }
          const kn = kindName(m.kind, name);
          const ix = states.index('kindName').get(kn);
          ix.onsuccess = step(() => {
            if (ix.result && ix.result.id !== id) { abort('name-taken', cleanMeta(ix.result)); return; }
            const row = Object.assign({}, cur, { name, kindName: kn });
            states.put(row);
            done(cleanMeta(row));
          });
        });
      }).then(m => {
        notify({ op: 'rename', id: m.id, rev: m.rev, kind: m.kind });
        return m;
      });
    }
    // resolves with what was removed, for reinsert (Undo)
    function remove(id) {
      if (mode !== 'idb') return readonlyErr();
      return txn(['states', 'payloads'], 'readwrite', (tx, done, abort, step) => {
        const states = tx.objectStore('states'), payloads = tx.objectStore('payloads');
        const a = states.get(id), b = payloads.get(id);
        let row;
        a.onsuccess = step(() => { row = a.result; });
        b.onsuccess = step(() => {
          if (!row && !b.result) { abort('gone'); return; }
          states.delete(id);
          payloads.delete(id);
          done({ meta: row ? cleanMeta(row) : { id, broken: true, kind: null, reason: 'its record is missing' },
                 row: row || null, payload: b.result || null });
        });
      }).then(rec => {
        notify({ op: 'delete', id, rev: rec.meta.rev || 0, kind: rec.meta.kind || null });
        return rec;
      });
    }
    function reinsert(rec) {
      if (mode !== 'idb') return readonlyErr();
      const m = rec.meta;
      if (m.broken || !rec.payload) {
        // as it was, unreadable or not
        return txn(['states', 'payloads'], 'readwrite', (tx, done, abort, step) => {
          if (rec.row) tx.objectStore('states').put(rec.row);
          if (rec.payload) tx.objectStore('payloads').put(rec.payload);
          done(m);
        }).then(x => { notify({ op: 'put', id: m.id, rev: 0, kind: m.kind || null }); return x; });
      }
      // its rev as it was: the content is, so a tab that has it open can
      // still update it without a conflict
      const again = name => put({ kind: m.kind, name, data: rec.payload.data, summary: m.summary, id: m.id,
                                  insert: true, rev: m.rev, created: m.created, build: m.build, arch: m.arch });
      return again(m.name).catch(e => {
        if (!(e instanceof StoreError) || e.code !== 'name-taken') throw e;
        return list(m.kind).then(l => again(uniqueName(m.name + ' (restored)',
                                                       new Set(l.filter(x => !x.broken).map(x => nameKey(x.name))))));
      });
    }
    return {
      mode, reason,
      list, get, put, rename, remove, reinsert,
      estimate: () => estimate(env),
      onChange(fn) {
        const c = channel(env);
        c.fns.add(fn);
        return () => c.fns.delete(fn);
      },
    };
  }

  // never rejects: a store of mode 'none' says why nothing can be kept
  function openStore(env, opts) {
    env = env || globalThis;
    const timeoutMs = (opts && opts.timeoutMs) || OPEN_TIMEOUT_MS;
    return new Promise(resolve => {
      let idb;
      try { idb = env.indexedDB; } catch (e) { resolve(noneStore('site data is blocked for this page', env)); return; }
      if (!idb) { resolve(noneStore('this browser has no IndexedDB', env)); return; }
      let finished = false, blockedReason = null, timer = 0;
      const finish = s => {
        if (finished) return false;
        finished = true;
        clearTimeout(timer);
        if (s.mode !== 'none') channel(env);
        resolve(s);
        return true;
      };
      const opened = (req, mode, reason) => () => {
        const db = req.result;
        if (!finish(idbStore(env, idb, db, mode, reason))) { try { db.close(); } catch (e) { /* closed */ } }
      };
      let req;
      try { req = idb.open(DB_NAME, DB_VERSION); }
      catch (e) { finish(noneStore('site data is blocked for this page', env)); return; }
      timer = setTimeout(() => finish(noneStore(blockedReason || 'the browser did not open its storage in time', env)), timeoutMs);
      req.onupgradeneeded = e => {
        try { migrate(req.result, e.oldVersion); }
        catch (x) { try { req.transaction.abort(); } catch (y) { /* finished */ } }
      };
      req.onblocked = () => { blockedReason = 'another tab of this page is updating the saved states; close or reload it'; };
      req.onsuccess = opened(req, 'idb', null);
      req.onerror = e => {
        if (e && e.preventDefault) e.preventDefault();
        const err = req.error, name = err && err.name;
        if (name === 'VersionError') {
          // saved by a newer page: read them as they are
          let r2;
          try { r2 = idb.open(DB_NAME); }
          catch (x) { finish(noneStore('site data is blocked for this page', env)); return; }
          r2.onsuccess = opened(r2, 'readonly', MESSAGES.readonly);
          r2.onerror = ev => {
            if (ev && ev.preventDefault) ev.preventDefault();
            finish(noneStore(MESSAGES.readonly, env));
          };
          return;
        }
        finish(noneStore((name ? name + ': ' : '') + ((err && err.message) || 'the storage could not be opened'), env));
      };
    });
  }

  return {
    DB_NAME, DB_VERSION, RECORD_V, CONSOLE_FORMAT, NOTEBOOK_SAVE_FORMAT, FORMAT_VERSION, READER,
    CHANNEL, PING_KEY, PROMPT_END, PROMPT_SPLIT, ID_RE, LIMITS,
    cleanName, nameKey, kindName, uniqueName, newId, sizeOf, fmtSize, fmtDate, fingerprint,
    errorCode, StoreError, mergeChunks, trimTranscript, stripTrailingPrompt,
    createInputLog, planReplay, b64encode, b64decode, checkFiles, checkConsole, checkNotebookSave,
    consoleSummary, cleanMeta, toFile, fromFile, openStore, broadcast, TAB,
  };
});
