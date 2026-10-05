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
// Exits with status 1 if any check fails or the page logs a console error
// (or, for a build with exnref, the warning about legacy exception
// handling that Firefox gives).
//
// A page with two builds (make wasm WASM_WEB_ARCHS="wasm64 wasm32") is
// tested on wasm64, which both browsers run, and then on wasm32 as an
// engine without memory64 or exnref gets it, and as ?arch= and the
// Settings choose it; the warnings of the wasm32 pages, with legacy
// exception handling, are only counted.  (SHOTS also gets screenshots
// of the wasm32 page.)

import { createRequire } from 'node:module';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const require = createRequire(import.meta.url);
const pw = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const webDir = path.resolve(process.argv[2] || 'web');
const shots = process.env.SHOTS ? path.resolve(process.env.SHOTS) : null;
// The builds of the page (make wasm WASM_ARCH=... WASM_WEB_ARCHS=...):
// "ARCH:EH" each in chicken-wasm-builds, EH being how setjmp/longjmp were
// built (WASM_SJLJ): exnref, legacy or none.  A page from before
// WASM_WEB_ARCHS has the one of chicken-wasm-arch and chicken-wasm-eh.
const html = fs.readFileSync(path.join(webDir, 'index.html'), 'utf8');
const pageMeta = name => (new RegExp('<meta name="' + name + '" content="([^"]*)">').exec(html) || [])[1];
const builds = (pageMeta('chicken-wasm-builds') || pageMeta('chicken-wasm-arch') + ':' + pageMeta('chicken-wasm-eh'))
  .split(/\s+/).filter(Boolean).map(w => { const [a, e] = w.split(':'); return { arch: a, eh: e }; });
for (const b of builds) {
  if (b.arch !== 'wasm64' && b.arch !== 'wasm32') throw new Error('no wasm arch in ' + webDir + '/index.html');
  if (!['exnref', 'legacy', 'none'].includes(b.eh)) throw new Error('no wasm EH mode in ' + webDir + '/index.html');
}
const dual = builds.length > 1;
// the build the page runs in a browser with every feature
const { arch, eh } = builds.find(b => b.arch === 'wasm64') || builds[0];
const other = dual ? builds.find(b => b.arch !== arch) : null;
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

// WebAssembly.validate rejecting the page's probe for a feature (see
// PROBES in repl.js), as in an engine without it: a memory section
// declaring a 64-bit memory (flags 0x04 or 0x05), a try_table, or a
// legacy try ("legacy").
async function lackFeature(page, feature) {
  await page.addInitScript(feature => {
    const lacks = b => {
      for (let i = 8; i + 3 < b.length; i++) {
        if (feature === 'memory64' && b[i] === 0x05 && b[i + 2] === 0x01 && (b[i + 3] & ~1) === 0x04) return true;
        if (feature === 'exnref' && b[i] === 0x1f && b[i + 1] === 0x40 && b[i + 2] === 0x00 && b[i + 3] === 0x0b) return true;
        if (feature === 'legacy' && b[i] === 0x06 && b[i + 1] === 0x40 && b[i + 2] === 0x0b && b[i + 3] === 0x0b) return true;
      }
      return false;
    };
    const validate = WebAssembly.validate;
    WebAssembly.validate = function (bytes) {
      if (lacks(new Uint8Array(bytes.buffer || bytes))) return false;
      return validate.apply(this, arguments);
    };
  }, feature);
}
// The page and the notebook are locked out (file://, no memory64, ...):
// nothing that would start an interpreter may look enabled.
async function assertLockedOut(f, what) {
  assert(await f.isDisabled('#line'), what + ': input disabled');
  assert(await f.isDisabled('#restart'), what + ': Restart disabled');
  assert(await f.isHidden('#notice-restart'), what + ': no Restart in the notice');
  assert(await f.isDisabled('#compile'), what + ': Compile disabled');
  assert(await f.isDisabled('#upload-btn'), what + ': Upload disabled');
  assert(await f.getAttribute('#nb-menu [data-act="upload"]', 'aria-disabled') === 'true',
         what + ': the notebook\'s Upload disabled');
  assert(await f.isDisabled('#nb-run-all'), what + ': Run all disabled');
  assert(await f.isDisabled('#nb-restart'), what + ': Restart kernel disabled');
  assert(await f.getAttribute('#nb-menu [data-act="restart-run"]', 'aria-disabled') === 'true',
         what + ': Restart & run all disabled');
  // a forced click does nothing either
  const notice = await f.textContent('#notice-text');
  await f.click('#restart', { force: true });
  await new Promise(r => setTimeout(r, 300));
  assert(await f.$eval('#status', e => e.dataset.state) === 'error', what + ': still unavailable after Restart');
  assert(await f.textContent('#notice-text') === notice, what + ': notice unchanged');
  // nor does an upload (the input is still there for a drop)
  await f.setInputFiles('#upload', { name: 'up.scm', mimeType: 'text/plain', buffer: Buffer.from('(define up 1)\n') });
  await new Promise(r => setTimeout(r, 300));
  assert(!/uploaded/.test(await f.textContent('#term')), what + ': no upload: ' + await f.textContent('#term'));
}

// the notebook in the lockout: a short status, the whole message (with
// what to do) in its notice; Run starts nothing and keeps it so
async function assertNotebookLockedOut(f, what, re) {
  await f.setViewportSize({ width: 320, height: 640 });
  await f.click('#tab-notebook');
  const notice = async () => f.textContent('#nb-notice-text');
  assert(re.test(await notice()), what + ': nb notice: ' + await notice());
  await f.locator('#nb-cells > li[data-type="code"] .nb-src').first().press('Shift+Enter');
  await new Promise(r => setTimeout(r, 500));
  assert(!f.workers().length, what + ': no worker: ' + f.workers().map(w => w.url()));
  assert(await f.textContent('#nb-status-text') === 'unavailable', what + ': status: ' + await f.textContent('#nb-status-text'));
  assert(re.test(await notice()) && await f.isVisible('#nb-notice'), what + ': nb notice after Run: ' + await notice());
  const panel = await f.$eval('#panel-notebook', e => [e.scrollWidth, e.clientWidth]);
  assert(panel[0] <= panel[1], what + ': the notebook scrolls sideways: ' + panel);
}

