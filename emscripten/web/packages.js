/* packages.js - packages of compiled extensions for the page (index.html)
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

/* Packages of compiled extensions (made by "make wasm-package", see the
 * README) and the Packages dialog (dialog#packages).  repl.js creates
 * the one manager with window.ChickenPackages.create(host); the
 * notebook reaches it as ChickenPage.packages.  Needs package-check.js.
 *
 * - A package is a manifest.json and, per build of the page it was made
 *   for, a bundle of files (.bundle.gz, or the raw .bundle without
 *   DecompressionStream).  Its build for this page is the one of the
 *   ABI of the build running (the third field of chicken-wasm-builds).
 * - Every file is checked (size, SHA-256 when crypto.subtle exists),
 *   and every side module (.so) compiled and checked as make
 *   wasm-package checks it (ChickenPackageCheck.checkModules): its
 *   imports against what this page's main module exports and imports,
 *   the dynamic linker's names and the package's other modules.  Any
 *   problem refuses the whole package before a single file reaches an
 *   interpreter: a module that fails to load leaves emscripten's
 *   dynamic linker with entries it cannot undo for the session.
 * - The files of the packages loaded are kept here, by their path
 *   under /packages, and given to every interpreter started (console
 *   and notebook kernel: files()), after waiting a while for those
 *   loading (ready(ms)); running ones get a package loaded later at once
 *   (on('load')), unless they have other files of its paths (another
 *   version of it, removed or replaced): it then takes effect at their
 *   next restart, as removing a package does (on('change')).  What each
 *   interpreter has is known from its start (applied(who)).
 * - A load that stalls (no data for STALL_MS) fails, and Remove stops
 *   one, so a package never keeps csi or the kernel from starting.
 * - The list [{url, enabled}] is kept in localStorage (chicken-repl.packages),
 *   merged with what other tabs keep, and loaded at every start; a
 *   package is kept once it loaded.  ?pkg=URL (repeatable) adds packages,
 *   after a confirm() for another site's.  A saved console session or a
 *   notebook records the packages it used (urls()); offer() lists the
 *   missing ones in the dialog without fetching them.
 * - Fetches obey the page's Content-Security-Policy (connect-src, made
 *   by make wasm WASM_WEB_PACKAGE_ORIGINS): a URL it does not allow is
 *   refused here with a message, not left to fail in the browser.  (It
 *   binds the page, not the workers where a package's code runs.)
 * - What a manifest says reaches the page as text only, without control
 *   or formatting characters (clean()). */

