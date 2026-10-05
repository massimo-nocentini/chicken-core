// page.spec.mjs - browser test of the WebAssembly REPL page (build-wasm/web)
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
// usage: node page.spec.mjs WEB_DIR
//
// A plain node script (no @playwright/test).  It serves WEB_DIR over
// HTTP (no COOP/COEP headers, like any static host) and drives the page
// in each browser named by BROWSERS (default "chromium"; e.g.
// BROWSERS=chromium,firefox).  Environment:
//
//   PLAYWRIGHT_MODULE  the playwright package to use, as a path (e.g.
//                      /some/dir/node_modules/playwright); default: resolve
//                      "playwright" from here
//   SHOTS              if set, a directory for screenshots (light and dark,
//                      desktop and 360 px wide)
//
// The usual Playwright variables apply (PLAYWRIGHT_BROWSERS_PATH, ...).
// Exits with status 1 if any check fails or the page logs a console error.

import { createRequire } from 'node:module';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);
const pw = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const webDir = path.resolve(process.argv[2] || 'web');
const shots = process.env.SHOTS ? path.resolve(process.env.SHOTS) : null;
// the architecture the page was built for (make wasm WASM_ARCH=...)
const arch = (/<meta name="chicken-wasm-arch" content="([^"]*)">/
              .exec(fs.readFileSync(path.join(webDir, 'index.html'), 'utf8')) || [])[1];
if (arch !== 'wasm64' && arch !== 'wasm32') throw new Error('no wasm arch in ' + webDir + '/index.html');
const browsers = (process.env.BROWSERS || 'chromium').split(',').map(s => s.trim()).filter(Boolean);

const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
                '.wasm': 'application/wasm', '.png': 'image/png', '.css': 'text/css',
                '.scm': 'text/plain; charset=utf-8' };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  const p = path.join(webDir, path.normalize(decodeURIComponent(u.pathname)).replace(/^([/\\])+/, '') || 'index.html');
  const f = p.endsWith(path.sep) ? path.join(p, 'index.html') : p;
  if (!f.startsWith(webDir) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) {
    res.writeHead(404); res.end('not found'); return;
  }
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(f)] || 'application/octet-stream' });
  fs.createReadStream(f).pipe(res);
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const base = 'http://127.0.0.1:' + server.address().port + '/';

let failures = 0, passes = 0;
async function check(name, f) {
  try {
    await f();
    passes++;
    console.log('ok - ' + name);
  } catch (e) {
    failures++;
    console.log('not ok - ' + name + '\n  ' + String((e && e.message) || e).split('\n').join('\n  '));
  }
}
function assert(c, msg) { if (!c) throw new Error('assertion failed: ' + msg); }

