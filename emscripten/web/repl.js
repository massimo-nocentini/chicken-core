/* repl.js - the CHICKEN Scheme REPL page (index.html)
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

/* The page side of the REPL (index.html): owns the csi worker
 * (repl-worker.js, see there for the message protocol) and the compiler
 * worker (compiler-worker.js), renders output, and handles input,
 * history, Stop, uploads and settings.  No dependencies.
 *
 * - The .wasm is compiled once here and handed to every csi worker, so
 *   Restart only instantiates.
 * - Output is buffered and rendered once per animation frame, then acked
 *   to the worker (which pauses csi above 1 MB unacked).
 * - Stop always posts "interrupt".  If the worker then stays silent for
 *   3 s while evaluating (a long primitive that never yields), it is
 *   terminated and a fresh one started.
 * - Settings, history and the theme live in localStorage when available;
 *   everything works without it (a build chosen in the Settings then
 *   goes in ?arch=).
 * - A page may have the modules of two architectures (make wasm
 *   WASM_WEB_ARCHS="wasm64 wasm32"): it runs the first one this browser
 *   supports (or the one ?arch= or the Settings ask for), and every
 *   worker loads that one's modules (see "the build" below).
 * - window.ChickenPage gives the Notebook tab (notebook.js) the settings,
 *   the storage, the compiled .wasm and the uploads; the page sends it
 *   "chicken:tab" and "chicken:settings" events.
 * - Named saves of the console (transcript, inputs, files) are kept in
 *   IndexedDB by sessions.js; opening one starts a fresh csi and runs its
 *   finished inputs again (see "saved sessions" below).  The heap of an
 *   interpreter is never saved, nor subdirectories of its home, its open
 *   ports and threads, the history or the Settings. */