(function () {
  'use strict';

  const PC = window.ChickenPackageCheck;
  const $ = id => document.getElementById(id);
  const plural = (n, w) => n + ' ' + w + (n === 1 ? '' : 's');
  function fmtSize(n) {
    if (!(n >= 0)) return '';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + ' KB';
    return (n / 1024 / 1024).toFixed(1) + ' MB';
  }
  const MANIFEST_MAX = 4 * 1024 * 1024;
  // the most a bundle may have, unpacked or not (aux has 17.6 MB), and
  // files (aux has 385)
  const BUNDLE_MAX = 256 * 1024 * 1024, FILES_MAX = 20000;
  const STALL_MS = 30000;
  const STORE_KEY = 'packages';
  const URL_MAX = 2000, LIST_MAX = 50;

  class Refusal extends Error {}
  const refuse = msg => { throw new Refusal(msg); };
  // text from elsewhere, as one line without control or bidi characters
  const clean = s => String(s).replace(/[\p{Cc}\p{Cf}\u2028\u2029]+/gu, ' ');
  const why = e => clean((e && e.message) || e);

  // a package's URL: its manifest.json, or the directory holding it
  function manifestUrl(text) {
    let u;
    try { u = new URL(String(text).trim(), location.href); } catch (e) { return null; }
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
    if (u.username || u.password) return null;   // (fetch refuses them; a confirm() would mislead)
    u.hash = '';
    if (!/\.json$/i.test(u.pathname)) u.pathname = u.pathname.replace(/\/?$/, '/') + 'manifest.json';
    return u.href.length <= URL_MAX ? u.href : null;
  }
  // a name for a package not fetched yet: its directory's
  function nameOfUrl(url) {
    const p = new URL(url).pathname.split('/').filter(Boolean);
    if (p.length && /^manifest\.json$/i.test(p[p.length - 1])) p.pop();
    if (!p.length) return new URL(url).host;
    let n = p[p.length - 1];
    try { n = decodeURIComponent(n); } catch (e) { /* a bare "%": as it is */ }
    return clean(n).slice(0, 80);
  }

  // ---- the page's Content-Security-Policy: where it may fetch from

  function connectSources() {
    const m = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
    if (!m) return null;
    const dirs = {};
    for (const d of m.content.split(';')) {
      const t = d.trim().split(/\s+/).filter(Boolean);
      if (t.length && !(t[0].toLowerCase() in dirs)) dirs[t[0].toLowerCase()] = t.slice(1);
    }
    return dirs['connect-src'] || dirs['default-src'] || null;
  }
  // whether the CSP source expression SRC allows URL U (scheme, host
  // and port; a path in SRC is left to the browser)
  function sourceAllows(src, u) {
    const s = src.toLowerCase();
    if (s === "'self'") return u.origin === location.origin;
    if (s === '*') return u.protocol === 'https:' || u.protocol === 'http:';
    if (/^[a-z][a-z0-9+.-]*:$/.test(s)) return u.protocol === s || (s === 'http:' && u.protocol === 'https:');
    const m = /^(?:([a-z][a-z0-9+.-]*):\/\/)?(\*|(?:\*\.)?[a-z0-9.-]+|\[[0-9a-f:.]+\])(?::(\*|\d+))?(?:\/.*)?$/.exec(s);
    if (!m) return false;
    const proto = m[1] ? m[1] + ':' : location.protocol;
    if (!(u.protocol === proto || (proto === 'http:' && u.protocol === 'https:'))) return false;
    const host = m[2];
    if (host.startsWith('*.') ? !u.hostname.endsWith(host.slice(1)) : host !== '*' && u.hostname !== host) return false;
    const deflt = p => (p === 'https:' ? '443' : '80');
    const want = m[3] || deflt(proto);
    return want === '*' || (u.port || deflt(u.protocol)) === want ||
      (!m[3] && u.protocol === 'https:' && proto === 'http:' && (u.port || '443') === '443');
  }
  function allowedByPage(url) {
    const srcs = connectSources();
    if (!srcs) return true;
    const u = new URL(url);
    return srcs.some(s => sourceAllows(s, u));
  }
  // where the page may fetch packages from, in words
  function allowedOrigins() {
    const srcs = connectSources();
    if (!srcs) return 'anywhere';
    const l = srcs.filter(s => s.toLowerCase() !== "'none'").map(s => (s.toLowerCase() === "'self'" ? location.origin : s));
    return l.length ? l.join(', ') : 'nowhere';
  }

  // ---- fetching

  async function fetchOk(url, what, signal) {
    let r;
    try { r = await fetch(url, { cache: 'no-cache', signal }); }
    catch (e) {
      if (signal && signal.aborted) throw e;
      refuse('could not fetch ' + what + ': ' + why(e) +
             (new URL(url).origin !== location.origin ? ' (the other site must allow it: Access-Control-Allow-Origin)' : ''));
    }
    if (!r.ok) refuse('could not fetch ' + what + ' (HTTP ' + r.status + ' for ' + url + ')');
    return r;
  }
  // what READER gives, at most MAX bytes (else the refusal BIG);
  // progress(n) as it comes
  async function readAll(rd, max, big, progress) {
    const parts = [];
    let n = 0;
    for (;;) {
      const { done, value } = await rd.read();
      if (done) break;
      n += value.length;
      if (n > max) { rd.cancel().catch(() => {}); refuse(big); }
      parts.push(value);
      if (progress) progress(n);
    }
    const out = new Uint8Array(n);
    let at = 0;
    for (const p of parts) { out.set(p, at); at += p.length; }
    return out;
  }
  // the body, at most MAX bytes; progress(n) as it comes
  async function readBody(r, max, progress) {
    if (!r.body || typeof r.body.getReader !== 'function') {
      const b = new Uint8Array(await r.arrayBuffer());
      if (b.length > max) refuse('it is larger than its manifest says');
      return b;
    }
    return readAll(r.body.getReader(), max, 'it is larger than its manifest says', progress);
  }
  // BYTES unpacked, at most MAX bytes.  (Read here: through a Response
  // the error of damaged data would be a bare "Failed to fetch" or
  // "The operation was aborted", and Firefox would log it.)
  function gunzip(bytes, max) {
    return readAll(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip')).getReader(), max,
                   'its bundle unpacks to more than its manifest says');
  }
  const hex = buf => Array.from(new Uint8Array(buf), b => b.toString(16).padStart(2, '0')).join('');
  const subtle = (() => { try { return (self.crypto && self.crypto.subtle) || null; } catch (e) { return null; } })();
  const sameBytes = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

  const isInt = (n, lo) => Number.isSafeInteger(n) && n >= lo;
  const isFileName = s => typeof s === 'string' && PC.SAFE.test(s) && s !== '.' && s !== '..';

  // the manifest's build B for this page, checked, or a Refusal
  function checkBuild(b, host) {
    if (!b || typeof b !== 'object' || !Array.isArray(b.files)) refuse('its manifest is damaged (no files)');
    if (b.arch !== host.arch || b.eh !== host.eh)
      refuse('its build for this page’s ABI is for ' + b.arch + '/' + b.eh + ', not ' + host.arch + '/' + host.eh);
    if (!isInt(b.size, 0) || !isFileName(b.rawBundle) || (b.bundle != null && !isFileName(b.bundle)) ||
        (b.gzSize != null && !isInt(b.gzSize, 0)))
      refuse('its manifest is damaged (bundle)');
    if (b.size > BUNDLE_MAX || b.gzSize > BUNDLE_MAX || b.files.length > FILES_MAX)
      refuse('it is too large: this page loads at most ' + fmtSize(BUNDLE_MAX) + ' and ' + FILES_MAX + ' files a package');
    for (const f of b.files) {
      if (!f || typeof f !== 'object') refuse('its manifest is damaged (files)');
      const bad = PC.checkPath(f.path);
      if (bad) refuse('its manifest has a ' + bad);
    }
    const clash = PC.checkPaths(b.files.map(f => f.path));
    if (clash) refuse('its manifest is damaged (' + clash + ')');
    for (const f of b.files) {
      if (!isInt(f.offset, 0) || !isInt(f.size, 0) || f.offset + f.size > b.size)
        refuse('its manifest is damaged (' + f.path + ' is not in the bundle)');
      if (typeof f.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(f.sha256))
        refuse('its manifest is damaged (no SHA-256 of ' + f.path + ')');
    }
  }

  // ---- the manager

  function create(host) {
    // host: {abi, arch, eh (of the build running; abi null without dynamic
    // loading), unavailable() (why nothing runs, or null), replModule()
    // (Promise<WebAssembly.Module>), store (repl.js's)}
    const entries = [];
    const hooks = { load: [], change: [] };
    const emit = (k, ...a) => { for (const f of hooks[k]) { try { f(...a); } catch (e) { /* the hook's problem */ } } };
    const queue = [];
    let running = null, idle = [];
    let mainInfo = null;
    // who (an interpreter: 'console', 'notebook') -> Map of the paths of
    // the files it got since it started to their SHA-256
    const given = new Map();
    // the URLs this tab added to the list kept, and removed from it
    const added = new Set(), dropped = new Set();

    const byUrl = url => entries.find(e => e.url === url) || null;
    // (one removed while it loads no longer counts)
    const busy = () => (!!running && entries.includes(running)) || queue.length > 0;
    function settle() {
      if (busy()) return;
      for (const f of idle.splice(0)) f();
    }
    // the list kept: what is kept now (another tab may have changed it),
    // with this tab's changes
    function save() {
      let kept = [];
      try { kept = JSON.parse(host.store.get(STORE_KEY, '[]')); } catch (x) { kept = []; }
      if (!Array.isArray(kept)) kept = [];
      const mine = new Map(entries.filter(e => e.saved).map(e => [e.url, e.enabled]));
      const l = [], seen = new Set();
      for (const k of kept) {
        if (!k || typeof k.url !== 'string' || seen.has(k.url) || dropped.has(k.url)) continue;
        seen.add(k.url);
        l.push({ url: k.url, enabled: mine.has(k.url) ? mine.get(k.url) : k.enabled !== false });
      }
      for (const [url, enabled] of mine)
        if (!seen.has(url) && added.has(url)) { seen.add(url); l.push({ url, enabled }); }
      host.store.set(STORE_KEY, JSON.stringify(l.slice(0, LIST_MAX)));
    }

    function mainModuleInfo() {
      // (with their kinds: an import must be of the kind of what it gets)
      if (!mainInfo)
        mainInfo = host.replModule().then(m => ({
          exports: new Map(WebAssembly.Module.exports(m).map(e => [e.name, e.kind])),
          imports: new Map(WebAssembly.Module.imports(m)
                           .filter(i => i.module === 'env' || i.module === 'wasi_snapshot_preview1')
                           .map(i => [i.name, i.kind])),
        }));
      mainInfo.catch(() => { mainInfo = null; });
      return mainInfo;
    }

    function setState(e, state, detail) {
      e.state = state;
      e.detail = detail || '';
      ui.update(e);
    }

    // what the page says when it may not fetch from URL's site
    function notAllowed(url) {
      const o = new URL(url).origin;
      return 'this page can load packages only from ' + allowedOrigins() + ', not from ' + o +
        ': copy the package there, or ask whoever publishes this page to allow ' + o +
        ' (WASM_WEB_PACKAGE_ORIGINS, see the README)';
    }

    // loads entry E: the files are E's only when every check passed.  It
    // fails when no data comes for STALL_MS, and stops when E is removed
    // (e.ac.abort()).
    async function load(e) {
      const ac = e.ac = new AbortController();
      let timer = 0;
      const kick = () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          e.stopped = 'no data came from its site for ' + STALL_MS / 1000 + ' s';
          ac.abort();
        }, STALL_MS);
      };
      const live = () => { if (ac.signal.aborted) refuse(e.stopped || 'stopped'); };
      try {
        kick();
        return await fetchAndCheck(e, ac.signal, kick, live, () => clearTimeout(timer));
      } catch (x) {
        if (ac.signal.aborted) refuse(e.stopped || 'stopped');
        throw x;
      } finally {
        clearTimeout(timer);
        e.ac = null;
      }
    }
    async function fetchAndCheck(e, signal, kick, live, fetched) {
      const unav = host.unavailable();
      if (unav) refuse('this browser cannot run csi: ' + unav);
      if (!host.abi) refuse('this build of the page cannot load packages (it was made with WASM_DYLINK=0)');
      if (!allowedByPage(e.url)) refuse(notAllowed(e.url));
      setState(e, 'downloading', 'fetching its manifest');
      const mr = await fetchOk(e.url, 'its manifest', signal);
      kick();
      let m;
      try { m = JSON.parse(new TextDecoder().decode(await readBody(mr, MANIFEST_MAX))); }
      catch (x) { live(); refuse(x instanceof Refusal ? x.message : 'its manifest is not JSON'); }
      if (!m || m.format !== 'chicken-wasm-package' || m.formatVersion !== 1 || !m.builds || typeof m.builds !== 'object')
        refuse('not a package manifest (format chicken-wasm-package, version 1)');
      if (typeof m.name !== 'string' || !PC.SAFE.test(m.name)) refuse('its manifest has no valid name');
      e.name = m.name;
      e.version = typeof m.version === 'string' ? clean(m.version).slice(0, 40) : '';
      e.eggs = Array.isArray(m.eggs) ? m.eggs.filter(g => g && typeof g.name === 'string')
        .map(g => ({ name: clean(g.name).slice(0, 80), version: typeof g.version === 'string' ? clean(g.version).slice(0, 40) : null })) : [];
      const b = Object.prototype.hasOwnProperty.call(m.builds, host.abi) ? m.builds[host.abi] : null;
      if (!b) {
        const abis = Object.keys(m.builds).filter(k => PC.ABI_RE.test(k) && m.builds[k] && typeof m.builds[k] === 'object');
        const has = abis.map(k => clean(String(m.builds[k].arch).slice(0, 10) + '/' + String(m.builds[k].eh).slice(0, 10)) + '/' + k);
        // (one of the page's other builds may load it)
        const other = (host.builds || []).find(x => x.abi && x.abi !== host.abi && abis.includes(x.abi));
        e.unbuilt = true;
        refuse('not built for this page (needs ' + host.arch + '/' + host.eh + '/' + host.abi + ')' +
               (has.length ? '; it has ' + has.join(', ') : '') +
               (other ? '. This page’s ' + other.arch + ' build can load it: Settings → WebAssembly build'
                : '. It must be built again for this version of the page (make wasm-package); Remove it meanwhile'));
      }
      checkBuild(b, host);
      e.size = b.size;
      e.gzSize = b.gzSize;
      // the bundle: gzipped when the browser can unpack it; beside the
      // manifest (after its redirects)
      const gz = typeof DecompressionStream === 'function' && b.bundle;
      const bundleUrl = new URL(gz ? b.bundle : b.rawBundle, mr.url || e.url).href;
      if (!allowedByPage(bundleUrl)) refuse('its bundle is on a site this page may not fetch from');
      const total = gz && b.gzSize != null ? b.gzSize : b.size;
      setState(e, 'downloading', 'downloading ' + fmtSize(total));
      const br = await fetchOk(bundleUrl, 'its bundle', signal);
      kick();
      let bytes = await readBody(br, Math.max(total, b.size), n => {
        kick();
        if (total) setState(e, 'downloading', 'downloading ' + Math.min(100, Math.floor(100 * n / total)) + '% of ' + fmtSize(total));
      });
      fetched();
      // (a server may have unpacked it already: Content-Encoding)
      if (gz && bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b) {
        try { bytes = await gunzip(bytes, b.size); }
        catch (x) { refuse(x instanceof Refusal ? x.message : 'its bundle is not valid gzip: ' + why(x)); }
      }
      if (bytes.length !== b.size) refuse('its bundle has ' + bytes.length + ' bytes, not ' + b.size + ' as its manifest says');
      // every file, checked; then every side module (every WebAssembly
      // binary: load takes one for an extension, whatever its name)
      setState(e, 'validating', 'checking ' + plural(b.files.length, 'file'));
      const files = [];
      for (const f of b.files) {
        live();
        const data = bytes.slice(f.offset, f.offset + f.size);
        if (subtle && hex(await subtle.digest('SHA-256', data)) !== f.sha256)
          refuse(f.path + ': bad SHA-256 (the bundle does not match its manifest)');
        files.push({ path: f.path, data, sha256: f.sha256 });
      }
      e.unverified = !subtle;
      const sos = files.filter(f => PC.isModule(f.data));
      const modules = [];
      let i = 0;
      for (const f of sos) {
        live();
        setState(e, 'validating', 'checking module ' + (++i) + ' of ' + sos.length);
        let info;
        try { info = PC.parseModule(f.data); } catch (x) { refuse(f.path + ': ' + why(x)); }
        try { await WebAssembly.compile(f.data); }
        catch (x) { refuse(f.path + ': not a valid WebAssembly module for this browser: ' + why(x)); }
        modules.push({ path: f.path, info });
      }
      const main = await mainModuleInfo();
      live();
      const problems = PC.checkModules(modules, { exports: main.exports, mainImports: main.imports, arch: host.arch });
      if (problems.length)
        refuse('csi of this page cannot load its modules: ' + problems.slice(0, 3).join('; ') +
               (problems.length > 3 ? '; and ' + (problems.length - 3) + ' more' : ''));
      // another package of its name is replaced; another's files must be
      // the same as its own, if it has some of them, and none may be the
      // directory of another's
      const old = entries.find(x => x !== e && x.state === 'loaded' && x.name === e.name) || null;
      const owner = new Map();
      for (const x of entries) if (x !== e && x !== old && x.state === 'loaded') for (const f of x.files) owner.set(f.path, x);
      for (const f of files) {
        const x = owner.get('/packages/' + f.path);
        if (x && !sameBytes(x.files.find(y => y.path === '/packages/' + f.path).data, f.data))
          refuse(f.path + ' is also in the package ' + x.name + ', with other contents');
      }
      const clash = PC.checkPaths([...new Set([...owner.keys(), ...files.map(f => '/packages/' + f.path)])]);
      if (clash) refuse('its files clash with those of another package loaded: ' + clash.replace(/\/packages\//g, ''));
      return { files: files.map(f => ({ path: '/packages/' + f.path, data: f.data, sha256: f.sha256 })), old };
    }

    async function pump() {
      if (running) return;
      while (queue.length) {
        const e = running = queue.shift();
        if (!entries.includes(e)) continue;
        try {
          const { files, old } = await load(e);
          if (!entries.includes(e)) continue;   // removed meanwhile
          e.files = files;
          if (old) {
            entries.splice(entries.indexOf(old), 1);
            ui.drop(old);
            if (old.url !== e.url) dropped.add(old.url);
          }
          // an interpreter running gets it now, unless it has other files
          // of its paths (another version, replaced or removed): then at
          // its restart
          const now = new Set();
          for (const [who, had] of given) {
            if (files.some(f => had.has(f.path) && had.get(f.path) !== f.sha256)) e.restartFor.add(who);
            else { now.add(who); for (const f of files) had.set(f.path, f.sha256); }
          }
          e.saved = true;                // (kept once it loaded)
          added.add(e.url);
          dropped.delete(e.url);
          setState(e, 'loaded', '');
          save();
          ui.say('Loaded ' + e.name + (e.version ? ' ' + e.version : '') + (e.restartFor.size ? '; restart to use it instead of ' +
                 (old && old.version ? 'version ' + old.version : 'the one loaded') : '') + '.');
          emit('load', e, files, who => !given.has(who) || now.has(who));
          if (old) emit('change', 'replaced', e);
        } catch (x) {
          if (!(x instanceof Refusal)) console.warn(x);
          e.files = null;
          if (entries.includes(e)) {
            setState(e, e.unbuilt ? 'unbuilt' : 'failed', why(x));
            ui.say((e.name || nameOfUrl(e.url)) + ': ' + why(x));
          }
        } finally {
          running = null;
        }
      }
      settle();
    }
    function enqueue(e) {
      e.unbuilt = false;
      e.stopped = null;
      e.restartFor = new Set();
      e.noted = new Set();
      e.t0 = Date.now();
      setState(e, 'queued', '');
      queue.push(e);
      pump();
    }

    // adds the package at URL (or loads it again), kept once it loaded;
    // opts.offered: from offer(), listed only; opts.link: from ?pkg=
    function add(text, opts) {
      const url = manifestUrl(text);
      if (!url) return { error: 'not an http(s) URL' };
      let e = byUrl(url);
      if (e && (e.state === 'loaded' || e.state === 'queued' || e.state === 'downloading' || e.state === 'validating'))
        return { entry: e, already: true };
      if (!e) {
        if (entries.length >= LIST_MAX) return { error: 'too many packages (' + LIST_MAX + ')' };
        e = { url, name: null, version: '', eggs: null, state: 'offered', detail: '', saved: false, enabled: true, files: null };
        entries.push(e);
      }
      if (opts && opts.offered) {
        e.from = opts.from || null;
        ui.update(e);
        return { entry: e };
      }
      if (opts && opts.link) e.link = true;
      if (!e.enabled) {
        e.enabled = true;
        if (e.saved) save();
      }
      enqueue(e);
      return { entry: e };
    }

    function remove(e) {
      const i = entries.indexOf(e);
      if (i < 0) return;
      entries.splice(i, 1);
      const qi = queue.indexOf(e);
      if (qi >= 0) queue.splice(qi, 1);
      if (e.ac) { e.stopped = 'removed'; e.ac.abort(); }
      ui.drop(e);
      if (e.saved) { dropped.add(e.url); added.delete(e.url); save(); }
      ui.say('Removed ' + (e.name || nameOfUrl(e.url)) + (e.state === 'loaded' ? '; restart to unload it.' : '.'));
      if (e.state === 'loaded') emit('change', 'removed', e);
      settle();
    }

    // ---- the dialog

    const ui = (() => {
      const dlg = $('packages');
      if (!dlg) return { update() {}, drop() {}, say() {}, open() {}, closed: () => Promise.resolve() };
      const list = $('packages-list'), input = $('packages-url'), loadBtn = $('packages-load');
      const statusEl = $('packages-status'), emptyEl = $('packages-empty');
      const rows = new Map();
      let returnFocus = null, rowIds = 0;
      const STATUS = {
        offered: 'not loaded', queued: 'waiting', downloading: 'downloading', validating: 'checking',
        loaded: 'loaded', failed: 'failed', unbuilt: 'not built for this page', off: 'not loaded',
      };
      function el(tag, cls, text) {
        const x = document.createElement(tag);
        if (cls) x.className = cls;
        if (text != null) x.textContent = text;
        return x;
      }
      function row(e) {
        let r = rows.get(e);
        if (r) return r;
        const li = el('li', 'pkg-row');
        const who = el('div', 'saves-who');
        const name = el('span', 'saves-name'), ver = el('span', 'saves-badge');
        const meta = el('span', 'saves-meta'), url = el('span', 'saves-meta pkg-url');
        const st = el('span', 'pkg-status');
        // (the buttons of two rows of one name differ by their URL)
        url.id = 'pkg-url-' + (++rowIds);
        who.append(name, ver, meta, url, st);
        const acts = el('div', 'saves-acts');
        const load = el('button', 'btn'), rm = el('button', 'btn danger', 'Remove');
        load.type = rm.type = 'button';
        load.setAttribute('aria-describedby', url.id);
        rm.setAttribute('aria-describedby', url.id);
        load.addEventListener('click', () => { add(e.url); input.focus(); });
        rm.addEventListener('click', () => {
          // the focus goes to the next row's button, or the input
          const all = [...rows.values()], k = all.indexOf(rows.get(e));
          remove(e);
          const next = all[k + 1] || all[k - 1];
          (next && next.rm.isConnected ? next.rm : input).focus();
        });
        acts.append(load, rm);
        li.append(who, acts);
        r = { li, name, ver, meta, url, st, load, rm, shown: null };
        rows.set(e, r);
        list.appendChild(li);
        return r;
      }
      function update(e) {
        if (!entries.includes(e)) return;
        const r = row(e);
        // a row added, loaded or failed is brought into view
        if (r.shown !== e.state && /^(offered|queued|loaded|failed|unbuilt)$/.test(e.state) && dlg.open)
          r.li.scrollIntoView({ block: 'nearest' });
        r.shown = e.state;
        const n = e.name || nameOfUrl(e.url);
        r.name.textContent = n;
        r.ver.textContent = e.version || '';
        r.ver.hidden = !e.version;
        const bits = [];
        if (e.eggs) bits.push(plural(e.eggs.length, 'egg'));
        if (e.gzSize != null || e.size != null)
          bits.push(e.gzSize != null ? fmtSize(e.gzSize) + ' (' + fmtSize(e.size) + ' unpacked)' : fmtSize(e.size));
        if (e.state === 'loaded' && e.unverified) bits.push('SHA-256 not checked (not a secure context)');
        r.meta.textContent = bits.join(' · ');
        r.meta.hidden = !bits.length;
        r.url.textContent = e.url;
        let s = STATUS[e.state] || e.state;
        if (e.state === 'failed') s = 'failed: ' + e.detail;
        else if (e.state === 'unbuilt') s = e.detail;
        else if (e.state === 'loaded' && e.restartFor && e.restartFor.size) s = 'loaded — restart to apply';
        else if (e.state === 'offered' && e.from) s = 'not loaded (used by ' + e.from + ')';
        else if (e.detail) s = e.detail + '…';
        r.st.textContent = s;
        r.st.dataset.state = e.state === 'unbuilt' ? 'failed' : /^(queued|downloading|validating)$/.test(e.state) ? 'busy' : e.state;
        r.li.setAttribute('aria-busy', String(r.st.dataset.state === 'busy'));
        const busyNow = r.st.dataset.state === 'busy';
        r.load.textContent = e.state === 'failed' || e.state === 'unbuilt' ? 'Retry' : 'Load';
        r.load.hidden = busyNow || e.state === 'loaded';
        r.load.setAttribute('aria-label', r.load.textContent + ' ' + n);
        r.rm.setAttribute('aria-label', 'Remove ' + n);
        emptyEl.hidden = entries.length > 0;
      }
      function drop(e) {
        const r = rows.get(e);
        if (r) { r.li.remove(); rows.delete(e); }
        emptyEl.hidden = entries.length > 0;
      }
      // (the same text again is said again: set after a frame without it)
      function say(text) {
        if (statusEl.textContent !== text) { statusEl.textContent = text; return; }
        statusEl.textContent = '';
        requestAnimationFrame(() => { if (!statusEl.textContent) statusEl.textContent = text; });
      }
      function submit() {
        const t = input.value.trim();
        if (!t) { say('Type the URL of a package: its manifest.json, or the directory holding it.'); input.focus(); return; }
        const r = add(t);
        if (r.error) { say('Cannot load “' + t.slice(0, 200) + '”: ' + r.error + '.'); input.focus(); return; }
        input.value = '';
        if (r.already) say((r.entry.name || nameOfUrl(r.entry.url)) + ' is ' + (r.entry.state === 'loaded' ? 'already loaded.' : 'loading.'));
        else say('Loading ' + nameOfUrl(r.entry.url) + '…');
      }
      loadBtn.addEventListener('click', submit);
      input.addEventListener('keydown', ev => {
        if (ev.key === 'Enter' && !ev.isComposing) { ev.preventDefault(); submit(); }
      });
      dlg.addEventListener('close', () => {
        if (returnFocus && returnFocus.isConnected && !returnFocus.disabled) returnFocus.focus();
        returnFocus = null;
      });
      function info() {
        const unav = host.unavailable();
        const b = $('packages-build');
        b.textContent = unav ? 'This browser cannot run csi, so no package can load: ' + unav
          : !host.abi ? 'This build of the page cannot load packages: it was made without dynamic loading (WASM_DYLINK=0).'
          : 'A package must have a build for this page: ' + host.arch + ' (' + host.eh + '), ABI ' + host.abi +
            '. This page may fetch packages from ' + allowedOrigins() + '.';
        loadBtn.disabled = input.disabled = !!unav || !host.abi;
      }
      function open() {
        if (dlg.open) return;
        info();
        for (const e of entries) update(e);
        emptyEl.hidden = entries.length > 0;
        returnFocus = document.activeElement;
        dlg.showModal();
        if (!input.disabled) input.focus();
      }
      emptyEl.hidden = false;
      // Promise, settled when the dialog is closed (at once without one)
      const closed = () => new Promise(r => dlg.addEventListener('close', () => r(), { once: true }));
      return { update, drop, say, open, closed };
    })();

    // opens the dialog once no other one is open (a session's offer
    // comes while the saves dialog closes)
    function openSoon() {
      const other = document.querySelector('dialog[open]');
      if (!other) { ui.open(); return; }
      other.addEventListener('close', () => setTimeout(openSoon, 0), { once: true });
    }

    // ---- start: the packages kept, then ?pkg=

    // (one entry that cannot be read is left out, not fatal to the page)
    function start() {
      let kept = [];
      try { kept = JSON.parse(host.store.get(STORE_KEY, '[]')); } catch (x) { kept = []; }
      if (!Array.isArray(kept)) kept = [];
      for (const k of kept.slice(0, LIST_MAX)) {
        try {
          const url = k && typeof k.url === 'string' ? manifestUrl(k.url) : null;
          if (!url || byUrl(url)) continue;
          const e = { url, name: null, version: '', eggs: null, state: 'off', detail: '', saved: true,
                      enabled: k.enabled !== false, files: null };
          entries.push(e);
          // (one that cannot load here fails at once, saying why)
          if (e.enabled) enqueue(e);
          else ui.update(e);
        } catch (x) { console.warn(x); }
      }
      let asked = [];
      try { asked = new URLSearchParams(location.search).getAll('pkg'); } catch (x) { asked = []; }
      for (const t of asked.slice(0, LIST_MAX)) {
        try {
          const url = manifestUrl(t);
          if (!url) continue;
          const e = byUrl(url);
          if (e && e.saved) { if (!e.enabled) add(url); continue; }
          // one this page may not fetch fails at once, without asking
          const o = new URL(url).origin;
          if (o !== location.origin && allowedByPage(url) &&
              !confirm('Load a package from ' + o + '?\n\n' + url + '\n\nA package is compiled code: it runs in ' +
                       'this page, with access to what the page keeps in this browser (saved sessions and notebooks). ' +
                       'Load it only from a site you trust.')) continue;
          add(url, { link: true });
        } catch (x) { console.warn(x); }
      }
    }
    start();

    return Object.freeze({
      // Promise, settled when no package is loading, or MS after the
      // last one loading was asked for (so a slow one delays the console
      // and the kernel once, not each of their starts)
      ready(ms) {
        if (!busy()) return Promise.resolve();
        const left = ms == null ? null : Math.max(...entries.filter(e => e === running || queue.includes(e)).map(e => e.t0)) + ms - Date.now();
        if (left != null && !(left > 0)) return Promise.resolve();
        return new Promise(r => { idle.push(r); if (left != null) setTimeout(r, left); });
      },
      busy,
      // the names of the packages loading
      pending: () => entries.filter(e => e === running || queue.includes(e)).map(e => e.name || nameOfUrl(e.url)),
      // the files of the packages loaded: [{path (/packages/...), data}]
      files() {
        const seen = new Set(), out = [];
        for (const e of entries) if (e.state === 'loaded' && e.files)
          for (const f of e.files) if (!seen.has(f.path)) { seen.add(f.path); out.push(f); }
        return out;
      },
      // the URLs of the packages loaded, for a save
      urls: () => entries.filter(e => e.state === 'loaded').map(e => e.url),
      // [{name, version, eggs, link (from ?pkg=)}] of the packages loaded
      loaded: () => entries.filter(e => e.state === 'loaded')
        .map(e => ({ name: e.name, version: e.version, eggs: e.eggs.length, link: !!e.link })),
      // the packages that failed and were not reported to WHO (a name)
      // yet, once each: [{name, reason}]
      failures(who) {
        const l = [];
        for (const e of entries) if ((e.state === 'failed' || e.state === 'unbuilt') && !(e.noted && e.noted.has(who))) {
          (e.noted || (e.noted = new Set())).add(who);
          l.push({ name: e.name || nameOfUrl(e.url), reason: e.detail });
        }
        return l;
      },
      // the interpreter WHO ('console', 'notebook') started with the
      // files(): a package that waited for its restart no longer does
      applied(who) {
        const had = new Map();
        for (const e of entries) if (e.state === 'loaded' && e.files)
          for (const f of e.files) if (!had.has(f.path)) had.set(f.path, f.sha256);
        given.set(who, had);
        for (const e of entries) if (e.restartFor && e.restartFor.delete(who)) ui.update(e);
      },
      // on('load', f(entry, files, apply)): a package loaded; apply(who)
      // whether the interpreter WHO running gets it now (else at its
      // restart: it has another version);
      // on('change', f(kind, entry)): 'removed' or 'replaced'
      on(k, f) { if (hooks[k]) hooks[k].push(f); },
      // the URLs of LIST (a save's) not loaded here, listed in the dialog
      // (not fetched); opts: {from: what used them, open: show the dialog}
      offer(list, opts) {
        const missing = [];
        for (const t of Array.isArray(list) ? list.slice(0, LIST_MAX) : []) {
          try {
            const url = manifestUrl(t);
            if (!url) continue;
            const e = byUrl(url);
            if (e && !/^(offered|failed|unbuilt|off)$/.test(e.state)) continue;   // loaded, or loading
            missing.push({ url, name: e && e.name ? e.name : nameOfUrl(url) });
            if (!e || e.state === 'offered') add(url, { offered: true, from: opts && opts.from });
          } catch (x) { console.warn(x); }
        }
        if (missing.length && opts && opts.open) openSoon();
        return missing;
      },
      open: () => ui.open(),
      // Promise, settled when the dialog is closed next
      closed: () => ui.closed(),
      nameOfUrl,
    });
  }

  window.ChickenPackages = Object.freeze({ create, manifestUrl });
})();