async function runBrowser(name) {
  const browser = await pw[name].launch();
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, acceptDownloads: true });
  const page = await context.newPage();
  const errors = [];
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('worker', w => { if (typeof w.on === 'function') w.on('console', m => { if (m.type() === 'error') errors.push('worker console: ' + m.text()); }); });
  page.on('requestfailed', r => errors.push('request failed: ' + r.url()));

  const P = name + ': ';
  const term = () => page.$eval('#term', e => e.textContent);
  const status = () => page.$eval('#status', e => e.dataset.state);
  const waitStatus = (st, timeout = 20000) =>
    page.waitForFunction(s => document.getElementById('status').dataset.state === s, st, { timeout });
  const waitTerm = (re, timeout = 20000) =>
    page.waitForFunction(([src, fl]) => new RegExp(src, fl).test(document.getElementById('term').textContent),
                         [re.source, re.flags], { timeout });
  // text after the last mark, so earlier output never satisfies a check
  let markAt = 0;
  const mark = async () => { markAt = (await term()).length; };
  const since = async () => (await term()).slice(markAt);
  const waitSince = (re, timeout = 20000) =>
    page.waitForFunction(([src, fl, at]) => new RegExp(src, fl).test(document.getElementById('term').textContent.slice(at)),
                         [re.source, re.flags, markAt], { timeout });
  async function enter(text) {
    await mark();
    await page.fill('#line', text);
    await page.press('#line', 'Enter');
  }
  async function evalTo(text, re) {
    await enter(text);
    await waitSince(re);
    await waitStatus('ready');
  }

  await check(P + 'page loads and the REPL becomes ready', async () => {
    const t0 = Date.now();
    await page.goto(base + 'index.html');
    assert(await page.title() === 'CHICKEN Scheme REPL', 'title');
    await waitStatus('ready', 60000);
    await waitTerm(/CHICKEN[\s\S]*#;1> $/);
    console.log('  # ready after ' + (Date.now() - t0) + ' ms');
  });

  await check(P + '(+ 1 2) and Enter gives 3', async () => {
    await evalTo('(+ 1 2)', /\n3\n#;\d+> $/);
    assert(/#;1> \(\+ 1 2\)\n/.test(await term()), 'input echoed after the prompt');
  });

  await check(P + `the REPL runs the ${arch} build`, async () => {
    const want = arch === 'wasm64' ? '(wasm64 #t 4611686018427387903)' : '(wasm32 #f 1073741823)';
    await evalTo('(import (chicken platform) (chicken fixnum))', /#;\d+> $/);
    await evalTo('(list (machine-type) (feature? #:64bit) most-positive-fixnum)', /\n\(.*\)\n#;\d+> $/);
    assert((await since()).includes('\n' + want + '\n'), 'got: ' + await since());
  });

  await check(P + 'multi-line input with Shift+Enter', async () => {
    await mark();
    await page.fill('#line', '(define (sq x)');
    await page.press('#line', 'Shift+Enter');
    await page.keyboard.type('(* x x))');
    assert((await page.inputValue('#line')).includes('\n'), 'newline inserted');
    await page.press('#line', 'Enter');
    await waitStatus('ready');
    await evalTo('(sq 12)', /\n144\n/);
  });

  await check(P + 'history: ArrowUp recalls the last input', async () => {
    await page.focus('#line');
    await page.press('#line', 'ArrowUp');
    assert(await page.inputValue('#line') === '(sq 12)', 'got ' + JSON.stringify(await page.inputValue('#line')));
    await page.press('#line', 'ArrowDown');
    assert(await page.inputValue('#line') === '', 'back to the empty draft');
  });

  await check(P + 'errors go to stderr, styled', async () => {
    await evalTo('(car 1)', /bad argument type/);
    assert(await page.$eval('#term', e => [...e.querySelectorAll('.err')].some(s => /bad argument type/.test(s.textContent))),
           'error text in an .err span');
  });

  await check(P + 'Stop during an endless loop gives user interrupt', async () => {
    await enter('(let loop () (loop))');
    await waitStatus('running');
    await page.waitForTimeout(300);
    const t = Date.now();
    await page.click('#stop');
    await waitSince(/user interrupt/, 5000);
    await waitStatus('ready');
    console.log('  # stopped in ' + (Date.now() - t) + ' ms');
    await evalTo('(+ 2 2)', /\n4\n/);
  });

  await check(P + 'Esc stops too', async () => {
    await enter('(let loop ((i 0)) (loop (+ i 1)))');
    await waitStatus('running');
    await page.press('#line', 'Escape');
    await waitSince(/user interrupt/, 5000);
    await waitStatus('ready');
  });

  await check(P + 'Stop in a long non-yielding primitive restarts the worker', async () => {
    // bignum expt runs in library code with interrupts disabled: no slices,
    // no messages, so the 3 s liveness watchdog replaces the worker
    await enter('(define big (expt 7 6000000))');
    await waitStatus('running');
    await page.waitForTimeout(300);
    const t = Date.now();
    await page.click('#stop');
    await waitSince(/interpreter restarted \(state lost\)[\s\S]*#;1> $/, 20000);
    await waitStatus('ready');
    const ms = Date.now() - t;
    console.log('  # replaced in ' + ms + ' ms');
    assert(ms >= 2900, 'not before the 3 s watchdog');
    await evalTo('(+ 5 5)', /\n10\n/);
  });

  await check(P + 'sleep shows the sleeping state and returns', async () => {
    await enter('(sleep 1) (print \'woke)');
    await waitStatus('sleeping', 3000);
    await waitSince(/woke\n/, 5000);
    await waitStatus('ready');
  });

  await check(P + 'upload a file and load it with ,l', async () => {
    await mark();
    await page.setInputFiles('#upload', { name: 'up.scm', mimeType: 'text/plain',
                                          buffer: Buffer.from('(define up-val 99)\n(print "loaded up")\n') });
    await waitSince(/uploaded up\.scm .*,l up\.scm/);
    await evalTo(',l up.scm', /loaded up\n/);
    await evalTo('up-val', /\n99\n/);
  });

  await check(P + 'long output streams and stays capped', async () => {
    await enter('(let loop ((i 0)) (when (< i 30000) (print i) (loop (+ i 1))))');
    await waitSince(/\n29999\n#;\d+> $/, 60000);
    await waitStatus('ready');
    const n = await page.$eval('#term', e => e.textContent.split('\n').length);
    assert(n <= 20001, 'terminal capped at 20000 lines, has ' + n);
    // At the cap, new output trims the start of the terminal, which
    // would move the text after a mark(): start afresh.
    await page.click('#clear');
    await evalTo('(+ 1 1)', /\n2\n/);
  });

  if (shots) {
    fs.mkdirSync(shots, { recursive: true });
    await page.click('#clear');
    await evalTo('(import (chicken string))', /#;\d+> $/);
    await evalTo('(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))', /#;\d+> $/);
    await evalTo('(fact 30)', /265252859812191058636308480000000/);
    await evalTo('(string-intersperse \'("a" "b" "c") ", ")', /"a, b, c"/);
    await evalTo('(map (lambda (x) (* x x)) \'(1 2 3 4 5))', /\(1 4 9 16 25\)/);
    await evalTo('(vector-ref (vector 1 2) 5)', /out of range/);
    await page.fill('#line', '(let loop ((i 0))');
    await page.mouse.move(0, 0);
    for (const scheme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme: scheme });
      await page.setViewportSize({ width: 1280, height: 800 });
      await page.waitForTimeout(400);             // let colour transitions finish
      await page.screenshot({ path: path.join(shots, `${name}-repl-${scheme}-desktop.png`) });
      await page.setViewportSize({ width: 360, height: 740 });
      await page.screenshot({ path: path.join(shots, `${name}-repl-${scheme}-360.png`) });
    }
    await page.fill('#line', '');
    await page.emulateMedia({ colorScheme: 'light' });
    await page.setViewportSize({ width: 1280, height: 800 });
  }

  await check(P + 'Restart gives a fresh prompt; uploads survive', async () => {
    await mark();
    await page.click('#restart');
    await waitSince(/restarting[\s\S]*CHICKEN[\s\S]*#;1> $/, 60000);
    await waitStatus('ready');
    await evalTo('(begin (load "up.scm") up-val)', /\n99\n/);
  });

  await check(P + '(exit 7) shows the exit and offers Restart', async () => {
    await enter('(exit 7)');
    await waitStatus('exited');
    await waitSince(/process exited \(code 7\)/);
    assert(await page.isVisible('#notice-restart'), 'restart offered');
    assert(await page.isDisabled('#line'), 'input disabled');
    await mark();
    await page.click('#notice-restart');
    await waitStatus('ready', 60000);
    await waitSince(/#;1> $/);
    assert(!(await page.isVisible('#notice')), 'notice hidden again');
  });

  await check(P + 'Ctrl+D at the prompt asks, then ends the session', async () => {
    let asked = '';
    page.once('dialog', d => { asked = d.message(); d.accept(); });
    await mark();
    await page.focus('#line');
    await page.press('#line', 'Control+d');
    await waitStatus('exited');
    await waitSince(/session ended/);
    assert(asked === 'End session?', 'confirmation asked: ' + JSON.stringify(asked));
    await page.click('#notice-restart');
    await waitStatus('ready', 60000);
  });

  await check(P + 'output without newlines stays capped', async () => {
    await page.click('#clear');
    await enter('(let loop ((i 0)) (when (< i 3000) (display (make-string 1000 #\\x)) (loop (+ i 1))))');
    await waitSince(/#;\d+> $/, 120000);
    await waitStatus('ready');
    const n = await page.$eval('#term', e => e.textContent.length);
    assert(n <= 2000100, 'terminal capped at 2000000 characters, has ' + n);
    await page.click('#clear');
  });

  // elements sticking out of the viewport, and the page's scroll widths
  const overflow = () => page.evaluate(() => {
    const d = document.documentElement;
    const wide = [...document.querySelectorAll('body *')].filter(e => {
      const r = e.getBoundingClientRect();
      return r.width && (r.right > d.clientWidth + 0.5 || r.left < -0.5) && getComputedStyle(e).visibility !== 'hidden';
    }).map(e => e.tagName + (e.id ? '#' + e.id : '') + (e.className && typeof e.className === 'string' ? '.' + e.className : ''));
    return { sw: d.scrollWidth, cw: d.clientWidth, bw: document.body.scrollWidth, wide: wide.slice(0, 5) };
  });

  for (const width of [360, 320]) await check(P + `no horizontal scroll at ${width} px`, async () => {
    await page.setViewportSize({ width, height: 740 });
    await evalTo('(make-string 300 #\\x)', /xxxxxxxxxx"\n/);
    const over = overflow;
    let o = await over();
    assert(o.sw <= o.cw && o.bw <= o.cw && !o.wide.length, 'REPL tab: ' + JSON.stringify(o));
    const bar = await page.$eval('.bar', e => [e.scrollWidth, e.clientWidth]);
    assert(bar[0] <= bar[1], 'header bar fits: ' + bar);
    const gutter = await page.$eval('#console', e => e.getBoundingClientRect().left);
    assert(gutter >= 15.5 && gutter <= 16.5, '16 px gutter, got ' + gutter);
    await page.click('#tab-compile');
    o = await over();
    assert(o.sw <= o.cw && o.bw <= o.cw && !o.wide.length, 'compile tab: ' + JSON.stringify(o));
    await page.click('#tab-repl');
    await page.setViewportSize({ width: 1280, height: 800 });
  });

  await check(P + 'Compile to C: (print 1) gives C_toplevel, with a download', async () => {
    await page.click('#tab-compile');
    assert(await page.isVisible('#panel-compile') && !(await page.isVisible('#panel-repl')), 'tab switched');
    await page.fill('#src', '(define (f x) (* x 2)) (print (f 21))');
    await page.click('#compile');
    await page.waitForFunction(() => /ok|fail/.test(document.getElementById('cstatus').className), null, { timeout: 60000 });
    assert(await page.$eval('#cstatus', e => e.classList.contains('ok')), 'ok: ' + await page.textContent('#cstatus'));
    assert((await page.textContent('#cout')).includes('C_toplevel'), 'C_toplevel in the output');
    const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#download')]);
    assert(dl.suggestedFilename() === 'program.c', 'file name ' + dl.suggestedFilename());
    const file = await dl.path();
    assert(fs.readFileSync(file, 'utf8').includes('C_toplevel'), 'downloaded C');
  });

  await check(P + 'Compile to C: a syntax error fails with messages', async () => {
    await page.fill('#src', '(define (f x) (* x 2)');
    await page.click('#compile');
    await page.waitForFunction(() => /ok|fail/.test(document.getElementById('cstatus').className) &&
                               !document.getElementById('compile').disabled, null, { timeout: 60000 });
    assert(await page.$eval('#cstatus', e => e.classList.contains('fail')), 'fail status');
    assert(/unterminated list/.test(await page.textContent('#clog')), 'compiler message shown');
    assert((await page.textContent('#cout')) === '', 'no C');
  });

  const compiled = () => page.waitForFunction(() => /ok|fail/.test(document.getElementById('cstatus').className) &&
                                              !document.getElementById('compile').disabled, null, { timeout: 60000 });

  await check(P + 'Compile to C: -check-syntax succeeds without C', async () => {
    await page.fill('#src', '(print 1)');
    await page.fill('#cargs', '-check-syntax');
    try {
      await page.click('#compile');
      await compiled();
      assert(await page.$eval('#cstatus', e => e.classList.contains('ok')), 'ok: ' + await page.textContent('#cstatus'));
      assert(/without generating C/.test(await page.textContent('#cstatus')), 'status ' + await page.textContent('#cstatus'));
      assert(!/object Object/.test(await page.textContent('#clog')), 'no [object Object]');
    } finally { await page.fill('#cargs', ''); }
  });

  await check(P + 'Compile to C: Cancel stops a compile that never ends', async () => {
    await page.fill('#src', '(define-syntax hang (er-macro-transformer (lambda (x r c) (let l () (l)))))\n(hang)');
    await page.click('#compile');
    await page.waitForSelector('#ccancel', { state: 'visible' });
    await page.waitForTimeout(1500);
    assert(await page.$eval('#compile', e => e.disabled), 'still compiling');
    await page.click('#ccancel');
    await compiled();
    assert(/cancelled/.test(await page.textContent('#cstatus')), 'status ' + await page.textContent('#cstatus'));
    assert(!(await page.isVisible('#ccancel')), 'Cancel hidden again');
    await page.fill('#src', '(print 1)');
    await page.click('#compile');
    await compiled();
    assert((await page.textContent('#cout')).includes('C_toplevel'), 'compiles again');
  });

  if (shots) {
    await page.fill('#src', ';; Press Ctrl+Enter or Compile to translate this to C.\n(define (fib n)\n  (if (< n 2)\n      n\n      (+ (fib (- n 1)) (fib (- n 2)))))\n\n(print (fib 25))\n');
    await page.click('#compile');
    await page.waitForFunction(() => document.getElementById('cstatus').classList.contains('ok'), null, { timeout: 60000 });
    for (const scheme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme: scheme });
      await page.setViewportSize({ width: 1280, height: 800 });
      await page.waitForTimeout(400);             // let colour transitions finish
      await page.screenshot({ path: path.join(shots, `${name}-compile-${scheme}-desktop.png`) });
      await page.setViewportSize({ width: 360, height: 740 });
      await page.screenshot({ path: path.join(shots, `${name}-compile-${scheme}-360.png`) });
    }
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.emulateMedia({ colorScheme: 'light' });
    await page.click('#tab-repl');
    await page.click('#settings-btn');
    await page.screenshot({ path: path.join(shots, `${name}-settings-light-desktop.png`) });
    await page.keyboard.press('Escape');
  }

  // ---- the Notebook tab (notebook.js, nb-kernel.js)

  const NB_DONE = /^(ok|error|interrupted|cancelled)$/;
  const nbCells = () => page.$$eval('#nb-cells > li', l => l.length);
  const nbCell = i => page.locator('#nb-cells > li').nth(i);
  const nbSrc = i => nbCell(i).locator('.nb-src');
  const nbWait = (i, re = NB_DONE, timeout = 30000) =>
    page.waitForFunction(([i, s, f]) => {
      const li = document.querySelectorAll('#nb-cells > li')[i];
      return !!li && new RegExp(s, f).test(li.dataset.status);
    }, [i, re.source, re.flags], { timeout });
  const nbStatus = i => page.$eval(`#nb-cells > li:nth-child(${i + 1})`, e => e.dataset.status);
  const nbOut = i => page.$eval(`#nb-cells > li:nth-child(${i + 1}) .nb-out`, e => e.textContent);
  const nbValues = i => page.$$eval(`#nb-cells > li:nth-child(${i + 1}) .nb-value`, l => l.map(e => e.textContent));
  const nbCountText = i => page.$eval(`#nb-cells > li:nth-child(${i + 1}) .nb-count`, e => e.textContent);
  const waitNbStatus = (re, timeout = 30000) =>
    page.waitForFunction(([s, f]) => new RegExp(s, f).test(document.getElementById('nb-status').dataset.state),
                         [re.source, re.flags], { timeout });
  async function nbNew(src) {           // a new code cell at the end; its index
    await page.click('#nb-end-code');
    const i = (await nbCells()) - 1;
    if (src != null) await nbSrc(i).fill(src);
    return i;
  }
  async function nbRun(i, src, key = 'Control+Enter') {
    if (src != null) await nbSrc(i).fill(src);
    await nbSrc(i).press(key);
  }
  async function nbEval(src, timeout) {    // run src in a new cell, wait for the end
    const i = await nbNew(src);
    await nbRun(i);
    await nbWait(i, NB_DONE, timeout);
    return i;
  }
  const replWorkers = () => page.workers().filter(w => /repl-worker\.js/.test(w.url())).length;
  const scm = s => '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  async function accepting(f) {         // run f, accepting confirm() dialogs
    const h = d => d.accept().catch(() => {});
    page.on('dialog', h);
    try { await f(); await page.waitForTimeout(200); } finally { page.off('dialog', h); }
  }
  async function menu(label) {
    await page.click('#nb-more');
    await page.click(`#nb-menu [role="menuitem"]:has-text("${label}")`);
  }

  await check(P + 'notebook: lazy kernel start; status loading, then ready', async () => {
    assert(replWorkers() === 1, 'one csi worker before the first visit: ' + replWorkers());
    assert(await page.$eval('#nb-status', e => e.dataset.state) === 'off', 'kernel not started');
    await page.evaluate(() => {
      window.__nbStates = [];
      const s = document.getElementById('nb-status');
      new MutationObserver(() => window.__nbStates.push(s.dataset.state)).observe(s, { attributes: true });
    });
    await page.click('#tab-notebook');
    await waitNbStatus(/^ready$/, 60000);
    const states = await page.evaluate(() => window.__nbStates);
    assert(states.indexOf('loading') >= 0 && states.indexOf('loading') < states.lastIndexOf('ready'), 'states ' + states);
    assert(/^CHICKEN .* · wasm(32|64)$/.test(await page.textContent('#nb-info')), 'info ' + await page.textContent('#nb-info'));
    assert(replWorkers() === 2, 'two csi workers after it: ' + replWorkers());
  });

  await check(P + 'notebook: three tabs, keyboard navigation, per-tab toolbars', async () => {
    const names = await page.$$eval('[role="tab"]', l => l.map(t => t.textContent.trim()));
    assert(names.join('|') === 'REPL|Notebook|Compile to C', 'tabs ' + names);
    const consistent = () => page.evaluate(() => [...document.querySelectorAll('[role="tab"]')].every(t =>
      (t.getAttribute('aria-selected') === 'true') === !document.getElementById(t.getAttribute('aria-controls')).hidden));
    const sel = () => page.evaluate(() => document.querySelector('[role="tab"][aria-selected="true"]').id);
    const vis = () => page.evaluate(() => ({
      nbBar: !document.getElementById('nb-toolbar').hidden, bar: !document.getElementById('toolbar').hidden,
      pill: getComputedStyle(document.getElementById('status')).visibility,
    }));
    assert(await sel() === 'tab-notebook' && await consistent(), 'notebook selected');
    let v = await vis();
    assert(v.nbBar && !v.bar && v.pill === 'hidden', 'notebook chrome ' + JSON.stringify(v));
    await page.focus('#tab-notebook');
    await page.keyboard.press('ArrowRight');
    assert(await sel() === 'tab-compile' && await consistent(), 'ArrowRight');
    await page.keyboard.press('Home');
    assert(await sel() === 'tab-repl' && await consistent(), 'Home');
    v = await vis();
    assert(!v.nbBar && v.bar && v.pill === 'visible', 'REPL chrome ' + JSON.stringify(v));
    await page.keyboard.press('End');
    assert(await sel() === 'tab-compile', 'End');
    await page.keyboard.press('ArrowLeft');
    assert(await sel() === 'tab-notebook' && await consistent(), 'ArrowLeft');
    assert(await page.evaluate(() => document.activeElement.id) === 'tab-notebook', 'focus follows');
  });
  await page.click('#tab-notebook');    // whatever happened above

  await check(P + 'notebook: Run all on the example; stop on error', async () => {
    const types = await page.$$eval('#nb-cells > li', l => l.map(e => e.dataset.type));
    assert(types.length >= 8 && types[0] === 'markdown' && types.includes('code'), 'example loaded: ' + types);
    await page.click('#nb-run-all');
    await page.waitForFunction(() => {
      const l = [...document.querySelectorAll('#nb-cells > li[data-type="code"]')];
      return l.length && l.every(e => /^(ok|error|cancelled|interrupted)$/.test(e.dataset.status));
    }, null, { timeout: 90000 });
    const cells = await page.$$eval('#nb-cells > li[data-type="code"]', l => l.map(e =>
      ({ st: e.dataset.status, n: e.querySelector('.nb-count').textContent, err: (e.querySelector('.nb-error-msg') || {}).textContent })));
    const bad = cells.findIndex(c => c.st === 'error');
    assert(bad > 0, 'an error cell: ' + JSON.stringify(cells));
    assert(/out of range|bad argument/.test(cells[bad].err), 'error text ' + cells[bad].err);
    cells.slice(0, bad + 1).forEach((c, k) => assert(c.n === '[' + (k + 1) + ']', 'count of code cell ' + k + ': ' + c.n));
    assert(cells.slice(0, bad).every(c => c.st === 'ok'), 'cells before it ok');
    assert(cells.slice(bad + 1).length && cells.slice(bad + 1).every(c => c.st === 'cancelled'), 'cells after it cancelled');
  });

  await check(P + 'notebook: rich output (table, themed SVG, progress in place)', async () => {
    const r = await page.evaluate(() => {
      const rich = [...document.querySelectorAll('#nb-cells .nb-rich')];
      const table = rich.find(e => e.querySelector('table'));
      const svg = document.querySelector('#nb-cells .nb-rich svg');
      const rect = svg && svg.querySelector('rect');
      const probe = document.createElement('span');
      probe.style.color = 'var(--accent)';
      document.body.appendChild(probe);
      const accent = getComputedStyle(probe).color;
      probe.remove();
      const prog = [...document.querySelectorAll('#nb-cells > li')].find(li => li.querySelector('progress'));
      return {
        table: !!table && !!table.querySelector('th') && table.querySelectorAll('td').length === 6,
        fill: rect && getComputedStyle(rect).fill, accent,
        progress: prog ? [...prog.querySelectorAll('progress')].map(p => p.getAttribute('value')) : null,
      };
    });
    assert(r.table, 'table with th and td');
    assert(r.fill && r.fill === r.accent, 'bar fill ' + r.fill + ' vs accent ' + r.accent);
    assert(r.progress && r.progress.length === 1 && r.progress[0] === '3', 'progress ' + JSON.stringify(r.progress));
  });

  if (shots) {
    await page.mouse.move(0, 0);
    // the table, the chart and the progress bar
    await page.$eval('#nb-cells .nb-rich svg', e => {
      e.scrollIntoView({ block: 'start' });
      document.getElementById('panel-notebook').scrollTop -= 230;
    });
    for (const scheme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme: scheme });
      await page.setViewportSize({ width: 1280, height: 800 });
      await page.waitForTimeout(400);
      await page.screenshot({ path: path.join(shots, `${name}-notebook-${scheme}-desktop.png`) });
      await page.setViewportSize({ width: 360, height: 740 });
      await page.waitForTimeout(200);
      await page.screenshot({ path: path.join(shots, `${name}-notebook-${scheme}-360.png`) });
    }
    await page.emulateMedia({ colorScheme: 'light' });
    await page.setViewportSize({ width: 1280, height: 800 });
  }

  await check(P + 'notebook: Shift+Enter, Ctrl+Enter and Alt+Enter', async () => {
    const i = await nbNew('(+ 1 2)');
    const before = await nbCells();
    await nbRun(i, null, 'Shift+Enter');
    await nbWait(i);
    assert((await nbValues(i)).join() === '3', 'value ' + await nbValues(i));
    assert(/^\[\d+\]$/.test(await nbCountText(i)), 'count ' + await nbCountText(i));
    assert(await nbCells() === before + 1, 'a cell was appended');
    const focus = () => page.evaluate(() => {
      const a = document.activeElement, li = a.closest('#nb-cells > li');
      return { src: a.classList.contains('nb-src'), i: li ? [...li.parentNode.children].indexOf(li) : -1 };
    });
    let f = await focus();
    assert(f.src && f.i === i + 1, 'focus in the next editor: ' + JSON.stringify(f));
    await nbRun(i + 1, '(* 6 7)', 'Control+Enter');
    await nbWait(i + 1);
    assert((await nbValues(i + 1)).join() === '42', 'Ctrl+Enter value');
    f = await focus();
    assert(f.src && f.i === i + 1, 'Ctrl+Enter keeps focus: ' + JSON.stringify(f));
    await nbRun(i + 1, '(- 50 8)', 'Alt+Enter');
    await nbWait(i + 1, /^ok$/);
    f = await focus();
    assert(await nbCells() === before + 2 && f.src && f.i === i + 2, 'Alt+Enter inserts below: ' + JSON.stringify(f));
  });

  await check(P + 'notebook: stdout and stderr in order; (values)', async () => {
    const i = await nbEval('(display "one") (display "two" (current-error-port)) (display "three") (values)');
    const parts = await page.$$eval(`#nb-cells > li:nth-child(${i + 1}) .nb-out > *`, l => l.map(e => e.className + ':' + e.textContent));
    assert(parts.join('|') === 'nb-stream stdout:one|nb-stream stderr:two|nb-stream stdout:three|nb-value none:; no values',
           'outputs ' + parts.join('|'));
  });

  await check(P + 'notebook: a separate interpreter; the REPL answers while a cell runs', async () => {
    await nbEval('(define nb-only 1)');
    const loop = await nbNew('(let loop () (loop))');
    await nbRun(loop);
    await nbWait(loop, /^running$/);
    await page.click('#tab-repl');
    await evalTo('nb-only', /unbound variable: nb-only/);
    await evalTo('(+ 1 2)', /\n3\n/);
    await page.click('#tab-notebook');
    assert(await nbStatus(loop) === 'running', 'still running');
    await page.click('#nb-stop');
    await nbWait(loop, /^interrupted$/, 5000);
  });

  await check(P + 'notebook: Stop with i i and with Ctrl+C', async () => {
    const a = await nbNew('(let loop ((i 0)) (loop (+ i 1)))');
    await nbRun(a);
    await nbWait(a, /^running$/);
    await nbSrc(a).press('Escape');
    assert(await page.evaluate(() => document.activeElement.matches('#nb-cells > li')), 'command mode');
    await page.keyboard.press('i');
    await page.keyboard.press('i');
    await nbWait(a, /^interrupted$/, 5000);
    await nbSrc(a).click();
    await nbRun(a);
    await nbWait(a, /^running$/);
    await nbSrc(a).press('Control+c');
    await nbWait(a, /^interrupted$/, 5000);
    const b = await nbEval('(+ 2 2)');
    assert((await nbValues(b)).join() === '4', 'next cell works');
  });

  await check(P + 'notebook: stdin from a cell; EOF; Stop while waiting', async () => {
    await nbEval('(import (chicken io))');
    const i = await nbNew('(read-line)');
    await nbRun(i);
    await nbWait(i, /^waiting$/);
    await page.waitForFunction(n => document.activeElement.matches(`#nb-cells > li:nth-child(${n}) .nb-stdin-text`), i + 1);
    assert(await nbCell(i).locator('.nb-stdin').isVisible(), 'stdin form shown');
    await page.keyboard.type('bob');
    await page.keyboard.press('Enter');
    await nbWait(i);
    assert((await nbValues(i)).join() === '"bob"', 'value ' + await nbValues(i));
    assert(!(await nbCell(i).locator('.nb-stdin').isVisible()), 'stdin form hidden again');
    const j = await nbNew('(read-line)');
    await nbRun(j);
    await nbWait(j, /^waiting$/);
    await nbCell(j).locator('.nb-eof').click();
    await nbWait(j);
    assert((await nbValues(j)).join() === '#!eof', 'EOF ' + await nbValues(j));
    const k = await nbNew('(read-line)');
    await nbRun(k);
    await nbWait(k, /^waiting$/);
    await page.click('#nb-stop');
    await nbWait(k, /^interrupted$/, 5000);
  });

  await check(P + 'notebook: output streams while the cell runs', async () => {
    const i = await nbNew('(do ((i 0 (+ i 1))) ((= i 3)) (print i) (sleep 1))');
    await nbRun(i);
    await page.waitForFunction(n => {
      const li = document.querySelectorAll('#nb-cells > li')[n];
      return /^0\n/.test(li.querySelector('.nb-out').textContent) &&
        /^(running|sleeping)$/.test(document.getElementById('nb-status').dataset.state);
    }, i, { timeout: 5000 });
    await nbWait(i, NB_DONE, 10000);
    assert(await nbStatus(i) === 'ok', 'ok');
  });

  await check(P + 'notebook: incomplete input evaluates nothing', async () => {
    const i = await nbEval('(display "x") (car (list');
    assert(await nbStatus(i) === 'error', 'error status');
    const out = await nbOut(i);
    assert(/Incomplete input/.test(out), 'note: ' + out);
    assert(!(await page.$(`#nb-cells > li:nth-child(${i + 1}) .nb-stream`)), 'no output');
    assert(await page.$eval(`#nb-cells > li:nth-child(${i + 1})`, e => !!e.querySelector('.nb-hl mark')), 'line highlighted');
  });

  await check(P + 'notebook: big output is capped and the kernel stays responsive', async () => {
    const i = await nbEval('(let loop ((i 0)) (when (< i 3000) (display (make-string 1000 #\\x)) (loop (+ i 1))))', 120000);
    const r = await page.$eval(`#nb-cells > li:nth-child(${i + 1})`, e => ({
      text: [...e.querySelectorAll('.nb-stream')].reduce((n, s) => n + s.textContent.length, 0),
      note: [...e.querySelectorAll('.nb-note')].map(n => n.textContent).join(' '),
    }));
    assert(r.text <= 1.05 * 1024 * 1024, 'kept ' + r.text + ' characters');
    assert(/omitted/.test(r.note), 'note ' + r.note);
    const t = Date.now();
    const j = await nbEval('(+ 1 1)', 5000);
    assert((await nbValues(j)).join() === '2' && Date.now() - t < 5000, 'responsive');
  });

  await check(P + 'notebook: markup is sanitized (outputs, markdown cells, imports)', async () => {
    const requests = [], dialogs = [];
    const onReq = r => { const u = r.url(); if (!u.startsWith(base) && !/^(data|blob):/.test(u)) requests.push(u); };
    const onDlg = d => {
      if (/^Replace the current notebook/.test(d.message())) d.accept().catch(() => {});
      else { dialogs.push(d.message()); d.dismiss().catch(() => {}); }
    };
    page.on('request', onReq);
    page.on('dialog', onDlg);
    try {
      const html = [
        '<img src=x onerror="window.__pwned=1">',
        '<a href="jav&#x09;ascript:window.__pwned=1">a</a>',
        '<svg><script>window.__pwned=1</script></svg>',
        '<svg><animate attributeName="href" values="javascript:window.__pwned=1"/></svg>',
        '<svg><a href="javascript:window.__pwned=1"><text y="20">a</text></a></svg>',
        '<style>body { display: none }</style>',
        '<iframe srcdoc="<script>parent.__pwned=1</script>"></iframe>',
        '<form><button formaction="javascript:window.__pwned=1">b</button></form>',
        '<div style="background:url(http://example.invalid/x)">bg</div>',
        '<math><mtext><table><mglyph><style><img src=x onerror="window.__pwned=1">',
        '<object data="http://example.invalid/o"></object><embed src="http://example.invalid/e">',
        '<div role="group" aria-label="evil" aria-owns="nb-run-all nb-restart" aria-controls="nb-cells" ' +
          'aria-activedescendant="nb-title" aria-flowto="tab-repl">own</div>',
        '<svg><a href="https://example.com/" tabindex="1"><text y="20">t</text></a>' +
          '<rect tabindex="2" width="5" height="5"/></svg>',
      ];
      const svgs = html.filter(s => s.startsWith('<svg'));
      const md = ['[x](javascript:window.__pwned=1)', '![x](http://example.invalid/t.png)', ...html];
      const src = '(import notebook)\n' +
        html.map(s => `(show (html ${scm(s)}))`).join('\n') + '\n' +
        svgs.map(s => `(show (svg ${scm(s)}))`).join('\n') + '\n' +
        md.map(s => `(show (markdown ${scm(s)}))`).join('\n');
      const i = await nbEval(src);
      assert(await nbStatus(i) === 'ok', 'cell ok: ' + await nbOut(i));
      await page.click('#nb-end-text');
      const m = (await nbCells()) - 1;
      await nbSrc(m).fill(md.join('\n\n'));
      await nbSrc(m).press('Shift+Enter');
      const outs = [...html.map(s => ({ k: 'display', mime: 'text/html', data: s, id: null })),
                    ...svgs.map(s => ({ k: 'display', mime: 'image/svg+xml', data: s.replace('<svg', '<svg xmlns="http://www.w3.org/2000/svg"'), id: null })),
                    ...md.map(s => ({ k: 'display', mime: 'text/markdown', data: s, id: null }))];
      const nbJson = JSON.stringify({ format: 'chicken-notebook', version: 1, meta: { title: 'xss' }, cells: [
        { id: 'x1', type: 'code', source: '1', count: 1, outputs: outs },
        { id: 'x2', type: 'markdown', source: md.join('\n\n') }] });
      const scan = () => page.evaluate(() => {
        const bad = [];
        for (const e of document.querySelectorAll('#panel-notebook *')) {
          for (const a of e.attributes) if (/^on/i.test(a.name)) bad.push(e.localName + '[' + a.name + ']');
          if (/^(script|iframe|foreignobject|animate|set|style|object|embed|math|form)$/i.test(e.localName) &&
              !e.matches('form.nb-stdin')) bad.push(e.localName);   // (the page's own stdin fields)
          const src = e.getAttribute('src') || (e.localName === 'a' ? '' : e.getAttribute('href')) || '';
          if (/^\s*(javascript|vbscript):|example\.invalid/i.test(src)) bad.push(e.localName + ' ' + src);
          if (/^\s*(javascript|vbscript|data):/i.test(e.getAttribute('href') || '')) bad.push(e.localName + ' href');
          if (Number(e.getAttribute('tabindex')) > 0) bad.push(e.localName + ' tabindex');
          const st = e.getAttribute('style') || '';
          if (/url\(/i.test(st)) bad.push('style ' + st);
          const box = e.closest('.nb-rich, .nb-md');
          if (box) for (const a of e.attributes) {
            if (!/^aria-/.test(a.name)) continue;
            for (const id of a.value.split(/\s+/)) {
              const t = id && document.getElementById(id);
              if (t && t.closest('.nb-rich, .nb-md') !== box) bad.push(a.name + '=' + id);
            }
          }
        }
        return { bad, pwned: window.__pwned, rich: document.querySelectorAll('#nb-cells .nb-rich').length };
      });
      await page.waitForTimeout(300);
      let r = await scan();
      assert(!r.bad.length && r.pwned === undefined, 'outputs and markdown: ' + JSON.stringify(r));
      await accepting(() => page.setInputFiles('#nb-file', { name: 'xss.json', mimeType: 'application/json', buffer: Buffer.from(nbJson) }));
      await page.waitForFunction(() => document.querySelectorAll('#nb-cells > li').length === 2);
      await page.waitForTimeout(300);
      r = await scan();
      assert(r.rich >= outs.length - 2, 'imported outputs rendered: ' + r.rich);
      assert(!r.bad.length && r.pwned === undefined, 'imported: ' + JSON.stringify(r));
      assert(!dialogs.length, 'dialogs: ' + dialogs);
      assert(!requests.length, 'requests: ' + requests);
    } finally {
      page.off('request', onReq);
      page.off('dialog', onDlg);
    }
  });

  await check(P + 'notebook: markdown cells render and edit', async () => {
    await page.click('#nb-end-text');
    const i = (await nbCells()) - 1;
    assert(await nbSrc(i).evaluate(e => e === document.activeElement), 'new text cell in edit mode');
    await nbSrc(i).fill('## Title\n\nSome *em*, **strong** and `code`.\n\n- one\n- two\n\n```\n(+ 1 2)\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |');
    await nbSrc(i).press('Shift+Enter');
    const r = await page.$eval(`#nb-cells > li:nth-child(${i + 1}) .nb-md`, e => ({
      h2: (e.querySelector('h2') || {}).textContent, em: !!e.querySelector('em'), strong: !!e.querySelector('strong'),
      code: !!e.querySelector('p code'), li: e.querySelectorAll('ul li').length, pre: (e.querySelector('pre code') || {}).textContent,
      td: e.querySelectorAll('table td').length, visible: !!e.offsetParent,
    }));
    assert(r.h2 === 'Title' && r.em && r.strong && r.code && r.li === 2 && r.pre === '(+ 1 2)' && r.td === 2 && r.visible,
           'rendered ' + JSON.stringify(r));
    assert(!(await nbSrc(i).isVisible()), 'editor hidden');
    await nbCell(i).locator('.nb-md').dblclick();
    assert(await nbSrc(i).isVisible() && await nbSrc(i).evaluate(e => e === document.activeElement), 'double-click edits');
    await nbSrc(i).press('Shift+Enter');
    assert(await nbCell(i).locator('.nb-md h2').isVisible(), 'rendered again');
  });

  await check(P + 'notebook: command mode keys', async () => {
    const a = await nbNew('(+ 10 1)');
    await nbNew('(+ 10 2)');
    const focused = () => page.evaluate(() => {
      const a = document.activeElement;
      return a.matches('#nb-cells > li') ? [...a.parentNode.children].indexOf(a) : -1;
    });
    const n0 = await nbCells();
    await nbSrc(a).press('Escape');
    assert(await focused() === a, 'Esc selects the cell');
    await page.keyboard.press('j');
    assert(await focused() === a + 1, 'j');
    await page.keyboard.press('k');
    assert(await focused() === a, 'k');
    await page.keyboard.press('b');
    assert(await nbCells() === n0 + 1 && await focused() === a + 1, 'b inserts below');
    await page.keyboard.press('d');
    await page.keyboard.press('d');
    assert(await nbCells() === n0, 'd d deletes');
    assert(await page.isVisible('#nb-toast') && /Undo/.test(await page.textContent('#nb-toast')), 'undo toast');
    await page.keyboard.press('z');
    assert(await nbCells() === n0 + 1, 'z restores');
    await page.keyboard.press('d');
    await page.keyboard.press('d');
    assert(await focused() === a + 1, 'the next cell is selected: ' + await focused());
    await page.keyboard.press('m');
    assert(await nbCell(a + 1).getAttribute('data-type') === 'markdown', 'm');
    await page.keyboard.press('y');
    assert(await nbCell(a + 1).getAttribute('data-type') === 'code', 'y');
    assert(await nbSrc(a + 1).inputValue() === '(+ 10 2)', 'source kept');
    await page.keyboard.press('Alt+ArrowUp');
    assert(await nbSrc(a).inputValue() === '(+ 10 2)' && await focused() === a, 'Alt+Up moves the cell');
    await page.keyboard.press('Alt+ArrowDown');
    assert(await nbSrc(a + 1).inputValue() === '(+ 10 2)', 'Alt+Down moves it back');
    await page.keyboard.press('Shift+Enter');
    await nbWait(a + 1);
    assert((await nbValues(a + 1)).join() === '12', 'Shift+Enter in command mode runs');
    // Tab reaches the run button, the editor and the tools of a cell
    await nbCell(a).focus();
    const seen = [];
    for (let k = 0; k < 8 && !/source/.test(seen[seen.length - 1]); k++) {   // Tab in an editor indents
      await page.keyboard.press('Tab');
      seen.push(await page.evaluate(() => document.activeElement.getAttribute('aria-label') || document.activeElement.className));
    }
    assert(seen.some(s => /^Run cell/.test(s)) && seen.some(s => /source/.test(s)) &&
           seen.some(s => /^Move cell .* down/.test(s)) && seen.some(s => /^Delete cell/.test(s)), 'tab order ' + seen.join(', '));
  });

  await check(P + 'notebook: upload from More, then load it in a cell', async () => {
    const [fc] = await Promise.all([page.waitForEvent('filechooser'), menu('Upload files')]);
    await fc.setFiles({ name: 'nbup.scm', mimeType: 'text/plain', buffer: Buffer.from('(define nbup-val 99)\n') });
    await page.waitForFunction(() => /nbup\.scm/.test(document.getElementById('nb-toast-text').textContent));
    const i = await nbEval('(load "nbup.scm") nbup-val');
    assert((await nbValues(i)).join() === '99', 'value ' + await nbOut(i));
  });

  await check(P + 'notebook: settings re-theme it but do not restart the kernel', async () => {
    await nbEval('(define p21 5)');
    const setTheme = async t => {
      await menu('Settings');
      await page.waitForSelector('#settings[open]');
      await page.check(`input[name="theme"][value="${t}"]`);
      await page.click('#settings .actions .btn.primary');
      await page.waitForFunction(() => !document.getElementById('settings').open);
    };
    await setTheme('dark');
    const bg = await page.$eval('.nb-editor', e => getComputedStyle(e).backgroundColor);
    assert(await page.evaluate(() => document.documentElement.dataset.theme) === 'dark' && bg === 'rgb(14, 13, 12)', 'dark editor ' + bg);
    assert(/restart the kernel/.test(await page.textContent('#nb-notice-text')), 'restart notice');
    const i = await nbEval('p21');
    assert((await nbValues(i)).join() === '5', 'still bound: ' + await nbOut(i));
    await setTheme('auto');
    assert(await page.evaluate(() => !document.documentElement.dataset.theme), 'back to auto');
    await page.click('#nb-notice-close');
  });

  // the layout check of the REPL tab, on the Notebook tab
  for (const width of [360, 320]) await check(P + `notebook: no horizontal scroll at ${width} px`, async () => {
    await page.setViewportSize({ width, height: 740 });
    const i = await nbEval('(make-string 300 #\\x)');
    await nbCell(i).scrollIntoViewIfNeeded();
    const o = await overflow();
    assert(o.sw <= o.cw && o.bw <= o.cw && !o.wide.length, 'notebook tab: ' + JSON.stringify(o));
    const bar = await page.$eval('.bar', e => [e.scrollWidth, e.clientWidth]);
    assert(bar[0] <= bar[1], 'header bar fits: ' + bar);
    const tb = await page.$$eval('#nb-toolbar > .btn', l => [...new Set(l.map(e => Math.round(e.getBoundingClientRect().top)))]);
    assert(tb.length === 1, 'toolbar on one row: ' + tb);
    const v = await page.$eval(`#nb-cells > li:nth-child(${i + 1}) .nb-value`, e => [e.scrollWidth, e.clientWidth]);
    assert(v[0] > v[1], 'the long value scrolls in its own box: ' + v);
    await page.setViewportSize({ width: 1280, height: 800 });
  });

  await check(P + 'notebook: Stop in a non-yielding primitive restarts the kernel', async () => {
    const before = await nbEval('(define pre-kill 1)');
    const i = await nbNew('(define big (expt 7 6000000))');
    await nbRun(i);
    await nbWait(i, /^running$/);
    await page.waitForTimeout(300);
    const t = Date.now();
    await page.click('#nb-stop');
    await nbWait(i, /^error$/, 20000);
    const ms = Date.now() - t;
    console.log('  # replaced in ' + ms + ' ms');
    assert(ms >= 2900, 'not before the 3 s watchdog');
    assert(/did not respond/.test(await nbOut(i)), 'note: ' + await nbOut(i));
    assert(await nbCell(before).getAttribute('data-stale') === 'true', 'earlier cells stale');
    const j = await nbEval('(+ 5 5)', 60000);
    assert((await nbValues(j)).join() === '10', '(+ 5 5)');
  });

  await check(P + 'notebook: Restart resets the counter and the state', async () => {
    const a = await nbEval('(define before-restart 1)');
    await page.click('#nb-restart');
    await waitNbStatus(/^ready$/, 60000);
    assert(await nbCell(a).getAttribute('data-stale') === 'true', 'old output stale');
    const i = await nbEval('before-restart');
    assert(await nbCountText(i) === '[1]', 'count ' + await nbCountText(i));
    assert(/unbound variable/.test(await nbOut(i)), 'unbound: ' + await nbOut(i));
  });

  await check(P + 'notebook: export and import .scm and .json', async () => {
    const cells = () => page.$$eval('#nb-cells > li', l => l.map(e => [e.dataset.type, e.querySelector('.nb-src').value]));
    const before = await cells();
    for (const [label, ext] of [['Export .scm', '.scm'], ['Export .json', '.json']]) {
      const [dl] = await Promise.all([page.waitForEvent('download'), menu(label)]);
      assert(dl.suggestedFilename().endsWith(ext), 'file name ' + dl.suggestedFilename());
      const text = fs.readFileSync(await dl.path(), 'utf8');
      if (ext === '.scm') assert(/^;; %%$/m.test(text) && /^;; %% \[markdown\]$/m.test(text), 'percent markers');
      else assert(JSON.parse(text).format === 'chicken-notebook', 'json format');
      await page.click('#nb-end-code');            // changed, then replaced by the import
      await accepting(() => page.setInputFiles('#nb-file', { name: 'nb' + ext, mimeType: 'text/plain', buffer: Buffer.from(text) }));
      await page.waitForFunction(n => document.querySelectorAll('#nb-cells > li').length === n, before.length);
      const after = await cells();
      assert(JSON.stringify(after) === JSON.stringify(before), ext + ' round trip:\n' + JSON.stringify(before) + '\n' + JSON.stringify(after));
    }
    const r = await page.evaluate(() => {
      const L = window.ChickenNotebookLib;
      const split = L.splitPercent('(define a 1)\n\n(define (f)\n\n  "x\n\ny")\n\n; c\n(f)\r\n');
      const crlf = L.splitPercent(';; %%\r\n(+ 1 2)\r\n;; %% [markdown]\r\n;; # T\r\n');
      const j = L.fromJson(JSON.stringify({ format: 'chicken-notebook', version: 1, meta: {}, cells: [
        { id: 'd1', type: 'code', source: '1', outputs: [{ k: 'value', text: '1' }, { k: 'evil', text: 'x' },
                                                          { k: 'display', mime: 'text/javascript', data: 'x' }] },
        { id: 'd1', type: 'code', source: '2', count: 'x' },
        { type: 'shell', source: 'rm' }, { id: 'ok', type: 'markdown', source: 7 }] }));
      // lines that would read as markers survive the round trip
      const marks = [{ type: 'markdown', source: '```mermaid\n%% a\n```' }, { type: 'code', source: '1\n;;%% b\n;; \\%% c\n2' }];
      const back = L.splitPercent(L.toPercent({ title: 't', cells: marks })).cells;
      return { split: split.cells.map(c => c.source), crlf: crlf.cells.map(c => c.type + ':' + c.source),
               marks: JSON.stringify(back.map(c => [c.type, c.source])) === JSON.stringify(marks.map(c => [c.type, c.source])),
               ids: j.cells.map(c => c.id), outs: j.cells[0].outputs.length, count: 'count' in j.cells[1], n: j.cells.length };
    });
    assert(JSON.stringify(r.split) === JSON.stringify(['(define a 1)', '(define (f)\n\n  "x\n\ny")', '; c\n(f)']), 'split ' + r.split);
    assert(r.crlf.join('|') === 'code:(+ 1 2)|markdown:# T', 'crlf ' + r.crlf);
    assert(r.marks, 'marker-like lines round trip');
    assert(r.n === 2 && r.ids[0] === 'd1' && r.ids[1] !== 'd1' && r.outs === 1 && !r.count, 'json ' + JSON.stringify(r));
  });

  await check(P + 'notebook: Ctrl+C on selected output copies; the running cell goes on', async () => {
    const a = await nbEval('(display "copy me")');
    const b = await nbNew('(let loop () (sleep 1) (loop))');
    await nbRun(b);
    await nbWait(b, /^running$/);
    await nbCell(a).locator('.nb-stream').click({ clickCount: 3 });
    const sel = await page.evaluate(() => [String(getSelection()), document.activeElement.matches('#nb-cells > li')]);
    assert(/copy me/.test(sel[0]) && sel[1], 'output selected, the cell focused: ' + sel);
    await page.keyboard.press('Control+c');
    await page.waitForTimeout(500);
    const st = await nbStatus(b);
    assert(st === 'running', 'still running: ' + st);
    await nbSrc(b).click();
    await nbSrc(b).press('Control+c');
    await nbWait(b, /^interrupted$/, 5000);
  });

  await check(P + 'notebook: saved status, (values) and fragment links survive an import', async () => {
    const v = await nbEval('(values)');
    const s = await nbNew('(let loop () (loop))');
    await nbRun(s);
    await nbWait(s, /^running$/);
    await page.click('#nb-stop');
    await nbWait(s, /^interrupted$/, 5000);
    for (const src of ['# Tips\n\n[to the tips](#tips)', '# Tips']) {
      await page.click('#nb-end-text');
      const m = (await nbCells()) - 1;
      await nbSrc(m).fill(src);
      await nbSrc(m).press('Shift+Enter');
    }
    const links = () => page.evaluate(() => {
      const a = [...document.querySelectorAll('#nb-cells .nb-md a[href^="#"]')].pop();
      const ids = [...document.querySelectorAll('#nb-cells .nb-md [id]')].map(e => e.id);
      return { to: a && document.querySelector(a.getAttribute('href'))?.textContent, unique: new Set(ids).size === ids.length };
    });
    const before = await links();
    assert(before.to === 'Tips' && before.unique, 'links ' + JSON.stringify(before));
    const [dl] = await Promise.all([page.waitForEvent('download'), menu('Export .json')]);
    const text = fs.readFileSync(await dl.path(), 'utf8');
    await accepting(() => page.setInputFiles('#nb-file', { name: 'nb.json', mimeType: 'text/plain', buffer: Buffer.from(text) }));
    const st = [await nbStatus(s), (await nbValues(v)).join()];
    assert(st[0] === 'interrupted' && st[1] === '; no values', 'status and values after the import: ' + st);
    const after = await links();
    assert(after.to === 'Tips' && after.unique, 'links after the import ' + JSON.stringify(after));
  });

  await check(P + 'notebook: undo of a delete does not reach into an imported notebook', async () => {
    const [dl] = await Promise.all([page.waitForEvent('download'), menu('Export .json')]);
    const text = fs.readFileSync(await dl.path(), 'utf8');
    const n = await nbCells();
    await nbCell(1).locator('[data-act="del"]').click();
    await accepting(() => page.setInputFiles('#nb-file', { name: 'nb.json', mimeType: 'text/plain', buffer: Buffer.from(text) }));
    await page.waitForFunction(n => document.querySelectorAll('#nb-cells > li').length === n, n);
    assert(await page.isHidden('#nb-toast'), 'the Undo toast is gone');
    await nbCell(0).focus();
    await page.keyboard.press('z');
    await page.waitForTimeout(200);
    const ids = await page.$$eval('#nb-cells > li', l => l.map(e => e.dataset.id));
    assert(ids.length === n && new Set(ids).size === n, 'cells ' + ids.length + ' of ' + n + ', unique ids');
    await page.keyboard.press('Control+s');
    const saved = await page.evaluate(() => JSON.parse(localStorage.getItem('chicken-repl.notebook')).cells.length);
    assert(saved === n, 'saved cells ' + saved);
  });

  await check(P + 'notebook: the shortcuts dialog fits at 320 px', async () => {
    await page.setViewportSize({ width: 320, height: 740 });
    await nbCell(0).focus();
    await page.keyboard.press('?');
    await page.waitForSelector('#nb-shortcuts[open]');
    const w = await page.$eval('#nb-shortcuts', d => [d.scrollWidth, d.clientWidth, d.querySelector('.keys').scrollWidth,
                                                       d.querySelector('.keys').clientWidth]);
    await page.keyboard.press('Escape');
    await page.setViewportSize({ width: 1280, height: 800 });
    assert(w[0] <= w[1] && w[2] <= w[3], 'no horizontal scroll: ' + w);
  });

  await check(P + 'notebook: every button has an accessible name', async () => {
    const nameless = await page.evaluate(() => [...document.querySelectorAll('#panel-notebook button, #nb-toolbar button, #nb-shortcuts button')]
      .filter(b => !(b.getAttribute('aria-label') || b.textContent.trim() || b.title || b.getAttribute('aria-labelledby')))
      .map(b => b.outerHTML.slice(0, 80)));
    assert(!nameless.length, nameless.join('\n'));
  });

  await check(P + 'notebook: persistence across reloads; storage failures', async () => {
    const i = await nbEval('(define persisted 1) "persist me"');
    await page.keyboard.press('Control+s');
    await page.reload();
    await page.click('#tab-notebook');
    const k = await page.$$eval('#nb-cells > li', l => l.findIndex(e => /persist me/.test(e.querySelector('.nb-src').value)));
    assert(k === i, 'source restored at ' + k);
    assert(await nbCell(k).getAttribute('data-stale') === 'true' && /persist me/.test(await nbOut(k)), 'stale output');
    assert(await page.isVisible('#nb-notice') && /Restored/.test(await page.textContent('#nb-notice-text')), 'restored notice');
    await waitNbStatus(/^ready$/, 60000);
    await waitStatus('ready', 60000);
    // no localStorage at all, then a full one
    for (const mode of ['blocked', 'full']) {
      const f = await context.newPage();
      const errs = [];
      f.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
      f.on('pageerror', e => errs.push(e.message));
      if (mode === 'blocked') await f.addInitScript(() => {
        Object.defineProperty(window, 'localStorage', { get() { throw new DOMException('denied', 'SecurityError'); } });
      });
      else await f.addInitScript(() => {
        const set = Storage.prototype.setItem;
        Storage.prototype.setItem = function (k, v) {
          if (String(v).length > 1000) throw new DOMException('full', 'QuotaExceededError');
          return set.call(this, k, v);
        };
      });
      await f.goto(base + 'index.html');
      await f.click('#tab-notebook');
      await f.waitForFunction(() => document.getElementById('nb-status').dataset.state === 'ready', null, { timeout: 60000 });
      await f.click('#nb-end-code');
      await f.keyboard.type('(+ 20 22)');
      await f.keyboard.press('Control+Enter');
      await f.waitForFunction(() => /42/.test([...document.querySelectorAll('.nb-value')].map(e => e.textContent).join()), null, { timeout: 20000 });
      await f.waitForFunction(() => /Autosave failed/.test(document.getElementById('nb-notice-text').textContent) &&
                              !document.getElementById('nb-notice').hidden, null, { timeout: 5000 });
      assert(!errs.length, mode + ': ' + errs.join('\n'));
      await f.close();
    }
  });

  await check(P + 'from file:// the page explains that it needs HTTP', async () => {
    const f = await context.newPage();
    f.on('pageerror', e => errors.push('file:// pageerror: ' + e.message));
    await f.goto('file://' + path.join(webDir, 'index.html'));
    await f.waitForFunction(() => document.getElementById('status').dataset.state === 'error', null, { timeout: 10000 });
    assert(/served over HTTP/.test(await f.textContent('#notice-text')), 'notice: ' + await f.textContent('#notice-text'));
    assert(await f.isDisabled('#line'), 'input disabled');
    // the notebook says so too, and starts nothing
    await f.click('#tab-notebook');
    assert(/served over HTTP/.test(await f.textContent('#nb-notice-text')), 'nb notice: ' + await f.textContent('#nb-notice-text'));
    assert(await f.isDisabled('#nb-run-all'), 'Run all disabled');
    await f.locator('#nb-cells > li[data-type="code"] .nb-src').first().press('Shift+Enter');
    await new Promise(r => setTimeout(r, 500));
    assert(!f.workers().length, 'no worker: ' + f.workers().map(w => w.url()));
    assert(/served over HTTP/.test(await f.textContent('#nb-status-text')), 'status: ' + await f.textContent('#nb-status-text'));
    await f.close();
  });

  // Engines without memory64 (as Safari 26 and 27): the page must say so
  // for a wasm64 build, and still start a wasm32 build.
  await check(P + `without memory64 the ${arch} page ` +
              (arch === 'wasm64' ? 'explains what it needs' : 'still works'), async () => {
    const f = await context.newPage();
    const wasmFetched = [];
    f.on('pageerror', e => errors.push('no-memory64 pageerror: ' + e.message));
    f.on('request', r => { if (/\.wasm(\?|$)/.test(r.url())) wasmFetched.push(r.url()); });
    await f.addInitScript(() => {
      const validate = WebAssembly.validate;
      WebAssembly.validate = function (bytes) {
        const b = new Uint8Array(bytes.buffer || bytes);
        // a memory section declaring a 64-bit memory: flags 0x04 or 0x05
        for (let i = 8; i + 3 < b.length; i++)
          if (b[i] === 0x05 && b[i + 2] === 0x01 && (b[i + 3] & ~1) === 0x04) return false;
        return validate.apply(this, arguments);
      };
    });
    await f.goto(base + 'index.html');
    if (arch === 'wasm64') {
      await f.waitForFunction(() => document.getElementById('status').dataset.state === 'error', null, { timeout: 10000 });
      assert(/64-bit WebAssembly \(memory64\)/.test(await f.textContent('#notice-text')),
             'notice: ' + await f.textContent('#notice-text'));
      assert(/WASM_ARCH=wasm32/.test(await f.textContent('#term')), 'term suggests a wasm32 build');
      assert(await f.isDisabled('#line'), 'input disabled');
      assert(await f.isDisabled('#compile'), 'compile disabled');
      await f.click('#restart');
      await new Promise(r => setTimeout(r, 500));
      assert(await f.$eval('#status', e => e.dataset.state) === 'error', 'still unavailable after Restart');
      // Ctrl+Enter in the editor must not get past the disabled Compile button
      await f.click('#tab-compile');
      await f.click('#src');
      await f.keyboard.press('Control+Enter');
      await new Promise(r => setTimeout(r, 500));
      assert(await f.isDisabled('#compile'), 'compile still disabled after Ctrl+Enter');
      assert(/memory64/.test(await f.textContent('#cstatus')), 'cstatus: ' + await f.textContent('#cstatus'));
      await f.click('#tab-notebook');
      assert(/memory64/.test(await f.textContent('#nb-notice-text')), 'nb notice: ' + await f.textContent('#nb-notice-text'));
      await f.locator('#nb-cells > li[data-type="code"] .nb-src').first().press('Shift+Enter');
      await new Promise(r => setTimeout(r, 500));
      assert(!wasmFetched.length, 'fetched ' + wasmFetched.join(' '));
    } else {
      await f.waitForFunction(() => document.getElementById('status').dataset.state === 'ready', null, { timeout: 60000 });
      await f.click('#tab-notebook');
      await f.click('#nb-end-code');
      await f.keyboard.type('(+ 1 2)');
      await f.keyboard.press('Control+Enter');
      await f.waitForFunction(() => [...document.querySelectorAll('#nb-cells .nb-value')].some(e => e.textContent === '3'),
                              null, { timeout: 60000 });
    }
    await f.close();
  });

  await check(P + 'zero console errors', async () => {
    assert(!errors.length, errors.join('\n'));
  });

  await browser.close();
}

for (const b of browsers) {
  try { await runBrowser(b); }
  catch (e) { failures++; console.log('not ok - ' + b + ': ' + ((e && e.stack) || e)); }
}
server.close();
console.log('# ' + passes + ' passed, ' + failures + ' failed');
process.exit(failures ? 1 : 0);
