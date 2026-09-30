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
const browsers = (process.env.BROWSERS || 'chromium').split(',').map(s => s.trim()).filter(Boolean);

const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
                '.wasm': 'application/wasm', '.png': 'image/png', '.css': 'text/css' };
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

  for (const width of [360, 320]) await check(P + `no horizontal scroll at ${width} px`, async () => {
    await page.setViewportSize({ width, height: 740 });
    await evalTo('(make-string 300 #\\x)', /xxxxxxxxxx"\n/);
    const over = () => page.evaluate(() => {
      const d = document.documentElement;
      const wide = [...document.querySelectorAll('body *')].filter(e => {
        const r = e.getBoundingClientRect();
        return r.width && (r.right > d.clientWidth + 0.5 || r.left < -0.5) && getComputedStyle(e).visibility !== 'hidden';
      }).map(e => e.tagName + (e.id ? '#' + e.id : ''));
      return { sw: d.scrollWidth, cw: d.clientWidth, bw: document.body.scrollWidth, wide: wide.slice(0, 5) };
    });
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

  await check(P + 'from file:// the page explains that it needs HTTP', async () => {
    const f = await context.newPage();
    f.on('pageerror', e => errors.push('file:// pageerror: ' + e.message));
    await f.goto('file://' + path.join(webDir, 'index.html'));
    await f.waitForFunction(() => document.getElementById('status').dataset.state === 'error', null, { timeout: 10000 });
    assert(/served over HTTP/.test(await f.textContent('#notice-text')), 'notice: ' + await f.textContent('#notice-text'));
    assert(await f.isDisabled('#line'), 'input disabled');
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
