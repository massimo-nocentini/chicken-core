/* sessions.js - the saved states dialog of the page (index.html)
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

/* The "Saved in this browser" dialog (dialog#saves): named copies of the
 * console session (repl.js) and of notebooks (notebook.js), kept in
 * IndexedDB by session-store.js.  Save, Update (a save under the name of
 * the copy the console or notebook came from), Open, Rename, Delete
 * (with Undo), Download and Import.  No dependencies.
 *
 * - Each tab gives a provider through ChickenPage.provideSaves: what it
 *   captures at three levels (everything; less; the least), how it
 *   checks and opens a saved payload, whether it has unsaved changes or
 *   is running, and the copy it is linked to (origin).
 * - A save that does not fit in the browser's storage is tried again
 *   with less (levels 1 and 2), and says what was left out.
 * - A copy changed in another tab since this one saved or opened it is
 *   never overwritten without asking (its rev is checked in the save's
 *   transaction); lists follow other tabs' changes.
 * - Without IndexedDB (blocked site data, private mode, a newer page's
 *   database) only the dialog changes: it says why, and Download and
 *   Import still work through files.
 * - IndexedDB is opened at the first use of the dialog, not at startup.
 * - window.ChickenSaves.open({kind, mode}): mode 'save' or 'open' shows
 *   the dialog; 'quick' (Ctrl+S) updates the linked copy without it. */

