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
 *   everything works without it. */

(function () {
  'use strict';

  const RUNNING = 0, WAITING = 1, BUSY = 2, EXITED = 3, SLEEPING = 4;
  const TERM_LINES = 20000;             // terminal scrollback cap,
  const TERM_CHARS = 2000000;           // also for output without newlines
  const HISTORY_MAX = 500;
  const WATCHDOG_MS = 3000;
  const HOME = '/home/web_user/';
  const PROMPT_END = /#;\d+> $/;

  const BUILD = (document.querySelector('meta[name="chicken-build"]') || {}).content || '';
  const Q = BUILD && BUILD.indexOf('@') < 0 ? '?v=' + encodeURIComponent(BUILD) : '';
  const ARCH = (document.querySelector('meta[name="chicken-wasm-arch"]') || {}).content || '';
  const $ = id => document.getElementById(id);
  const term = $('term'), line = $('line'), statusPill = $('status'), statusText = $('status-text');

  // ---- storage (may be unavailable: private mode, blocked site data)

  const store = {
    get(k, d) {
      try { const v = localStorage.getItem('chicken-repl.' + k); return v === null ? d : v; }
      catch (e) { return d; }
    },
    set(k, v) {
      try { localStorage.setItem('chicken-repl.' + k, v); } catch (e) { /* ignore */ }
    },
  };
  const touch = matchMedia('(pointer: coarse)').matches;
  const settings = {
    csirc: store.get('csirc', ''),
    args: store.get('args', ''),
    sliceMs: Number(store.get('sliceMs', '50')) || 50,
    quotes: store.get('quotes', touch ? '1' : '0') === '1',
    theme: store.get('theme', 'auto'),
  };

  function applyTheme() {
    if (settings.theme === 'light' || settings.theme === 'dark')
      document.documentElement.dataset.theme = settings.theme;
    else delete document.documentElement.dataset.theme;
  }
  applyTheme();

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
    if (last && last.cls === cls) last.text += text; else pending.push({ cls, text });
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
    const parts = text.split(/(#;\d+> )/);
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
  let lastMsgAt = 0, watchdog = 0, eofSent = false;
  const reqs = new Map();
  let reqId = 0;

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
  const HTTP_HINT = 'This page must be served over HTTP, for example with "make wasm-serve".';
  const NO_MEMORY64 = '; this browser does not support 64-bit WebAssembly (memory64), which this build needs.\n' +
        '; Use Chrome or Edge 133, Firefox 134 or later, or a build made with "make wasm WASM_ARCH=wasm32".';
  let noMemory64 = false;               // set at start (see hasMemory64)
  let unavailable = null;               // why nothing can run (set at start), or null

  function csiArgs() {
    const extra = settings.args.trim() ? settings.args.trim().split(/\s+/) : [];
    // CHICKEN_parse_command_line stops at the first non "-:" argument
    return [...extra.filter(a => a.startsWith('-:')),
            ...(settings.csirc.trim() ? [] : ['-n']),
            ...extra.filter(a => !a.startsWith('-:'))];
  }

  function kill() {
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

  async function spawn() {
    if (noMemory64) { fatal(NO_MEMORY64); return; }   // Restart in the header
    kill();
    const g = gen;
    alive = true;
    eofSent = false;
    tail = '';
    hideNotice();
    setInputEnabled(false);
    setStatus('loading');
    let mod;
    try {
      mod = await (replModuleP || (replModuleP = compileWasm('chicken-repl.wasm' + Q)));
    } catch (e) {
      replModuleP = null;
      if (g === gen) fatal('; could not load chicken-repl.wasm: ' + ((e && e.message) || e) + '\n; ' + HTTP_HINT);
      return;
    }
    if (g !== gen) return;
    let w;
    try { w = new Worker('repl-worker.js' + Q); }
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
      files: [...uploads].map(([name, data]) => ({ path: HOME + name, data })),
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

  function onWorker(m) {
    lastMsgAt = performance.now();
    switch (m.type) {
    case 'ready':
      ready = true;
      setInputEnabled(true);
      if (!touch && document.activeElement !== $('src') && !$('settings').open &&
          !$('panel-repl').hidden) line.focus();
      updateStatus();
      break;
    case 'output':
      emit(m.fd === 2 ? 'err' : 'out', m.text, true);
      break;
    case 'state':
      state = m.state;
      updateStatus();
      break;
    case 'exit':
      if (eofSent && m.code === 0) finished('; session ended', 'The session ended.');
      else finished('; process exited (code ' + m.code + ')', 'csi exited with code ' + m.code + '.');
      break;
    case 'crash':
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

  // ---- Stop, Restart, EOF

  function stop() {
    if (!worker || !alive) return;
    worker.postMessage({ type: 'interrupt' });
    if (state === WAITING) { line.value = ''; autosize(); }
    if (state === RUNNING || state === BUSY || !ready) {
      const g = gen, t0 = performance.now();
      clearTimeout(watchdog);
      watchdog = setTimeout(() => {
        if (g !== gen || lastMsgAt > t0) return;
        note('; interpreter restarted (state lost)');
        spawn();
      }, WATCHDOG_MS);
    }
  }

  function restart() {
    render();
    if (term.textContent) note('; restarting…');
    spawn();
  }

  function sendEof() {
    if (!worker || !alive) return;
    if (state === WAITING && atPrompt() && !confirm('End session?')) return;
    eofSent = true;
    worker.postMessage({ type: 'input', text: '', eof: true });
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
    if (!worker || !alive || !ready) return;
    let text = line.value;
    if (settings.quotes) text = straightenQuotes(text);
    if (text.trim() && history[history.length - 1] !== text) {
      history.push(text);
      if (history.length > HISTORY_MAX) history = history.slice(-HISTORY_MAX);
      store.set('history', JSON.stringify(history));
    }
    histIdx = history.length;
    draft = '';
    emit('in', text + '\n');
    render();
    term.scrollTop = term.scrollHeight;
    worker.postMessage({ type: 'input', text: text + '\n', eof: false });
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
    if ($('settings').open || $('panel-repl').hidden) return;
    const k = e.key.toLowerCase();
    if (e.key === 'Escape') { e.preventDefault(); stop(); }
    else if (e.ctrlKey && !e.shiftKey && !e.altKey && !e.metaKey && k === 'c') {
      // Ctrl-C copies when something is selected, else it stops
      const sel = getSelection();
      if ((sel && !sel.isCollapsed) || line.selectionStart !== line.selectionEnd) return;
      e.preventDefault();
      stop();
    } else if (e.ctrlKey && !e.shiftKey && !e.altKey && k === 'l') {
      e.preventDefault();
      clearTerm();
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
  $('clear').addEventListener('click', () => { clearTerm(); if (!touch && !line.disabled) line.focus(); });
  $('hist-up').addEventListener('click', () => { recall(-1); line.focus(); });
  $('hist-down').addEventListener('click', () => { recall(1); line.focus(); });

  // ---- uploads (button and drag and drop)

  async function uploadFiles(files) {
    for (const f of files) {
      const name = f.name.replace(/^.*[\\/]/, '') || 'upload';
      let data;
      try { data = new Uint8Array(await f.arrayBuffer()); }
      catch (e) { note('; could not read ' + name + ': ' + e.message); continue; }
      uploads.set(name, data);
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
  $('settings-btn').addEventListener('click', () => {
    $('set-csirc').value = settings.csirc;
    $('set-args').value = settings.args;
    $('set-slice').value = settings.sliceMs;
    $('set-quotes').checked = settings.quotes;
    for (const r of document.querySelectorAll('input[name="theme"]')) r.checked = r.value === settings.theme;
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
    store.set('csirc', settings.csirc);
    store.set('args', settings.args);
    store.set('sliceMs', String(settings.sliceMs));
    store.set('quotes', settings.quotes ? '1' : '0');
    store.set('theme', settings.theme);
    applyTheme();
    restart();
  });

  // ---- tabs

  const tabs = [$('tab-repl'), $('tab-compile')];
  function selectTab(tab, focus) {
    for (const t of tabs) {
      const on = t === tab;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      $(t.getAttribute('aria-controls')).hidden = !on;
    }
    $('toolbar').style.visibility = tab === tabs[0] ? '' : 'hidden';
    if (focus) tab.focus();
    if (tab === tabs[0]) {
      render();
      term.scrollTop = term.scrollHeight;
      if (!touch && !line.disabled) line.focus();
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
    const w = new Worker('compiler-worker.js' + Q);
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

  // ---- start

  // A wasm64 build (the default) needs memory64: without it the modules
  // fail to compile.  This module declares a 64-bit memory and nothing else.
  function hasMemory64() {
    try {
      return WebAssembly.validate(new Uint8Array([
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,   // magic, version
        0x05, 0x03, 0x01, 0x04, 0x00]));                  // memory: i64, min 0
    } catch (e) { return false; }
  }
  noMemory64 = ARCH === 'wasm64' && typeof WebAssembly === 'object' && !hasMemory64();

  if (location.protocol === 'file:')
    unavailable = '; ' + HTTP_HINT + '\n; Browsers do not run workers or fetch .wasm files from file:// URLs.';
  else if (typeof WebAssembly !== 'object' || typeof Worker !== 'function')
    unavailable = '; this browser lacks WebAssembly or Web Workers.';
  else if (noMemory64)
    unavailable = NO_MEMORY64;
  if (unavailable) {
    term.textContent = '';
    fatal(unavailable);
    $('notice-restart').hidden = true;
    $('compile').disabled = true;
    unavailable = unavailable.split('\n')[0].replace(/^; /, '');
  } else {
    spawn();
  }
})();