(function () {
  'use strict';

  const RUNNING = 0, WAITING = 1, BUSY = 2, EXITED = 3, SLEEPING = 4;
  const TERM_LINES = 20000;             // terminal scrollback cap,
  const TERM_CHARS = 2000000;           // also for output without newlines
  const HISTORY_MAX = 500;
  const WATCHDOG_MS = 3000;
  const HOME = '/home/web_user/';
  const PROMPT_END = /#;(?:[^\s>]*:)?\d+> $/;    // "#;3> ", in a module "#;m:3> " (csi.scm)

  const meta = name => (document.querySelector('meta[name="' + name + '"]') || {}).content || '';
  const BUILD = meta('chicken-build');
  const Q = BUILD && BUILD.indexOf('@') < 0 ? '?v=' + encodeURIComponent(BUILD) : '';
  const $ = id => document.getElementById(id);
  const term = $('term'), line = $('line'), statusPill = $('status'), statusText = $('status-text');

  // ---- storage (may be unavailable: private mode, blocked site data)

  const store = {
    // whether settings persist (not with blocked site data, say)
    works: (() => {
      try { localStorage.setItem('chicken-repl.?', '1'); localStorage.removeItem('chicken-repl.?'); return true; }
      catch (e) { return false; }
    })(),
    get(k, d) {
      try { const v = localStorage.getItem('chicken-repl.' + k); return v === null ? d : v; }
      catch (e) { return d; }
    },
    set(k, v) {                         // whether it was stored
      try { localStorage.setItem('chicken-repl.' + k, v); return true; } catch (e) { return false; }
    },
  };
  const touch = matchMedia('(pointer: coarse)').matches;
  const settings = {
    csirc: store.get('csirc', ''),
    args: store.get('args', ''),
    sliceMs: Number(store.get('sliceMs', '50')) || 50,
    quotes: store.get('quotes', touch ? '1' : '0') === '1',
    theme: store.get('theme', 'auto'),
    arch: store.get('arch', 'auto'),    // the build to run, when the page has several
  };

  function applyTheme() {
    if (settings.theme === 'light' || settings.theme === 'dark')
      document.documentElement.dataset.theme = settings.theme;
    else delete document.documentElement.dataset.theme;
  }
  applyTheme();

  // ---- the build

  // The builds of the page (make wasm WASM_WEB_ARCHS=...), "ARCH:EH" each
  // in the chicken-wasm-builds meta tag: the first one's modules are
  // beside the page, another's in a directory named after its
  // architecture.  EH is how setjmp/longjmp were built (WASM_SJLJ):
  // exnref, legacy or none.  A page without the tag has the one build
  // of the chicken-wasm-arch and chicken-wasm-eh tags.
  const BUILDS = (() => {
    const l = [], words = meta('chicken-wasm-builds').split(/\s+/).filter(w => w && w.indexOf('@') < 0);
    words.forEach((w, i) => {
      const [arch, eh] = w.split(':');
      if (/^wasm(32|64)$/.test(arch) && /^(exnref|legacy|none)$/.test(eh) && !l.some(b => b.arch === arch))
        l.push({ arch, eh, dir: i ? arch + '/' : '' });
    });
    return l.length ? l : [{ arch: meta('chicken-wasm-arch'), eh: meta('chicken-wasm-eh'), dir: '' }];
  })();
  const PREFER = ['wasm64', 'wasm32'];     // the order of the automatic choice

  // A wasm64 build needs memory64 in the engine, and one made with
  // WASM_SJLJ=wasm (the default on wasm64) or wasm-legacy (the default
  // on wasm32) the exception handling instructions it uses: without them
  // the modules fail to compile.  Each probe module has just the
  // feature: a 64-bit memory, an empty try_table (exnref), an empty
  // legacy try.  A feature is probed only when a build that needs it is
  // considered: Firefox may warn about a module with the deprecated try,
  // even a probe.
  const HEADER = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];   // magic, version
  const FUNC = [0x01, 0x04, 0x01, 0x60, 0x00, 0x00,                  // type: [] -> []
                0x03, 0x02, 0x01, 0x00];                             // one function
  const PROBES = {
    memory64: [...HEADER, 0x05, 0x03, 0x01, 0x04, 0x00],             // memory: i64, min 0
    exnref: [...HEADER, ...FUNC, 0x0a, 0x08, 0x01, 0x06, 0x00, 0x1f, 0x40, 0x00, 0x0b, 0x0b],  // try_table end end
    legacy: [...HEADER, ...FUNC, 0x0a, 0x07, 0x01, 0x05, 0x00, 0x06, 0x40, 0x0b, 0x0b],        // try end end
  };
  const FEATURES = {
    memory64: '64-bit WebAssembly (memory64)',
    exnref: 'WebAssembly exception handling with exnref',
    legacy: 'WebAssembly exception handling (the legacy instructions)',
  };
  const probed = {};
  function has(f) {
    if (!(f in probed)) {
      try { probed[f] = WebAssembly.validate(new Uint8Array(PROBES[f])); }
      catch (e) { probed[f] = false; }
    }
    return probed[f];
  }
  const needs = b => [...(b.arch === 'wasm64' ? ['memory64'] : []), ...(b.eh in PROBES ? [b.eh] : [])];
  const lacks = b => needs(b).filter(f => !has(f));
  // the same, but without a probe for legacy that has not been made
  const lacksKnown = b => needs(b).filter(f => (f !== 'legacy' || f in probed) && !has(f));
  const featureList = l => l.map(f => FEATURES[f]).join(' and ');

  // the browsers that run a build (see the README)
  function browsersFor(b) {
    if (b.arch === 'wasm64') return 'Chrome or Edge ' + (b.eh === 'exnref' ? 137 : 133) + ', Firefox 134 or later';
    if (b.eh === 'exnref') return 'Chrome or Edge 137, Firefox 131, Safari 18.4 or later';
    return 'Chrome or Edge 95, Firefox 100, Safari 15.4 or later';
  }
  // why this browser cannot run the page's only build b, and what to do
  function missingFeature(b, miss) {
    const exnref = b.eh === 'exnref';
    if (miss.includes('memory64'))
      return '; this browser does not support 64-bit WebAssembly (memory64), which this build needs.\n' +
        '; Use Chrome or Edge ' + (exnref ? 137 : 133) + ', Firefox 134 or later, or a build made with "make wasm WASM_ARCH=wasm32".';
    if (miss.includes('exnref'))
      return '; this browser does not support WebAssembly exception handling with exnref, which this build needs.\n' +
        (b.arch === 'wasm64'
         ? '; Use Chrome or Edge 137, Firefox 134 or later, or a build made with "make wasm WASM_SJLJ=wasm-legacy".'
         : '; Use Chrome or Edge 137, Firefox 131, Safari 18.4 or later, or a build made with ' +
           '"make wasm WASM_ARCH=wasm32 WASM_SJLJ=wasm-legacy".');
    return '; this browser does not support WebAssembly exception handling, which this build needs.\n' +
      '; Use ' + browsersFor(b) + ', or a build made with "make wasm ' +
      (b.arch === 'wasm32' ? 'WASM_ARCH=wasm32 ' : '') + 'WASM_SJLJ=emscripten".';
  }

  // The build to run: the one ?arch= in the URL asks for, else the one
  // chosen in the Settings (on a page with several builds), if this
  // browser can run it; else, as with "auto" for either, the first in
  // PREFER order it can run.  Returns {build, notes, missing}: build is
  // null when it can run none (missing then says why), notes explain
  // the choice.
  function choose(urlArch, setArch) {
    const inUrl = urlArch != null && urlArch !== '';
    const want = inUrl ? (urlArch === 'auto' ? null : urlArch)
      : BUILDS.length > 1 && setArch !== 'auto' ? setArch : null;
    const how = inUrl ? '?arch=' + urlArch.slice(0, 40) : 'the build chosen in the Settings';
    const notes = [];
    let build = null, refused = null;
    if (want != null) {
      const b = BUILDS.find(x => x.arch === want);
      if (!b)
        notes.push('; ignoring ' + how + ': this page has ' +
                   (BUILDS.length > 1 ? 'the ' + BUILDS.map(x => x.arch).join(' and ') + ' builds.'
                    : 'only the ' + BUILDS[0].arch + ' build.'));
      else if (lacks(b).length) {
        notes.push('; ignoring ' + how + ': this browser lacks ' + featureList(lacks(b)) +
                   ', which the ' + b.arch + ' build needs.');
        refused = b;
      } else {
        build = b;
        if (BUILDS.length > 1) notes.push('; running the ' + b.arch + ' build, as ' + how + ' asks.');
      }
    }
    if (build) return { build, notes, missing: null };
    const fails = [];
    for (const b of BUILDS.slice().sort((x, y) => PREFER.indexOf(x.arch) - PREFER.indexOf(y.arch))) {
      const miss = lacks(b);
      if (!miss.length) { build = b; break; }
      fails.push({ b, miss });
    }
    if (build && fails.length)
      notes.push(fails[0].b === refused ? '; running the ' + build.arch + ' build instead.'
                 : '; running the ' + build.arch + ' build: this browser lacks ' + featureList(fails[0].miss) +
                   ', which the ' + fails[0].b.arch + ' build needs.');
    if (build) return { build, notes, missing: null };
    return {
      build: null, notes,
      missing: BUILDS.length === 1 ? missingFeature(fails[0].b, fails[0].miss)
        : '; this browser runs no build of this page: ' +
          fails.map(({ b, miss }) => b.arch + ' needs ' + featureList(miss)).join('; ') + '.\n' +
          '; Use ' + browsersFor(fails[fails.length - 1].b) + '.',
    };
  }

  let urlArch = null;
  try { urlArch = new URLSearchParams(location.search).get('arch'); } catch (e) { urlArch = null; }
  const CHOICE = choose(urlArch, settings.arch);
  // Without storage the choice in the Settings is the one ?arch= makes
  // (a choice there loads the page again with it).
  if (!store.works && BUILDS.length > 1 && (urlArch === 'auto' || BUILDS.some(b => b.arch === urlArch)))
    settings.arch = urlArch;
  const HTTP_HINT = 'This page must be served over HTTP, for example with "make wasm-serve".';
  // why nothing can run here, or null
  const LOCKOUT = location.protocol === 'file:'
    ? '; ' + HTTP_HINT + '\n; Browsers do not run workers or fetch .wasm files from file:// URLs.'
    : typeof WebAssembly !== 'object' || typeof Worker !== 'function'
    ? '; this browser lacks WebAssembly or Web Workers.'
    : CHOICE.missing;
  // the build that runs; when none does, what a page with one build was
  // built for, and nothing on a page with several
  const RUNS = LOCKOUT ? (BUILDS.length > 1 ? null : BUILDS[0]) : CHOICE.build;
  const ARCH = RUNS ? RUNS.arch : '', EH = RUNS ? RUNS.eh : '';
  const DIR = CHOICE.build ? CHOICE.build.dir : '';
  // the workers get the build id and the directory of the modules
  const WQ = (() => {
    const p = new URLSearchParams();
    if (Q) p.set('v', BUILD);
    if (DIR) p.set('dir', DIR);
    const t = p.toString();
    return t ? '?' + t : '';
  })();
  const workerUrl = name => name + WQ;
  if (BUILDS.length > 1) {
    // the build in the header, and its choice in the Settings
    if (!LOCKOUT) {
      const chip = $('arch');
      chip.textContent = ARCH;
      chip.title = 'Running the ' + ARCH + ' build (' + (ARCH === 'wasm64' ? '64' : '32') +
        '-bit WebAssembly); this page has ' + BUILDS.map(b => b.arch).join(' and ') + '. Choose one in the Settings.';
      chip.hidden = false;
    }
    for (const r of document.querySelectorAll('input[name="arch"]'))
      r.parentNode.hidden = r.value !== 'auto' && !BUILDS.some(b => b.arch === r.value);
    archSetting();
    $('set-arch').hidden = false;
  }
  // The builds in the Settings: one this browser is known not to run
  // (probed, see lacksKnown) cannot be chosen.
  function archSetting() {
    if (BUILDS.length < 2) return;
    const cannot = [];
    for (const r of document.querySelectorAll('input[name="arch"]')) {
      const b = BUILDS.find(x => x.arch === r.value), miss = b ? lacksKnown(b) : [];
      r.disabled = miss.length > 0;
      if (miss.length) cannot.push('This browser cannot run ' + b.arch + ': it lacks ' + featureList(miss) + '.');
    }
    $('set-arch-help').textContent = (LOCKOUT ? '' : 'Running ' + ARCH + '. ') +
      'Automatic runs ' + PREFER.filter(a => BUILDS.some(b => b.arch === a)).join(' where the browser supports it, else ') +
      '; ?arch= in the URL overrides this. Choosing another build than the one running reloads the page' +
      (store.works ? '.' : ' with ?arch=, as this browser keeps no settings.') +
      (cannot.length ? ' ' + cannot.join(' ') : '');
  }

  // ---- terminal output

  let pending = [];                     // [{cls, text}] not yet rendered
  let ackChars = 0;                     // worker output rendered, not yet acked
  let rendering = 0;
  let lines = 0, chars = 0;
  let tail = '';                        // the end of the transcript, for prompt detection

  function countLines(s) {
    let n = 0;
    for (let i = s.indexOf('\n'); i >= 0; i = s.indexOf('\n', i + 1)) n++;
    return n;
  }

  // cls: 'out' (stdout), 'err', 'in' (echoed input), 'sys' (page notes)
  function emit(cls, text, fromWorker) {
    if (!text) return;
    if (cls !== 'sys') tail = (tail + text).slice(-64);
    const last = pending[pending.length - 1];
    if (last && last.cls === cls) {
      last.text += text;
      // what render() would trim at once (pieces of a large write come
      // in many messages a frame)
      if (last.text.length > TERM_CHARS) last.text = last.text.slice(-TERM_CHARS);
    } else pending.push({ cls, text });
    if (fromWorker) ackChars += text.length;
    if (!rendering) rendering = requestAnimationFrame(render);
  }
  function note(text) {                 // a page message on a line of its own
    const lastText = pending.length ? pending[pending.length - 1].text : term.textContent;
    emit('sys', (lastText && !lastText.endsWith('\n') ? '\n' : '') + text + '\n');
  }

  function outNode(text) {
    // stdout, with csi's "#;N> " prompts dimmed
    const span = document.createElement('span');
    const parts = text.split(/(#;(?:[^\s>]*:)?\d+> )/);   // one group: the prompts at odd indices
    for (let i = 0; i < parts.length; i++) {
      if (!parts[i]) continue;
      if (i % 2) {
        const p = document.createElement('span');
        p.className = 'p';
        p.textContent = parts[i];
        span.appendChild(p);
      } else span.appendChild(document.createTextNode(parts[i]));
    }
    return span;
  }

  function render() {
    rendering = 0;
    const loading = term.querySelector('.loading');
    if (loading) loading.remove();
    const stick = term.scrollHeight - term.scrollTop - term.clientHeight < 40;
    const frag = document.createDocumentFragment();
    for (const { cls, text } of pending) {
      let node;
      if (cls === 'out') node = outNode(text);
      else {
        node = document.createElement('span');
        node.className = cls;
        node.textContent = text;
      }
      node._lines = countLines(text);
      node._chars = text.length;
      lines += node._lines;
      chars += text.length;
      frag.appendChild(node);
    }
    pending = [];
    term.appendChild(frag);
    trim();
    if (stick) term.scrollTop = term.scrollHeight;
    if (ackChars && worker) {
      worker.postMessage({ type: 'ack', bytes: ackChars });
    }
    ackChars = 0;
  }

  function trim() {
    let excess = lines - TERM_LINES;
    while (excess > 0 && term.firstChild) {
      const n = term.firstChild, nl = n._lines || 0;
      if (nl <= excess) {
        term.removeChild(n);
        lines -= nl;
        chars -= n._chars || 0;
        excess -= nl;
        continue;
      }
      const t = n.textContent;
      let i = -1;
      for (let k = 0; k < excess; k++) i = t.indexOf('\n', i + 1);
      n.textContent = t.slice(i + 1);
      n._lines -= excess;
      lines -= excess;
      chars -= i + 1;
      n._chars -= i + 1;
      excess = 0;
    }
    let cexcess = chars - TERM_CHARS;
    while (cexcess > 0 && term.firstChild) {
      const n = term.firstChild, nc = n._chars || 0, nl = n._lines || 0;
      if (nc <= cexcess) {
        term.removeChild(n);
        chars -= nc;
        lines -= nl;
        cexcess -= nc;
        continue;
      }
      const t = n.textContent.slice(cexcess);
      n.textContent = t;
      n._chars = t.length;
      n._lines = countLines(t);
      lines -= nl - n._lines;
      chars -= cexcess;
      cexcess = 0;
    }
  }

  function clearTerm() {
    pending = [];
    term.textContent = '';
    lines = chars = 0;
    if (worker && ackChars) worker.postMessage({ type: 'ack', bytes: ackChars });
    ackChars = 0;
  }

  // ---- status

  let worker = null, gen = 0, ready = false, alive = false, state = null;
  let msgs = 0, watchdog = 0, eofSent = false;   // msgs: messages from the worker
  const reqs = new Map();
  let reqId = 0;

  // saved sessions (session-store.js; sessions.js has the dialog)
  const SS = window.ChickenSessionStore || null;
  const ilog = SS ? SS.createInputLog() : null;   // the inputs of this interpreter
  // consoleGen counts the changes a save would keep; cleanGen is its
  // value when the console was last saved or opened
  let consoleGen = 0, cleanGen = 0, spawned = false;
  let origin = null;                    // {id, rev, name}: the saved state it was saved to or opened from
  let replay = null;                    // a saved session's inputs being run again (see replayStep)
  const saveProviders = new Map();      // kind -> provider (ChickenPage.provideSaves)

  const atPrompt = () => PROMPT_END.test(tail);

  function setStatus(key, text) {
    statusPill.dataset.state = key;
    if (statusText.textContent !== (text || key)) statusText.textContent = text || key;
  }
  function updateStatus() {
    if (!alive) return;
    if (!ready) return setStatus('loading');
    switch (state) {
    case WAITING:  return atPrompt() ? setStatus('ready') : setStatus('waiting', 'waiting for input');
    case RUNNING:
    case BUSY:     return setStatus('running');
    case SLEEPING: return setStatus('sleeping');
    default:       return setStatus('loading');
    }
  }
  function setInputEnabled(on) {
    line.disabled = !on;
    $('send').disabled = !on;
    $('stop').disabled = !on;
  }
  function showNotice(text) {
    $('notice-text').textContent = text;
    $('notice').hidden = false;
  }
  function hideNotice() { $('notice').hidden = true; }

  // ---- the csi worker

  let replModuleP = null;
  function compileWasm(url) {
    return (async () => {
      if (WebAssembly.compileStreaming) {
        try { return await WebAssembly.compileStreaming(fetch(url)); }
        catch (e) { /* no application/wasm type: fall back */ }
      }
      const r = await fetch(url);
      if (!r.ok) throw new Error('cannot fetch ' + url + ' (HTTP ' + r.status + ')');
      return WebAssembly.compile(await r.arrayBuffer());
    })();
  }

  const uploads = new Map();            // name -> Uint8Array, resent on every spawn
  let unavailable = null;               // why nothing can run (set at start), or null
  let unavailableDetail = null;         // the same with what to do about it

  function csiArgs() {
    const extra = settings.args.trim() ? settings.args.trim().split(/\s+/) : [];
    // CHICKEN_parse_command_line stops at the first non "-:" argument
    return [...extra.filter(a => a.startsWith('-:')),
            ...(settings.csirc.trim() ? [] : ['-n']),
            ...extra.filter(a => !a.startsWith('-:'))];
  }

  function kill() {
    if (replay) {                       // Restart, the watchdog, Settings, exit, crash
      const r = replay;
      replay = null;
      note('; replay stopped at input ' + r.i + ' of ' + r.n);
    }
    gen++;
    clearTimeout(watchdog);
    if (worker) worker.terminate();
    worker = null;
    alive = ready = false;
    state = null;
    for (const r of reqs.values()) r.reject(new Error('the interpreter was restarted'));
    reqs.clear();
    ackChars = 0;
  }

  function fatal(msg) {
    kill();
    setStatus('error', 'unavailable');
    setInputEnabled(false);
    note(msg);
    showNotice(msg.split('\n')[0].replace(/^; /, ''));
  }

  // opts: {files: [{name, data}] written to the home directory after the
  // uploads (not kept as uploads: Restart drops them, as it drops the
  // files csi writes), quiet: not a change of the console (an open)}
  async function spawn(opts) {
    opts = opts || {};
    if (unavailable) return;
    kill();
    if (ilog) ilog.reset();
    if (spawned && !opts.quiet) consoleGen++;
    spawned = true;
    const g = gen;
    alive = true;
    eofSent = false;
    tail = '';
    hideNotice();
    setInputEnabled(false);
    setStatus('loading');
    let mod;
    try {
      mod = await (replModuleP || (replModuleP = compileWasm(DIR + 'chicken-repl.wasm' + Q)));
    } catch (e) {
      replModuleP = null;
      if (g === gen) fatal('; could not load ' + DIR + 'chicken-repl.wasm: ' + ((e && e.message) || e) + '\n; ' + HTTP_HINT);
      return;
    }
    if (g !== gen) return;
    let w;
    try { w = new Worker(workerUrl('repl-worker.js')); }
    catch (e) { fatal('; could not start the worker: ' + ((e && e.message) || e) + '\n; ' + HTTP_HINT); return; }
    worker = w;
    w.onmessage = e => { if (g === gen) onWorker(e.data); };
    w.onerror = e => {
      if (g !== gen) return;
      e.preventDefault();
      fatal('; the interpreter worker failed: ' + ((e && e.message) || 'could not load repl-worker.js') + '\n; ' + HTTP_HINT);
    };
    w.onmessageerror = () => { if (g === gen) fatal('; a message from the interpreter could not be decoded'); };
    w.postMessage({
      type: 'init',
      args: csiArgs(),
      csirc: settings.csirc.trim() ? settings.csirc : null,
      files: [...[...uploads].map(([name, data]) => ({ path: HOME + name, data })),
              ...(opts.files || []).map(f => ({ path: HOME + f.name, data: f.data }))],
      sliceMs: settings.sliceMs,
      wasmModule: mod,
    });
  }

  function finished(text, notice) {
    render();
    kill();
    setStatus('exited');
    setInputEnabled(false);
    note(text);
    showNotice(notice);
  }

  let choiceNoted = false;
  function onWorker(m) {
    msgs++;
    switch (m.type) {
    case 'ready':
      ready = true;
      if (!choiceNoted) {               // before the banner
        choiceNoted = true;
        if (CHOICE.notes.length && term.querySelector('.loading')) term.querySelector('.loading').remove();
        for (const t of CHOICE.notes) note(t);
      }
      if (replay) {                     // no input until it is done; Stop ends it
        setInputEnabled(false);
        $('stop').disabled = false;
        setStatus('running', 'replaying ' + replay.i + '/' + replay.n);
        break;
      }
      setInputEnabled(true);
      if (!touch && document.activeElement !== $('src') && !document.querySelector('dialog[open]') &&
          !$('panel-repl').hidden) line.focus();
      updateStatus();
      break;
    case 'output':
      if (replay) {
        // hidden, but acked (the worker pauses csi above 1 MB unacked)
        tail = (tail + m.text).slice(-64);
        worker.postMessage({ type: 'ack', bytes: m.text.length });
        if (m.fd === 2) { if (replay.i === 0) replay.startErr = true; else replay.curErr = true; }
        break;
      }
      emit(m.fd === 2 ? 'err' : 'out', m.text, true);
      break;
    case 'state':
      state = m.state;
      if (state === WAITING && atPrompt() && ilog) ilog.prompt();
      if (replay) { replayStep(); break; }
      updateStatus();
      break;
    case 'exit':
      if (ilog) ilog.exited();
      if (eofSent && m.code === 0) finished('; session ended', 'The session ended.');
      else finished('; process exited (code ' + m.code + ')', 'csi exited with code ' + m.code + '.');
      break;
    case 'crash':
      if (ilog) ilog.interrupted();
      emit('err', String(m.message).replace(/\n?$/, '\n'));
      finished('; the interpreter crashed', 'The interpreter crashed.');
      break;
    case 'ack': case 'file': case 'dir': case 'error': {
      const r = reqs.get(m.id);
      if (!r) break;
      reqs.delete(m.id);
      if (m.type === 'error') r.reject(new Error(m.message)); else r.resolve(m);
      break;
    }
    }
  }

  function request(msg) {
    return new Promise((resolve, reject) => {
      if (!worker) { reject(new Error('the interpreter is not running')); return; }
      const id = ++reqId;
      reqs.set(id, { resolve, reject });
      worker.postMessage(Object.assign({ id }, msg));
    });
  }
  // the same, given up after ms (csi in a long primitive answers nothing;
  // a late answer is then ignored)
  function requestT(msg, ms) {
    return new Promise((resolve, reject) => {
      if (!worker) { reject(new Error('the interpreter is not running')); return; }
      const id = ++reqId;
      const timer = setTimeout(() => {
        if (!reqs.has(id)) return;
        reqs.delete(id);
        reject(new Error('timeout'));
      }, ms);
      reqs.set(id, { resolve: v => { clearTimeout(timer); resolve(v); }, reject: e => { clearTimeout(timer); reject(e); } });
      worker.postMessage(Object.assign({ id }, msg));
    });
  }

  // ---- Stop, Restart, EOF

  function stop() {
    if (!worker || !alive) return;
    if (replay) {                       // the inputs before it stay run
      const r = replay;
      replay = null;
      note('; replay stopped at input ' + r.i + ' of ' + r.n + '; the inputs before it were run (saving now keeps only those)');
      consoleGen++;                     // its saved copy has more: ask before replacing it
      // (an interrupt at a fresh prompt prints nothing: show the prompt)
      const p = state === WAITING && PROMPT_END.exec(tail);
      if (p) emit('out', p[0], false);
      writeHome(r.home);
      setInputEnabled(true);
    }
    if (ilog) ilog.interrupted();
    worker.postMessage({ type: 'interrupt' });
    if (state === WAITING) { line.value = ''; autosize(); }
    // The interrupt makes the worker report at once, whatever state it
    // was last in: a slice that woke from a sleep or got its input may
    // have run into a long primitive since, without reporting.  (Counted,
    // not timed: the reply may come within the clock's resolution, which
    // is 1 ms or coarser in some browsers.)
    const g = gen, n0 = msgs;
    clearTimeout(watchdog);
    watchdog = setTimeout(() => {
      if (g !== gen || msgs !== n0) return;
      note('; interpreter restarted (state lost)');
      spawn();
    }, WATCHDOG_MS);
  }

  function restart() {
    if (unavailable) return;            // also from Settings
    render();
    if (term.textContent) note('; restarting…');
    spawn();
  }

  function sendEof() {
    if (!worker || !alive || replay) return;
    const atP = state === WAITING && atPrompt();
    if (atP && !confirm('End session?')) return;
    eofSent = true;
    worker.postMessage({ type: 'input', text: '', eof: true });
    if (!atP && ilog) ilog.addEof();     // (at a prompt it ends the session: not logged)
    consoleGen++;
  }

  // ---- input and history

  let history = [];
  try { history = JSON.parse(store.get('history', '[]')); } catch (e) { history = []; }
  if (!Array.isArray(history)) history = [];
  let histIdx = history.length, draft = '';

  function autosize() {
    line.style.height = 'auto';
    line.style.height = line.scrollHeight + 'px';
  }

  // Touch keyboards "smart quote" apostrophes and quotes; outside string
  // literals they are never what the user meant in Scheme.
  function straightenQuotes(s) {
    let out = '', inStr = false, curly = false;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (inStr) {
        if (c === '\\') { out += c + (s[++i] || ''); continue; }
        if (c === '"' || (curly && c === '”')) { out += '"'; inStr = false; continue; }
        out += c;
      } else if (c === '"' || c === '“' || c === '”') {
        out += '"'; inStr = true; curly = c !== '"';
      } else if (c === '‘' || c === '’') out += "'";
      else if (c === ';') {                // a comment runs to the end of the line
        const j = s.indexOf('\n', i);
        const end = j < 0 ? s.length : j;
        out += s.slice(i, end); i = end - 1;
      } else out += c;
    }
    return out;
  }

  function submit() {
    if (!worker || !alive || !ready || replay) return;
    let text = line.value;
    if (settings.quotes) text = straightenQuotes(text);
    if (text.trim() && history[history.length - 1] !== text) {
      history.push(text);
      if (history.length > HISTORY_MAX) history = history.slice(-HISTORY_MAX);
      store.set('history', JSON.stringify(history));
    }
    histIdx = history.length;
    draft = '';
    const atP = state === WAITING && atPrompt();    // (before the echo, which goes in tail)
    emit('in', text + '\n');
    render();
    term.scrollTop = term.scrollHeight;
    worker.postMessage({ type: 'input', text: text + '\n', eof: false });
    if (ilog) ilog.add(text, atP);
    consoleGen++;
    line.value = '';
    autosize();
    // csi is evaluating until the worker reports otherwise, which may be
    // never: a long primitive does not yield (and then Stop needs the
    // watchdog)
    state = RUNNING;
    updateStatus();
  }

  function recall(dir) {
    if (!history.length) return;
    if (histIdx === history.length) draft = line.value;
    histIdx = Math.max(0, Math.min(history.length, histIdx + dir));
    line.value = histIdx === history.length ? draft : history[histIdx];
    autosize();
    const end = line.value.length;
    line.setSelectionRange(end, end);
  }

  line.addEventListener('input', autosize);
  line.addEventListener('keydown', e => {
    const v = line.value, a = line.selectionStart, b = line.selectionEnd;
    if (e.key === 'Enter' && !e.shiftKey && !e.altKey && !e.isComposing) {
      e.preventDefault();
      submit();
    } else if (e.key === 'Tab' && !e.shiftKey && !e.ctrlKey && !e.altKey && v) {
      e.preventDefault();                 // on an empty line Tab moves focus as usual
      line.setRangeText('  ', a, b, 'end');
      autosize();
    } else if (e.key === 'ArrowUp' && !e.shiftKey && !e.altKey && a === b && v.lastIndexOf('\n', a - 1) < 0) {
      e.preventDefault();
      recall(-1);
    } else if (e.key === 'ArrowDown' && !e.shiftKey && !e.altKey && a === b && v.indexOf('\n', a) < 0) {
      e.preventDefault();
      recall(1);
    } else if ((e.ctrlKey || e.metaKey) && !e.shiftKey && e.key.toLowerCase() === 'd' && !v) {
      e.preventDefault();
      sendEof();
    }
  });

  document.addEventListener('keydown', e => {
    if (document.querySelector('dialog[open]') || $('panel-repl').hidden) return;
    const k = e.key.toLowerCase();
    if (e.key === 'Escape') { e.preventDefault(); stop(); }
    else if (e.ctrlKey && !e.shiftKey && !e.altKey && !e.metaKey && k === 'c') {
      // Ctrl-C copies when something is selected, else it stops
      const sel = getSelection();
      if ((sel && !sel.isCollapsed) || line.selectionStart !== line.selectionEnd) return;
      e.preventDefault();
      stop();
    } else if ((e.ctrlKey || e.metaKey) && !e.shiftKey && !e.altKey && k === 's') {
      e.preventDefault();
      if (window.ChickenSaves) window.ChickenSaves.open({ kind: 'console', mode: 'quick' });
      else note('; saved sessions are not available: sessions.js did not load');
    } else if (e.ctrlKey && !e.shiftKey && !e.altKey && k === 'l') {
      e.preventDefault();
      clearTerm();
      consoleGen++;
    }
  });

  // Clicking the terminal (without selecting) focuses the input line.
  term.addEventListener('mouseup', () => {
    const sel = getSelection();
    if ((!sel || sel.isCollapsed) && !line.disabled) line.focus({ preventScroll: true });
  });

  $('entry').addEventListener('submit', e => { e.preventDefault(); submit(); line.focus(); });
  $('stop').addEventListener('click', () => { stop(); if (!touch) line.focus(); });
  $('restart').addEventListener('click', restart);
  $('notice-restart').addEventListener('click', () => { restart(); });
  $('clear').addEventListener('click', () => { clearTerm(); consoleGen++; if (!touch && !line.disabled) line.focus(); });
  $('hist-up').addEventListener('click', () => { recall(-1); line.focus(); });
  $('hist-down').addEventListener('click', () => { recall(1); line.focus(); });

  // ---- uploads (button and drag and drop)

  const uploadHooks = [];               // ChickenPage.onUpload (the notebook)
  async function uploadFiles(files) {
    if (unavailable) return;            // nothing could load them
    let stored = false;
    for (const f of files) {
      const name = f.name.replace(/^.*[\\/]/, '') || 'upload';
      let data;
      try { data = new Uint8Array(await f.arrayBuffer()); }
      catch (e) { note('; could not read ' + name + ': ' + e.message); continue; }
      uploads.set(name, data);
      if (!stored) { stored = true; consoleGen++; }
      for (const hook of uploadHooks) { try { hook(name, data); } catch (e) { /* the hook's problem */ } }
      try {
        if (worker && ready) await request({ type: 'writeFile', path: HOME + name, data });
        else if (worker) worker.postMessage({ type: 'writeFile', id: ++reqId, path: HOME + name, data });
        note('; uploaded ' + name + ' (' + data.length + ' bytes) — load it with ,l ' + name);
      } catch (e) {
        note('; upload of ' + name + ' failed: ' + e.message);
      }
    }
  }
  $('upload-btn').addEventListener('click', () => $('upload').click());
  $('upload').addEventListener('change', e => {
    const files = [...e.target.files];
    e.target.value = '';
    uploadFiles(files).then(() => { if (!touch && !line.disabled) line.focus(); });
  });
  const consoleBox = $('console');
  consoleBox.addEventListener('dragover', e => {
    if (e.dataTransfer && [...e.dataTransfer.types].includes('Files')) {
      e.preventDefault();
      consoleBox.classList.add('drop');
    }
  });
  consoleBox.addEventListener('dragleave', () => consoleBox.classList.remove('drop'));
  consoleBox.addEventListener('drop', e => {
    consoleBox.classList.remove('drop');
    if (!e.dataTransfer || !e.dataTransfer.files.length) return;
    e.preventDefault();
    uploadFiles([...e.dataTransfer.files]);
  });

  // ---- settings

  const dlg = $('settings');
  let archShown = null;                 // the build checked when the dialog opened
  $('settings-btn').addEventListener('click', () => {
    $('set-csirc').value = settings.csirc;
    $('set-args').value = settings.args;
    $('set-slice').value = settings.sliceMs;
    $('set-quotes').checked = settings.quotes;
    for (const r of document.querySelectorAll('input[name="theme"]')) r.checked = r.value === settings.theme;
    for (const r of document.querySelectorAll('input[name="arch"]')) r.checked = r.value === settings.arch;
    if (!document.querySelector('input[name="arch"]:checked')) $('set-arch-auto').checked = true;
    archShown = document.querySelector('input[name="arch"]:checked').value;
    archSetting();
    dlg.showModal();
  });
  dlg.addEventListener('close', () => {
    if (dlg.returnValue !== 'save') return;
    settings.csirc = $('set-csirc').value;
    settings.args = $('set-args').value;
    settings.sliceMs = Math.max(5, Math.min(1000, Number($('set-slice').value) || 50));
    settings.quotes = $('set-quotes').checked;
    const th = document.querySelector('input[name="theme"]:checked');
    settings.theme = th ? th.value : 'auto';
    const ar = document.querySelector('input[name="arch"]:checked');
    settings.arch = ar ? ar.value : 'auto';
    store.set('csirc', settings.csirc);
    store.set('args', settings.args);
    store.set('sliceMs', String(settings.sliceMs));
    store.set('quotes', settings.quotes ? '1' : '0');
    store.set('theme', settings.theme);
    const archStored = store.set('arch', settings.arch);
    // Choosing a build other than the one running means other modules
    // for every worker: load the page again, without the ?arch= that
    // would override the choice (the notebook saves itself on pagehide),
    // or, when the choice could not be stored, with ?arch= making it.
    // Other changes keep the page, its ?arch= and its uploads.
    const archChoice = BUILDS.length > 1 && settings.arch !== archShown ? choose(null, settings.arch) : null;
    if (archChoice && archChoice.build !== CHOICE.build) {
      const u = new URL(location.href);
      if (archStored) u.searchParams.delete('arch'); else u.searchParams.set('arch', settings.arch);
      if (u.href === location.href) location.reload(); else location.replace(u.href);
      return;
    }
    applyTheme();
    document.dispatchEvent(new Event('chicken:settings'));
    // a build this browser turned out not to run: say so
    if (archChoice && archChoice.build && settings.arch !== 'auto' && archChoice.build.arch !== settings.arch)
      for (const t of archChoice.notes) note(t);
    restart();
  });

  // ---- tabs

  // in DOM order: REPL, Notebook (notebook.js), Compile to C
  const tabs = [...document.querySelectorAll('[role="tablist"] [role="tab"]')];
  function selectTab(tab, focus) {
    for (const t of tabs) {
      const on = t === tab;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      $(t.getAttribute('aria-controls')).hidden = !on;
    }
    const nb = tab.id === 'tab-notebook';
    $('toolbar').hidden = nb;
    if ($('nb-toolbar')) $('nb-toolbar').hidden = !nb;
    $('toolbar').style.visibility = tab === tabs[0] ? '' : 'hidden';
    statusPill.style.visibility = nb ? 'hidden' : '';   // the notebook has its own
    if (focus) tab.focus();
    document.dispatchEvent(new CustomEvent('chicken:tab', { detail: { id: tab.id } }));
    if (tab === tabs[0]) {
      render();
      term.scrollTop = term.scrollHeight;
      // (arrow keys on the tabs keep the focus there)
      if (!focus && !touch && !line.disabled) line.focus();
    }
  }
  for (const t of tabs) {
    t.addEventListener('click', () => selectTab(t));
    t.addEventListener('keydown', e => {
      const i = tabs.indexOf(t);
      let j = null;
      if (e.key === 'ArrowRight') j = (i + 1) % tabs.length;
      else if (e.key === 'ArrowLeft') j = (i + tabs.length - 1) % tabs.length;
      else if (e.key === 'Home') j = 0;
      else if (e.key === 'End') j = tabs.length - 1;
      if (j !== null) { e.preventDefault(); selectTab(tabs[j], true); }
    });
  }

  // ---- Compile to C

  let cworker = null, cid = 0, cbusy = false, cUrl = null;
  const creqs = new Map();
  function compilerWorker() {
    if (cworker) return cworker;
    const w = new Worker(workerUrl('compiler-worker.js'));
    w.onmessage = ({ data: m }) => {
      const r = creqs.get(m.id);
      if (r) { creqs.delete(m.id); r(m); }
    };
    w.onerror = e => {
      e.preventDefault();
      const msg = 'the compiler worker failed: ' + ((e && e.message) || 'could not load compiler-worker.js') + '. ' + HTTP_HINT;
      for (const r of creqs.values()) r({ ok: false, code: null, log: msg });
      creqs.clear();
      w.terminate();
      cworker = null;
    };
    return (cworker = w);
  }

  function setDownload(code, name) {
    const a = $('download');
    if (cUrl) URL.revokeObjectURL(cUrl);
    cUrl = null;
    if (code == null) {
      a.removeAttribute('href');
      a.setAttribute('aria-disabled', 'true');
      a.tabIndex = -1;
      $('copy').disabled = true;
      return;
    }
    cUrl = URL.createObjectURL(new Blob([code], { type: 'text/x-csrc' }));
    a.href = cUrl;
    a.download = name;
    a.textContent = 'Download ' + name;
    a.removeAttribute('aria-disabled');
    a.tabIndex = 0;
    $('copy').disabled = false;
  }
  setDownload(null);
  $('download').addEventListener('click', e => { if (!cUrl) e.preventDefault(); });

  async function compile() {
    if (unavailable) {                  // Ctrl+Enter bypasses the disabled button
      const st = $('cstatus');
      st.className = 'cstatus fail';
      st.textContent = unavailable;
      return;
    }
    if (cbusy) return;
    cbusy = true;
    const btn = $('compile'), st = $('cstatus');
    btn.disabled = true;
    st.className = 'cstatus';
    st.textContent = cworker ? 'Compiling…' : 'Loading the compiler and compiling…';
    const extra = $('cargs').value.trim();
    const options = ['-optimize-level', $('copt').value, ...(extra ? extra.split(/\s+/) : [])];
    const name = ($('cname').value.trim().replace(/[\\/]/g, '_').replace(/\.(c|scm)$/, '') || 'program') + '.c';
    const id = ++cid;
    $('ccancel').hidden = false;
    const m = await new Promise(resolve => {
      creqs.set(id, resolve);
      try { compilerWorker().postMessage({ type: 'compile', id, source: $('src').value, options }); }
      catch (e) { creqs.delete(id); resolve({ ok: false, code: null, log: String(e.message || e) + '. ' + HTTP_HINT }); }
    });
    $('ccancel').hidden = true;
    const log = (m.log || '').replace(/^\s*\n/, '').replace(/\s+$/, '');
    $('clog').textContent = log;
    $('clog-wrap').hidden = !log;
    $('clog-wrap').open = !m.ok || m.code == null || /Warning|Error/.test(log);
    if (m.cancelled) {
      st.className = 'cstatus fail';
      st.textContent = 'Compilation cancelled.';
    } else if (m.ok && m.code == null) {   // -check-syntax, -version, ...
      $('cout').textContent = '';
      setDownload(null);
      st.className = 'cstatus ok';
      st.textContent = 'The compiler finished without generating C' +
        (log ? '; see the compiler messages.' : '.');
    } else if (m.ok) {
      $('cout').textContent = m.code;
      setDownload(m.code, name);
      st.className = 'cstatus ok';
      st.textContent = 'Translated in ' + m.ms + ' ms: ' + countLines(m.code) + ' lines of C' +
        (log ? ', with compiler messages.' : '.');
    } else {
      $('cout').textContent = '';
      setDownload(null);
      st.className = 'cstatus fail';
      st.textContent = 'Compilation failed; see the compiler messages.';
    }
    btn.disabled = false;
    cbusy = false;
  }
  $('compile').addEventListener('click', compile);
  // A compile that never ends (a looping macro) can only be stopped by
  // replacing the worker; the next compile starts a fresh one.
  $('ccancel').addEventListener('click', () => {
    if (!cworker) return;
    cworker.terminate();
    cworker = null;
    for (const r of creqs.values()) r({ ok: false, cancelled: true, code: null, log: '' });
    creqs.clear();
  });
  $('src').addEventListener('keydown', e => {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); compile(); }
    else if (e.key === 'Tab' && !e.shiftKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault();
      e.target.setRangeText('  ', e.target.selectionStart, e.target.selectionEnd, 'end');
    }
  });
  $('copy').addEventListener('click', async () => {
    const b = $('copy');
    try { await navigator.clipboard.writeText($('cout').textContent); b.textContent = 'Copied'; }
    catch (e) {
      const r = document.createRange();
      r.selectNodeContents($('cout'));
      const s = getSelection();
      s.removeAllRanges();
      s.addRange(r);
      b.textContent = 'Selected';
    }
    setTimeout(() => { b.textContent = 'Copy'; }, 1500);
  });

  // ---- saved sessions (the dialog is sessions.js's, the format session-store.js's)
  //
  // A save keeps the transcript, the unsent line, the inputs sent to this
  // interpreter with how each ended (ilog), the uploads and the regular
  // files at the top of the home directory; the .csirc and arguments are
  // only recorded.  Not the heap: opening a session starts a fresh csi,
  // shows the transcript and runs again, one at a time and with their
  // output hidden, the inputs that had finished, which rebuilds the
  // definitions; then the home files are written back.  An input that
  // behaves differently the second time (random, the time, files) is not
  // noticed beyond its errors being counted; "#N" history references
  // shift when inputs were skipped; files the replay made that were not
  // saved stay.

  const fmtDate = d => (SS ? SS.fmtDate(d) : new Date(d).toLocaleString());
  const plural = (n, w) => n + ' ' + w + (n === 1 ? '' : 's');
  const hasContent = () => !!(ilog && (ilog.entries.length || ilog.broken)) || !!term.querySelector('span.in') ||
    pending.some(p => p.cls === 'in');
  const isDirty = () => hasContent() && consoleGen !== cleanGen;
  const isBusy = () => !!replay || (alive && !(ready && state === WAITING && atPrompt()));
  const sameBytes = (a, b) => !!a && !!b && a.length === b.length && a.every((x, i) => x === b[i]);
  const someNames = l => l.slice(0, 5).join(', ') + (l.length > 5 ? ' and ' + (l.length - 5) + ' more' : '');

  // the regular files at the top of the home directory, but the uploads
  // unchanged and .csirc: {files, note} (note: what was not saved, and why)
  async function readHome() {
    if (!alive) return { files: [], note: 'The files csi wrote were not saved: it had ended.' };
    if (replay || !ready) return { files: [], note: 'The files csi wrote were not saved: it was starting or re-running inputs.' };
    let dir;
    try { dir = await requestT({ type: 'listDir', path: HOME }, 3000); }
    catch (e) {
      return { files: [], note: e.message === 'timeout' ? 'csi was busy, so the files it wrote were not saved (uploads were).'
               : 'The files csi wrote could not be read: ' + e.message + '.' };
    }
    const L = SS.LIMITS;
    const names = (dir.entries || []).filter(n => typeof n === 'string' && n !== '.' && n !== '..' && n !== '.csirc').sort();
    let bytes = 0, count = uploads.size;
    for (const d of uploads.values()) bytes += d.length;
    const files = [], odd = [], big = [], many = [];
    for (const name of names) {
      if (count >= L.FILES_COUNT) { many.push(name); continue; }
      let r;
      try { r = await requestT({ type: 'readFile', path: HOME + name }, 3000); }
      catch (e) { odd.push(name); continue; }          // a directory (EISDIR), or unreadable
      if (!(r.data instanceof Uint8Array)) { odd.push(name); continue; }
      if (sameBytes(r.data, uploads.get(name))) continue;
      if (r.data.length > L.FILE_MAX || bytes + r.data.length > L.FILES_BYTES) { big.push(name); continue; }
      bytes += r.data.length;
      count++;
      files.push({ name, data: r.data });
    }
    const why = [odd.length && someNames(odd) + ' (not regular files)',
                 big.length && someNames(big) + ' (over ' + SS.fmtSize(L.FILE_MAX) + ' each or ' +
                   SS.fmtSize(L.FILES_BYTES) + ' in all)',
                 many.length && someNames(many) + ' (over ' + L.FILES_COUNT + ' files)'].filter(Boolean);
    return { files, note: why.length ? 'Not saved from the home directory: ' + why.join('; ') + '.' : null };
  }

  // level 0: everything; 1: without the files csi wrote and the start of
  // the transcript; 2: without the transcript and files (when browser
  // storage is too full for more)
  async function capture(level, cache) {
    // While a saved session's inputs run again, the input log holds only
    // those run so far and the home directory is not yet restored: what
    // is saved is the session being re-run (its plan and its home files),
    // so a save then (Ctrl+S on the session opened) loses nothing.
    const r = replay;
    render();
    const L = SS.LIMITS;
    const pieces = [];
    for (const n of term.childNodes) {
      if (n.nodeType !== 1 || n.classList.contains('loading')) continue;
      const cls = n.className || 'out';
      if (cls === 'out' || cls === 'err' || cls === 'in' || cls === 'sys') pieces.push([cls, n.textContent]);
    }
    const t = level >= 2 ? { chunks: [], cut: true }
      : SS.trimTranscript(SS.mergeChunks(pieces), level ? L.TRANSCRIPT_LEAN : L.TRANSCRIPT_MAX);
    const inputs = r ? r.list.map(e => Object.assign({}, e)) : ilog.snapshot();
    const up = level < 2 ? [...uploads].map(([name, data]) => ({ name, data })) : [];
    let home = { files: [], note: null };
    if (level === 0) home = r ? { files: r.home, note: null } : cache.home || (cache.home = await readHome());
    const data = {
      format: SS.CONSOLE_FORMAT, version: 1, minReader: 1,
      transcript: t.chunks, transcriptCut: t.cut,
      inputs, entry: line.value.slice(0, L.ENTRY_MAX),
      uploads: up, home: home.files, homeNote: home.note,
      settings: { csirc: settings.csirc, args: settings.args },
      saved: { build: BUILD, arch: ARCH, eh: EH },
    };
    const warnings = [];
    if (home.note) warnings.push(home.note);
    if (r) warnings.push('csi was still running again the inputs of “' + r.name + '”: all of them are saved, ' +
                         'with its files, and run again when it is opened.');
    else if (isBusy()) warnings.push('csi was busy, so the unfinished input is skipped when the session is opened.');
    if (inputs === null) warnings.push('Its inputs were too many to keep: opening it brings back the transcript only.');
    return {
      data, summary: SS.consoleSummary(data), warnings,
      dropped: level === 0 ? null : level === 1 ? 'the files csi wrote and the start of the transcript'
        : 'the transcript and all files (uploaded files are needed again to load them)',
    };
  }

  // opens a saved session (checked: SS.checkConsole's {data, warnings});
  // opts.replay: run its finished inputs again
  function applySession(meta, checked, opts) {
    const s = checked.data;
    replay = null;                      // (the worker goes below)
    clearTerm();
    for (const [cls, text] of SS.stripTrailingPrompt(s.transcript)) emit(cls, text, false);
    if (s.transcriptCut && !s.transcript.length) note('; its transcript was not saved');
    render();
    note('; opened “' + meta.name + '”, saved ' + fmtDate(meta.modified));
    for (const w of checked.warnings) note('; ' + w);
    if (s.homeNote) note('; ' + s.homeNote);
    if (s.uploads.length) {
      for (const f of s.uploads) {
        uploads.set(f.name, f.data);
        for (const hook of uploadHooks) { try { hook(f.name, f.data); } catch (e) { /* the hook's problem */ } }
      }
      note('; restored ' + plural(s.uploads.length, 'uploaded file') + ': ' + someNames(s.uploads.map(f => f.name)));
    }
    if (s.settings.csirc !== settings.csirc || s.settings.args !== settings.args)
      note('; it was saved with another .csirc or other csi arguments (see Settings); this interpreter uses the current ones');
    line.value = s.entry;
    autosize();
    histIdx = history.length;
    draft = '';
    const plan = s.inputs ? SS.planReplay(s.inputs) : { send: [], skipped: 0 };
    if (opts && opts.replay && plan.send.length) {
      spawn({ quiet: true });
      replay = { gen, list: plan.send, i: 0, n: plan.send.length, errs: 0, curErr: false, startErr: false,
                 skipped: plan.skipped, home: s.home, name: meta.name };
      setStatus('running', 'replaying 0/' + replay.n);
    } else {
      spawn({ quiet: true, files: s.home });
      if (!(opts && opts.replay)) note('; transcript only: this is a fresh interpreter, its definitions were not restored');
      else if (s.inputs === null) note('; its inputs were not kept, so its definitions were not restored');
      else if (s.inputs.length) note('; none of its inputs had finished when it was saved, so nothing was run again');
      if (s.home.length) note('; restored ' + plural(s.home.length, 'file') + ' in the home directory');
    }
    origin = meta.id ? { id: meta.id, rev: meta.rev, name: meta.name } : null;
    cleanGen = consoleGen;
  }

  // At every WAITING the next input goes: csi waits only once its input
  // is used up, and the worker posts a slice's output before its state,
  // so stdin answers, type-ahead and the rest of an incomplete form go in
  // their order, prompt or not.  No timeout: (sleep 10) is fine, and
  // Stop ends the replay.
  function replayStep() {
    const r = replay;
    if (state === RUNNING || state === BUSY) return setStatus('running', 'replaying ' + r.i + '/' + r.n);
    if (state === SLEEPING) return setStatus('sleeping', 'replaying ' + r.i + '/' + r.n);
    if (state !== WAITING) return;
    if (r.curErr) { r.errs++; r.curErr = false; }
    if (r.i >= r.n) { finishReplay(); return; }
    const e = r.list[r.i++];
    if (e.eof) {
      ilog.addEof();
      worker.postMessage({ type: 'input', text: '', eof: true });
      eofSent = true;
    } else {
      ilog.add(e.t, e.k === 'p');
      worker.postMessage({ type: 'input', text: e.t + '\n', eof: false });
    }
    state = RUNNING;
    setStatus('running', 'replaying ' + r.i + '/' + r.n);
  }
  function finishReplay() {
    const r = replay;
    replay = null;
    note('; ran its ' + plural(r.n, 'input') + ' again' +
         (r.errs ? '; ' + r.errs + ' of them wrote errors (their output is hidden)' : '') +
         (r.skipped ? '; skipped ' + r.skipped + ' that had not finished or were stopped' : '') +
         (r.startErr ? '; .csirc wrote errors' : ''));
    const p = PROMPT_END.exec(tail);
    if (p) emit('out', p[0], false);
    else note('; csi is waiting for more input');
    writeHome(r.home);
    setInputEnabled(true);
    updateStatus();
    if (!touch && !document.querySelector('dialog[open]') && !$('panel-repl').hidden) line.focus();
    cleanGen = consoleGen;              // (a replay is no change)
  }
  // the saved home files, after the replay: home ends as it was saved
  async function writeHome(files) {
    if (!files || !files.length || !(worker && ready)) return;
    let ok = 0, failed = 0;
    for (const f of files) {
      try { await requestT({ type: 'writeFile', path: HOME + f.name, data: f.data }, 3000); ok++; }
      catch (e) { failed++; }
    }
    note('; restored ' + plural(ok, 'file') + ' in the home directory' + (failed ? '; ' + failed + ' could not be written' : ''));
  }

  // uploads of an opened notebook: for the REPL and the kernel too
  async function addUploads(list, fromName) {
    let n = 0;
    for (const f of list) {
      uploads.set(f.name, f.data);
      for (const hook of uploadHooks) { try { hook(f.name, f.data); } catch (e) { /* the hook's problem */ } }
      n++;
      try {
        if (worker && ready) await requestT({ type: 'writeFile', path: HOME + f.name, data: f.data }, 3000);
        else if (worker) worker.postMessage({ type: 'writeFile', id: ++reqId, path: HOME + f.name, data: f.data });
      } catch (e) { note('; could not write ' + f.name + ': ' + e.message); }
    }
    if (n) note('; restored ' + plural(n, 'uploaded file') + ' from “' + fromName + '”');
  }

  // ---- the page API for notebook.js

  function replModule() {               // of the build chosen
    if (!replModuleP) {
      const p = compileWasm(DIR + 'chicken-repl.wasm' + Q);
      replModuleP = p;
      p.catch(() => { if (replModuleP === p) replModuleP = null; });
    }
    return replModuleP;
  }
  window.ChickenPage = Object.freeze({
    Q, ARCH, EH, HOME, HTTP_HINT, BUILD, store, settings, touch,
    BUILDS,                             // [{arch, eh, dir}] the page has
    workerUrl,                          // the URL of a worker script, for the build chosen
    get unavailable() { return unavailable; },              // one line
    get unavailableDetail() { return unavailableDetail; },  // and what to do
    replModule,                         // Promise<WebAssembly.Module>, compiled once
    straightenQuotes, countLines,
    uploads,                            // name -> Uint8Array
    onUpload(f) { uploadHooks.push(f); },
    uploadFiles,
    openSettings() { $('settings-btn').click(); },
    // saved states (sessions.js): the console's and the notebook's providers
    provideSaves(kind, provider) { saveProviders.set(kind, provider); },
    savesProvider(kind) { return saveProviders.get(kind) || null; },
    addUploads,                         // ([{name, data}], from what)
    selectTab(id) { const t = $(id); if (t && t.getAttribute('aria-selected') !== 'true') t.click(); },
  });

  window.ChickenPage.provideSaves('console', {
    kind: 'console', noun: 'console session', nounPlural: 'console sessions', current: 'the current console',
    // why it cannot be saved or opened, or null
    available: () => (unavailable ? 'This browser cannot run csi: ' + unavailable
                      : SS ? null : 'The saved-sessions code (session-store.js) did not load'),
    defaultName: () => (origin ? origin.name : 'Console ' + fmtDate(new Date())),
    origin: () => origin && Object.assign({}, origin),
    linked(meta) { origin = meta ? { id: meta.id, rev: meta.rev, name: meta.name } : null; cleanGen = consoleGen; },
    renamed(id, name) { if (origin && origin.id === id) origin.name = name; },
    isDirty, isBusy,
    busyText: () => (replay ? 'csi is re-running a saved session; it will be stopped.' : 'csi is running; it will be stopped.'),
    capture,
    check: d => SS.checkConsole(d),
    apply: applySession,
    saved(meta, dropped, quiet, warnings) {
      note('; saved “' + meta.name + '” in this browser' + (dropped ? ' without ' + dropped + ' (browser storage is nearly full)' : ''));
      if (quiet && warnings) for (const w of warnings) note('; ' + w);   // (the dialog shows them otherwise)
    },
    fail(text) { note('; ' + text); },
    focus() { if (!touch && !line.disabled) line.focus(); },
  });

  // ---- start

  unavailable = LOCKOUT;
  if (unavailable) {
    term.textContent = '';
    fatal(unavailable);
    // nothing can start: Restart only would show the message again
    $('notice-restart').hidden = true;
    $('restart').disabled = true;
    $('compile').disabled = true;
    $('upload-btn').disabled = true;
    if ($('saves-btn')) $('saves-btn').disabled = true;
    unavailableDetail = unavailable.replace(/^; /gm, '');
    unavailable = unavailableDetail.split('\n')[0];
  } else {
    spawn();
  }
})();