(function () {
  'use strict';

  const P = window.ChickenPage, SS = window.ChickenSessionStore;
  const $ = id => document.getElementById(id);
  const dlg = $('saves');
  if (!P || !SS || !dlg || typeof P.savesProvider !== 'function') return;

  const nameEl = $('saves-name'), listEl = $('saves-list'), emptyEl = $('saves-empty');
  const closeBtn = dlg.querySelector('button[value="close"]');
  const q = s => '“' + s + '”';
  const plural = (n, w) => n + ' ' + w + (n === 1 ? '' : 's');
  const sentence = s => (/[.!?]$/.test(s) ? s : s + '.');
  const cap = s => s.charAt(0).toUpperCase() + s.slice(1);
  const errText = e => String((e && e.message) || e || 'unknown error');

  let kind = 'console';                 // the kind shown
  let storeP = null, store = null;      // the store, once opened (one of mode 'none': retried at the next open)
  let storeNone = false;                // storeP gave mode 'none'
  let busy = false;                     // an operation runs: one at a time
  let undoRec = null;                   // the last deleted state, until the dialog closes
  let opener = null;                    // what had the focus before the dialog
  let rows = [];                        // the rows listed
  let refreshSeq = 0, focusOpen = false;
  let saveOff = null;                   // why Save cannot work, or null

  const prov = k => P.savesProvider(k || kind);

  function getStore() {
    if (!storeP) {
      // (a 'none' result is kept until the dialog is opened again: each
      // step would otherwise wait for another open that may hang)
      storeP = SS.openStore(window).then(s => {
        if (s.mode === 'none') storeNone = true;
        else if (store !== s) { store = s; s.onChange(onRemote); }
        return s;
      });
    }
    return storeP;
  }

  // ---- messages

  function live(text) {
    const l = $('saves-live');
    l.textContent = '';
    setTimeout(() => { l.textContent = text; }, 30);
  }
  // text with up to three actions [label, fn?]; an action hides the
  // message, then runs fn (as an operation)
  function msg(text, actions) {
    const acts = actions || [];
    $('saves-msg-text').textContent = text;
    ['a', 'b', 'c'].forEach((x, i) => {
      const b = $('saves-msg-' + x), a = acts[i];
      b.hidden = !a;
      if (!a) return;
      b.textContent = a[0];
      b.onclick = () => {
        if (busy) return;
        msgClear();
        if (a[1]) op(a[1]);
        else nameEl.focus();
      };
    });
    $('saves-msg').hidden = false;
    live(text);
    if (acts.length && dlg.open) $('saves-msg-a').focus();
  }
  function msgClear() {
    const had = $('saves-msg').contains(document.activeElement);
    $('saves-msg').hidden = true;
    if (had) nameEl.focus();
  }

  // ---- one operation at a time

  // every button but Close: aria-disabled while busy, or when its own
  // reason (data-off) says it cannot work
  function syncDisabled() {
    for (const b of dlg.querySelectorAll('button')) {
      if (b === closeBtn) continue;
      if (busy || b.dataset.off) b.setAttribute('aria-disabled', 'true');
      else b.removeAttribute('aria-disabled');
    }
    if (busy) listEl.setAttribute('aria-busy', 'true'); else listEl.removeAttribute('aria-busy');
  }
  async function op(fn) {
    if (busy) return;
    busy = true;
    syncDisabled();
    try { await fn(); }
    catch (e) {
      console.warn('saved states:', e);
      msg('Something went wrong: ' + sentence(errText(e)));
    } finally {
      busy = false;
      syncDisabled();
    }
  }

  // ---- the dialog

  function setKind(k) {
    if (!prov(k)) k = 'console';
    kind = k;
    const p = prov(k);
    for (const r of document.querySelectorAll('input[name="saves-kind"]')) r.checked = r.value === k;
    $('saves-name-label').textContent = 'Save ' + p.current + ' as';
    $('saves-download').textContent = k === 'console' ? 'Download this console' : 'Download this notebook';
    $('saves-replay-wrap').hidden = k !== 'console';
    $('saves-replay').checked = P.store.get('saves.replay', '1') === '1';
    listEl.setAttribute('aria-label', 'Saved ' + p.nounPlural);
    nameEl.value = p.defaultName();
    refresh();
  }

  function openDialog(k, mode, name) {
    if (!dlg.open) opener = document.activeElement;
    setKind(k || (!$('panel-notebook') || $('panel-notebook').hidden ? 'console' : 'notebook'));
    if (name != null) nameEl.value = name;
    msgClear();
    if (!dlg.open) dlg.showModal();
    focusOpen = mode === 'open';
    nameEl.focus();
    if (mode !== 'open') nameEl.select();
  }

  const keysOf = list => new Set(list.filter(r => !r.broken).map(r => SS.nameKey(r.name)));
  async function keysFor(k) {
    if (k === kind && rows.length) return keysOf(rows);
    const s = await getStore();
    try { return keysOf(await s.list(k)); } catch (e) { return new Set(); }
  }

  function metaText(m, p) {
    const s = m.summary || {}, parts = [];
    if (m.kind === 'console') {
      parts.push(s.inputs != null ? plural(s.inputs | 0, 'input') : 'transcript only');
      parts.push(plural(s.files | 0, 'file'));
    } else {
      parts.push(plural(s.cells | 0, 'cell'));
      if (s.files) parts.push(plural(s.files | 0, 'file'));
    }
    parts.push(SS.fmtSize(m.size), SS.fmtDate(m.modified));
    if (m.kind === 'console' && s.cut) parts.push('start cut');
    if (m.arch && P.ARCH && m.arch !== P.ARCH) parts.push(m.arch);
    const o = p.origin();
    if (o && o.id === m.id && m.rev > o.rev) parts.push('changed in another tab');
    return parts.filter(Boolean).join(' · ');
  }
  function button(op, label, aria, cls) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'btn' + (cls ? ' ' + cls : '');
    b.dataset.op = op;
    b.textContent = label;
    b.setAttribute('aria-label', aria);
    return b;
  }
  function rowEl(m, p, why) {
    const li = document.createElement('li');
    li.dataset.id = String(m.id);
    const who = document.createElement('div');
    who.className = 'saves-who';
    const name = document.createElement('span');
    name.className = 'saves-name';
    const metaEl = document.createElement('span');
    metaEl.className = 'saves-meta';
    const acts = document.createElement('div');
    acts.className = 'saves-acts';
    if (m.broken) {
      li.className = 'saves-broken';
      li.setAttribute('aria-current', 'false');
      name.textContent = 'Unreadable saved state';
      metaEl.textContent = cap(m.reason || 'its record is damaged');
      acts.appendChild(button('delete', 'Delete', 'Delete this unreadable saved state', 'ghost danger'));
    } else {
      const o = p.origin(), current = !!o && o.id === m.id;
      li.setAttribute('aria-current', String(current));
      name.textContent = m.name;
      who.appendChild(name);
      if (current) {
        const badge = document.createElement('span');
        badge.className = 'saves-badge';
        badge.textContent = 'current';
        who.appendChild(badge);
      }
      metaEl.textContent = metaText(m, p);
      const open = button('open', 'Open', 'Open ' + q(m.name));
      if (why) { open.dataset.off = why; open.title = why; }
      acts.append(open, button('rename', 'Rename', 'Rename ' + q(m.name), 'ghost'),
                  button('download', 'Download', 'Download ' + q(m.name), 'ghost'),
                  button('delete', 'Delete', 'Delete ' + q(m.name), 'ghost danger'));
      for (const b of acts.children) if (b.dataset.op !== 'open' && store && store.mode === 'readonly' &&
                                         b.dataset.op !== 'download') b.dataset.off = 'read-only';
    }
    if (!who.contains(name)) who.appendChild(name);
    who.appendChild(metaEl);
    li.append(who, acts);
    return li;
  }

  async function refresh() {
    const seq = ++refreshSeq, k = kind, p = prov(k);
    const a = document.activeElement;
    const keep = a && listEl.contains(a) && a.closest('li') ? [a.closest('li').dataset.id, a.dataset.op] : null;
    if (!store) { emptyEl.textContent = 'Opening browser storage…'; emptyEl.hidden = false; }
    const s = await getStore();
    let list = [], err = null;
    if (s.mode !== 'none') { try { list = await s.list(k); } catch (e) { err = e; } }
    if (seq !== refreshSeq) return;     // a later refresh is under way
    rows = list;
    // a rename this tab did not hear of (it had not opened the storage)
    const og = p.origin(), mine = og && list.find(m => !m.broken && m.id === og.id);
    if (mine && mine.name !== og.name) {
      if (nameEl.value === og.name) nameEl.value = mine.name;
      p.renamed(og.id, mine.name);
    }
    const why = p.available();
    saveOff = s.mode === 'none' ? 'Saved states cannot be kept in this browser: ' + s.reason + '.'
      : why ? sentence(why) : null;
    $('saves-save').dataset.off = saveOff ? 'off' : '';
    listEl.textContent = '';
    for (const m of list) listEl.appendChild(rowEl(m, p, why ? sentence(why) : null));
    let empty = '';
    if (s.mode === 'none')
      empty = 'Saved states cannot be kept in this browser: ' + s.reason + '. Download keeps a copy as a file; Import opens one.';
    else if (err) empty = 'The saved ' + p.nounPlural + ' could not be listed: ' + sentence(errText(err));
    else if (!list.length) empty = (why ? sentence(why) + ' ' : '') + 'No saved ' + p.nounPlural + ' yet.';
    else if (why && $('saves-msg').hidden) msg(sentence(why));
    if (!empty && s.mode === 'readonly') empty = 'Saved states are read-only here: ' + s.reason + '.';
    emptyEl.textContent = empty;
    emptyEl.hidden = !empty;
    syncDisabled();
    // the usage line
    const usage = 'Kept in this browser on this device only; clearing site data, closing a private window or low disk ' +
      'space can delete them, so download the ones you cannot lose.';
    $('saves-usage').textContent = usage;
    s.estimate().then(e => {
      if (seq === refreshSeq && e) $('saves-usage').textContent = usage + ' This site uses ' + SS.fmtSize(e.usage) +
        ' of about ' + SS.fmtSize(e.quota) + '.';
    }, () => {});
    // the focus where it was, or on the first Open asked for
    if (keep) {
      const b = listEl.querySelector('li[data-id="' + CSS.escape(keep[0]) + '"] button[data-op="' + keep[1] + '"]');
      if (b) b.focus(); else if (!dlg.contains(document.activeElement)) nameEl.focus();
    } else if (focusOpen && dlg.open) {
      focusOpen = false;
      const b = [...listEl.querySelectorAll('button[data-op="open"]')].find(x => !x.dataset.off);
      if (b) b.focus();
    }
  }

  // ---- save

  // the save of what the console or notebook has now, as name; o: {quiet
  // (Ctrl+S: the dialog only for a problem), target ({id, expectRev} to
  // update, {} for a new state), keepName (an update keeps the name the
  // state has now), startLevel (of the quota ladder), shrink (an update
  // may go down the ladder: the user said so)}; resolves with the meta, or
  // null
  async function doSave(k, rawName, o) {
    o = o || {};
    const p = prov(k);
    const name = SS.cleanName(rawName);
    const show = (text, acts) => {
      if (!dlg.open) openDialog(k, 'save', name || rawName);
      msg(text, acts);
    };
    if (!name) { show('Give it a name.'); nameEl.focus(); return null; }
    const why = p.available();
    if (why) { show('Not saved. ' + sentence(why)); return null; }
    const s = await getStore();
    if (s.mode === 'none') {
      show('Not saved: ' + sentence(s.reason), [['Download instead', () => downloadCurrent(k, name)]]);
      return null;
    }
    if (s.mode === 'readonly') { show('Not saved: saved states are read-only here: ' + sentence(s.reason)); return null; }
    const og = p.origin();
    const fromOrigin = !o.target && !!og && SS.nameKey(og.name) === SS.nameKey(name);
    const target = o.target || (fromOrigin ? { id: og.id, expectRev: og.rev } : {});
    // the copy it came from, under the name this tab knows: under the name
    // it has now (another tab may have renamed it, which this tab may not
    // have heard of)
    const keepName = !!o.keepName || (fromOrigin && name === og.name);
    const cache = {};
    let meta = null, got = null;
    try {
      for (let level = o.startLevel || 0; ; level++) {
        got = await p.capture(level, cache);
        try {
          meta = await s.put(Object.assign({ kind: k, name, data: got.data, summary: got.summary,
                                             build: P.BUILD, arch: P.ARCH, keepName }, target));
          break;
        } catch (e) {
          if (!(e && e.code === 'quota' && level < 2)) throw e;
          // a new state: what fits, said (also once asked, below)
          if (target.id == null || o.shrink) continue;
          // an update replaces a copy that may have what a smaller save
          // leaves out: asked first
          const next = await p.capture(level + 1, cache);
          show('Browser storage is full: ' + q(name) + ' can only be updated with less in it (without ' + next.dropped +
               (level + 1 < 2 ? ', or more' : '') + '), and that replaces the copy it has now.',
               [['Update it with less', () => doSave(k, name, { target, keepName, startLevel: level + 1, shrink: true })],
                ['Download instead', () => downloadCurrent(k, name)], ['Cancel']]);
          return null;
        }
      }
    } catch (e) {
      await saveFailed(k, name, e, show);
      return null;
    }
    p.linked(meta);
    p.saved(meta, got.dropped, !!o.quiet && !dlg.open, got.warnings);
    if (dlg.open) {
      msg('Saved ' + q(meta.name) + '.' + (got.dropped ? ' Without ' + got.dropped + ': browser storage is nearly full.' : '') +
          (got.warnings.length ? ' ' + got.warnings.join(' ') : ''));
      refresh();
    }
    return meta;
  }
  async function saveFailed(k, name, e, show) {
    const p = prov(k), code = e && e.code, cur = e && e.current;
    const again = target => () => doSave(k, name, { target });
    if (code === 'name-taken' && cur && !cur.broken) {
      show('There is already a saved ' + p.noun + ' named ' + q(cur.name) + '.',
           [['Replace it', again({ id: cur.id, expectRev: cur.rev })], ['Cancel']]);
    } else if (code === 'name-taken') {
      show('There is already a saved ' + p.noun + ' with this name, and it cannot be read; delete it first.');
    } else if (code === 'conflict') {
      const alt = SS.uniqueName(name, await keysFor(k));
      show(q(name) + ' was changed in another tab after this tab saved or opened it.',
           [['Overwrite it', again(cur && !cur.broken ? { id: cur.id, expectRev: cur.rev } : {})],
            ['Save as ' + q(alt), () => doSave(k, alt, { target: {} })], ['Cancel']]);
    } else if (code === 'gone') {
      show(q(name) + ' was deleted, perhaps in another tab.', [['Save it again', again({})], ['Cancel']]);
    } else if (code === 'quota') {
      show('Not saved: browser storage is full. Delete saved states you no longer need' +
           (k === 'notebook' ? ', or export the notebook' : '') + '.', [['Download instead', () => downloadCurrent(k, name)]]);
    } else if (code === 'unavailable' || code === 'readonly') {
      show('Not saved: ' + sentence(errText(e)), [['Download instead', () => downloadCurrent(k, name)]]);
    } else {
      console.warn('saved states: saving failed:', e);
      show('Not saved: ' + sentence(errText(e)));
    }
  }

  // ---- open

  async function doOpen(k, meta) {
    const p = prov(k);
    const why = p.available();
    if (why) { msg(sentence(why)); return; }
    const s = await getStore();
    let rec;
    try { rec = await s.get(meta.id); }
    catch (e) {
      if (e && e.code === 'gone') { msg(q(meta.name) + ' was deleted, perhaps in another tab.'); refresh(); return; }
      if (e && e.code === 'corrupt') { unreadable(k, meta, e); return; }
      msg('Could not open ' + q(meta.name) + ': ' + sentence(errText(e)));
      return;
    }
    let checked;
    try { checked = p.check(rec.data); }
    catch (e) { unreadable(k, rec.meta, e); return; }
    await confirmAndGo(k, rec.meta, checked, s);
  }
  function unreadable(k, meta, e) {
    msg(q(meta.name) + ' cannot be read (' + errText(e) + '). You can delete it.',
        [['Delete it', () => doDelete(k, meta)], ['Cancel']]);
  }
  // what opening replaces: asks first when it has unsaved changes or runs
  async function confirmAndGo(k, meta, checked, s) {
    const p = prov(k);
    const running = p.isBusy();
    let dirty = p.isDirty();
    // the copy it came from was deleted (here, or in another tab): the
    // page has the only copy now, and opening another would lose it
    const og = p.origin();
    let orphan = false;
    if (!dirty && og && og.id !== meta.id && s && s.mode !== 'none') {
      let l = null;
      try { l = await s.list(k); } catch (e) { l = null; }
      if (l && !l.some(r => r.id === og.id)) dirty = orphan = true;
    }
    const go = () => {
      if (dlg.open) dlg.close();
      P.selectTab(k === 'console' ? 'tab-repl' : 'tab-notebook');
      try { p.apply(meta, checked, { replay: $('saves-replay').checked }); }
      catch (e) {
        console.warn('saved states: opening failed:', e);
        p.fail('could not open ' + q(meta.name) + ': ' + errText(e));
      }
    };
    if (!dirty && !running) { go(); return; }
    const text = [orphan ? 'The saved copy of the current ' + k + ', ' + q(og.name) + ', was deleted, so it is not kept anywhere else.'
                  : dirty && 'The current ' + k + ' has changes that are not saved.', running && p.busyText(),
                  k === 'console' && 'Opening ' + q(meta.name) + ' starts a fresh interpreter.'].filter(Boolean).join(' ');
    if (!dirty) { msg(text, [['Open', go], ['Cancel']]); return; }
    const canSave = s && s.mode === 'idb';
    const saveThenOpen = async () => {
      const og = p.origin();
      const saved = og && !orphan ? await doSave(k, og.name, { target: { id: og.id, expectRev: og.rev }, keepName: true })
        : await doSave(k, SS.uniqueName(og ? og.name : p.defaultName(), await keysFor(k)), { target: {} });
      if (!saved) return;               // (its message says why)
      // the state opened was the one just saved: open what it has now
      if (og && og.id === meta.id) await doOpen(k, saved);
      else go();
    };
    msg(text, canSave ? [['Save, then open', saveThenOpen], ['Open without saving', go], ['Cancel']]
        : [['Open without saving', go], ['Cancel']]);
  }

  // ---- rename, delete, download, import

  async function doRename(k, meta) {
    const n = prompt('New name for ' + q(meta.name) + ':', meta.name);
    if (n == null) return;
    const name = SS.cleanName(n);
    if (!name || name === meta.name) return;
    const s = await getStore();
    try {
      const m2 = await s.rename(meta.id, name);
      prov(k).renamed(meta.id, m2.name);
      await refresh();
      msg('Renamed to ' + q(m2.name) + '.');
    } catch (e) {
      const code = e && e.code;
      if (code === 'name-taken' && e.current && !e.current.broken)
        msg('There is already a saved ' + prov(k).noun + ' named ' + q(e.current.name) + '.');
      else if (code === 'name-taken') msg('There is already a saved ' + prov(k).noun + ' with this name.');
      else if (code === 'gone') { msg('It was deleted, perhaps in another tab.'); refresh(); }
      else msg('Not renamed: ' + sentence(errText(e)));
    }
  }

  async function doDelete(k, meta) {
    const s = await getStore();
    const label = meta.broken ? 'the unreadable saved state' : q(meta.name);
    let rec;
    try { rec = await s.remove(meta.id); }
    catch (e) {
      if (e && e.code === 'gone') { msg('It was deleted, perhaps in another tab.'); refresh(); return; }
      msg('Not deleted: ' + sentence(errText(e)));
      return;
    }
    undoRec = rec;
    await refresh();
    msg('Deleted ' + label + '.', [['Undo', async () => {
      const r = undoRec;
      if (!r) return;
      try {
        const m = await s.reinsert(r);
        undoRec = null;
        await refresh();
        msg(r.meta.broken ? 'Restored the unreadable saved state.' : 'Restored ' + q(m.name) + '.');
      } catch (e) { msg('Could not restore ' + label + ': ' + sentence(errText(e))); }
    }]]);
  }

  function slug(name) {
    const L = window.ChickenNotebookLib;
    const s = L && L.slug ? L.slug(name) : String(name).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
    return String(s || '').slice(0, 60) || 'session';
  }
  function download(name, text, type) {
    const url = URL.createObjectURL(new Blob([text], { type: type + ';charset=utf-8' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = name;
    a.hidden = true;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 30000);
  }
  // a checked payload as a file; says what it left out
  function downloadData(k, meta, data) {
    if (k === 'console') {
      download(slug(meta.name) + '.chicken-session.json', SS.toFile('console', meta, data), 'application/json');
      msg('Downloaded ' + q(meta.name) + '.');
    } else {
      download(slug(meta.name) + '.json', SS.toFile('notebook', meta, data), 'application/json');
      msg('Downloaded ' + q(meta.name) + (data.uploads && data.uploads.length ? ' (the uploaded files are not in the file).' : '.'));
    }
  }
  async function doDownload(k, meta) {
    const s = await getStore();
    let rec, data;
    try {
      rec = await s.get(meta.id);
      data = (k === 'console' ? SS.checkConsole(rec.data) : SS.checkNotebookSave(rec.data)).data;
    } catch (e) {
      if (e && e.code === 'gone') { msg(q(meta.name) + ' was deleted, perhaps in another tab.'); refresh(); return; }
      unreadable(k, meta, e);
      return;
    }
    downloadData(k, rec.meta, data);
  }
  // what the console or notebook has now (no storage needed)
  async function downloadCurrent(k, name) {
    const p = prov(k);
    const now = new Date().toISOString();
    const got = await p.capture(0, {});
    downloadData(k, { name: SS.cleanName(name || nameEl.value) || p.defaultName(), created: now, modified: now }, got.data);
  }

  // An imported notebook is someone's file: kept within what More →
  // Import reads (cells, the size of a cell, outputs per cell), as the
  // copies opened later skip those limits (limits: false).  Not its 5 MB
  // file limit: a downloaded copy (outputs up to 1 MB per cell) comes back
  // whole.  Resolves with the payload to keep and what was cut.
  function limitImported(d) {
    const L = window.ChickenNotebookLib, lim = L && L.LIMITS;
    if (!lim) return { data: d, warnings: [] };
    SS.checkNotebookSave(d);            // (its size; throws)
    let j;
    try { j = JSON.parse(d.notebook); } catch (e) { throw new Error('it is not valid JSON'); }
    if (j && Array.isArray(j.cells) && j.cells.length > lim.cells) throw new Error('it has more than ' + lim.cells + ' cells');
    const res = L.fromJson(d.notebook, { limits: false });
    if (res.cells.some(c => c.source.length > lim.source))
      throw new Error('a cell is larger than ' + SS.fmtSize(lim.source));
    let cut = 0;
    for (const c of res.cells) {
      if (!c.outputs || c.outputs.length <= lim.outputs) continue;
      c.outputs = L.limitOutputs(c.outputs, lim.outputs);
      cut++;
    }
    if (!cut) return { data: d, warnings: [] };
    const text = L.toJson({ title: res.title, created: res.created, modified: res.modified, cells: res.cells });
    return { data: Object.assign({}, d, { notebook: text }),
             warnings: [plural(cut, 'cell') + ' had more than ' + lim.outputs + ' outputs, so some were left out.'] };
  }

  async function doImport(f) {
    if (f.size > SS.LIMITS.IMPORT_MAX) { msg('Could not import ' + f.name + ': it is larger than 100 MB.'); return; }
    let r, p, checked;
    try {
      r = SS.fromFile(await f.text());
      p = prov(r.kind);
      if (!p) throw new Error('this page has no notebook');
      if (r.kind === 'notebook') {
        const lim = limitImported(r.data);
        r.data = lim.data;
        checked = p.check(r.data);
        checked.warnings = lim.warnings.concat(checked.warnings);
      } else checked = p.check(r.data);
    } catch (e) {
      msg('Could not import ' + f.name + ': ' + sentence(errText(e)));
      return;
    }
    const title = r.kind === 'notebook' ? checked.data.res.title : '';
    const s = await getStore();
    const name = SS.uniqueName(r.name || SS.cleanName(title) || f.name.replace(/\.[^.]*$/, ''),
                               s.mode === 'none' ? new Set() : await keysFor(r.kind));
    if (s.mode === 'idb') {
      const summary = r.kind === 'console' ? SS.consoleSummary(checked.data)
        : { cells: checked.data.res.cells.length, code: checked.data.res.cells.filter(c => c.type !== 'markdown').length,
            files: checked.data.uploads.length };
      let meta;
      try { meta = await s.put({ kind: r.kind, name, data: r.data, summary, build: P.BUILD, arch: P.ARCH }); }
      catch (e) {
        msg('Could not import ' + f.name + ': ' + (e && e.code === 'quota' ? 'browser storage is full.' : sentence(errText(e))),
            [['Open it without saving', () => confirmAndGo(r.kind, { id: null, name, modified: new Date().toISOString() }, checked, s)]]);
        return;
      }
      if (kind !== r.kind) setKind(r.kind); else await refresh();
      msg('Imported ' + q(name) + '.' + (checked.warnings.length ? ' ' + checked.warnings.join(' ') : ''),
          [['Open', () => doOpen(r.kind, meta)]]);
      return;
    }
    // nowhere to keep it: open it as it is
    if (kind !== r.kind) setKind(r.kind);
    await confirmAndGo(r.kind, { id: null, name, modified: new Date().toISOString() }, checked, s);
  }

  // ---- other tabs

  function onRemote(m) {
    if (dlg.open && (m.kind === kind || m.kind == null)) refresh();
    if (m.op === 'rename' && m.kind && store) {
      const p = prov(m.kind);
      store.list(m.kind).then(l => {
        const meta = l.find(x => x.id === m.id && !x.broken);
        if (meta && p) p.renamed(m.id, meta.name);
      }, () => {});
    }
  }

  // ---- events

  listEl.addEventListener('click', e => {
    const b = e.target.closest('button[data-op]');
    if (!b || busy) return;
    const li = b.closest('li'), id = li && li.dataset.id;
    const meta = rows.find(r => String(r.id) === id);
    if (!meta) return;
    const k = kind;
    if (b.dataset.op === 'open' && b.dataset.off) { msg(b.dataset.off); return; }
    if (b.dataset.off && store && store.mode === 'readonly') { msg('Saved states are read-only here: ' + sentence(store.reason)); return; }
    msgClear();
    if (b.dataset.op === 'open') op(() => doOpen(k, meta));
    else if (b.dataset.op === 'rename') op(() => doRename(k, meta));
    else if (b.dataset.op === 'download') op(() => doDownload(k, meta));
    else if (b.dataset.op === 'delete') op(() => doDelete(k, meta));
  });
  $('saves-save').addEventListener('click', () => { if (!busy) { msgClear(); op(() => doSave(kind, nameEl.value)); } });
  $('saves-download').addEventListener('click', () => { if (!busy) { msgClear(); op(() => downloadCurrent(kind)); } });
  $('saves-import').addEventListener('click', () => { if (!busy) $('saves-file').click(); });
  $('saves-file').addEventListener('change', e => {
    const f = e.target.files[0];
    e.target.value = '';
    if (f) { msgClear(); op(() => doImport(f)); }
  });
  for (const r of document.querySelectorAll('input[name="saves-kind"]'))
    r.addEventListener('change', () => { if (r.checked) { msgClear(); setKind(r.value); } });
  $('saves-replay').addEventListener('change', () => P.store.set('saves.replay', $('saves-replay').checked ? '1' : '0'));
  // Enter in a field must not close the dialog (Close is its default button)
  $('saves-form').addEventListener('submit', e => { if (!e.submitter || e.submitter.value !== 'close') e.preventDefault(); });
  dlg.addEventListener('keydown', e => {
    const k = e.key.toLowerCase();
    if (e.key === 'Enter' && e.target === nameEl && !e.isComposing) {
      e.preventDefault();
      if (!busy) op(() => doSave(kind, nameEl.value));
    } else if (e.key === 'Enter' && e.target.tagName === 'INPUT') e.preventDefault();
    else if ((e.ctrlKey || e.metaKey) && !e.shiftKey && !e.altKey && k === 's') {
      e.preventDefault();
      if (!busy) op(() => doSave(kind, nameEl.value));
    }
  });
  dlg.addEventListener('close', () => {
    undoRec = null;
    msgClear();
    focusOpen = false;
    // (not one hidden since: opening a notebook from the REPL's dialog
    // hides the REPL's toolbar)
    if (opener && opener.isConnected && opener !== document.body && opener.getClientRects().length) opener.focus();
    else { const p = prov(); if (p) p.focus(); }
    opener = null;
  });
  $('saves-btn').addEventListener('click', () => open({ kind: 'console', mode: 'save' }));

  // ---- the API

  // {kind: 'console'|'notebook', mode: 'save'|'open'|'quick'}; never
  // rejected (the callers do not wait)
  function open(o) {
    return openAsync(o || {}).catch(e => { console.warn('saved states:', e); });
  }
  async function openAsync(o) {
    const k = o.kind && prov(o.kind) ? o.kind : null;
    if (!dlg.open && storeNone) { storeP = null; storeNone = false; }   // try the storage again
    if (o.mode !== 'quick') { openDialog(k, o.mode); return; }
    // Ctrl+S: update the copy it came from, quietly
    if (busy || document.querySelector('dialog[open]')) return;
    const p = prov(k || 'console');
    if (!p) return;
    const s = await getStore();
    const og = p.origin();
    if (s.mode === 'idb' && og && !p.available()) {
      await op(async () => {
        try { await doSave(p.kind, og.name, { quiet: true }); }
        catch (e) { openDialog(p.kind, 'save', og.name); msg('Not saved: ' + sentence(errText(e))); }
      });
    } else if (p.kind === 'console') openDialog('console', 'save');
    // (a notebook without a copy: its autosave was all Ctrl+S asked)
  }

  if (!P.unavailable) $('saves-btn').disabled = false;
  if (!prov('notebook')) $('saves-kind-nb').hidden = true;
  window.ChickenSaves = Object.freeze({ open });
})();