async function runBrowser(name) {
  const browser = await pw[name].launch();
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, acceptDownloads: true });
  const page = await context.newPage();
  const errors = [];
  // Firefox warns once per module compiled with legacy exception handling
  // ("The WebAssembly exception handling 'try' instruction is deprecated")
  const legacyEh = [];
  const isLegacyEh = m => m.type() === 'warning' && /exception handling 'try' instruction is deprecated/.test(m.text());
  page.on('console', m => {
    if (m.type() === 'error') errors.push('console: ' + m.text());
    if (isLegacyEh(m)) legacyEh.push(m.text());
  });
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('worker', w => { if (typeof w.on === 'function') w.on('console', m => {
    if (m.type() === 'error') errors.push('worker console: ' + m.text());
    if (isLegacyEh(m)) legacyEh.push(m.text());
  }); });
  page.on('requestfailed', r => errors.push('request failed: ' + r.url()));
  const mainWasm = [];
  page.on('request', r => { if (/\.wasm(\?|$)/.test(r.url())) mainWasm.push(r.url()); });

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

  // the modules of a build: beside the page for its first one, else in
  // the directory named after its architecture
  const dirOf = a => (a === builds[0].arch ? '' : a + '/');
  const fromDir = (urls, a) => urls.every(u => new URL(u, base).pathname.startsWith('/' + dirOf(a) + 'chicken-') &&
                                         new URL(u, base).pathname.split('/').length === (dirOf(a) ? 3 : 2));

  if (dual) await check(P + `two builds: the page runs ${arch}, shows it, and loads only its modules`, async () => {
    assert(await page.evaluate(() => ChickenPage.ARCH) === arch, 'ChickenPage.ARCH');
    assert(await page.isVisible('#arch') && await page.textContent('#arch') === arch, 'chip: ' + await page.textContent('#arch'));
    assert(mainWasm.length && fromDir(mainWasm, arch), 'wasm fetched: ' + mainWasm.join(' '));
    const ws = page.workers().map(w => w.url()).filter(u => /repl-worker/.test(u));
    assert(ws.length === 1 && (dirOf(arch) ? new URL(ws[0], base).searchParams.get('dir') === dirOf(arch)
                                         : !new URL(ws[0], base).searchParams.has('dir')), 'worker ' + ws);
    assert(!/running the|ignoring/.test(await term()), 'no note about the choice: ' + (await term()).slice(0, 300));
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

  // The worker answers a Stop at once, often within the same tick of a
  // coarse clock (1 ms in Firefox): that must not count as no answer.
  await check(P + 'Esc and Stop at an idle prompt keep the state', async () => {
    await evalTo('(define kept 42)', /#;\d+> $/);
    for (const how of ['Esc', 'Stop']) {
      await mark();
      if (how === 'Esc') await page.press('#line', 'Escape'); else await page.click('#stop');
      await page.waitForTimeout(3600);    // past the 3 s watchdog
      assert(!/restarted/.test(await since()), how + ': restarted: ' + (await since()).slice(-300));
      await evalTo('kept', /\n42\n/);
    }
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

  await check(P + 'Stop after a sleep, in a non-yielding primitive, restarts the worker', async () => {
    // the page last heard "sleeping": the slice that woke up is in the
    // primitive, and reports nothing
    await enter('(begin (sleep 1) (define big (expt 7 60000000)))');
    await waitStatus('sleeping', 3000);
    await page.waitForTimeout(1500);
    const t = Date.now();
    await page.click('#stop');
    await waitSince(/interpreter restarted \(state lost\)[\s\S]*#;1> $/, 20000);
    await waitStatus('ready');
    const ms = Date.now() - t;
    assert(ms >= 2900, 'not before the 3 s watchdog: ' + ms);
    await evalTo('(+ 5 6)', /\n11\n/);
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
    // the marked line keeps its spans, in the plain text color (readable on the mark)
    const hl = await page.$eval(`#nb-cells > li:nth-child(${i + 1})`, e => {
      const o = e.querySelector('.nb-hl'), m = o.querySelector('mark');
      return { mark: m.textContent, text: [...o.children].map(d => d.textContent).join('\n'), src: e.querySelector('.nb-src').value,
               spans: m.querySelectorAll('.syn-string, .syn-paren').length, fg: getComputedStyle(o).color,
               colors: [...new Set([...m.querySelectorAll('span')].map(s => getComputedStyle(s).color))] };
    });
    assert(hl.mark === hl.src && hl.text === hl.src && hl.spans >= 3 && hl.colors.join() === hl.fg,
           'the marked line ' + JSON.stringify(hl));
  });

  await check(P + 'notebook: code cells are colored, text cells are not', async () => {
    const i = await nbNew('(define (f x) ; c\n  (if x "s" #\\( 1))\n');
    // the overlay: a block per line (its text is r.text)
    const paint = i => page.$eval(`#nb-cells > li:nth-child(${i + 1})`, e => {
      const hl = e.querySelector('.nb-hl'), src = e.querySelector('.nb-src'), cs = getComputedStyle(src);
      const a = hl.getBoundingClientRect(), b = src.getBoundingClientRect();
      return { syn: e.querySelector('.nb-editor').classList.contains('syn'), src: src.value,
               text: hl.firstElementChild ? [...hl.children].map(d => d.textContent).join('\n') : hl.textContent,
               kinds: [...hl.querySelectorAll('span')].map(s => s.className + ':' + s.textContent),
               color: cs.color, caret: cs.caretColor, hlColor: getComputedStyle(hl).color, inert: hl.inert,
               box: [a.left - b.left, a.top - b.top, a.width - b.width, a.height - b.height].map(x => Math.abs(x) < 1) };
    });
    const clear = /rgba\(0, 0, 0, 0\)|transparent/;
    let r = await paint(i);
    assert(r.syn && r.text === r.src, 'overlay mirrors the source ' + JSON.stringify(r));
    for (const k of ['syn-special:define', 'syn-special:if', 'syn-comment:; c', 'syn-string:"s"', 'syn-char:#\\(', 'syn-number:1'])
      assert(r.kinds.includes(k), k + ' in ' + r.kinds.join(' '));
    assert(clear.test(r.color) && !clear.test(r.caret) && !clear.test(r.hlColor),
           'the editor shows the caret, the overlay the text ' + JSON.stringify(r));
    assert(r.box.every(x => x), 'overlay and editor in the same box ' + JSON.stringify(r.box));
    // find in page sees the text once (the overlay is inert)
    const found = await page.evaluate(() => {
      const hits = [];
      getSelection().removeAllRanges();
      for (let k = 0; k < 3 && window.find('#\\( 1', false, false, true); k++)
        hits.push(!!(getSelection().anchorNode && getSelection().anchorNode.parentElement &&
                     getSelection().anchorNode.parentElement.closest('.nb-hl')));
      return { hits, inert: document.querySelector('.nb-hl').inert };
    });
    assert(found.inert && !found.hits.includes(true), 'find skips the overlay ' + JSON.stringify(found));
    // an IME composes in the editor's own (visible) text
    const ime = async type => {
      await nbSrc(i).dispatchEvent(type);
      return nbSrc(i).evaluate(e => [getComputedStyle(e).color, getComputedStyle(e.parentNode.querySelector('.nb-hl')).visibility]);
    };
    const [during, after] = [await ime('compositionstart'), await ime('compositionend')];
    assert(!clear.test(during[0]) && during[1] === 'hidden' && clear.test(after[0]) && after[1] === 'visible',
           'composition ' + JSON.stringify([during, after]));
    // typing repaints, an unterminated string included
    await nbSrc(i).press('Control+End');
    await nbSrc(i).pressSequentially(' "open');
    r = await paint(i);
    assert(r.text === r.src && r.kinds[r.kinds.length - 1] === 'syn-string:"open', 'repainted on input ' + JSON.stringify(r.kinds));
    // only what changed is repainted: a quote typed and taken back
    await nbSrc(i).press('Control+Home');
    await nbSrc(i).press('ArrowRight');
    await nbSrc(i).press('"');
    const q = await paint(i);
    assert(q.text === q.src && q.kinds[1] === 'syn-string:"define (f x) ; c' && q.kinds[2] === 'syn-string:  (if x "',
           'a quote typed ' + JSON.stringify(q.kinds));
    await nbSrc(i).press('Backspace');
    const back = await paint(i);
    assert(back.text === r.src && JSON.stringify(back.kinds) === JSON.stringify(r.kinds), 'and taken back ' + JSON.stringify(back.kinds));
    // a text cell is plain; back to code it is colored again
    await nbSrc(i).press('Escape');
    await page.keyboard.press('m');
    r = await paint(i);
    assert(!r.syn && !r.kinds.length && !r.text, 'a text cell is not colored ' + JSON.stringify(r));
    await page.keyboard.press('y');
    r = await paint(i);
    assert(r.syn && r.text === r.src && r.kinds.length, 'code again ' + JSON.stringify(r));
    // a new text cell
    await page.click('#nb-end-text');
    const t = (await nbCells()) - 1;
    await nbSrc(t).fill('(define x 1) "s"');
    r = await paint(t);
    assert(!r.syn && !r.kinds.length && !/rgba\(0, 0, 0, 0\)|transparent/.test(r.color), 'a new text cell ' + JSON.stringify(r));
    await nbSrc(t).press('Shift+Enter');
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

  await check(P + 'notebook: a flood of shows is capped while the cell runs; ids still update', async () => {
    const i = await nbEval('(import notebook) (show "p0" \'p) (do ((i 0 (+ i 1))) ((= i 3000)) (show i)) ' +
                           '(show "p1" \'p) \'done', 120000);
    const r = await page.$eval(`#nb-cells > li:nth-child(${i + 1})`, e => ({
      outs: e.querySelector('.nb-out').children.length,
      rich: [...e.querySelectorAll('.nb-rich')].map(d => d.textContent),
      note: [...e.querySelectorAll('.nb-note')].map(n => n.textContent).join(' '),
    }));
    assert(r.outs === 1002, r.outs + ' outputs');      // 500, the note, 500, the value
    assert(r.rich.length === 1000 && r.rich[0] === 'p1' && r.rich[1] === '0' && r.rich[999] === '2999',
           'displays ' + JSON.stringify([r.rich.length, r.rich.slice(0, 2), r.rich.slice(-1)]));
    assert(/^… 2,001 outputs omitted …$/.test(r.note), 'note ' + r.note);
    assert((await nbValues(i)).join() === 'done', 'value');
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
        // images through CSS functions other than url(), and escapes
        '<svg><rect width="5" height="5" mask="image-set(\'http://example.invalid/m.png\' 1x)"/>' +
          '<rect width="5" height="5" mask="-webkit-image-set(\'http://example.invalid/w.png\' 1x)"/>' +
          '<rect width="5" height="5" fill="\\75 rl(http://example.invalid/f.png)"/></svg>',
        '<div style="background:image(\'http://example.invalid/i.png\')">i</div>',
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
          // (markdown links the URLs in the text: links load nothing)
          if (e.closest('.nb-rich, .nb-md')) for (const a of e.attributes)
            if (/example\.invalid|image-set|\\/i.test(a.value) && !(e.localName === 'a' && a.name === 'href'))
              bad.push(e.localName + '[' + a.name + ']=' + a.value);
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
    // time linear in the source (a reload renders every saved cell):
    // about 500 KB of input each
    const slow = await page.evaluate(() => {
      const L = window.ChickenNotebookLib;
      const inputs = {
        'backtick runs, longest first': Array.from({ length: 1000 }, (_, i) => '`'.repeat(1000 - i)).join('a'),
        'backtick runs, shortest first': Array.from({ length: 1000 }, (_, i) => '`'.repeat(i + 1)).join('a'),
        'unclosed backticks and brackets': '`[a'.repeat(170000),
        'unclosed emphasis': '*a _b ~~c '.repeat(50000),
        'nested brackets': '['.repeat(250000) + ']'.repeat(250000),
      };
      const r = [];
      for (const [k, s] of Object.entries(inputs)) {
        const t = performance.now();
        L.renderMarkdown(s, document, 'perf-');
        const ms = performance.now() - t;
        if (ms > 1000) r.push(k + ': ' + Math.round(ms) + ' ms');
      }
      // short table rows: one cell for the missing ones, not N each
      const N = 3000, t = performance.now();
      const table = L.renderMarkdown('|a'.repeat(N) + '\n' + '|-'.repeat(N) + '\n' + '|\n'.repeat(N),
                                     document, 'perf-');
      const tableMs = performance.now() - t, tds = table.querySelectorAll('td');
      if (tableMs > 1000) r.push('short table rows: ' + Math.round(tableMs) + ' ms');
      const ragged = [...L.renderMarkdown('|a|b|c|\n|-|-|-|\n|1|\n|1|2|3|4|', document, 'perf-')
        .querySelectorAll('tbody tr')].map(tr => [...tr.children].map(td => td.textContent + '/' + td.colSpan).join(' '));
      // a closer must be as long as the opener
      const code = [...L.renderMarkdown('`a``b` and ``c`d``', document, 'perf-').querySelectorAll('code')]
        .map(e => e.textContent);
      return { r, code, tds: tds.length, ragged };
    });
    assert(!slow.r.length, 'slow markdown: ' + slow.r.join('; '));
    assert(slow.tds === 6000, 'short table rows: ' + slow.tds + ' cells');
    assert(JSON.stringify(slow.ragged) === JSON.stringify(['1/1 /2', '1/1 2/1 3/1']), 'ragged rows ' + JSON.stringify(slow.ragged));
    assert(JSON.stringify(slow.code) === JSON.stringify(['a``b', 'c`d']), 'code spans ' + JSON.stringify(slow.code));
  });

  await check(P + 'notebook: the Scheme highlighter', async () => {
    const r = await page.evaluate(() => {
      const L = window.ChickenNotebookLib, bad = [];
      const kinds = s => L.highlight(s).filter(p => p[0]).map(p => p[0] + ':' + p[1]);
      const expect = (s, want) => {
        const got = kinds(s);
        if (JSON.stringify(got) !== JSON.stringify(want)) bad.push(JSON.stringify(s) + ' gave ' + JSON.stringify(got));
      };
      expect('(define (f x) (if x 1 2))',
             ['paren:(', 'special:define', 'paren:(', 'paren:)', 'paren:(', 'special:if', 'number:1', 'number:2', 'paren:))']);
      expect('(list define if) [let ()]', ['paren:(', 'paren:)', 'paren:[', 'special:let', 'paren:()]']);
      expect("'(if a) `(b ,(when c) ,@d) #(do)",
             ['quote:\'', 'paren:(', 'paren:)', 'quote:`', 'paren:(', 'quote:,', 'paren:(', 'special:when', 'paren:)',
              'quote:,@d', 'paren:)', 'paren:#(', 'paren:)']);
      expect("'sym 'a.b 'x: '1", ['quote:\'sym', 'quote:\'a.b', 'quote:\'', 'keyword:x:', 'quote:\'', 'number:1']);
      expect('; line\n#| a #| nested |# b |# x', ['comment:; line', 'comment:#| a #| nested |# b |#']);
      expect('#;(a (b)) c #; #; d e f (g #;) h #;\'(i) j',
             ['comment:#;(a (b))', 'comment:#; #; d e', 'paren:(', 'comment:#;', 'paren:)', 'comment:#;\'(i)']);
      expect('"a\\"b\nc" #\\a #\\space #\\x41 #\\( #\\) #\\; #\\" #\\|',
             ['string:"a\\"b\nc"', 'char:#\\a', 'char:#\\space', 'char:#\\x41', 'char:#\\(', 'char:#\\)', 'char:#\\;',
              'char:#\\"', 'char:#\\|']);
      expect('1 -2 3.5 .5 1. 1/2 1e10 -1.5e-3 #x1F #b101 #o17 #e1.5 #i1/3 #x#e10 +inf.0 -nan.0 1+2i +i 1@2',
             ['1', '-2', '3.5', '.5', '1.', '1/2', '1e10', '-1.5e-3', '#x1F', '#b101', '#o17', '#e1.5', '#i1/3', '#x#e10',
              '+inf.0', '-nan.0', '1+2i', '+i', '1@2'].map(x => 'number:' + x));
      expect('- ... + 1+ a1 #b2 #o8 #xg inf.0 1/ 1e', []);
      expect('#t #f #true #false #!eof #!optional #!rest #!key #!default #:k k: : |a b| |x:|',
             ['#t', '#f', '#true', '#false', '#!eof', '#!optional', '#!rest', '#!key', '#!default'].map(x => 'constant:' + x)
               .concat(['keyword:#:k', 'keyword:k:']));
      expect('#u8(1) #U8() #\'f', ['paren:#u8(', 'number:1', 'paren:)', 'paren:#U8()', 'quote:#\'f']);
      // as CHICKEN reads them: {} are parens; ' , end a token, ` does not
      expect("{if x} (a{b}) (1,2) '(a'b) a`b", ['paren:{', 'special:if', 'paren:}', 'paren:(', 'paren:{', 'paren:})', 'paren:(',
                                                'number:1', 'quote:,', 'number:2', 'paren:)', 'quote:\'', 'paren:(', 'quote:\'b',
                                                'paren:)']);
      // #|, #; and "#! " are comments at the start of a token only
      expect('a#|b|# 1#;2\n(c#! d)', ['comment:;2', 'paren:(', 'paren:)']);
      expect('#!/usr/bin/env csi -s (\n#! x (\n(x #!eof)', ['comment:#!/usr/bin/env csi -s (', 'comment:#! x (', 'paren:(',
                                                           'constant:#!eof', 'paren:)']);
      // a #; datum leaves the head of the form and a quote as they were
      expect("(#;x define y) '#;a b '#;(x) (if y)", ['paren:(', 'comment:#;x', 'special:define', 'paren:)', 'quote:\'',
                                                   'comment:#;a', 'quote:b', 'quote:\'', 'comment:#;(x)', 'paren:(',
                                                   'paren:)']);
      expect('(and-let* ()) (cut f <>) (time x) (: f (-> fixnum))', ['paren:(', 'special:and-let*', 'paren:())', 'paren:(',
             'special:cut', 'paren:)', 'paren:(', 'special:time', 'paren:)', 'paren:(', 'special::', 'paren:(', 'paren:))']);
      // unterminated: to the end
      expect('(a "open', ['paren:(', 'string:"open']);
      expect('x #| open #| more |# still', ['comment:#| open #| more |# still']);
      expect('|bar ( "', []);
      expect('#\\', ['char:#\\']);
      // the texts add up to the source; the parens are scan()'s (but for
      // those of a #; datum, which are comment)
      const tricky = ['', '#', "'", ',@', '#\\', '#;', '#|', '|#', '"\\', '|\\', '#u8', '#\\😀x', 'a#|b|#c', 'a|b c|d (e)',
                      '#\\a#\\(b', 'x#;(y)', '((#;#;))', ')))', '\r\n\t\u00a0 x', '#\\(#| ( |#', '|a|#| ( |#', '#! (', 'a#! (',
                      '"s"#! (', '{[(}])'];
      let seed = 7;
      const rnd = n => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) % n;
      const A = ['(', ')', '[', ']', '{', '}', '"', '|', ';', '#', '\\', '\n', ' ', 'a', '1', "'", ',', '`', '@', 'u8', 'x', ':',
                 '#|', '|#', '#;', '#\\', '#!', '/', '😀', 'if'];
      for (let k = 0; k < 20000; k++) { let s = ''; for (let m = rnd(24); m > 0; m--) s += A[rnd(A.length)]; tricky.push(s); }
      for (const s of tricky) {
        const p = L.highlight(s);
        if (p.map(x => x[1]).join('') !== s) { bad.push('texts of ' + JSON.stringify(s)); continue; }
        if (p.some((x, k) => !x[1] || (k && x[0] === p[k - 1][0]))) bad.push('pieces of ' + JSON.stringify(s));
        if (s.includes('#;')) continue;
        const want = [], got = [];
        L.scan(s, (kind, i) => { if (kind === 'open' || kind === 'close') want.push(i); });
        let at = 0;
        for (const [k, t] of p) {
          if (k === 'paren') for (let j = 0; j < t.length; j++) if ('()[]{}'.includes(t[j])) got.push(at + j);
          at += t.length;
        }
        if (want.join() !== got.join()) bad.push('parens of ' + JSON.stringify(s) + ': ' + want + ' / ' + got);
        if (bad.length > 10) break;
      }
      // linear time
      const slow = [];
      for (const [k, s] of Object.entries({
        code: '(define (f n) (if (= n 0) 1 (* n (f (- n 1))))) ; c\n"s" #\\a \'x #t\n'.repeat(10000),
        'block comments': '#|'.repeat(250000), quotes: '"'.repeat(500000), bars: '|'.repeat(500000),
        'datum comments': '#;'.repeat(250000), parens: '('.repeat(250000) + ')'.repeat(250000), chars: '#\\'.repeat(250000),
        prefixes: "',@`".repeat(125000), atoms: 'a'.repeat(500000),
      })) {
        const t = performance.now();
        L.highlight(s);
        const ms = performance.now() - t;
        if (ms > 1000) slow.push(k + ': ' + Math.round(ms) + ' ms');
      }
      // as DOM, and line by line
      const d = L.highlightDom('(a "b\nc")\n(d)', document);
      const dom = { text: d.textContent, kids: [...d.childNodes].map(e => e.className || '#text') };
      const lines = JSON.stringify(L.highlightLines(L.highlight('(a "b\nc")\n\n')));
      // fenced code: Scheme (or no language) is colored, now or (lazy) by colorCode
      const src = '```\n(if a)\n```\n\n```scheme\n"s"\n```\n\n```python\nif a: "s"\n```';
      const codes = md => [...md.querySelectorAll('pre code')].map(c => c.querySelectorAll('span').length + ':' + c.textContent);
      const pres = codes(L.renderMarkdown(src, document, 't-'));
      const lazy = L.renderMarkdown(src, document, 't-', null, true), div = document.createElement('div');
      div.appendChild(lazy);
      const before = codes(div);
      L.colorCode(div, document);
      const after = codes(div);
      // at most 32 KB of code is colored per call
      const big = '```\n' + '(a)\n'.repeat(5000) + '```\n\n```\n' + '(b)\n'.repeat(5000) + '```';
      const capped = [...L.renderMarkdown(big, document, 't-').querySelectorAll('pre code')].map(c => c.childElementCount > 0);
      // what CHICKEN's reader takes for a whole, or not
      const bal = ['#;(a\n b) (c)', '(a#;(b\n)', '(f x#;c (\n)', '#! /usr/bin/csi -s (\n(x)', '{a [b]}', '(a {b) }', '(a]',
                   '(a#|b c|#)'].map(s => s + ' ' + L.balance(s).ok);
      return { bad, slow, dom, lines, pres, before, after, capped, bal };
    });
    assert(!r.bad.length, r.bad.join('\n'));
    assert(!r.slow.length, 'slow: ' + r.slow.join('; '));
    assert(r.dom.text === '(a "b\nc")\n(d)' &&
           r.dom.kids.join() === 'syn-paren,#text,syn-string,syn-paren,#text,syn-paren,#text,syn-paren', 'highlightDom ' + JSON.stringify(r.dom));
    assert(r.lines === '[[["paren","("],["","a "],["string","\\"b"]],[["string","c\\""],["paren",")"]],[],[]]', 'lines ' + r.lines);
    const fenced = ['3:(if a)', '1:"s"', '0:if a: "s"'];
    assert(JSON.stringify(r.pres) === JSON.stringify(fenced) && JSON.stringify(r.after) === JSON.stringify(fenced) &&
           JSON.stringify(r.before) === JSON.stringify(['0:(if a)', '0:"s"', '0:if a: "s"']),
           'fenced code ' + JSON.stringify([r.pres, r.before, r.after]));
    assert(JSON.stringify(r.capped) === '[true,false]', 'fenced code budget ' + JSON.stringify(r.capped));
    assert(r.bal.join() === ['#;(a\n b) (c) true', '(a#;(b\n) true', '(f x#;c (\n) true', '#! /usr/bin/csi -s (\n(x) true',
                             '{a [b]} true', '(a {b) } false', '(a] false', '(a#|b c|#) true'].join(), 'balance ' + r.bal.join(' / '));
  });

  // ten uses of a group of ten uses of ...: 10^5 elements from 1.2 KB
  await check(P + 'notebook: nested <use> in markup is bounded', async () => {
    const r = await page.evaluate(async () => {
      const L = window.ChickenNotebookLib;
      const bomb = lv => {
        let s = '<defs><g id="l0"><rect width="1" height="1"/></g>';
        for (let k = 1; k <= lv; k++) s += `<g id="l${k}">` + `<use href="#l${k - 1}"/>`.repeat(10) + '</g>';
        return s + `</defs><use href="#l${lv}"/>`;
      };
      const sprite = '<defs><symbol id="s"><rect width="2" height="2"/><circle r="1"/></symbol>' +
        '<g id="t"><use href="#s"/><use href="#s" x="3"/></g></defs>' +
        Array.from({ length: 100 }, (_, i) => `<use href="#t" y="${i * 3}"/>`).join('') +
        '<g id="c"><use href="#c"/></g>';
      const doc = s => '<svg xmlns="http://www.w3.org/2000/svg">' + s + '</svg>';
      const out = {};
      const cases = {
        svg: [doc(bomb(5)), 'svg'], html: ['<p>a</p><svg>' + bomb(5) + '</svg>', 'html'], sprite: [doc(sprite), 'svg'],
      };
      for (const [k, [src, kind]] of Object.entries(cases)) {
        const box = document.createElement('div');
        box.className = 'nb-rich';
        document.body.appendChild(box);
        const t = performance.now();
        box.appendChild(L.sanitizeMarkup(src, kind, 'use-' + k + '-'));
        box.getBoundingClientRect();
        await new Promise(res => requestAnimationFrame(() => requestAnimationFrame(res)));
        // the elements rendered, each use counting what it copies
        const inst = (el, d) => {
          if (d > 32) return Infinity;
          let n = 1;
          const t = el.localName === 'use' && document.getElementById((el.getAttribute('href') || '').slice(1));
          if (t) n += inst(t, d + 1);
          for (const c of el.children) n += inst(c, d);
          return n;
        };
        out[k] = { ms: Math.round(performance.now() - t), uses: box.querySelectorAll('use').length,
                   top: box.querySelectorAll('svg > use').length, rendered: inst(box, 0) };
        box.remove();
      }
      return out;
    });
    // (the budget is 2000 here; the uses in <defs> are counted too)
    for (const k of ['svg', 'html']) {
      assert(r[k].ms < 1000, k + ' bomb rendered in ' + r[k].ms + ' ms');
      assert(r[k].rendered < 5000, k + ' bomb kept ' + JSON.stringify(r[k]));
    }
    // a sprite well under the budget is kept whole; a cycle is dropped
    assert(r.sprite.uses === 102 && r.sprite.top === 100, 'sprite ' + JSON.stringify(r.sprite));
  });

  // twenty 800x800 rects sharing five blurs and dilations: minutes a paint
  await check(P + 'notebook: filters in markup are bounded', async () => {
    const r = await page.evaluate(() => {
      const L = window.ChickenNotebookLib;
      const doc = s => '<svg xmlns="http://www.w3.org/2000/svg" width="800" height="800">' + s + '</svg>';
      const heavy = '<filter id="f">' +
        '<feGaussianBlur stdDeviation="30"/><feMorphology operator="dilate" radius="40"/>'.repeat(5) + '</filter>';
      const shadow = '<filter id="s"><feGaussianBlur in="SourceAlpha" stdDeviation="3"/><feOffset dx="2" dy="2"/>' +
        '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>';
      const rects = (n, f) => `<rect width="800" height="800" filter="url(#${f})"/>`.repeat(n);
      const cases = {
        heavy: [doc(heavy + rects(20, 'f')), 'svg'],
        shadows: [doc(shadow + rects(20, 's')), 'svg'],
        uses: [doc(shadow + '<defs><g id="g"><rect width="9" height="9" filter="url(#s)"/></g></defs>' +
                   '<use href="#g"/>'.repeat(20)), 'svg'],
        mask: [doc(shadow + '<mask id="m"><rect width="9" height="9" fill="white" filter="url(#s)"/></mask>' +
                   '<rect width="9" height="9" mask="url(#m)"/>'), 'svg'],
        css: ['<div style="width:800px;height:800px;filter:' + 'blur(30px) '.repeat(40) + '">x</div>' +
              '<p style="color:red;text-shadow:' + Array(40).fill('0 0 9px red').join(',') + '">t</p>' +
              '<svg width="800" height="800"><rect width="800" height="800" filter="' + 'blur(9px) '.repeat(40) + '"/></svg>' +
              '<p style="filter:blur(1px)">kept</p>', 'html'],
      };
      const out = {};
      for (const [k, [src, kind]] of Object.entries(cases)) {
        const box = document.createElement('div');
        box.appendChild(L.sanitizeMarkup(src, kind, 'flt-' + k + '-'));
        out[k] = { filtered: box.querySelectorAll('[filter]').length,
                   styles: [...box.querySelectorAll('[style]')].map(e => e.getAttribute('style')) };
      }
      return out;
    });
    const J = x => JSON.stringify(x);
    assert(r.heavy.filtered === 0, 'heavy ' + J(r.heavy));
    // a drop shadow weighs 7: nine of them fit
    assert(r.shadows.filtered === 9, 'shadows ' + J(r.shadows));
    assert(r.uses.filtered === 0, 'one filtered element, copied 20 times ' + J(r.uses));
    assert(r.mask.filtered === 0, 'in a mask ' + J(r.mask));
    assert(r.css.filtered === 0 && J(r.css.styles) === J(['width:800px; height:800px', 'color:red', 'filter:blur(1px)']),
           'css ' + J(r.css));
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

  // the client last heard "sleeping": the slice that woke up is in the
  // primitive, and reports nothing
  await check(P + 'notebook: Stop after a sleep, in a non-yielding primitive, restarts the kernel', async () => {
    const i = await nbNew('(sleep 1) (define big (expt 7 60000000))');
    await nbRun(i);
    await waitNbStatus(/^sleeping$/);
    await page.waitForTimeout(1500);
    const t = Date.now();
    await page.click('#nb-stop');
    await nbWait(i, /^error$/, 20000);
    const ms = Date.now() - t;
    assert(ms >= 2900, 'not before the 3 s watchdog: ' + ms);
    assert(/did not respond/.test(await nbOut(i)), 'note: ' + await nbOut(i));
    const j = await nbEval('(+ 5 6)', 60000);
    assert((await nbValues(j)).join() === '11', '(+ 5 6)');
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

  // Export .json keeps every output only while Import can read the file
  // back (5 MB)
  await check(P + 'notebook: an export with more than 5 MB of outputs imports again', async () => {
    const i = await nbEval('(import notebook) (do ((i 0 (+ i 1))) ((= i 6)) (show (text (make-string 1000000 #\\x))))', 60000);
    assert(await nbStatus(i) === 'ok', 'status ' + await nbStatus(i));
    const n = await nbCells();
    const [dl] = await Promise.all([page.waitForEvent('download'), menu('Export .json')]);
    const file = await dl.path();
    const size = fs.statSync(file).size;
    assert(size > 900000 && size <= 5 * 1024 * 1024, 'exported ' + size + ' bytes');
    await page.waitForFunction(() => /left out/.test(document.getElementById('nb-toast').textContent), null, { timeout: 5000 });
    await accepting(() => page.setInputFiles('#nb-file', { name: 'big.json', mimeType: 'application/json', buffer: fs.readFileSync(file) }));
    await page.waitForFunction(n => document.querySelectorAll('#nb-cells > li').length === n, n);
    assert(await page.isHidden('#nb-notice') || !/Could not import/.test(await page.textContent('#nb-notice-text')),
           'notice: ' + await page.textContent('#nb-notice-text'));
    const out = await nbOut(i);
    assert(/more output was not saved/.test(out) && out.length > 900000, 'outputs after the import: ' + out.length);
    await nbCell(i).locator('[data-act="del"]').click();
  });

  // A cell may have more outputs than Import keeps (1000): its own save
  // brings back all of them, an export keeps the last one (the error).
  await check(P + 'notebook: more than 1000 outputs survive a reload; an export keeps the error', async () => {
    const i = await nbEval('(do ((i 0 (+ i 1))) ((= i 600)) (display i) (flush-output) ' +
                           '(display i (current-error-port)) (flush-output (current-error-port))) (car 1)', 60000);
    const outs = () => page.$eval(`#nb-cells > li:nth-child(${i + 1}) .nb-out`,
                                  o => [o.children.length, o.lastElementChild.textContent]);
    const before = await outs();
    assert(before[0] > 1000 && /bad argument type/.test(before[1]), 'before: ' + before);
    await page.keyboard.press('Control+s');
    await page.reload();
    await page.click('#tab-notebook');
    const after = await outs();
    assert(after[0] === before[0] && after[1] === before[1], 'after the reload: ' + after);
    await waitNbStatus(/^ready$/, 60000);
    await waitStatus('ready', 60000);
    const [dl] = await Promise.all([page.waitForEvent('download'), menu('Export .json')]);
    const o = JSON.parse(fs.readFileSync(await dl.path(), 'utf8')).cells[i].outputs;
    assert(o.length === 1000 && o[999].k === 'error' && /outputs were left out/.test(o[998].text),
           'exported: ' + o.length + ' ' + JSON.stringify(o.slice(-2)).slice(0, 300));
    await page.waitForFunction(() => /at most 1000 per cell/.test(document.getElementById('nb-toast').textContent),
                               null, { timeout: 5000 });
    await nbCell(i).locator('[data-act="del"]').click();
  });

  // The other tab saved, this one autosaved over it before the choice
  // was made: Load theirs still loads theirs.
  await check(P + 'notebook: Load theirs loads what the other tab saved', async () => {
    await page.keyboard.press('Control+s');
    const setLast = (p, v) => p.evaluate(v => {
      const t = [...document.querySelectorAll('#nb-cells > li[data-type="code"] .nb-src')].pop();
      t.value = v;
      t.dispatchEvent(new Event('input'));
    }, v);
    const saved = (p, re) => p.waitForFunction(([s, f]) => new RegExp(s, f).test(localStorage.getItem('chicken-repl.notebook')),
                                               [re.source, re.flags], { timeout: 5000 });
    const f = await context.newPage();
    await f.goto(base + 'index.html');
    await f.click('#tab-notebook');
    await setLast(f, '(theirs)');
    await saved(f, /\(theirs\)/);
    await f.close();
    await page.waitForFunction(() => !document.getElementById('nb-notice').hidden &&
                               /changed in another tab/.test(document.getElementById('nb-notice-text').textContent),
                               null, { timeout: 5000 });
    await setLast(page, '(mine)');
    await saved(page, /\(mine\)/);
    await page.click('#nb-notice-action');
    const last = await page.$$eval('#nb-cells > li[data-type="code"] .nb-src', l => l.map(t => t.value).pop());
    assert(last === '(theirs)', 'loaded: ' + last);
    await saved(page, /\(theirs\)/);
    await waitNbStatus(/^ready$/, 60000);
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
    // a cell larger than 1 MB, which autosave keeps, is restored too
    const b = await nbNew(';' + 'x'.repeat(1100000));
    await nbNew('(define after-big 2)');
    await page.keyboard.press('Control+s');
    const n = await nbCells();
    await page.reload();
    await page.click('#tab-notebook');
    const big = await page.$$eval('#nb-cells > li .nb-src', l => l.map(e => e.value.length));
    assert(big.length === n && big[b] === 1100001, 'cells after the reload: ' + big.length + ' of ' + n + ', big ' + big[b]);
    assert(!/skipped/.test(await page.textContent('#nb-notice-text')), 'notice: ' + await page.textContent('#nb-notice-text'));
    await nbCell(b).locator('[data-act="del"]').click();
    await page.keyboard.press('Control+s');
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

  // Import reads at most 5000 cells, from a .json or a .scm file; Export
  // says when a notebook has more
  await check(P + 'notebook: more than 5000 cells', async () => {
    const forms = n => Array.from({ length: n }, (_, i) => '(+ ' + i + ' 1)').join('\n\n');
    await accepting(() => page.setInputFiles('#nb-file', { name: 'many.scm', mimeType: 'text/plain', buffer: Buffer.from(forms(5001)) }));
    assert(/Could not import many\.scm: more than 5000 cells/.test(await page.textContent('#nb-notice-text')),
           'notice: ' + await page.textContent('#nb-notice-text'));
    await accepting(() => page.setInputFiles('#nb-file', { name: 'most.scm', mimeType: 'text/plain', buffer: Buffer.from(forms(5000)) }));
    await page.waitForFunction(() => document.querySelectorAll('#nb-cells > li').length === 5000, null, { timeout: 20000 });
    // only the cells near the view are colored
    await page.waitForFunction(() => document.querySelector('#nb-cells > li .nb-editor.syn'), null, { timeout: 5000 });
    const painted = await page.$$eval('#nb-cells .nb-editor.syn', l => l.length);
    assert(painted > 0 && painted < 500, painted + ' cells painted');
    await nbNew('(+ 1 1)');
    await page.waitForFunction(() => document.querySelector('#nb-cells > li:nth-child(5001) .nb-editor.syn'), null, { timeout: 5000 });
    for (const fmt of ['.json', '.scm']) {
      if (await page.isVisible('#nb-notice')) await page.click('#nb-notice-close');
      await page.waitForFunction(() => document.getElementById('nb-notice').hidden, null, { timeout: 5000 });
      const [dl] = await Promise.all([page.waitForEvent('download'), menu('Export ' + fmt)]);
      assert(/more than 5000 cells: Import cannot read the file back/.test(await page.textContent('#nb-notice-text')) &&
             await page.isVisible('#nb-notice'), fmt + ' export notice: ' + await page.textContent('#nb-notice-text'));
      // and Import does refuse it
      const back = fs.readFileSync(await dl.path());
      await accepting(() => page.setInputFiles('#nb-file', { name: 'back' + fmt, mimeType: 'text/plain', buffer: back }));
      assert(new RegExp('Could not import back\\' + fmt + ': more than 5000 cells').test(await page.textContent('#nb-notice-text')),
             fmt + ' import back: ' + await page.textContent('#nb-notice-text'));
    }
    await accepting(() => page.setInputFiles('#nb-file', { name: 'small.scm', mimeType: 'text/plain', buffer: Buffer.from('(+ 1 2)') }));
    await page.waitForFunction(() => document.querySelectorAll('#nb-cells > li').length === 1, null, { timeout: 20000 });
  });

  // a lone \r is a line break in the editor, so it is one in the overlay;
  // the code blocks of text cells are colored when they come into view
  await check(P + 'notebook: imported sources are colored as the editor shows them', async () => {
    const cells = [{ type: 'code', source: '(a)\r(b) ; x\r\n(c)' }, { type: 'markdown', source: '```\n(if a "s")\n```' }]
      .concat(Array.from({ length: 300 }, (_, k) => ({ type: 'code', source: '(+ ' + k + ' 1)' })),
              [{ type: 'markdown', source: '```scheme\n(when b)\n```' }]);
    const buf = Buffer.from(JSON.stringify({ format: 'chicken-notebook', version: 1, meta: { title: 'cr' }, cells }));
    await accepting(() => page.setInputFiles('#nb-file', { name: 'cr.json', mimeType: 'application/json', buffer: buf }));
    await page.waitForFunction(() => document.querySelectorAll('#nb-cells > li').length === 303, null, { timeout: 20000 });
    await page.waitForFunction(() => document.querySelector('#nb-cells > li:nth-child(2) .nb-md .syn-special'), null, { timeout: 5000 });
    const r = await page.evaluate(() => {
      const li = document.querySelectorAll('#nb-cells > li'), hl = li[0].querySelector('.nb-hl');
      return { src: li[0].querySelector('.nb-src').value, lines: [...hl.children].map(d => d.textContent),
               comments: [...hl.querySelectorAll('.syn-comment')].map(e => e.textContent),
               far: li[302].querySelectorAll('.nb-md span').length };
    });
    assert(r.src === '(a)\n(b) ; x\n(c)' && r.lines.join('|') === '(a)|(b) ; x|(c)' && r.comments.join() === '; x',
           'line breaks ' + JSON.stringify(r));
    assert(r.far === 0, 'a text cell out of sight is not colored yet: ' + r.far);
    await page.locator('#nb-cells > li').nth(302).scrollIntoViewIfNeeded();
    await page.waitForFunction(() => document.querySelector('#nb-cells > li:nth-child(303) .nb-md .syn-special'), null, { timeout: 5000 });
    await accepting(() => page.setInputFiles('#nb-file', { name: 'small.scm', mimeType: 'text/plain', buffer: Buffer.from('(+ 1 2)') }));
    await page.waitForFunction(() => document.querySelectorAll('#nb-cells > li').length === 1, null, { timeout: 20000 });
  });

  // Export .html: a static page of what the notebook shows, which loads
  // nothing and runs nothing
  await check(P + 'notebook: Export .html is a static page of the notebook', async () => {
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    const cells = [
      { type: 'markdown', source: '# Export </title><script>x</script> test\n\n- one\n- two\n\n[to the end](#the-end)\n\n```scheme\n(define x "s") ; c\n```' },
      { type: 'code', source: '(display "out")', count: 1, outputs: [{ k: 'stream', name: 'stdout', text: 'out\n' },
                                                                       { k: 'stream', name: 'stderr', text: 'err\n' }] },
      { type: 'code', source: '(iota 40)', count: 2,
        outputs: [{ k: 'value', text: Array.from({ length: 40 }, (_, k) => 'line ' + k).join('\n') }] },
      { type: 'code', source: '(car \'())', count: 3, status: 'error', outputs: [{ k: 'error', error: { text: 'Error: (car) bad argument type: ()',
        chain: [{ where: '<syntax>', form: '(car (quote ()))' }, { where: 'In[3]:1', form: '(car (quote ()))' }] } }] },
      { type: 'code', source: '(show-all)', count: 4, outputs: [
        { k: 'display', mime: 'image/svg+xml', data: '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" style="fill: var(--accent)"/></svg>' },
        { k: 'display', mime: 'text/html', data: '<p class="x" onclick="alert(1)">rich <b>html</b> <a href="https://call-cc.org/">link</a> ' +
                                                 '<img src="https://example.com/x.png" alt="ext"><img src="data:image/png;base64,' + png + '" alt="dot"></p>' },
        { k: 'display', mime: 'text/markdown', data: '### Shown\n\n- a\n- b' },
        { k: 'note', text: '… 10 characters omitted …' }] },
      { type: 'code', source: '(print "hidden")', count: 5, outputs: [{ k: 'stream', name: 'stdout', text: 'hidden text\n' }] },
      // text the parser would change: a newline right after <pre>, a CR
      { type: 'code', source: '(newline)', count: 6, outputs: [{ k: 'stream', name: 'stdout', text: '\nafter newline\n10%\r20%\r30%\n' },
                                                                 { k: 'display', mime: 'text/plain', data: '\nplain' }] },
      // markup that must not get out of its cell: an <li> with no list, an
      // HTML element in SVG (XML only), and (below) a tree that the parser
      // would build otherwise
      { type: 'code', source: '(html)', count: 7, outputs: [
        { k: 'display', mime: 'text/html', data: '<li>item</li>' },
        { k: 'display', mime: 'text/html', data: '<div><li style="position:fixed;top:0;left:0;width:100vw;height:100vh;z-index:99">ESCAPED</li></div>' },
        { k: 'display', mime: 'image/svg+xml', data: '<svg xmlns="http://www.w3.org/2000/svg" xmlns:h="http://www.w3.org/1999/xhtml" width="10" height="10">' +
                                                     '<rect width="10" height="10"/><h:li>svg li</h:li></svg>' },
        { k: 'display', mime: 'text/html', data: '<p>replaced</p>' }] },
    ].concat(Array.from({ length: 200 }, (_, k) => ({ type: 'code', source: '(+ ' + k + ' 1)' })),
             [{ type: 'code', source: '(define (far-away) (if #t "far" 0))' },
              { type: 'code', source: '(list ' + '"0123456789" '.repeat(3000) + ')' },
              { type: 'markdown', source: '## The end\n\n```\n(lambda () \'q)\n```' }]);
    const buf = Buffer.from(JSON.stringify({ format: 'chicken-notebook', version: 1, meta: { title: 'html export' }, cells }));
    await accepting(() => page.setInputFiles('#nb-file', { name: 'ex.json', mimeType: 'application/json', buffer: buf }));
    await page.waitForFunction(n => document.querySelectorAll('#nb-cells > li').length === n, cells.length, { timeout: 20000 });
    await nbCell(5).focus();
    await page.keyboard.press('o');                       // its output hidden
    await nbSrc(1).fill('(display "out!")');              // edited since it ran
    await nbCell(0).locator('.nb-md').dblclick();         // the text cell in edit mode
    const inApp = await page.evaluate(() => {
      const li = document.querySelectorAll('#nb-cells > li')[7], rich = li.querySelectorAll('.nb-rich');
      // ul > li > div > li: read back, the inner <li> closes the outer one
      const ul = rich[3].appendChild(document.createElement('ul')), o = ul.appendChild(document.createElement('li'));
      o.appendChild(document.createElement('div')).appendChild(document.createElement('li')).textContent = 'inner';
      const st = li.previousElementSibling.querySelector('.nb-stream');
      return [st.textContent, li.previousElementSibling.querySelector('.nb-rich pre').textContent, rich[2].textContent, st.getBoundingClientRect().height];
    });
    assert(inApp[0] === '\nafter newline\n10%\r20%\r30%\n' && inApp[1] === '\nplain' && inApp[2] === '', 'in the page ' + JSON.stringify(inApp));
    const far = cells.length - 3;
    assert(!await nbCell(far).locator('.nb-editor.syn').count(), 'the far cell is not painted in the page');
    const [dl] = await Promise.all([page.waitForEvent('download'), menu('Export .html')]);
    assert(/^html-export\.html$/.test(dl.suggestedFilename()), 'file name ' + dl.suggestedFilename());
    // saved as .html: file:// goes by the extension
    const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'nb-export-')), dl.suggestedFilename());
    await dl.saveAs(file);
    const text = fs.readFileSync(file, 'utf8');
    assert(/^<!doctype html>\n<html lang="en"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:;/.test(text),
           'head: ' + text.slice(0, 300));
    assert(!/<script|<link|<iframe|<object|@import|url\((?!#)/i.test(text), 'no script, link or external CSS');
    await page.waitForFunction(() => document.getElementById('nb-live').textContent === 'Exported html-export.html', null, { timeout: 5000 });

    // loaded from file://, as a page of its own
    const f = await context.newPage();
    const fErrors = [], requests = [];
    f.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') fErrors.push(m.type() + ': ' + m.text()); });
    f.on('pageerror', e => fErrors.push('pageerror: ' + e.message));
    f.on('request', r => { if (!/^(file|data):/.test(r.url())) requests.push(r.url()); });
    await f.goto('file://' + file);
    const r = await f.evaluate(() => {
      const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
      const li = $$('.nb-cells > .nb-cell'), col = e => e && getComputedStyle(e).color, box = e => e.getBoundingClientRect();
      const attrs = $$('*').flatMap(e => [...e.attributes].map(a => [e.localName, a.name, a.value]));
      const probe = document.body.appendChild(document.createElement('span'));
      probe.style.color = 'var(--accent)';
      const accent = getComputedStyle(probe).color;
      probe.style.color = 'var(--bad)';
      const bad = getComputedStyle(probe).color;
      probe.remove();
      const count = document.createRange();
      count.selectNodeContents(li[1].querySelector('.nb-count'));
      const svg = $('.nb-rich svg rect');
      return {
        title: document.title, head: $('.nbx-title').textContent, foot: $('.nbx-foot').textContent,
        csp: !!$('meta[http-equiv="Content-Security-Policy"]'),
        handlers: attrs.filter(([, n]) => /^on/i.test(n)).length,
        urls: attrs.filter(([t, n, v]) => (n === 'src' && !v.startsWith('data:image/')) || (n === 'href' && !(t === 'a' && /^(#|https?:|mailto:)/.test(v))) ||
                                          (n === 'style' && /url\((?!#)/.test(v))).map(a => a.join(' ')),
        chrome: $$('button, textarea, input, form, .nb-bal, .nb-tools, .nb-run, .nb-stdin').length,
        md: [$('.nb-md h1') && $('.nb-md h1').textContent, $$('.nb-md ul > li').length],
        fence: $$('.nb-md pre code .syn-special').map(e => e.textContent), lastFence: !!li.at(-1).querySelector('pre code .syn-special'),
        anchor: (() => { const a = $('.nb-md a[href^="#"]'); return a && document.getElementById(a.getAttribute('href').slice(1))?.textContent; })(),
        counts: li.filter(e => e.dataset.type === 'code').slice(0, 6).map(e => e.querySelector('.nb-count').textContent),
        edited: li[1].dataset.edited === 'true' && getComputedStyle(li[1].querySelector('.nb-count')).fontStyle === 'italic',
        stale: li[2].dataset.stale === 'true', src1: li[1].querySelector('.nb-code').textContent,
        streams: [...li[1].querySelectorAll('.nb-stream')].map(e => e.className + ':' + e.textContent),
        value: (() => { const v = li[2].querySelector('.nb-value'); return v && [v.classList.contains('clamped'), v.textContent.split('\n').length, v.scrollHeight <= v.clientHeight + 1]; })(),
        error: [$('.nb-error-msg .tag')?.textContent, $('.nb-error-msg')?.textContent, $$('.nb-trace .where').map(e => e.localName + ':' + e.textContent)],
        svg: svg && [getComputedStyle(svg).fill, svg.getBoundingClientRect().width], accent,
        html: [$$('.nb-rich[data-mime="text/html"] b').length, $$('.nb-rich img').map(i => i.getAttribute('src') ? i.alt + ':' + i.naturalWidth : i.alt + ':none')],
        rmd: $$('.nb-rich[data-mime="text/markdown"] li').length, note: $$('.nb-note').map(e => e.textContent),
        hidden: (() => { const d = li[5].querySelector('details.nbx-hidden'); return d && [d.open, d.querySelector('summary').textContent, d.querySelector('.nb-out').textContent]; })(),
        far: [li.at(-3).querySelector('.nb-code').textContent, [...li.at(-3).querySelectorAll('.syn-special')].map(e => e.textContent)],
        big: [li.at(-2).querySelector('.nb-code').textContent.length, li.at(-2).querySelectorAll('.nb-code span').length],
        syn: col($('.nb-code .syn-special')), plain: col($('.nb-code')), string: col($('.nb-code .syn-string')),
        wide: document.documentElement.scrollWidth <= document.documentElement.clientWidth,
        cells: [li.length, document.body.children.length, !!$('.nbx > footer.nbx-foot'), $$('.nb-cells > :not(.nb-cell)').length],
        // [n] next to the code, as in the page; the red bar of an error
        right: box(li[1].querySelector('.nb-gutter')).right - count.getBoundingClientRect().right,
        bars: [getComputedStyle(li[3], '::before').backgroundColor, getComputedStyle(li[1], '::before').backgroundColor], bad,
        pre: [li[6].querySelector('.nb-stream').textContent, li[6].querySelector('.nb-rich pre').textContent,
              box(li[6].querySelector('.nb-stream')).height],
        markup: [...li[7].querySelectorAll('.nb-out > *')].map(e => e.className + ':' + e.textContent),
        held: $$('li').filter(e => !/^[uo]l$/.test(e.parentNode.localName) && !e.closest('.nb-rich')).length, fixed: (() => { const e = $$('li').find(e => e.textContent === 'ESCAPED');
                                                                                        return e && !!e.closest('.nb-rich') && getComputedStyle(e).position; })(),
      };
    });
    const j = JSON.stringify(r), T = 'Export </title><script>x</script> test';     // escaped
    assert(r.title === T && r.head === T && r.csp, 'title and CSP ' + j);
    assert(/^Exported from the CHICKEN Scheme notebook on \S/.test(r.foot), 'footer ' + r.foot);
    assert(!r.handlers && !r.urls.length && !r.chrome, 'static, nothing external: ' + j);
    assert(r.md[0] === T && r.md[1] === 2 && r.fence.join() === 'define,lambda' && r.lastFence && r.anchor === 'The end',
           'markdown (also in edit mode), fences colored, anchors ' + j);
    assert(r.counts.join() === '[1],[2],[3],[4],[5],[6]' && r.edited && r.stale && r.src1 === '(display "out!")', 'gutter ' + j);
    assert(r.streams.join('|') === 'nb-stream stdout:out\n|nb-stream stderr:err\n', 'streams ' + r.streams);
    assert(r.value && !r.value[0] && r.value[1] === 40 && r.value[2], 'the long value in full ' + JSON.stringify(r.value));
    assert(r.error[0] === 'Error' && /bad argument type/.test(r.error[1]) && r.error[2].join() === 'span:In[3]:1', 'error ' + JSON.stringify(r.error));
    assert(r.svg && r.svg[0] === r.accent && r.svg[1] === 40, 'svg ' + JSON.stringify(r.svg) + ' ' + r.accent);
    assert(r.html.join() === '1,dot:1', 'html (the external image dropped) ' + JSON.stringify(r.html));
    assert(r.rmd === 2 && r.note.includes('… 10 characters omitted …'), 'markdown output and note ' + j);
    assert(r.hidden && !r.hidden[0] && r.hidden[1] === 'Output hidden' && r.hidden[2] === 'hidden text\n', 'hidden ' + JSON.stringify(r.hidden));
    assert(r.far[0] === '(define (far-away) (if #t "far" 0))' && r.far[1].join() === 'define,if', 'far cell colored ' + JSON.stringify(r.far));
    assert(r.big[0] > 32 * 1024 && r.big[1] === 0, 'a big cell stays plain ' + r.big);
    assert(r.syn !== r.plain && r.string !== r.plain && r.syn !== r.string, 'colors ' + [r.syn, r.string, r.plain]);
    assert(r.wide, 'no horizontal scroll');
    assert(r.cells[0] === cells.length && r.cells[1] === 1 && r.cells[2] && !r.cells[3], 'every cell in its place ' + JSON.stringify(r.cells));
    assert(r.right >= 0 && r.right <= 4, 'the count is right-aligned: ' + r.right);
    assert(r.bars[0] === r.bad && r.bars[1] !== r.bad, 'status bar ' + JSON.stringify([r.bars, r.bad]));
    assert(r.pre[0] === '\nafter newline\n10% 20% 30%\n' && r.pre[1] === '\nplain' && Math.abs(r.pre[2] - inApp[3]) < 1,
           'a leading newline and a CR as in the page ' + JSON.stringify([r.pre, inApp]));
    assert(r.markup.join('|') === 'nb-rich:item|nb-rich:ESCAPED|nb-rich:|nb-note bad:output left out: its markup does not read back the same in a static page' &&
           !r.held && r.fixed === 'fixed', 'markup kept in its cell ' + JSON.stringify(r.markup) + ' ' + r.held + ' ' + r.fixed);
    // the dark scheme, print (light whatever the scheme) and a phone
    const look = () => f.evaluate(() => [getComputedStyle(document.body).backgroundColor, getComputedStyle(document.querySelector('.nb-code .syn-special')).color,
                                         document.documentElement.scrollWidth <= document.documentElement.clientWidth]);
    const light = await look();
    await f.emulateMedia({ colorScheme: 'dark' });
    const dark = await look();
    await f.emulateMedia({ media: 'print', colorScheme: 'dark' });
    const print = await look();
    await f.emulateMedia({ media: 'screen', colorScheme: 'light' });
    await f.setViewportSize({ width: 390, height: 800 });
    const phone = await look();
    assert(dark[0] !== light[0] && dark[1] !== light[1], 'dark ' + JSON.stringify([light, dark]));
    assert(print[1] === light[1] && print[0] !== dark[0], 'print is light ' + JSON.stringify([print, dark]));
    assert(phone[2], 'no horizontal scroll at 390 px');
    assert(!fErrors.length && !requests.length, 'the export page: ' + fErrors.concat(requests).join('\n'));
    await f.close();
    fs.rmSync(path.dirname(file), { recursive: true, force: true });
    await accepting(() => page.setInputFiles('#nb-file', { name: 'small.scm', mimeType: 'text/plain', buffer: Buffer.from('(+ 1 2)') }));
    await page.waitForFunction(() => document.querySelectorAll('#nb-cells > li').length === 1, null, { timeout: 20000 });
  });

  // a big notebook is colored up to 1 MB of sources in all, the rest
  // plain, so that the export does not freeze the page for seconds
  await check(P + 'notebook: Export .html colors at most 1 MB of sources', async () => {
    const unit = '(define (g x) (if (> x 1) "s" #\\a)) ; c\n', src = unit.repeat(Math.floor(31000 / unit.length));
    const cells = Array.from({ length: 40 }, () => ({ type: 'code', source: src }));
    const buf = Buffer.from(JSON.stringify({ format: 'chicken-notebook', version: 1, meta: { title: 'big export' }, cells }));
    await accepting(() => page.setInputFiles('#nb-file', { name: 'big.json', mimeType: 'application/json', buffer: buf }));
    await page.waitForFunction(n => document.querySelectorAll('#nb-cells > li').length === n, cells.length, { timeout: 20000 });
    const [dl] = await Promise.all([page.waitForEvent('download'), menu('Export .html')]);
    const text = fs.readFileSync(await dl.path(), 'utf8');
    const code = text.split('<pre class="nb-code"><code>').slice(1).map(t => t.startsWith('<span') ? 'c' : 'p').join('');
    assert(code === 'c'.repeat(Math.floor(1024 * 1024 / src.length)) + 'p'.repeat(40 - Math.floor(1024 * 1024 / src.length)), 'colored ' + code);
    await accepting(() => page.setInputFiles('#nb-file', { name: 'small.scm', mimeType: 'text/plain', buffer: Buffer.from('(+ 1 2)') }));
    await page.waitForFunction(() => document.querySelectorAll('#nb-cells > li').length === 1, null, { timeout: 20000 });
  });

  await check(P + 'from file:// the page explains that it needs HTTP', async () => {
    const f = await context.newPage();
    f.on('pageerror', e => errors.push('file:// pageerror: ' + e.message));
    await f.goto('file://' + path.join(webDir, 'index.html'));
    await f.waitForFunction(() => document.getElementById('status').dataset.state === 'error', null, { timeout: 10000 });
    assert(/served over HTTP/.test(await f.textContent('#notice-text')), 'notice: ' + await f.textContent('#notice-text'));
    await assertLockedOut(f, 'file://');
    // a page with two builds does not claim to run one
    if (dual) {
      assert(await f.isHidden('#arch'), 'file://: no build chip');
      assert(!/Running/.test(await f.textContent('#set-arch-help')), 'file://: help ' + await f.textContent('#set-arch-help'));
    }
    // the notebook says so too, and starts nothing
    await assertNotebookLockedOut(f, 'file://', /served over HTTP.*file:\/\/ URLs/);
    if (dual) assert(await f.textContent('#nb-info') === '', 'file://: nb-info ' + await f.textContent('#nb-info'));
    await f.close();
  });

  if (!dual) {
    // Engines without memory64 (as Safari 26 and 27): the page must say so
    // for a wasm64 build, and still start a wasm32 build.
    await check(P + `without memory64 the ${arch} page ` +
                (arch === 'wasm64' ? 'explains what it needs' : 'still works'), async () => {
      const f = await context.newPage();
      const wasmFetched = [];
      f.on('pageerror', e => errors.push('no-memory64 pageerror: ' + e.message));
      f.on('request', r => { if (/\.wasm(\?|$)/.test(r.url())) wasmFetched.push(r.url()); });
      await lackFeature(f, 'memory64');
      await f.goto(base + 'index.html');
      if (arch === 'wasm64') {
        await f.waitForFunction(() => document.getElementById('status').dataset.state === 'error', null, { timeout: 10000 });
        assert(/64-bit WebAssembly \(memory64\)/.test(await f.textContent('#notice-text')),
               'notice: ' + await f.textContent('#notice-text'));
        assert(/WASM_ARCH=wasm32/.test(await f.textContent('#term')), 'term suggests a wasm32 build');
        assert(new RegExp('Chrome or Edge ' + (eh === 'exnref' ? 137 : 133)).test(await f.textContent('#term')),
               'browser versions: ' + await f.textContent('#term'));
        await assertLockedOut(f, 'no memory64');
        // Ctrl+Enter in the editor must not get past the disabled Compile button
        await f.click('#tab-compile');
        await f.click('#src');
        await f.keyboard.press('Control+Enter');
        await new Promise(r => setTimeout(r, 500));
        assert(await f.isDisabled('#compile'), 'compile still disabled after Ctrl+Enter');
        assert(/memory64/.test(await f.textContent('#cstatus')), 'cstatus: ' + await f.textContent('#cstatus'));
        await assertNotebookLockedOut(f, 'no memory64', /memory64.*Chrome or Edge.*WASM_ARCH=wasm32/);
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

    // Engines without exnref (Chrome 133 to 136, Safari before 18.4): a
    // build with WASM_SJLJ=wasm must say so, any other must still start.
    await check(P + `without exnref the ${arch} ${eh}-EH page ` +
                (eh === 'exnref' ? 'explains what it needs' : 'still works'), async () => {
      const f = await context.newPage();
      const wasmFetched = [];
      f.on('pageerror', e => errors.push('no-exnref pageerror: ' + e.message));
      f.on('request', r => { if (/\.wasm(\?|$)/.test(r.url())) wasmFetched.push(r.url()); });
      await lackFeature(f, 'exnref');
      await f.goto(base + 'index.html');
      if (eh === 'exnref') {
        await f.waitForFunction(() => document.getElementById('status').dataset.state === 'error', null, { timeout: 10000 });
        assert(/exception handling with exnref/.test(await f.textContent('#notice-text')),
               'notice: ' + await f.textContent('#notice-text'));
        assert(/Chrome or Edge 137/.test(await f.textContent('#term')) && /WASM_SJLJ=wasm-legacy/.test(await f.textContent('#term')),
               'term: ' + await f.textContent('#term'));
        await assertLockedOut(f, 'no exnref');
        await assertNotebookLockedOut(f, 'no exnref', /exnref.*Chrome or Edge 137.*WASM_SJLJ=wasm-legacy/);
        assert(!wasmFetched.length, 'fetched ' + wasmFetched.join(' '));
      } else {
        await f.waitForFunction(() => document.getElementById('status').dataset.state === 'ready', null, { timeout: 60000 });
      }
      await f.close();
    });

    // a page with one build ignores ?arch= naming another, and says so
    await check(P + `?arch= naming another build: the ${arch} page says it has only ${arch}`, async () => {
      const o = arch === 'wasm64' ? 'wasm32' : 'wasm64';
      const f = await context.newPage();
      f.on('pageerror', e => errors.push('?arch pageerror: ' + e.message));
      await f.goto(base + 'index.html?arch=' + o);
      await f.waitForFunction(() => document.getElementById('status').dataset.state === 'ready', null, { timeout: 60000 });
      await f.waitForFunction(() => /ignoring/.test(document.getElementById('term').textContent), null, { timeout: 10000 });
      const t = await f.textContent('#term');
      assert(t.includes('; ignoring ?arch=' + o + ': this page has only the ' + arch + ' build.'), 'note: ' + t.slice(0, 300));
      assert(await f.isHidden('#arch') && await f.isHidden('#set-arch'), 'no build chip or setting');
      await f.close();
    });
  } else {
    // A page with two builds, in pages of the same context (and storage)
    // as an engine without some features would get it.  Their console
    // errors count; their warnings about legacy exception handling (the
    // wasm32 build) are only counted.
    let otherWarnings = 0;
    async function openPage(lacking, query = '', init = null) {
      const f = await context.newPage();
      const what = '[' + (lacking.length ? 'no ' + lacking.join(', no ') : 'all features') + query +
        (init ? ', ' + init.name : '') + '] ';
      const wasm = [];
      f.on('pageerror', e => errors.push(what + 'pageerror: ' + e.message));
      const onConsole = m => {
        if (m.type() === 'error') errors.push(what + 'console: ' + m.text());
        if (isLegacyEh(m)) otherWarnings++;
      };
      f.on('console', onConsole);
      f.on('worker', w => { if (typeof w.on === 'function') w.on('console', onConsole); });
      f.on('request', r => { if (/\.wasm(\?|$)/.test(r.url())) wasm.push(r.url()); });
      f.on('requestfailed', r => errors.push(what + 'request failed: ' + r.url()));
      for (const x of lacking) await lackFeature(f, x);
      if (init) await f.addInitScript(init);
      await f.goto(base + 'index.html' + query);
      return { f, wasm, what };
    }
    const fState = (f, st, timeout = 60000) =>
      f.waitForFunction(s => document.getElementById('status').dataset.state === s, st, { timeout });
    async function fEval(f, text, re) {
      const at = (await f.textContent('#term')).length;
      await f.fill('#line', text);
      await f.press('#line', 'Enter');
      await f.waitForFunction(([src, fl, n]) => new RegExp(src, fl).test(document.getElementById('term').textContent.slice(n)),
                              [re.source, re.flags, at], { timeout: 20000 });
      await fState(f, 'ready', 20000);
      return (await f.textContent('#term')).slice(at);
    }
    const MACHINE = { wasm64: '(wasm64 #t 4611686018427387903)', wasm32: '(wasm32 #f 1073741823)' };
    // the REPL of page f runs build a, which the header and the API show
    async function runs(f, a, what) {
      await fState(f, 'ready');
      await fEval(f, '(import (chicken platform) (chicken fixnum))', /#;\d+> $/);
      const out = await fEval(f, '(list (machine-type) (feature? #:64bit) most-positive-fixnum)', /\n\(.*\)\n#;\d+> $/);
      assert(out.includes('\n' + MACHINE[a] + '\n'), what + 'REPL: ' + out);
      assert(await f.evaluate(() => ChickenPage.ARCH) === a, what + 'ChickenPage.ARCH');
      assert(await f.isVisible('#arch') && await f.textContent('#arch') === a, what + 'chip: ' + await f.textContent('#arch'));
    }
    // (Firefox gives worker URLs as written, relative)
    const workerDirs = f => f.workers().map(w => new URL(w.url(), base))
      .filter(u => /(repl|compiler)-worker\.js$/.test(u.pathname)).map(u => u.searchParams.get('dir') || '');

    await check(P + `two builds: without memory64 the page runs ${other.arch}: REPL, notebook and compiler`, async () => {
      const { f, wasm, what } = await openPage(['memory64']);
      await runs(f, other.arch, what);
      assert(new RegExp('; running the ' + other.arch + ' build: this browser lacks 64-bit WebAssembly \\(memory64\\), ' +
                        'which the wasm64 build needs\\.').test(await f.textContent('#term')),
             what + 'note: ' + (await f.textContent('#term')).slice(0, 400));
      if (shots) {
        fs.mkdirSync(shots, { recursive: true });
        await f.screenshot({ path: path.join(shots, `${name}-${other.arch}-repl-desktop.png`) });
      }
      // the notebook's kernel runs the same build
      await f.click('#tab-notebook');
      await f.click('#nb-end-code');
      await f.keyboard.type('(import (chicken platform) (chicken fixnum)) (list (machine-type) most-positive-fixnum)');
      await f.keyboard.press('Control+Enter');
      const want = MACHINE[other.arch].replace(/ #[tf]/, '');
      await f.waitForFunction(w => [...document.querySelectorAll('#nb-cells .nb-value')].some(e => e.textContent === w),
                              want, { timeout: 60000 });
      assert(new RegExp('^CHICKEN .* · ' + other.arch + '$').test(await f.textContent('#nb-info')),
             what + 'nb-info: ' + await f.textContent('#nb-info'));
      if (shots) await f.screenshot({ path: path.join(shots, `${name}-${other.arch}-notebook-desktop.png`) });
      // and so does the compiler
      await f.click('#tab-compile');
      await f.fill('#src', '(print 1)');
      await f.click('#compile');
      await f.waitForFunction(() => /ok|fail/.test(document.getElementById('cstatus').className), null, { timeout: 60000 });
      assert(/ok/.test(await f.getAttribute('#cstatus', 'class')) && /C_toplevel/.test(await f.textContent('#cout')),
             what + 'compile: ' + await f.textContent('#cstatus'));
      if (shots) await f.screenshot({ path: path.join(shots, `${name}-${other.arch}-compile-desktop.png`) });
      assert(wasm.some(u => /chicken-repl\.wasm/.test(u)) && wasm.some(u => /chicken-compiler\.wasm/.test(u)) &&
             fromDir(wasm, other.arch) && wasm.every(u => /\?v=/.test(u)), what + 'wasm fetched: ' + wasm.join(' '));
      const dirs = workerDirs(f);
      assert(dirs.length === 3 && dirs.every(d => d === dirOf(other.arch)), what + 'worker dirs: ' + JSON.stringify(dirs));
      if (shots) {
        await f.click('#tab-repl');
        await f.click('#settings-btn');
        await f.screenshot({ path: path.join(shots, `${name}-${other.arch}-settings-desktop.png`) });
        await f.keyboard.press('Escape');
        for (const width of [360, 320]) {
          await f.setViewportSize({ width, height: 740 });
          await f.screenshot({ path: path.join(shots, `${name}-${other.arch}-repl-${width}.png`) });
        }
      }
      await f.setViewportSize({ width: 320, height: 740 });
      const o = await f.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth,
                                       document.querySelector('.top').scrollWidth, document.querySelector('.top').clientWidth]);
      assert(o[0] <= o[1] && o[2] <= o[3], what + 'no horizontal scroll at 320 px: ' + o);
      await f.close();
    });

    await check(P + `two builds: without exnref the page runs ${other.arch}`, async () => {
      const { f, what } = await openPage(['exnref']);
      await runs(f, other.arch, what);
      assert(/running the .* build: this browser lacks WebAssembly exception handling with exnref/.test(await f.textContent('#term')),
             what + 'note: ' + (await f.textContent('#term')).slice(0, 400));
      await f.close();
    });

    // no exception handling at all: neither build runs
    await check(P + 'two builds: without exnref and legacy exception handling the page explains it', async () => {
      const { f, wasm, what } = await openPage(['exnref', 'legacy']);
      await fState(f, 'error', 10000);
      const notice = await f.textContent('#notice-text');
      assert(/^this browser runs no build of this page: wasm64 needs WebAssembly exception handling with exnref; wasm32 needs WebAssembly exception handling \(the legacy instructions\)\.$/
             .test(notice), what + 'notice: ' + notice);
      assert(/Use Chrome or Edge 95, Firefox 100, Safari 15\.4 or later\./.test(await f.textContent('#term')),
             what + 'term: ' + await f.textContent('#term'));
      assert(await f.isHidden('#arch'), what + 'no build chip');
      await assertLockedOut(f, 'no EH');
      await assertNotebookLockedOut(f, 'no EH', /runs no build of this page.*Chrome or Edge 95/);
      assert(!wasm.length, what + 'fetched ' + wasm.join(' '));
      await f.close();
    });

    await check(P + `two builds: ?arch= picks ${other.arch} or ${arch}, or says why it cannot`, async () => {
      let { f, wasm, what } = await openPage([], '?arch=' + other.arch);
      await runs(f, other.arch, what);
      assert((await f.textContent('#term')).includes('; running the ' + other.arch + ' build, as ?arch=' + other.arch + ' asks.'),
             what + 'note: ' + (await f.textContent('#term')).slice(0, 300));
      assert(fromDir(wasm, other.arch), what + 'wasm fetched: ' + wasm.join(' '));
      await f.close();
      ({ f, what } = await openPage([], '?arch=' + arch));
      await runs(f, arch, what);
      await f.close();
      // a build this browser cannot run: the note, and the other build
      ({ f, what } = await openPage(['memory64'], '?arch=wasm64'));
      await runs(f, 'wasm32', what);
      const t = await f.textContent('#term');
      assert(t.includes('; ignoring ?arch=wasm64: this browser lacks 64-bit WebAssembly (memory64), which the wasm64 build needs.\n' +
                        '; running the wasm32 build instead.'), what + 'note: ' + t.slice(0, 400));
      await f.close();
      // not a build of the page
      ({ f, what } = await openPage([], '?arch=wasm16'));
      await runs(f, arch, what);
      assert((await f.textContent('#term')).includes('; ignoring ?arch=wasm16: this page has the ' +
                                                    builds.map(b => b.arch).join(' and ') + ' builds.'),
             what + 'note: ' + (await f.textContent('#term')).slice(0, 300));
      await f.close();
    });

    // the Settings choice persists, ?arch= overrides it, Automatic again
    await check(P + 'two builds: the Settings choose the build; ?arch= overrides them', async () => {
      let { f, what } = await openPage([]);
      await runs(f, arch, what);
      await f.click('#settings-btn');
      assert(await f.isVisible('#set-arch') && await f.isChecked('#set-arch-auto'), what + 'Automatic checked');
      assert(/Automatic runs wasm64 where the browser supports it, else wasm32/.test(await f.textContent('#set-arch-help')),
             what + 'help: ' + await f.textContent('#set-arch-help'));
      await f.check(`input[name="arch"][value="${other.arch}"]`);
      await Promise.all([f.waitForEvent('load'), f.click('#settings button[value="save"]')]);
      await runs(f, other.arch, what + 'after Save: ');
      assert(await f.evaluate(() => localStorage.getItem('chicken-repl.arch')) === other.arch, what + 'stored');
      assert((await f.textContent('#term')).includes('; running the ' + other.arch + ' build, as the build chosen in the Settings asks.'),
             what + 'note: ' + (await f.textContent('#term')).slice(0, 300));
      await f.close();
      // ?arch= wins over the Settings; ?arch=auto chooses as without them
      ({ f, what } = await openPage([], '?arch=' + arch));
      await runs(f, arch, what);
      await f.close();
      // a save that does not change the build running keeps the page
      async function saveKeeps(f, what) {
        await f.evaluate(() => { window.__same = 1; });
        await f.click('#settings button[value="save"]');
        await f.waitForTimeout(500);
        await fState(f, 'ready');
        assert(await f.evaluate(() => window.__same) === 1, what + 'reloaded');
      }
      ({ f, what } = await openPage([], '?arch=auto'));
      await runs(f, arch, what);
      // saving Automatic, which runs the same build, keeps the page and its ?arch=
      await f.click('#settings-btn');
      assert(await f.isChecked(`input[name="arch"][value="${other.arch}"]`), what + 'the stored choice checked');
      await f.check('#set-arch-auto');
      await saveKeeps(f, what + 'Automatic: ');
      assert(/\?arch=auto$/.test(f.url()), what + 'url ' + f.url());
      await runs(f, arch, what + 'after Save: ');
      assert(await f.evaluate(() => localStorage.getItem('chicken-repl.arch')) === 'auto', what + 'stored auto');
      await f.close();
      // with ?arch= naming the other build, saving other settings keeps
      // the page: its ?arch=, its build, the uploads and the Compile source
      ({ f, what } = await openPage([], '?arch=' + other.arch));
      await runs(f, other.arch, what);
      await f.setInputFiles('#upload', { name: 'kept.scm', mimeType: 'text/plain', buffer: Buffer.from('(define kept 7)\n') });
      await f.waitForFunction(() => /uploaded kept\.scm/.test(document.getElementById('term').textContent), null, { timeout: 10000 });
      await f.click('#tab-compile');
      await f.fill('#src', '(define (my-work) 42)');
      await f.click('#tab-repl');
      await f.click('#settings-btn');
      assert(await f.isChecked('#set-arch-auto'), what + 'Automatic checked');
      await saveKeeps(f, what + 'other settings: ');
      assert(new RegExp('\\?arch=' + other.arch + '$').test(f.url()), what + 'url ' + f.url());
      await runs(f, other.arch, what + 'after Save: ');
      assert(await f.inputValue('#src') === '(define (my-work) 42)', what + 'src ' + await f.inputValue('#src'));
      await fEval(f, ',l kept.scm', /#;\d+> $/);
      assert((await fEval(f, 'kept', /\n\d+\n#;\d+> $/)).includes('\n7\n'), what + 'upload resent');
      // choosing the build running there keeps the page too; another one
      // loads it again, without ?arch=
      await f.click('#settings-btn');
      await f.check(`input[name="arch"][value="${other.arch}"]`);
      await saveKeeps(f, what + 'the same build: ');
      await f.click('#settings-btn');
      await f.check(`input[name="arch"][value="${arch}"]`);
      await Promise.all([f.waitForEvent('load'), f.click('#settings button[value="save"]')]);
      assert(!/arch=/.test(f.url()), what + 'url ' + f.url());
      await runs(f, arch, what + 'after choosing ' + arch + ': ');
      assert(await f.evaluate(() => localStorage.getItem('chicken-repl.arch')) === arch, what + 'stored ' + arch);
      // and back to Automatic (the same build): no reload
      await f.click('#settings-btn');
      await f.check('#set-arch-auto');
      await saveKeeps(f, what + 'Automatic again: ');
      assert(await f.evaluate(() => localStorage.getItem('chicken-repl.arch')) === 'auto', what + 'stored auto');
      await f.close();
    });

    // a build the browser is known not to run cannot be chosen; one it
    // turns out not to run (the legacy probe waits for the choice) is
    // refused with a note, keeping the page
    await check(P + 'two builds: the Settings offer only the builds this browser runs', async () => {
      let { f, what } = await openPage(['memory64']);
      await runs(f, 'wasm32', what);
      await f.click('#settings-btn');
      assert(await f.isDisabled('input[name="arch"][value="wasm64"]') &&
             await f.isEnabled('input[name="arch"][value="wasm32"]'), what + 'wasm64 disabled');
      assert((await f.textContent('#set-arch-help')).endsWith(
        ' This browser cannot run wasm64: it lacks 64-bit WebAssembly (memory64).'),
             what + 'help: ' + await f.textContent('#set-arch-help'));
      await f.keyboard.press('Escape');
      await f.close();
      ({ f, what } = await openPage(['legacy']));
      await runs(f, 'wasm64', what);
      await f.click('#settings-btn');
      assert(await f.isEnabled('input[name="arch"][value="wasm32"]'), what + 'wasm32 offered before its probe');
      await f.check('input[name="arch"][value="wasm32"]');
      await f.evaluate(() => { window.__same = 1; });
      await f.click('#settings button[value="save"]');
      await f.waitForFunction(() => /; restarting…/.test(document.getElementById('term').textContent), null, { timeout: 10000 });
      await runs(f, 'wasm64', what + 'after Save: ');
      assert(await f.evaluate(() => window.__same) === 1, what + 'reloaded');
      const t = await f.textContent('#term');
      assert(t.includes('; ignoring the build chosen in the Settings: this browser lacks WebAssembly exception handling ' +
                        '(the legacy instructions), which the wasm32 build needs.\n; restarting…\n'),
             what + 'note: ' + JSON.stringify(t.slice(-600)));
      await f.click('#settings-btn');
      assert(await f.isDisabled('input[name="arch"][value="wasm32"]') &&
             await f.isChecked('input[name="arch"][value="wasm32"]'), what + 'wasm32 disabled after its probe, still chosen');
      await f.check('#set-arch-auto');
      await f.click('#settings button[value="save"]');
      // (the dialog's close event comes after the click)
      await f.waitForFunction(() => localStorage.getItem('chicken-repl.arch') === 'auto', null, { timeout: 10000 });
      await runs(f, 'wasm64', what + 'after Automatic: ');
      assert(await f.evaluate(() => window.__same) === 1, what + 'reloaded after Automatic');
      await f.close();
    });

    // without storage the build chosen in the Settings goes in ?arch=
    await check(P + 'two builds: without storage the Settings choose the build through ?arch=', async () => {
      const noStorage = () => {
        Object.defineProperty(window, 'localStorage', {
          configurable: true, get() { throw new DOMException('blocked', 'SecurityError'); } });
      };
      const { f, what } = await openPage([], '', noStorage);
      await runs(f, arch, what);
      await f.click('#settings-btn');
      assert(/reloads the page with \?arch=, as this browser keeps no settings\./.test(await f.textContent('#set-arch-help')),
             what + 'help: ' + await f.textContent('#set-arch-help'));
      await f.check(`input[name="arch"][value="${other.arch}"]`);
      await Promise.all([f.waitForEvent('load'), f.click('#settings button[value="save"]')]);
      assert(new RegExp('\\?arch=' + other.arch + '$').test(f.url()), what + 'url ' + f.url());
      await runs(f, other.arch, what + 'after Save: ');
      await f.click('#settings-btn');
      assert(await f.isChecked(`input[name="arch"][value="${other.arch}"]`), what + 'the choice checked');
      await f.check('#set-arch-auto');
      await Promise.all([f.waitForEvent('load'), f.click('#settings button[value="save"]')]);
      assert(/\?arch=auto$/.test(f.url()), what + 'url ' + f.url());
      await runs(f, arch, what + 'after Automatic: ');
      await f.close();
    });

    await check(P + `two builds: legacy exception handling warnings of the ${other.arch} pages counted`, async () => {
      console.log('  # ' + otherWarnings + ' legacy exception handling warnings on the ' + other.arch + ' pages');
    });
  }

  await check(P + 'zero console errors', async () => {
    assert(!errors.length, errors.join('\n'));
  });

  // Firefox deprecates the legacy "try" instruction: a build with exnref
  // must not use it in any of its modules.
  await check(P + (eh === 'exnref' ? 'no legacy exception handling warnings'
                   : 'legacy exception handling warnings counted'), async () => {
    if (eh === 'exnref') assert(!legacyEh.length, legacyEh.length + ' warnings: ' + legacyEh[0]);
    else console.log('  # ' + legacyEh.length + ' legacy exception handling warnings (WASM_SJLJ=' +
                     (eh === 'legacy' ? 'wasm-legacy' : 'emscripten') + ')');
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
