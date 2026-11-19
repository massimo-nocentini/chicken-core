// notebook-harness.js - headless tests of the notebook kernel (webnb.scm) and its client
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
// usage: node [v8 flags] notebook-harness.js WEB_DIR [--eggs] [--arch=A] [--package=DIR]
//
// WEB_DIR is a built web directory (build-wasm/web).  Part L tests the
// pure functions of the page's libraries (js-lexer.js, notebook-lib.js's
// JavaScript cells).  Part K drives the
// kernel ("csi -n -e (##webnb#kernel)") through repl-driver.js: it posts
// requests with post() and reads the events on fd 3.  Part C drives the
// page's client, nb-kernel.js, against the real WEB_DIR/repl-worker.js
// in worker_threads (behind the shim of worker-harness.js).  With
// --eggs (tests/wasm-eggs.sh, on a build with the test eggs) only the
// egg case runs; with --package=DIR (the packages lane) only the
// package cases: DIR is the package of the test eggs made by make
// wasm-package, whose build for the ABI of the modules tested is
// written under /packages, before the kernel starts or into a running
// one.  Exits with status 1 if any case fails.  Run it once
// in default node and once with "--liftoff --no-wasm-tier-up
// --stack-size=900".
//
// With --arch=A, the modules tested are those of the architecture A of
// a page with several (make wasm WASM_WEB_ARCHS="wasm64 wasm32"), in
// WEB_DIR/A unless A is the page's own (its chicken-wasm-arch); then
// Part C's repl-worker.js gets that directory in its dir= query, as on
// the page.

'use strict';
const { Worker } = require('worker_threads');
const fs = require('fs');
const path = require('path');

const webDir = path.resolve(process.argv[2] || 'web');
const eggsOnly = process.argv.includes('--eggs');
// the page's own architecture and those it has (chicken-wasm-builds,
// "ARCH:EH" each); --arch=A selects the modules of A
const pageMeta = (html, name) => (new RegExp('<meta name="' + name + '" content="([^"]*)">').exec(html) || [])[1];
function moduleArch(html) {
  const own = pageMeta(html, 'chicken-wasm-arch');
  const want = (process.argv.find(a => /^--arch=/.test(a)) || '').slice(7) || own;
  const has = (pageMeta(html, 'chicken-wasm-builds') || own || '').split(/\s+/).map(w => w.split(':')[0]);
  if (!has.includes(want)) throw new Error('the page in ' + webDir + ' has no ' + want + ' build (only ' + has.join(', ') + ')');
  return { arch: want, sub: want === own ? '' : want + '/' };
}
// the architecture of the modules (make wasm WASM_ARCH=...); the eggs
// lane builds no index.html
const pageHtml = eggsOnly ? null : fs.readFileSync(path.join(webDir, 'index.html'), 'utf8');
const { arch, sub } = eggsOnly ? { arch: undefined, sub: '' } : moduleArch(pageHtml);
const packageDir = (process.argv.find(a => /^--package=/.test(a)) || '').slice(10);
const createChickenRepl = require(path.join(webDir, sub, 'chicken-repl.js'));
const srcWeb = path.join(__dirname, '..', '..', 'emscripten', 'web');
const Driver = require(path.join(srcWeb, 'repl-driver.js'));
const Kernel = require(path.join(srcWeb, 'nb-kernel.js'));
const Lexer = require(path.join(srcWeb, 'js-lexer.js'));
const NbLib = require(path.join(srcWeb, 'notebook-lib.js'));
const { BUSY, WAITING, SLEEPING, IDLE, PAUSED, AWAITING, LAZY_NEXT, LAZY_GO, LAZY_PAUSE } = Driver;
const wasmModule = new WebAssembly.Module(fs.readFileSync(path.join(webDir, sub, 'chicken-repl.wasm')));
if (!eggsOnly) console.log('# ' + arch + ' modules in ' + path.join(webDir, sub));

let failures = 0, passes = 0, current = null;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const now = () => performance.now();
// the time since t, for a watchdog of 1000 ms: node's timers count from
// its loop clock, in whole milliseconds and read before the call, so one
// may fire a little earlier than performance.now() says
const fired = t => { const d = now() - t; return [d >= 998 && d < 5000, d]; };
function assert(c, msg) { if (!c) throw new Error('assertion failed: ' + msg); }
const J = x => JSON.stringify(x);
function eq(a, b, what) { assert(J(a) === J(b), what + ': expected ' + J(b) + ', got ' + J(a)); }

async function waitFor(what, pred, ms = 20000) {
  const t0 = now();
  for (;;) {
    const v = pred();
    if (v) return v;
    if (now() - t0 > ms) throw new Error('timed out after ' + ms + ' ms waiting for ' + what);
    await sleep(5);
  }
}

// what the workers of part C left uncaught ('__uncaught', see its
// prelude)
const uncaught = [];

// UNCAUGHT: the case leaves exceptions uncaught in the worker (else
// any is a failure: a bug of repl-worker.js would be one)
async function check(name, f, { uncaught: allowed = false } = {}) {
  const u0 = uncaught.length;
  try {
    await f();
    if (!allowed && uncaught.length > u0)
      throw new Error('left uncaught in the worker: ' + uncaught.slice(u0).join('\n'));
    passes++;
    console.log('ok - ' + name);
  } catch (e) {
    failures++;
    console.log('not ok - ' + name + '\n  ' + String((e && e.message) || e));
    if (current && current.tail) console.log('  recent traffic:\n  | ' +
                                             current.tail().split('\n').join('\n  | '));
  }
}


// ---- Part K: the raw kernel through repl-driver.js

// One kernel.  `items' is everything it emitted, in order: {fd, text}
// for fds 1 and 2 (adjacent chunks merged) and {ev} for each event.
async function kernel(opts = {}) {
  const s = { items: [], states: [], exit: null, crash: null, carry: '', rid: 0,
              unacked: 0, high: Infinity, onEvent: null, maxChunk: 0 };
  s.drv = await Driver.start(createChickenRepl, {
    args: opts.args || Kernel.kernelArgs(opts.argString || ''),
    csirc: opts.csirc == null ? null : opts.csirc,
    files: opts.files,
    sliceMs: opts.sliceMs,
    wasmModule,
    schedule: f => setImmediate(f),
    later: (f, ms) => setTimeout(f, ms),
    canRun: () => s.unacked < s.high,
    onOutput: (fd, t) => {
      s.unacked += t.length;
      s.maxChunk = Math.max(s.maxChunk, t.length);
      if (fd !== 3) {
        const last = s.items[s.items.length - 1];
        if (last && last.fd === fd) last.text += t; else s.items.push({ fd, text: t });
        return;
      }
      const lines = (s.carry + t).split('\n');
      s.carry = lines.pop();
      for (const l of lines) {
        const ev = JSON.parse(l);         // a bad line fails the case
        s.items.push({ ev });
        if (s.onEvent) s.onEvent(ev);
      }
    },
    onState: st => s.states.push(st),
    onExit: code => { s.exit = code; },
    onCrash: msg => { s.crash = msg; },
  });
  current = s;
  s.tail = () => J(s.items.slice(-8)).slice(-1500);
  s.events = () => s.items.filter(i => i.ev).map(i => i.ev);
  s.find = pred => s.events().find(pred);
  s.alive = () => { if (s.crash) throw new Error('crash: ' + s.crash); if (s.exit !== null) throw new Error('exit ' + s.exit); };
  // post a cell; resolves with {done, items (between start and done), out, err}
  s.post = (src, rid) => { rid = rid || ++s.rid; s.drv.post('run ' + rid + ' In[' + rid + ']\n' + src); return rid; };
  s.result = async (rid, ms) => {
    const done = await waitFor('done ' + rid, () => { s.alive(); return s.find(e => e.ev === 'done' && e.rid === rid); }, ms);
    const i0 = s.items.findIndex(i => i.ev && i.ev.ev === 'start' && i.ev.rid === rid);
    const i1 = s.items.findIndex(i => i.ev === done);
    const items = s.items.slice(i0 + 1, i1);
    const text = fd => items.filter(i => i.fd === fd).map(i => i.text).join('');
    return { done, items, out: text(1), err: text(2), displays: items.filter(i => i.ev && i.ev.ev === 'display').map(i => i.ev) };
  };
  s.run = (src, ms) => s.result(s.post(src), ms);
  // a JavaScript cell
  s.postJs = (src, rid) => { rid = rid || ++s.rid; s.drv.post('js ' + rid + ' In[' + rid + ']\n' + src); return rid; };
  s.runJs = (src, ms) => s.result(s.postJs(src), ms);
  s.idle = (ms) => waitFor('IDLE', () => { s.alive(); return s.drv.state() === IDLE; }, ms);
  s.stateSeen = (st, from, ms) => waitFor('state ' + st, () => { s.alive(); return s.states.slice(from).includes(st); }, ms);
  if (s.drv) s.drv.begin();
  return s;
}

async function ok(s, src, values, ms) {
  const r = await s.run(src, ms);
  assert(r.done.status === 'ok', src + ': status ' + r.done.status + ' ' + J(r.done.error));
  if (values !== undefined) eq(r.done.values, values, src);
  return r;
}

async function okJs(s, src, values, ms) {
  const r = await s.runJs(src, ms);
  assert(r.done.status === 'ok', src + ': status ' + r.done.status + ' ' + J(r.done.error));
  if (values !== undefined) eq(r.done.values, values, src);
  return r;
}


// ---- Part L: the pure functions of the page's libraries

async function partL() {
  const rw = src => Lexer.rewrite(src).code;
  const lines = src => src.split('\n').length;

  await check('L-JS1 rewrite: top-level let, const and class become var; lines are kept', async () => {
    eq(rw('const a = 1; let b = 2'), 'var   a = 1; var b = 2', 'let and const');
    eq(rw('class C extends B { m() {} }\nx'), 'var C = class C extends B { m() {} };\nx', 'class');
    for (const src of ['for (let i=0;;) {}', '{ let z }', 'if (x) { const y = 1 }', 'obj.let = 1', '"let q"',
                       '`${\'const r\'} let`', '/let w/', '// let c', '/* const d */'])
      eq(rw(src), src, 'untouched: ' + src);
    for (const src of ['const a = 1\nlet b = `\n${2}\n`\nclass K {\n}\n', 'x\nclass D {}\n/*\n*/ let e'])
      eq(lines(rw(src)), lines(src), 'lines of ' + J(src));
    eq(Lexer.rewrite('const x = await f()').topAwait, true, 'top-level await');
    eq(Lexer.rewrite('async function g() { await h() }').topAwait, false, 'await in a function');
  });

  await check('L-JS2 incomplete: open brackets, strings, templates and comments', async () => {
    for (const src of ['function f() {', "'abc", '`x ${', '/* c', '[1,'])
      eq(Lexer.incomplete(src), true, src);
    for (const src of ['f()', "'a\nb'", 'x / 2', 'a = /re/g'])
      eq(Lexer.incomplete(src), false, src);
    eq(Lexer.rewrite('function f() {').incomplete, true, 'rewrite says so too');
  });

  await check('L-JS3 regex versus division', async () => {
    const regex = src => Lexer.tokens(src).some(t => t.t === 'regex');
    eq([regex('a / b / c'), regex('x = /=/.test(s)'), regex('return /x/'), regex('f() / 2')],
       [false, true, true, false], 'regex tokens');
    // after a postfix ++ or --, a division; a prefix one (on the next line) is no operand
    eq([regex('i++ / 2 + "/"'), regex('a[0]-- / 2 /x'), regex('x = ++/re/.lastIndex'), regex('a\n++/b/.c')],
       [false, false, true, true], 'after ++ and --');
    const src = 'let i = 3, n = i++ / 2 + "/"; let k = 1';
    eq([rw(src), Lexer.incomplete(src), Lexer.balance(src).ok], ['var i = 3, n = i++ / 2 + "/"; var k = 1', false, true],
       'the rest of the line');
  });

  await check('L-JS4 highlight: the pieces make the source; the kinds', async () => {
    const src = "const t = true; 's'; 42n; // c\n`a${b}c`";
    const h = Lexer.highlight(src);
    eq(h.map(p => p[1]).join(''), src, 'the texts');
    const kind = text => (h.find(p => p[1] === text) || [])[0];
    eq([kind('const'), kind('true'), kind("'s'"), kind('42n'), kind('// c'), kind('${')],
       ['special', 'constant', 'string', 'number', 'comment', 'quote'], 'kinds');
    // a keyword that is a property name is a name there
    const special = src => Lexer.highlight(src).filter(p => p[0] === 'special').map(p => p[1]);
    eq(special('m.get(k); m.set(k, 1); p.catch(f).finally(g); s.delete(x); o?.default; ({ default: 1, get: 2, if: 3 })'),
       [], 'property names');
    eq(special('switch (x) { case 1: break; default: return }'), ['switch', 'case', 'break', 'default', 'return'],
       'a switch\'s keywords');
  });

  await check('L-JS5 balance', async () => {
    const b = src => { const r = Lexer.balance(src); return [r.depth, r.stray, r.mismatch, r.open, r.ok]; };
    eq([b('f('), b(')'), b('(]'), b("'x"), b('f(x)')],
       [[1, 0, 0, false, false], [0, 1, 0, false, false], [0, 0, 1, false, false], [0, 0, 0, true, false],
        [0, 0, 0, false, true]], 'balance');
    // a string that a line ended is unclosed too (though more lines do not make it complete)
    eq([b("const s = 'abc\nfoo()"), b('"a\n"'), Lexer.incomplete("const s = 'abc\nfoo()")],
       [[0, 0, 0, true, false], [0, 0, 0, true, false], false], 'a string a line ended');
  });

  await check('L-JS6 frames of V8 and Firefox stacks', async () => {
    eq(Lexer.frames('Error: x\n    at g (In[3]:2:9)\n    at eval (In[3]:4:1)\n    at eval (<anonymous>)\n' +
                    '    at Object.op (http://h/chicken-repl.js?v=1:9:9)'),
       [['In[3]:4', '(top level)'], ['In[3]:2', 'g']], 'V8');
    eq(Lexer.frames('g@In[3]:2:9\n@In[3]:4:1\nop@http://h/chicken-repl.js:9:9'),
       [['In[3]:4', '(anonymous)'], ['In[3]:2', 'g']], 'Firefox');
    eq(Lexer.frames('Error\n    at lib (https://cdn.example/x/lib.js?v=2:7:1)'), [['lib.js:7', 'lib']], 'a script of a site');
    eq(Lexer.frames('Error\n    at f (/home/x/notebook-harness.js:1:2)\n    at node:internal/x:1:1'), [], 'local and node frames');
  });

  const nbOf = cells => ({ title: 't', cells: cells.map((c, k) => Object.assign({ id: 'c' + k, outputs: [] }, c)) });

  await check('L-NB1 .json: a JavaScript cell keeps its lang (also made text); the version says so', async () => {
    const js = { type: 'code', lang: 'js', source: 'let a = 1' }, scm = { type: 'code', lang: 'scheme', source: '(+ 1 2)' };
    const md = { type: 'markdown', lang: 'js', source: '# t' };
    const j = JSON.parse(NbLib.toJson(nbOf([js, scm, md, { type: 'markdown', lang: 'scheme', source: '# u' }])));
    eq([j.version, j.cells.map(c => c.lang)], [2, ['js', undefined, 'js', undefined]], 'written');
    eq(JSON.parse(NbLib.toJson(nbOf([scm]))).version, 1, 'version 1 without JavaScript');
    eq(JSON.parse(NbLib.toJson(nbOf([scm, md]))).version, 1, 'version 1 when only a text cell was JavaScript');
    const back = NbLib.fromJson(JSON.stringify(j));
    eq([back.cells.map(c => c.lang), back.warnings], [['js', undefined, 'js', undefined], []], 'read back, version 2 silently');
    // the error and the notes of a callback stay marked so (they leave the cell's status as it was)
    const outs = [{ k: 'error', error: { text: 'Error: late', kind: [], chain: [] }, callback: true },
                  { k: 'note', text: 'n', bad: true, callback: true }, { k: 'note', text: 'm', callback: 'yes' }];
    const kept = NbLib.fromJson(NbLib.toJson(nbOf([Object.assign({}, js, { outputs: outs })]))).cells[0].outputs;
    eq(kept.map(o => [o.k, o.callback]), [['error', true], ['note', true], ['note', undefined]], 'callback outputs');
    const file = (version, cells) => JSON.stringify({ format: 'chicken-notebook', version, meta: {}, cells });
    const py = NbLib.fromJson(file(2, [{ type: 'code', lang: 'python', source: 'x' }, { type: 'code', lang: 'ruby', source: 'y' }]));
    eq([py.cells.map(c => c.lang), py.warnings],
       [[undefined, undefined], ['2 cells in a language this page does not know were imported as Scheme cells.']], 'unknown languages');
    assert(/newer version \(format 3\)/.test(NbLib.fromJson(file(3, [js])).warnings.join()), 'version 3 warns');
  });

  await check('L-NB2 .scm: a JavaScript cell is a ;; %% [javascript] block of commented lines', async () => {
    const src = 'const a = 1\n\n;; %% not a marker\n%% nor this\n`t`';
    const text = NbLib.toPercent(nbOf([{ type: 'code', lang: 'js', source: src }, { type: 'code', source: '(f)' }]));
    eq(text.split('\n').slice(3, 12),
       [';; %% [javascript]', ';; const a = 1', ';;', ';; ;; %% not a marker', ';; \\%% nor this', ';; `t`', '', ';; %%', '(f)'], 'written');
    const back = NbLib.splitPercent(text).cells;
    eq(back.map(c => [c.type, c.lang, c.source]), [['code', 'js', src], ['code', undefined, '(f)']], 'read back');
    eq(NbLib.splitPercent(';; %% [JavaScript]\n;; 1 + 1\n').cells.map(c => [c.lang, c.source]), [['js', '1 + 1']], 'any case');
  });

  await check('L-NB3 highlightDom colors JavaScript for lang js', async () => {
    const node = (props) => Object.assign({ children: [], appendChild(c) { this.children.push(c); return c; } }, props);
    const doc = { createDocumentFragment: () => node({}), createElement: tag => node({ tag }),
                  createTextNode: text => ({ text }) };
    const flat = f => f.children.map(c => (c.tag ? [c.className, c.textContent] : ['', c.text]));
    eq(flat(NbLib.highlightDom('const s = "x"', doc, 'js')),
       [['syn-special', 'const'], ['', ' s = '], ['syn-string', '"x"']], 'JavaScript');
    eq(flat(NbLib.highlightDom('(define s "x")', doc)).filter(p => p[0]).map(p => p[0]),
       ['syn-paren', 'syn-special', 'syn-string', 'syn-paren'], 'Scheme without lang');
    eq(NbLib.balanceJs('f({').depth, 2, 'balanceJs');
  });
}

async function partK() {
  let K;

  await check('K1 hello (proto 1, version), then IDLE; no banner or prompt', async () => {
    K = await kernel();
    assert(K.drv, 'start returned null: ' + (K.crash || K.exit));
    const h = await waitFor('hello', () => { K.alive(); return K.find(e => e.ev === 'hello'); }, 30000);
    eq(h.proto, 1, 'proto');
    assert(/^\d+\.\d+/.test(h.version), 'version ' + h.version);
    await K.idle();
    assert(!K.items.some(i => i.fd), 'no output on fds 1 and 2: ' + J(K.items));
    assert(K.items[0].ev === h, 'hello first');
  });
  if (!K || !K.drv) { console.log('cannot continue'); return; }

  await check('K2 stdout, stderr and done in order', async () => {
    const r = await ok(K, '(display "a")(display "b" (current-error-port)) 42', ['42']);
    eq(r.items.map(i => i.ev ? i.ev.ev : i.fd + ':' + i.text), ['1:a', '2:b'], 'items between start and done');
    const last = K.items[K.items.length - 1];
    assert(last.ev === r.done, 'done last');
    assert(typeof r.done.ms === 'number' && r.done.module === null, 'ms and module: ' + J(r.done));
  });

  await check('K3 definitions, syntax, imports and modules persist across cells', async () => {
    await ok(K, '(define-syntax swap! (syntax-rules () ((_ a b) (let ((t a)) (set! a b) (set! b t)))))');
    await ok(K, '(define p 1) (define q 2) (swap! p q) (list p q)', ['(2 1)']);
    await ok(K, '(import (chicken string))');
    await ok(K, '(string-intersperse \'("a" "b") "-")', ['"a-b"']);
    await ok(K, '(module m (z) (import scheme) (define z 5))');
    await ok(K, '(import m) z', ['5']);
  });

  await check('K4 values: several, none, unspecified', async () => {
    await ok(K, '(values 1 2)', ['1', '2']);
    await ok(K, '(values)', []);
    await ok(K, '(define x 1)', null);
    await ok(K, '(void)', null);
    await ok(K, '', null);
  });

  await check('K5 an incomplete cell evaluates nothing', async () => {
    let r = await K.run('(display "x") (car (list');
    eq(r.done.status, 'incomplete', 'status');
    eq(r.done.error.line, 1, 'line');
    eq(r.done.error.form, null, 'form');
    eq(r.out, '', 'stdout');
    r = await K.run('(define y 1) (car');
    eq(r.done.status, 'incomplete', 'status');
    r = await K.run('y');
    assert(r.done.status === 'error' && /unbound variable: y/.test(r.done.error.text), 'y unbound: ' + J(r.done));
    r = await K.run(')');
    eq(r.done.status, 'incomplete', 'stray )');
    r = await K.run('"abc');
    eq(r.done.status, 'incomplete', 'unterminated string');
    r = await K.run('(+ 1\n 2\n (* 3');
    assert(r.done.status === 'incomplete' && r.done.error.line === 3, 'line 3: ' + J(r.done.error));
    // a dotted tail at the end ("missing list terminator"), a quote with
    // nothing after it: incomplete too
    for (const src of ['(display 7) \'(1 . 2', '(display 8) (define al \'((a . 1) (b . ',
                       '(display 9) #(1 2 . 3\n\n', '(display 1) \'', '(display 2) `  \n', '(display 3) ,@']) {
      r = await K.run(src);
      eq(r.done.status, 'incomplete', src);
      eq(r.out, '', src + ': stdout');
    }
    // the same error in the middle, and a quoted end of file, are not
    r = await K.run('(display 4) \'(a . b c)');
    assert(r.done.status === 'error' && r.done.error.form === 2 && r.out === '4', 'mid-input: ' + J(r.done));
    r = await ok(K, '(display 5) \'#!eof', ['#!eof']);
    eq(r.out, '5', 'quoted #!eof');
    // a quote at the end followed by comments only, "#`", "#$", and a
    // "#;" or "#\" with nothing after it (but comments) are incomplete
    await ok(K, '(define k5n 0)');
    for (const src of ['(set! k5n 1) \'\n; comment', '(set! k5n 1) \' #| c |#', '(set! k5n 1) `#;1',
                       '(set! k5n 1) #`', '(set! k5n 1) #$', '(set! k5n 1) #;', '(set! k5n 1) #; ; c\n',
                       '(set! k5n 1) #; \'', '(set! k5n 1) #;#;1', '(set! k5n 1) #\\', '(set! k5n 1) \'#\\']) {
      r = await K.run(src);
      eq(r.done.status, 'incomplete', J(src));
    }
    r = await K.run('(set! k5n 1) #;');
    assert(/unexpected end of input$/.test(r.done.error.text), '#; message: ' + J(r.done.error));
    await ok(K, 'k5n', ['0']);
    // complete ones
    await ok(K, '(+ 1 2) #;(oops) ; c', ['3']);
    await ok(K, '1 #\\a', ['#\\a']);
    await ok(K, '\'#!eof ; c', ['#!eof']);
    await ok(K, '\'; c\n#!eof', ['#!eof']);
    await ok(K, '1 #!eof (oops', ['1']);
  });

  await check('K6 errors: text, kind, location, form and the call history of this cell only', async () => {
    const r = await K.run('(define (f n) (car n)) (define (g n) (+ 1 (f n))) (g 5)');
    const e = r.done.error;
    eq(r.done.status, 'error', 'status');
    assert(/bad argument type/.test(e.text) && /^Error: /.test(e.text), 'text ' + e.text);
    eq(e.kind, ['exn', 'type'], 'kind');
    eq(e.location, 'car', 'location');
    eq(e.form, 3, 'form');
    eq(e.line, 1, 'line');
    assert(e.chain.length > 0, 'a chain');
    for (const fr of e.chain) {
      assert(fr.where.startsWith('In[' + r.done.rid + ']:'), 'where ' + fr.where);
      assert(!/webnb/.test(J(fr)), 'no kernel frames: ' + J(fr));
    }
    assert(e.chain.some(fr => fr.proc === 'f' && fr.form === '(car n)'), 'f frame: ' + J(e.chain));
    eq(e.chain[e.chain.length - 1].form, '(car n)', 'last frame');
    // the REPL's ,c sees it
    const c = await ok(K, ',c');
    assert(/car n/.test(c.out), ',c shows the history: ' + c.out);
  });

  await check('K7 a reader error after a valid form: form 2, no history, the first form ran', async () => {
    const r = await K.run('(define q7 1) #\\bogus');
    eq(r.done.status, 'error', 'status');
    eq(r.done.error.chain, [], 'chain');
    eq(r.done.error.form, 2, 'form');
    eq(r.done.error.line, 1, 'line');
    await ok(K, 'q7', ['1']);
  });

  await check('K7b read-time code runs once; a cell may define read syntax and use it', async () => {
    await ok(K, '(import (chicken read-syntax)) (define rn 0)' +
             ' (define-reader-ctor \'tick7 (lambda () (set! rn (+ rn 1)) rn))', null);
    await ok(K, '#,(tick7)', ['1']);
    await ok(K, 'rn', ['1']);
    // read when its turn comes, after the forms before it, as csi does
    await ok(K, '(define-reader-ctor \'tick7 (lambda () 70)) #,(tick7)', ['70']);
    await ok(K, '(define base7 10) (define-reader-ctor \'plus7 (lambda (x) (+ x base7)))', null);
    await ok(K, '(set! base7 100) #,(plus7 1)', ['101']);
    await ok(K, '(define-reader-ctor \'boom7 (lambda () (display "side;") (car 1)))', null);
    let r = await K.run('(display "pre;") #,(boom7) 2');
    eq([r.done.status, r.out], ['error', 'pre;side;'], 'status and output');
    r = await K.run('(set-read-syntax! #\\$ (lambda (p) (let loop ((cs \'()))' +
                        ' (let ((c (read-char p))) (if (char=? c #\\$) (list->string (reverse cs))' +
                        ' (loop (cons c cs))))))) $a (b$');
    eq(r.done.status, 'ok', 'status ' + J(r.done));
    eq(r.done.values, ['"a (b"'], 'values');
    await ok(K, '$c (d$', ['"c (d"']);
    // an error in a file the cell loads: the line of the cell's form
    await ok(K, '(with-output-to-file "k7b.scm" (lambda () (display "1\\n2\\n3\\n(define x7")))', null);
    r = await K.run('(display "loading")\n(load "k7b.scm")');
    eq(r.done.status, 'error', 'load status');
    eq([r.done.error.form, r.done.error.line], [2, 2], 'form and line');
    // ,exn describes the last error
    await K.run('(car 7)');
    r = await ok(K, ',exn');
    assert(/bad argument type/.test(r.out) && /location: car/.test(r.out), ',exn: ' + J(r.out));
  });

  await check('K8 a raised non-condition; an error while printing the values', async () => {
    let r = await K.run('(import (only (scheme base) raise)) (raise \'oops)');
    eq(r.done.status, 'error', 'status');
    assert(/uncaught exception: oops/.test(r.done.error.text), 'text ' + r.done.error.text);
    eq(r.done.error.kind, [], 'kind');
    eq(r.done.error.location, null, 'location');
    // record printers are guarded by the printer itself, csi's print hook is not
    r = await K.run('(define old-hook ##sys#repl-print-hook)\n' +
                    '(set! ##sys#repl-print-hook (lambda (x p) (set! ##sys#repl-print-hook old-hook) (car x)))\n' +
                    '42');
    eq(r.done.status, 'error', 'status');
    eq(r.done.error.form, 'print', 'form');
    await ok(K, '(+ 1 2)', ['3']);
    // the length limit runs out in the closing parentheses
    await ok(K, '(define (nest8 n) (let loop ((i 0) (acc \'())) (if (= i n) acc (loop (+ i 1) (list i acc)))))');
    r = await ok(K, '(nest8 400)');
    assert(/^\(399 \(398 .*\)\.\.\.$/.test(r.done.values[0]), 'truncated: ' + r.done.values[0].slice(-40));
    // a record printer that resets while the error is reported (after
    // the cell): the fallback error, and the kernel goes on
    await ok(K, '(define k8 8)');
    r = await K.run('(import (scheme base) (chicken repl)) (define-record-type k8r (make-k8r) k8r?) ' +
                    '(set-record-printer! k8r (lambda (x p) (reset))) (raise (make-k8r))');
    eq(r.done.status, 'error', 'reset while reporting: status');
    assert(/while reporting an error/.test(r.done.error.text), 'fallback: ' + r.done.error.text);
    await ok(K, '(list k8 (k8r? (make-k8r)))', ['(8 #t)']);
  });

  await check('K9 Stop: a loop, a sleep and a read-line are interrupted, then cells go on', async () => {
    await ok(K, '(import (chicken io))');
    for (const [src, st] of [['(let loop () (loop))', BUSY], ['(sleep 10)', SLEEPING],
                             ['(read-line)', WAITING]]) {
      const from = K.states.length;
      const rid = K.post(src);
      await K.stateSeen(st, from);
      if (st === BUSY) await waitFor('two BUSY', () => K.states.slice(from).filter(x => x === BUSY).length >= 2);
      const t = now();
      K.drv.interrupt();
      const r = await K.result(rid, 2000);
      eq(r.done.status, 'interrupted', src);
      assert(now() - t < 2000, 'within 2 s');
      await ok(K, '(* 6 7)', ['42']);
    }
    // a nested repl waits at its own prompt: Stop interrupts it too
    // (the REPL's stale-Stop rule for a fresh prompt does not apply)
    const from = K.states.length;
    const rid = K.post('(import (chicken repl)) (repl)');
    await K.stateSeen(WAITING, from);
    K.drv.interrupt();
    const r = await K.result(rid, 2000);
    eq(r.done.status, 'interrupted', 'nested repl');
    assert(/^#;\d+> $/.test(r.out), 'its prompt: ' + J(r.out));
    await ok(K, '(* 6 7)', ['42']);
  });

  await check('K10 stale Stops: after done, and while idle', async () => {
    // in the very slice of the done (the kernel yields IDLE right after)
    K.onEvent = ev => { if (ev.ev === 'done') { K.onEvent = null; K.drv.interrupt(); } };
    await ok(K, '(+ 1 2)', ['3']);
    await K.idle();
    await ok(K, '(+ 1 1)', ['2']);
    await K.idle();
    K.drv.interrupt();                  // idle, nothing posted: dropped
    await sleep(50);
    await ok(K, '(let loop ((i 0)) (if (< i 200000) (loop (+ i 1)) i))', ['200000']);
  });

  await check('K11 Run then Stop before the worker pumped interrupts the new cell', async () => {
    await K.idle();
    const rid = K.post('(let loop () (loop))');
    K.drv.interrupt();
    const r = await K.result(rid, 5000);
    eq(r.done.status, 'interrupted', 'status');
    await ok(K, '(+ 2 3)', ['5']);
  });

  await check('K12 stdin: a cell reads what is fed; nothing leaks between cells; EOF', async () => {
    let from = K.states.length;
    let rid = K.post('(read-line)');
    await K.stateSeen(WAITING, from);
    K.drv.feed('hi\n');
    eq((await K.result(rid)).done.values, ['"hi"'], 'read-line');
    await K.idle();
    K.drv.feed('stale\n');              // nobody reads: dropped before the next cell
    await sleep(30);
    from = K.states.length;
    rid = K.post('(read-line)');
    await K.stateSeen(WAITING, from);
    K.drv.feed('fresh\n');
    eq((await K.result(rid)).done.values, ['"fresh"'], 'no stale text');
    from = K.states.length;
    rid = K.post('(list (read-line) (read-line))');
    await K.stateSeen(WAITING, from);
    K.drv.feed('one\ntw');
    await sleep(30);
    K.drv.feed('o\n');
    eq((await K.result(rid)).done.values, ['("one" "two")'], 'two lines');
    from = K.states.length;
    rid = K.post('(read-line)');
    await K.stateSeen(WAITING, from);
    K.drv.feed('', true);
    eq((await K.result(rid)).done.values, ['#!eof'], 'EOF');
    // a cell's (read) of its own stdin text
    from = K.states.length;
    rid = K.post('(+ 1 (read))');
    await K.stateSeen(WAITING, from);
    K.drv.feed('41\n');
    eq((await K.result(rid)).done.values, ['42'], 'read');
  });

  await check('K13 5 MB of output under credit backpressure: complete, ordered, done last', async () => {
    K.high = 1 << 20;
    K.unacked = 0;
    const timer = setInterval(() => { K.unacked = 0; K.drv.resumeOutput(); }, 20);
    try {
      const rid = K.post('(do ((i 0 (+ i 1))) ((= i 50000)) (display (make-string 99 #\\x)) (newline))');
      const r = await K.result(rid, 120000);
      eq(r.done.status, 'ok', 'status');
      assert(r.out.length === 5000000, 'length ' + r.out.length);
      assert(r.out === ('x'.repeat(99) + '\n').repeat(50000), 'content');
      const i1 = K.items.findIndex(i => i.ev === r.done);
      assert(K.items[i1 - 1].fd === 1, 'done follows the last stdout');
    } finally { clearInterval(timer); K.high = Infinity; }
  });

  await check('K14 a continuation of an earlier cell reports to the running one', async () => {
    await ok(K, '(define k #f) (+ 1 (call-with-current-continuation (lambda (c) (set! k c) 1)))', ['2']);
    const r = await ok(K, '(k 10)', ['11']);
    assert(r.done.rid === K.rid, 'done carries the running rid');
    await ok(K, '(+ 2 2)', ['4']);
    // its reset handler was restored: an error still reports normally
    const e = await K.run('(car 1)');
    eq(e.done.status, 'error', 'error after re-entry');
  });

  await check('K15 (reset) gives reset; (exit 3) ends the kernel without done', async () => {
    const r = await K.run('(import (chicken repl)) (display "before") (reset) (display "after")');
    eq(r.done.status, 'reset', 'status');
    eq(r.out, 'before', 'stdout');
    await ok(K, '(+ 1 1)', ['2']);
    const X = await kernel();
    await waitFor('hello', () => X.find(e => e.ev === 'hello'), 30000);
    const n = X.events().length;
    X.post('(display "bye") (exit 3)');
    await waitFor('exit', () => X.exit !== null, 10000);
    eq(X.exit, 3, 'exit code');
    assert(!X.events().slice(n).some(e => e.ev === 'done'), 'no done');
    assert(X.items.some(i => i.fd === 1 && /bye/.test(i.text)), 'output flushed');
    current = K;
  });

  await check('K16 requests are served in order; ping; bad requests', async () => {
    await K.idle();
    const a = K.post('(+ 1 0)'), b = K.post('(+ 2 0)');
    const ra = await K.result(a), rb = await K.result(b);
    eq([ra.done.values, rb.done.values], [['1'], ['2']], 'values');
    const ia = K.items.findIndex(i => i.ev === ra.done), ib = K.items.findIndex(i => i.ev === rb.done);
    assert(ia < ib, 'rid order');
    K.drv.post('ping 77');
    await waitFor('pong', () => K.find(e => e.ev === 'pong' && e.rid === 77));
    for (const bad of ['hello', 'run x In[1]\n1', 'run 5 bad name\n1', 'run 0 In[0]\n1', 'run 6 In[6]', 'ping']) {
      const n = K.events().length;
      K.drv.post(bad);
      await waitFor('bad-request', () => K.events().slice(n).find(e => e.ev === 'bad-request'));
    }
    const n = K.events().length;
    K.drv.post('x'.repeat(1000));
    const br = await waitFor('bad-request', () => K.events().slice(n).find(e => e.ev === 'bad-request'));
    eq(br.text.length, 200, 'text cut to 200 chars');
    await ok(K, '(+ 3 4)', ['7']);
  });

  await check('K17 the kernel refuses to nest', async () => {
    const r = await K.run('(##webnb#kernel)');
    assert(r.done.status === 'error' && /already running/.test(r.done.error.text), J(r.done));
    await ok(K, '(+ 1 1)', ['2']);
  });

  await check('K18 UTF-8, NUL and JSON escapes survive', async () => {
    await ok(K, '"héllo ✓ 𝄞"', ['"héllo ✓ 𝄞"']);
    await ok(K, '(string #\\nul)', ['"\\x00;"']);
    await ok(K, '(string-length "a\u0000b")', ['3']);   // a NUL in the source
    const big = 'é✓𝄞';
    for (const n of [8190, 8191, 8192, 65534, 65535]) {
      const r = await ok(K, `(display (make-string ${n} #\\a)) (display "${big}") (display "\\x0;z")`);
      assert(r.out === 'a'.repeat(n) + big + '\u0000z', 'output across ' + n);
    }
    const raw = '"\\\n\t\r\u0001\u001f</script> ';
    const r = await ok(K, '(import notebook) (show (text (list->string (map integer->char \'(' +
                       [...raw].map(c => c.codePointAt(0)).join(' ') + ')))))', null);
    eq(r.displays.map(d => d.data), [raw], 'escapes round-trip');
    const e = await K.run('(error "a\\"b\\\\c\\nd\\te\\x1;")');
    eq(e.done.error.text, 'Error: a"b\\c\nd\te\u0001', 'error text');
  });

  await check('K19 toplevel commands ,d and ,x', async () => {
    let r = await ok(K, ",d 'x");
    assert(/symbol/.test(r.out), ',d: ' + r.out);
    r = await ok(K, ',x (when #t 1)');
    assert(/##core#if/.test(r.out), ',x: ' + r.out);
    r = await ok(K, ',x (unless #f 2) (+ 1 1)', ['2']);   // reads its argument from the cell
  });

  await check('K20 the notebook module: show, update in place, svg, text, html, clear', async () => {
    let r = await ok(K, '(import notebook) (show (html "<b>x</b>") "p") (show (html "<b>y</b>") "p") ' +
                     "(svg '(svg (circle (@ (r 5)))))", null);
    eq(r.displays.map(d => [d.mime, d.id, d.rid]),
       [['text/html', 'p', r.done.rid], ['text/html', 'p', r.done.rid], ['image/svg+xml', null, r.done.rid]], 'displays');
    eq(r.displays[1].data, '<b>y</b>', 'second');
    assert(/xmlns="http:\/\/www\.w3\.org\/2000\/svg"/.test(r.displays[2].data) && /r="5"/.test(r.displays[2].data),
           'svg ' + r.displays[2].data);
    const dIdx = K.items.findIndex(i => i.ev === r.displays[2]);
    assert(K.items[dIdx + 1].ev === r.done, 'the value display just before done');
    r = await ok(K, '(text "a<b")', null);
    eq(r.displays.map(d => [d.mime, d.data]), [['text/plain', 'a<b']], 'text');
    r = await ok(K, "(html '(p \"a<b\"))", null);
    eq(r.displays[0].data, '<p>a&lt;b</p>', 'html');
    r = await ok(K, "(html '(p (@ (title \"x\\\"<\") (hidden #t) (lang #f)) (*raw* \"<i>r</i>\") (br) 3 #\\&))", null);
    eq(r.displays[0].data, '<p title="x&quot;&lt;" hidden=""><i>r</i><br/>3&amp;</p>', 'attributes, raw, void');
    r = await ok(K, '(show "plain") (show 42) (clear-output) (list (html "x"))', ['(#<notebook-display text/html 1 chars>)']);
    eq(r.items.filter(i => i.ev).map(i => i.ev.ev), ['display', 'display', 'clear'], 'events');
    eq(r.displays.map(d => d.data), ['plain', '42'], 'show of a string and a datum');
    r = await ok(K, "(table '((1 \"one\") (2 \"<two>\")) '(\"n\" \"name\"))", null);
    eq(r.displays[0].data, '<table><thead><tr><th>n</th><th>name</th></tr></thead><tbody>' +
       '<tr><td>1</td><td>one</td></tr><tr><td>2</td><td>&lt;two&gt;</td></tr></tbody></table>', 'table');
    r = await ok(K, '(import (chicken bytevector)) (image (bytevector 1 2 3 4 255))', null);
    eq([r.displays[0].mime, r.displays[0].data], ['image/png', 'AQIDBP8='], 'image');
    r = await ok(K, "(show (svg \"<svg viewBox='0 0 1 1'></svg>\")) (display-object? (text \"\"))", ['#t']);
    assert(r.displays[0].data.startsWith('<svg xmlns="http://www.w3.org/2000/svg" viewBox'), r.displays[0].data);
    r = await K.run("(html '(bad<tag))");
    assert(r.done.status === 'error' && /invalid SXML element name/.test(r.done.error.text), J(r.done.error));
    r = await K.run("(html '(p (@ (onclick=\"x\" 1))))");
    assert(r.done.status === 'error' && /invalid SXML attribute/.test(r.done.error.text), J(r.done.error));
  });

  await check('K21 the unbound-variable notice goes to stderr inside the cell', async () => {
    const r = await ok(K, '(define (h) (undefined-thing))');
    assert(/referenced but unbound/.test(r.err) && /undefined-thing/.test(r.err), 'stderr: ' + r.err);
  });

  await check('K22 .csirc: loaded before hello, its error reported, cells run anyway', async () => {
    let X = await kernel({ csirc: '(define from-rc 7)\n' });
    let h = await waitFor('hello', () => X.find(e => e.ev === 'hello'), 30000);
    const rc = X.find(e => e.ev === 'csirc');
    assert(rc && rc.status === 'ok', 'csirc ok: ' + J(rc));
    assert(X.events().indexOf(rc) < X.events().indexOf(h), 'before hello');
    await ok(X, 'from-rc', ['7']);
    X.drv.post('run 99 In[99]\n(exit 0)');
    X = await kernel({ csirc: '(display "rc-out")\n(car 1)\n' });
    h = await waitFor('hello', () => X.find(e => e.ev === 'hello'), 30000);
    const bad = X.find(e => e.ev === 'csirc');
    assert(bad && bad.status === 'error' && /bad argument type/.test(bad.error.text), 'csirc error: ' + J(bad));
    assert(X.items.some(i => i.fd === 1 && /rc-out/.test(i.text)), 'its output');
    await ok(X, '(+ 1 1)', ['2']);
    X.drv.post('run 99 In[99]\n(exit 0)');
    current = K;
  });

  await check('K23 arch probe and deep recursion', async () => {
    const r = await ok(K, '(import (chicken platform)) (feature? #:64bit)');
    assert(arch === 'wasm32' || arch === 'wasm64', 'arch in index.html: ' + arch);
    eq(r.done.values, [arch === 'wasm32' ? '#f' : '#t'], 'arch ' + arch);
    await ok(K, '(define (f n) (if (= n 0) 0 (+ 1 (f (- n 1))))) (f 1000000)', ['1000000'], 60000);
  });

  await check('K24 an uploaded file is loaded with (load "u.scm")', async () => {
    const X = await kernel({ files: [{ path: '/home/web_user/u.scm',
                                       data: new TextEncoder().encode('(define up-val 99)\n') }] });
    await waitFor('hello', () => X.find(e => e.ev === 'hello'), 30000);
    const r = await ok(X, '(load "u.scm") up-val', ['99']);
    assert(/; loading u\.scm/.test(r.out), 'notice: ' + r.out);
    X.drv.post('run 99 In[99]\n(exit 0)');
    current = K;
  });

  await check('K25 kernel options: -R and -: pass, others are dropped', async () => {
    const X = await kernel({ argString: '-:s128k -R chicken.string -s nope.scm -b' });
    await waitFor('hello', () => { X.alive(); return X.find(e => e.ev === 'hello'); }, 30000);
    await ok(X, '(string-intersperse \'("x" "y") "+")', ['"x+y"']);
    X.drv.post('run 99 In[99]\n(exit 0)');
    current = K;
  });

  await check('K26 redefining library procedures the kernel uses does not break it', async () => {
    const X = await kernel();
    await waitFor('hello', () => { X.alive(); return X.find(e => e.ev === 'hello'); }, 30000);
    // names of the units' own (webio.scm, webnb.scm) are hidden
    let r = await ok(X, '(define web-stdout 0) (define flush-std 0) (define json 0) (display "x")');
    eq(r.out, 'x', 'stdout');
    // csi prints values with write: they are empty, as in csi
    await ok(X, '(define w write) (define (write . a) 0)');
    await ok(X, '(+ 1 2)', ['']);
    r = await X.run('(error "oops" 1 "two")');
    eq([r.done.status, r.done.error.text], ['error', 'Error: oops\n1\n"two"'], 'error');
    await ok(X, '(set! write w)');
    await ok(X, '(define (display x . p) (write x))\n(define (substring s a b) s)\n' +
                '(define (string->number . a) 0)\n(define (eval . a) 0)');
    // the buggy reverse of an exercise (last: the expander uses it, in csi too)
    await ok(X, "(define (reverse l) (if (null? l) '() (cons (reverse (cdr l)) (car l))))");
    await ok(X, '(+ 1 2)', ['3']);
    r = await X.run('(car 1)');
    eq([r.done.status, r.done.error.text, r.done.error.line], ['error', 'Error: (car) bad argument type: 1', 1], 'car');
    X.drv.post('run 99 In[99]\n(exit 0)');
    current = K;
  });

  await check('K27 a cell that closes a standard port: the ports work again in the next cell', async () => {
    await ok(K, '(import (scheme base)) (define k27 27)');
    let r = await ok(K, '(call-with-port (current-output-port) (lambda (p) (write "hi" p)))', null);
    eq(r.out, '"hi"', 'written before the close');
    r = await ok(K, '(display "again") k27', ['27']);
    eq(r.out, 'again', 'stdout again');
    r = await ok(K, '(close-output-port (current-error-port)) 1', ['1']);
    r = await ok(K, '(display k27 (current-error-port))');
    eq(r.err, '27', 'stderr again');
    // writing to it after the close, in the same cell, is an error, as natively
    r = await K.run('(close-output-port (current-output-port)) (display 5)');
    assert(r.done.status === 'error' && /port already closed/.test(r.done.error.text), 'closed: ' + J(r.done));
    await ok(K, '(display "ok")');
    // stdin as well
    let from = K.states.length;
    let rid = K.post('(import (chicken io)) (call-with-port (current-input-port) read-line)');
    await K.stateSeen(WAITING, from);
    K.drv.feed('hello\n');
    eq((await K.result(rid)).done.values, ['"hello"'], 'read-line through call-with-port');
    from = K.states.length;
    rid = K.post('(read-line)');
    await K.stateSeen(WAITING, from);
    K.drv.feed('again\n');
    eq((await K.result(rid)).done.values, ['"again"'], 'stdin again');
    r = await K.run('(close-input-port (current-input-port)) (read-char)');
    assert(r.done.status === 'error' && /port already closed/.test(r.done.error.text), 'stdin closed: ' + J(r.done));
    await ok(K, '(char-ready?)', ['#f']);
  });

  await check('K28 a write over 1 MB reaches JS in pieces; a display over 4 MB as its size only', async () => {
    K.maxChunk = 0;
    let r = await ok(K, '(display (make-string 3000000 #\\a)) (display "after") 1', ['1']);
    eq([r.out.length, r.out.slice(-7)], [3000005, 'aaafter'], 'stdout');
    assert(K.maxChunk <= 1 << 20, 'pieces of ' + K.maxChunk);
    // pieces end on a character: none is broken in two
    r = await ok(K, '(display (make-string 1500001 #\\x3bb)) 2', ['2']);
    assert(r.out.length === 1500001 && /^\u03bb+$/.test(r.out), 'lambdas: ' + r.out.length);
    r = await ok(K, '(import notebook) (show (make-string 4194305 #\\x)) (show (text "small")) ' +
                    '(text (make-string 4194304 #\\y))', null);
    eq(r.displays.map(d => [d.data.length, d.size]), [[0, 4194305], [5, undefined], [4194304, undefined]], 'displays');
  });

  await check('K29 a lazy stream as its elements arrive: open, items, end; Pause, Next, Go on and Stop', async () => {
    const lazy = r => r.items.filter(i => i.ev && /^lazy-/.test(i.ev.ev)).map(i => i.ev);
    const brief = e => e.ev === 'lazy-open' ? ['open', e.sid, e.parent]
      : e.ev === 'lazy-end' ? ['end', e.sid, e.how] : [e.mime, e.data, e.dot, e.sid];
    await ok(K, '(define (nats n) (delay (cons n (nats (+ n 1)))))', null);
    let r = await ok(K, '(import notebook) (delay (list 1 (delay (list 2 "a")) (delay 3) (html "<b>x</b>") (delay (quote ()))))', null);
    let ls = lazy(r);
    assert(ls.every(e => e.rid === r.done.rid), 'rids');
    const s1 = ls[0].sid, s2 = ls[2].sid, s3 = ls[8].sid;
    eq(ls.map(brief), [['open', s1, null], ['text/plain', '1', null, s1], ['open', s2, s1],
                       ['text/plain', '2', null, s2], ['text/plain', '"a"', null, s2], ['end', s2, 'end'],
                       ['text/plain', '#<promise 3>', null, s1], ['text/html', '<b>x</b>', null, s1],
                       ['open', s3, s1], ['end', s3, 'end'], ['end', s1, 'end']], 'events');
    // an improper stream among other values; a promise that is no stream
    r = await ok(K, '(values (delay (cons 1 (delay 2))) 7)', ['7']);
    eq(lazy(r).map(e => e.ev === 'lazy-item' ? [e.data, e.dot] : e.ev), ['lazy-open', ['1', null], ['2', true], 'lazy-end'], 'improper');
    await ok(K, '(delay 42)', ['#<promise 42>']);
    // an infinite one: paused, one more element, on again, then Stop
    const items = () => K.events().filter(e => e.ev === 'lazy-item' && e.rid === rid).length;
    const rid = K.post('(nats 0)');
    await waitFor('elements', () => items() > 3);
    K.drv.lazy(LAZY_PAUSE);
    await waitFor('PAUSED', () => K.drv.state() === PAUSED);
    const n0 = items();
    await sleep(200);
    eq(items(), n0, 'no element while paused');
    K.drv.lazy(LAZY_NEXT);
    await waitFor('the next element', () => items() === n0 + 1);
    await sleep(100);
    eq([items(), K.drv.state()], [n0 + 1, PAUSED], 'one element, paused again');
    K.drv.lazy(LAZY_GO);
    await waitFor('elements again', () => items() > n0 + 100);
    K.drv.interrupt();
    r = await K.result(rid);
    eq([r.done.status, r.done.values], ['ok', null], 'Stop ends it as ok');
    ls = lazy(r);
    eq(brief(ls[ls.length - 1]).slice(0, 1).concat(ls[ls.length - 1].how), ['end', 'stopped'], 'stopped');
    eq(ls.slice(1, -1).map(e => e.data), ls.slice(1, -1).map((e, i) => String(i)), 'the elements in order');
    // an error while forcing one: the cell fails, the stream stays open
    r = await K.run('(delay (cons 1 (delay (car (quote ())))))');
    eq([r.done.status, r.done.error.form], ['error', 'print'], 'error');
    eq(lazy(r).map(e => e.ev), ['lazy-open', 'lazy-item'], 'no lazy-end');
    await ok(K, '(+ 1 2)', ['3']);
  });

  // ---- KJ: the JavaScript bridge (webjs.scm) in cells

  await check('KJ1 JavaScript values in cells', async () => {
    await ok(K, '(import js)', null);
    await ok(K, '(js-call (js-global "Math.max") 1 2)', ['2']);
    await ok(K, '(js-global "Math")', ['#<js-object Math>']);
    await ok(K, '(js-eval "undefined")', null);
    await ok(K, 'js-null', ['#<js-null>']);
    await ok(K, '(js->list (js-invoke (js-eval "[1,2,3]") "map" (lambda (x) (* x x))))', ['(1 4 9)']);
  });

  await check('KJ2 errors of JavaScript, and of Scheme across it', async () => {
    let r = await K.run('(js-eval "null.x")');
    assert(r.done.status === 'error' && /^Error: \(js-eval\) TypeError:/.test(r.done.error.text), J(r.done));
    eq(r.done.error.kind, ['exn', 'js'], 'kind');
    r = await K.run('(js-call (js-eval "f => f()") (lambda () (error "bad" 42)))');
    assert(r.done.status === 'error' && /bad/.test(r.done.error.text) && /42/.test(r.done.error.text), J(r.done));
    eq(r.done.error.kind, ['exn'], 'the original condition');
    await ok(K, '(+ 1 2)', ['3']);
  });

  await check('KJ3 js-await in a cell; Stop interrupts it', async () => {
    const s0 = K.states.length;
    await ok(K, '(js-await (js-eval "new Promise(r => setTimeout(() => r(7), 100))"))', ['7']);
    assert(K.states.slice(s0).includes(AWAITING), 'AWAITING: ' + K.states.slice(s0));
    const s1 = K.states.length;
    const rid = K.post('(js-await (js-eval "new Promise(() => {})"))');
    await K.stateSeen(AWAITING, s1);
    K.drv.interrupt();
    const r = await K.result(rid, 5000);
    eq(r.done.status, 'interrupted', 'status');
    await ok(K, '(+ 1 2)', ['3']);
    eq(K.drv.module.webjs.stats().awaits, 0, 'no slot left');
  });

  // the items after the done of R, up to the async-done of its rid
  const afterDone = (s, r) => {
    const i = s.items.findIndex(x => x.ev === r.done);
    const rest = s.items.slice(i + 1);
    const j = rest.findIndex(x => x.ev && x.ev.ev === 'async-done' && x.ev.rid === r.done.rid);
    return j < 0 ? null : rest.slice(0, j + 1);
  };
  const brief = it => it.ev ? it.ev.ev + ':' + it.ev.rid + (it.ev.status ? ':' + it.ev.status : '') : it.fd + ':' + it.text;

  await check('KJ4 calls from JavaScript while the kernel is idle are framed as their cell\'s', async () => {
    let r = await ok(K, '(begin (js-call (js-eval "f => setTimeout(f, 30)") (lambda () (display "late\\n"))) (void))', null);
    let a = await waitFor('async-done', () => afterDone(K, r), 2000);
    const rid = r.done.rid;
    eq(a.map(brief), ['async-start:' + rid, '1:late\n', 'async-done:' + rid + ':ok'], 'framed');
    await K.idle();
    r = await ok(K, "(begin (js-call (js-eval \"f => setTimeout(f, 10)\") (lambda () (car '()))) (void))", null);
    a = await waitFor('async-done', () => afterDone(K, r), 2000);
    const done = a[a.length - 1].ev;
    assert(done.status === 'error' && /\(car\) bad argument type/.test(done.error.text), 'error: ' + J(done));
    assert(!a.some(x => x.fd === 2), 'nothing on stderr: ' + J(a));
    await ok(K, '(+ 1 2)', ['3']);
  });

  await check('KJ5 calls from JavaScript inside a cell\'s js-await write in the cell', async () => {
    const r = await ok(K, '(begin (js-call (js-eval "f => setTimeout(() => f(\'x\'), 10)") (lambda (s) (display s))) ' +
                          '(js-await (js-eval "new Promise(r => setTimeout(r, 50))")) \'ok)', ['ok']);
    eq(r.out, 'x', 'out');
  });

  await check('KJ6 requests go before the calls from JavaScript', async () => {
    await ok(K, "(define kj6 '())", null);
    const r1 = K.post('(do ((i 0 (+ i 1))) ((= i 20)) (js-call (js-eval "f => setTimeout(f, 0)") ' +
                      "(lambda () (set! kj6 (cons i kj6)))))");
    const r2 = K.post('(length kj6)');
    eq((await K.result(r1)).done.status, 'ok', 'cell 1');
    eq((await K.result(r2)).done.status, 'ok', 'cell 2');
    // the calls run once the kernel is idle again
    let n = null;
    for (let t = now(); now() - t < 2000 && J(n) !== '["20"]'; await sleep(20))
      n = (await ok(K, '(length kj6)')).done.values;
    eq(n, ['20'], 'all ran');
  });

  await check('KJ7 redefining the exports and library procedures', async () => {
    const X = await kernel();
    await waitFor('hello', () => { X.alive(); return X.find(e => e.ev === 'hello'); }, 30000);
    await ok(X, '(import js)', null);
    await ok(X, "(define (js-call . x) 'clobbered)", null);
    await ok(X, '(js-invoke (js-eval "[1,2]") "join" "-")', ['"1-2"']);
    await ok(X, "(define (apply . x) 'x) (define (list? x) #f) (define (reverse x) x)", null);
    await ok(X, "(js->list (list->js '(1 2)))", ['(1 2)']);
    await ok(X, '(js-await (js-eval "Promise.resolve(1)"))', ['1']);
    X.drv.post('run 99 In[99]\n(exit 0)');
    current = K;
  });

  await check('KJ8 unbounded recursion between Scheme and JavaScript is an error', async () => {
    await ok(K, '(define bounce (js-eval "(f, n) => f(n)")) (define (down n) (js-call bounce down (+ n 1)))', null);
    const r = await K.run('(down 0)', 20000);
    assert(r.done.status === 'error' &&
           /RangeError: too many nested calls between Scheme and JavaScript/.test(r.done.error.text), J(r.done));
    await ok(K, '(+ 1 2)', ['3']);
    eq(K.drv.module.webjs.stats().depth, 0, 'no op left');
  });

  await check('KJ9 exit inside a call from JavaScript ends the kernel without done', async () => {
    const X = await kernel();
    await waitFor('hello', () => X.find(e => e.ev === 'hello'), 30000);
    const n = X.events().length;
    X.post('(import js) (js-call (js-eval "f => { try { f() } catch (e) {} }") (lambda () (exit 3)))');
    await waitFor('exit', () => { if (X.crash) throw new Error('crash: ' + X.crash); return X.exit !== null; }, 10000);
    eq(X.exit, 3, 'exit code');
    assert(!X.events().slice(n).some(e => e.ev === 'done'), 'no done');
    current = K;
  });

  await check('KJ10 reading stdin inside a call from JavaScript is an error', async () => {
    const r = await K.run('(import (chicken io)) (js-call (js-eval "f => f()") (lambda () (read-line)))', 5000);
    assert(r.done.status === 'error' &&
           /cannot read standard input inside a call from JavaScript/.test(r.done.error.text), J(r.done));
    await ok(K, '(+ 1 2)', ['3']);
  });

  // ---- N-JS: JavaScript cells (js requests, webjs.scm's run-js)

  // the worker's `scheme' and console, in this realm (no repl-worker.js);
  // and its setTimeout, which keeps the cell a function comes from, as
  // attributedTimeout (this realm's setTimeout is the harness's own)
  globalThis.scheme = K.drv.module.webjs.scheme;
  globalThis.attributedTimeout = (f, ms) => setTimeout(K.drv.module.webjs.attribute(f), ms);
  const withConsole = async f => {
    const log = console.log, b = K.drv.module.webjs;
    console.log = (...a) => b.console(1, a);
    try { await f(); } finally { console.log = log; }
  };

  await check('N-JS1 values as JavaScript shows them', async () => {
    await okJs(K, '1 + 2', ['3']);
    await okJs(K, "'ab'", ['"ab"']);
    await okJs(K, 'undefined', null);
    await okJs(K, 'null', ['null']);
    await okJs(K, "[1, 'x', {a: 1, b: [2, 3]}]", ['[1, "x", {a: 1, b: [2, 3]}]']);
    await okJs(K, '-0', ['-0']);
    await okJs(K, '10n', ['10n']);
    await okJs(K, '(function f() {})', ['[Function f]']);
    await okJs(K, 'new (class P { constructor() { this.x = 1 } })', ['P {x: 1}']);
    const r = await okJs(K, 'const o1 = {}; o1.o = o1; o1');
    assert(/\[Circular\]/.test(r.done.values[0]), 'circular: ' + J(r.done.values));
    await okJs(K, "new Map([[1, 'a']])", ['Map(1) {1 => "a"}']);
    await okJs(K, "scheme.eval('(list 1 \"a\")')", ['(1 "a")']);
  });

  await check('N-JS2 top-level declarations persist across cells, block-scoped ones do not', async () => {
    const src = 'const a2 = 1; let b2 = 2; class C2 {}; function f2() { return a2 + b2 }';
    await okJs(K, src, null);
    await okJs(K, '[a2, b2, typeof C2, f2()]', ['[1, 2, "function", 3]']);
    await okJs(K, src, null);
    await okJs(K, 'for (let i2 = 0; i2 < 2; i2++) {}', null);
    await okJs(K, 'typeof i2', ['"undefined"']);
    await okJs(K, '{ let z2 = 1 }', null);
    await okJs(K, 'typeof z2', ['"undefined"']);
    await okJs(K, "'use strict'; var us2 = 1");
    await okJs(K, 'typeof us2', ['"undefined"']);
  });

  await check('N-JS3 top-level await is a helpful SyntaxError', async () => {
    const r = await K.runJs('const x3 = await Promise.resolve(1)');
    assert(r.done.status === 'error' && /top level of a JavaScript cell/.test(r.done.error.text), J(r.done));
  });

  await check('N-JS4 an incomplete cell is incomplete and defines nothing', async () => {
    for (const [src, name] of [['function nf4() {', 'nf4'], ["var s4 = 'abc", 's4'], ['var t4 = `x ${', 't4']]) {
      const r = await K.runJs(src);
      eq(r.done.status, 'incomplete', src);
      await okJs(K, 'typeof ' + name, ['"undefined"']);
    }
  });

  await check('N-JS5 errors: text, kind, line and the frames of the cell', async () => {
    let r = await K.runJs("function g5() {\n  throw new TypeError('bad')\n}\ng5()");
    const e = r.done.error, rid = r.done.rid;
    eq([r.done.status, e.text, e.kind, e.line], ['error', 'Error: TypeError: bad', ['exn', 'js'], 2], 'error');
    eq(e.chain[e.chain.length - 1], { where: 'In[' + rid + ']:2', proc: 'g5', form: null }, 'the innermost frame');
    assert(e.chain.slice(0, -1).some(f => f.where === 'In[' + rid + ']:4'), 'the cell\'s frame: ' + J(e.chain));
    r = await K.runJs('null.x');
    assert(r.done.status === 'error' && /^Error: TypeError:/.test(r.done.error.text), J(r.done));
  });

  await check('N-JS6 a promise is waited for (AWAITING); a rejection is an error; Stop', async () => {
    const s0 = K.states.length;
    await okJs(K, 'new Promise(r => setTimeout(() => r(5), 50))', ['5']);
    assert(K.states.slice(s0).includes(AWAITING), 'AWAITING: ' + K.states.slice(s0));
    let r = await K.runJs("Promise.reject(new Error('no'))");
    eq([r.done.status, r.done.error.text], ['error', 'Error: Error: no'], 'rejected');
    const s1 = K.states.length;
    const rid = K.postJs('new Promise(() => {})');
    await K.stateSeen(AWAITING, s1);
    K.drv.interrupt();
    r = await K.result(rid, 5000);
    eq(r.done.status, 'interrupted', 'interrupted');
    await okJs(K, '1', ['1']);
    eq(K.drv.module.webjs.stats().awaits, 0, 'no slot left');
  });

  await check('N-JS7 the console and Scheme write in order', async () => {
    await ok(K, '(define (say s) (display s))', null);
    await withConsole(async () => {
      const r = await okJs(K, "console.log('a'); scheme.call('say', 'b'); console.log('c')", null);
      eq(r.out, 'a\nbc\n', 'out');
    });
  });

  await check('N-JS8 scheme.env and scheme.eval', async () => {
    await ok(K, '(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))', null);
    await okJs(K, 'scheme.env.fact(5)', ['120']);
    await okJs(K, 'typeof scheme.env.map', ['"function"']);
    await okJs(K, "scheme.env['string-append']('a', 'b')", ['"ab"']);
    await okJs(K, 'scheme.env.nosuch', null);
    await okJs(K, 'scheme.env.jsx = 42; 1', ['1']);
    await ok(K, 'jsx', ['42']);
    await okJs(K, 'scheme.env.jsdouble = x => x * 2; 1', ['1']);
    await ok(K, '(jsdouble 21)', ['42']);
    await okJs(K, 'scheme.eval("(map (lambda (x) (* x x)) \'(1 2 3))")', ['(1 4 9)']);
    await okJs(K, 'scheme.toArray(scheme.eval("\'(1 2)"))', ['[1, 2]']);
    await okJs(K, "scheme.toArray(scheme.eval(\"'(1 (2 3))\"), true)", ['[1, [2, 3]]']);
    await okJs(K, 'Promise.resolve(scheme.env).then(e => e === scheme.env)', ['true']);
    await okJs(K, '`${scheme.env}`', ['"[object SchemeEnvironment]"']);
    await okJs(K, "'fact' in scheme.env && !('nosuch' in scheme.env)", ['true']);
    const r = await K.runJs("scheme.eval('(car 1)')");
    assert(r.done.status === 'error' && /\(car\) bad argument type/.test(r.done.error.text), J(r.done));
  });

  await check('N-JS9 Scheme from a timer gives a promise; scheme.async', async () => {
    await okJs(K, "new Promise(r => setTimeout(() => r(scheme.call('fact', 5) instanceof Promise), 10))", ['true']);
    const r = await okJs(K, 'new Promise(r => setTimeout(() => { try { scheme.env.fact } catch (e) { r(e.message) } }, 10))');
    assert(/use scheme\.call/.test(r.done.values[0]), 'message: ' + J(r.done.values));
    await ok(K, '(import js) (define (slow x) (js-await (js-eval "new Promise(r => setTimeout(r, 20))")) (* x 2))', null);
    await okJs(K, "scheme.async('slow')(21)", ['42']);
    await okJs(K, 'scheme.async(scheme.env.slow)(4)', ['8']);
    const e = await K.runJs('scheme.env.slow(21)');
    assert(e.done.status === 'error' && /cannot wait inside a call from JavaScript/.test(e.done.error.text), J(e.done));
    const t = await K.runJs('scheme.async(1)');
    assert(t.done.status === 'error' && /not a Scheme procedure or name/.test(t.done.error.text), J(t.done));
  });

  await check('N-JS10 rich output from JavaScript', async () => {
    let r = await okJs(K, "scheme.html('<b>x</b>')", null);
    eq(r.displays.map(d => [d.mime, d.data]), [['text/html', '<b>x</b>']], 'html');
    r = await okJs(K, "scheme.show('hi'); scheme.show(scheme.svg('<svg></svg>')); 1", ['1']);
    eq(r.displays.map(d => d.mime), ['text/plain', 'image/svg+xml'], 'show');
    eq(r.displays[0].data, 'hi', 'text');
    r = await okJs(K, "scheme.table([[1, 2]], ['a', 'b'])", null);
    assert(r.displays.length === 1 && r.displays[0].mime === 'text/html' && /<table>/.test(r.displays[0].data),
           'table: ' + J(r.displays));
    r = await okJs(K, 'scheme.show({k: [1]}); scheme.text(new Set([1]))', null);
    eq(r.displays.map(d => d.data), ['{k: [1]}', 'Set(1) {1}'], 'JavaScript values as text');
  });

  await check('N-JS11 a Scheme procedure a JavaScript cell gave a timer runs framed as that cell\'s', async () => {
    let r = await okJs(K, 'setTimeout(scheme.eval(\'(lambda () (display "late\\\\n"))\'), 30); 1', ['1']);
    const rid = r.done.rid;
    let a = await waitFor('async-done', () => afterDone(K, r), 2000);
    eq(a.map(brief), ['async-start:' + rid, '1:late\n', 'async-done:' + rid + ':ok'], 'framed');
    assert(!a.some(x => x.ev && x.ev.ev === 'start'), 'no start');
    r = await okJs(K, "setTimeout(scheme.eval(\"(lambda () (car '()))\"), 10); 1", ['1']);
    a = await waitFor('async-done', () => afterDone(K, r), 2000);
    const done = a[a.length - 1].ev;
    assert(done.status === 'error' && /\(car\) bad argument type/.test(done.error.text), 'error: ' + J(done));
    assert(!a.some(x => x.fd === 2 && /Error in a call from JavaScript/.test(x.text)), 'not on stderr: ' + J(a));
  });

  await check('N-JS12 a callback of a cell inside another cell\'s js-await', async () => {
    const ra = await ok(K, '(begin (js-call (js-eval "f => attributedTimeout(f, 20)") (lambda () (display "a"))) (void))', null);
    const r = await ok(K, '(begin (display "b1") (js-await (js-eval "new Promise(r => setTimeout(r, 100))")) (display "b2"))');
    const a = ra.done.rid;
    // the timer's frame (JavaScript's, which queues the call), then the call's
    eq(r.items.map(brief), ['1:b1', 'async-start:' + a, 'async-done:' + a + ':ok',
                            'async-start:' + a, '1:a', 'async-done:' + a + ':ok', '1:b2'], 'between start and done');
    assert(/b1/.test(r.out) && /b2/.test(r.out), 'out ' + J(r.out));
  });

  await check('N-JS13 a callback that loops while the kernel is idle: Stop interrupts it', async () => {
    const r = await ok(K, '(begin (js-call (js-eval "f => setTimeout(f, 20)") (lambda () (let loop () (loop)))) (void))', null);
    const rid = r.done.rid;
    await waitFor('async-start', () => K.find(e => e.ev === 'async-start' && e.rid === rid), 2000);
    const s0 = K.states.length;
    await K.stateSeen(BUSY, s0);
    K.drv.interrupt();
    const done = await waitFor('async-done', () => K.find(e => e.ev === 'async-done' && e.rid === rid), 5000);
    eq(done.status, 'interrupted', 'status');
    await ok(K, '(+ 1 2)', ['3']);
  });

  await check('N-JS14 bad js requests', async () => {
    for (const bad of ['js 1 bad name\n1', 'js x In[1]\n1', 'js 7 In[7]']) {
      const n = K.events().length;
      K.drv.post(bad);
      await waitFor('bad-request', () => K.events().slice(n).find(e => e.ev === 'bad-request'));
    }
    await okJs(K, '2 * 3', ['6']);
  });

  await check('N-JS15 the frames of a JavaScript error in a Scheme cell', async () => {
    const t = await okJs(K, "function thrower() { throw new Error('t') }", null);
    const r = await K.run('(import js) (js-call (js-global "thrower"))');
    eq(r.done.status, 'error', 'status');
    const last = r.done.error.chain[r.done.error.chain.length - 1];
    eq([last.where, last.proc], ['In[' + t.done.rid + ']:1', 'thrower'], 'the innermost frame');
  });
}

async function eggs() {
  await check('E (eggs build) an egg in a notebook cell', async () => {
    const X = await kernel();
    await waitFor('hello', () => { X.alive(); return X.find(e => e.ev === 'hello'); }, 30000);
    await ok(X, '(import wasm-egg-b) (egg-b-report)', ['(10 18 42 42 2 1)']);
  });
}


// the files of the package's build for the modules tested, under
// /packages (see worker-harness.js)
function packageFiles(dir) {
  const entry = (pageMeta(pageHtml, 'chicken-wasm-builds') || '').split(/\s+/)
    .map(w => w.split(':')).find(f => f[0] === arch);
  if (!entry || !entry[2]) throw new Error('the page lists no ABI for ' + arch);
  const { readPackage } = require(path.join(__dirname, '..', '..', 'emscripten', 'wasm-package.js'));
  return readPackage(dir, { abi: entry[2] }).files.map(f => ({ path: '/packages/' + f.path, data: f.data }));
}

async function packages() {
  const files = packageFiles(packageDir);
  const report = ['(10 18 42 42 2 1)'];
  await check('PK1 (package) the package in the kernel\'s files, imported in a cell', async () => {
    const X = await kernel({ files });
    await waitFor('hello', () => { X.alive(); return X.find(e => e.ev === 'hello'); }, 30000);
    await ok(X, '(import wasm-egg-b) (egg-b-report)', report);
    await ok(X, '(import wasm-egg-a (chicken gc)) (length (egg-a-walk (lambda (i v) (when (= i 500) (gc #t)) ' +
                '(make-string 100 #\\x)) 100000))', ['100000']);
    await ok(X, '(call-with-current-continuation (lambda (k) (egg-a-walk (lambda (i v) ' +
                '(if (= i 500) (k (quote escaped)) i)) 1000)))', ['escaped']);
    await ok(X, '(include "wasm-egg-a-shared.scm") egg-a-shared-value', ['7']);
    // an exit out of Scheme called back from C: the kernel still waits
    // for (yields until) its next request
    const r = await X.run("(egg-a-call (lambda () (car '())))");
    assert(r.done.status === 'error' && /bad argument type/.test(r.done.error.text), 'error: ' + J(r.done));
    await ok(X, '(egg-a-call (lambda () 42))', ['42']);
  });
  await check('PC1 (package) nb-kernel.js: files() before start, then after a restart', async () => {
    const C = client({ files: () => files });
    try {
      await C.k.start();
      let d = await C.k.run('a', '(import wasm-egg-b) (egg-b-report)');
      assert(d.status === 'ok', 'status ' + d.status + ' ' + J(d.error));
      eq(d.values, report, 'values');
      await C.k.restart();
      d = await C.k.run('b', '(import wasm-egg-b) (egg-b-report)');
      assert(d.status === 'ok', 'after restart: status ' + d.status + ' ' + J(d.error));
      eq(d.values, report, 'values after restart');
    } finally { C.k.dispose(); }
  });
  await check('PC2 (package) nb-kernel.js: writeFiles into a running kernel', async () => {
    const C = client();
    try {
      await C.k.start();
      C.k.writeFiles(files);
      const d = await C.k.run('a', '(import wasm-egg-b) (egg-b-report)');
      assert(d.status === 'ok', 'status ' + d.status + ' ' + J(d.error));
      eq(d.values, report, 'values');
    } finally { C.k.dispose(); }
  });
}


// ---- Part C: nb-kernel.js against the real repl-worker.js

const prelude = `
  'use strict';
  const { parentPort, workerData } = require('worker_threads');
  const fs = require('fs'), path = require('path'), vm = require('vm');
  const dir = workerData.dir;
  globalThis.self = globalThis;
  self.location = { search: workerData.sub ? '?dir=' + encodeURIComponent(workerData.sub) : '' };
  globalThis.require = require;
  delete globalThis.module;
  delete globalThis.exports;
  globalThis.__dirname = path.join(dir, workerData.sub);
  globalThis.onmessage = null;
  globalThis.importScripts = (...files) => files.forEach(p =>
    vm.runInThisContext(fs.readFileSync(path.join(dir, p.split('?')[0]), 'utf8'), { filename: p }));
  globalThis.postMessage = m => parentPort.postMessage(m);
  // the worker's message, error and unhandledrejection events, which
  // repl-worker.js listens to (the page's messages, and what user
  // JavaScript leaves uncaught), and dispatchEvent, whose events are
  // not isTrusted (Node's Event); every exception left uncaught is also
  // told to the harness ('__uncaught'), which only the cases that
  // expect one allow
  const listeners = {};
  globalThis.addEventListener = (t, f) => { (listeners[t] = listeners[t] || []).push(f); };
  const fire = (t, ev) => {
    const l = listeners[t] || [];
    for (const f of l) { f(ev); if (ev.stopped) break; }
    return l.length > 0;
  };
  globalThis.dispatchEvent = ev => { fire(ev.type, ev); return true; };
  const uncaught = (what, x) => parentPort.postMessage({ type: '__uncaught', message: what + String((x && x.stack) || x) });
  process.on('uncaughtException', e => {
    uncaught('', e);
    if (!fire('error', { error: e, message: String((e && e.message) || e), preventDefault() {} })) throw e;
  });
  process.on('unhandledRejection', r => {
    uncaught('(in promise) ', r);
    fire('unhandledrejection', { reason: r, preventDefault() {} });
  });
  globalThis.MessageChannel = class {
    constructor() {
      const port1 = { onmessage: null };
      this.port1 = port1;
      this.port2 = { postMessage: d => setImmediate(() => port1.onmessage && port1.onmessage({ data: d })) };
    }
  };
  // (a listener that stops its propagation is the last to get it)
  parentPort.on('message', d => fire('message', { data: d, stopImmediatePropagation() { this.stopped = true; } }));
  importScripts('repl-worker.js');
`;

let workers = 0;
function createWorker() {
  const w = new Worker(prelude, { eval: true, workerData: { dir: webDir, sub }, resourceLimits: { stackSizeMb: 1 } });
  workers++;
  const shim = {
    onmessage: null, onerror: null,
    postMessage: m => w.postMessage(m),
    terminate: () => { w.terminate(); },
  };
  w.on('message', d => {
    if (d && d.type === '__uncaught') uncaught.push(d.message);
    else if (shim.onmessage) shim.onmessage({ data: d });
  });
  w.on('error', e => shim.onerror && shim.onerror({ message: String(e) }));
  return shim;
}

function client(extra = {}) {
  const c = { cells: {}, states: [], cb: [], logs: [], all: [] };
  c.k = Kernel.create(Object.assign({
    createWorker,
    getModule: () => Promise.resolve(wasmModule),
    args: () => '',
    csirc: () => null,
    files: () => [],
    sliceMs: () => 50,
    schedule: f => setImmediate(f),
    onCell: (id, ev) => { (c.cells[id] = c.cells[id] || []).push(ev); c.all.push([id, ev]); },
    onState: (st, info) => { c.states.push(st); c.cb.push([st, info.callback]); },
    onLog: (kind, text) => c.logs.push([kind, text]),
  }, extra));
  c.types = id => (c.cells[id] || []).map(e => e.type);
  c.stream = id => (c.cells[id] || []).filter(e => e.type === 'stream').map(e => e.text).join('');
  // what callbacks attributed to cell ID gave it
  c.async = id => (c.cells[id] || []).filter(e => e.type === 'async' || e.async === true);
  c.tail = () => J({ states: c.states.slice(-6), logs: c.logs.slice(-4), all: c.all.slice(-4) }).slice(-1500);
  current = c;
  return c;
}

async function partC() {
  let C;

  await check('C1 start() resolves on hello: starting, then idle', async () => {
    C = client();
    eq(C.k.state, 'off', 'off at first');
    await C.k.start();
    eq(C.states, ['starting', 'idle'], 'states');
    assert(C.k.info && C.k.info.proto === 1, 'info ' + J(C.k.info));
  });

  await check('C2 run gives queued, start, done; the promise resolves with done', async () => {
    const d = await C.k.run('a', '(+ 1 2)');
    eq(C.types('a'), ['queued', 'start', 'done'], 'events');
    eq(C.cells.a[1], { type: 'start', count: 1, name: 'In[1]' }, 'start');
    assert(d === C.cells.a[2] && d.status === 'ok', 'resolved with done');
    eq(d.values, ['3'], 'values');
    eq(d.count, 1, 'count');
    assert(typeof d.wallMs === 'number' && typeof d.ms === 'number', 'times');
    eq(C.k.state, 'idle', 'idle');
  });

  await check('C3 runMany: stop on error cancels the rest', async () => {
    const r = await C.k.runMany([{ cellId: 'm1', source: '(print "one") 1' },
                                 { cellId: 'm2', source: '(car 1)' },
                                 { cellId: 'm3', source: '3' }]);
    eq(r.map(e => e.status || e.reason), ['ok', 'error', 'previous cell failed'], 'outcomes');
    eq(C.stream('m1'), 'one\n', 'stream');
    eq(C.types('m3'), ['queued', 'cancelled'], 'm3 events');
    eq(C.k.execCount, 3, 'counter');
    // a cell that calls reset did not fail
    const t = await C.k.runMany([{ cellId: 'm4', source: '(import (chicken repl)) (reset)' },
                                 { cellId: 'm5', source: '(+ 1 2)' }]);
    eq(t.map(e => e.status || e.reason), ['reset', 'ok'], 'reset outcomes');
  });

  await check('C4 stop() interrupts the running cell and cancels the queue', async () => {
    const p = C.k.run('loop', '(let loop () (loop))');
    const q = C.k.run('after', '1');
    await waitFor('busy', () => C.k.current === 'loop' && C.k.state === 'busy');
    await sleep(100);
    C.k.stop();
    const d = await p;
    eq(d.status, 'interrupted', 'interrupted');
    eq((await q).reason, 'stopped', 'queued cancelled');
    eq((await C.k.run('next', '(* 2 21)')).values, ['42'], 'next cell');
  });

  await check('C5 watchdog: an unresponsive Stop kills and respawns the kernel', async () => {
    const W = client({ watchdogMs: 1000 });
    await W.k.run('d', '(define small 1)');
    const before = workers;
    const p = W.k.run('big', '(define big (expt 7 6000000))');
    await waitFor('busy', () => W.k.state === 'busy');
    await sleep(200);
    const t = now();
    W.k.stop();
    const d = await p;
    eq([d.status, d.reason], ['killed', 'unresponsive'], 'killed');
    assert(fired(t)[0], 'after watchdogMs: ' + fired(t)[1]);
    assert(W.logs.some(([k, t]) => k === 'kernel' && /did not respond/.test(t)), 'kernel log');
    const r = await W.k.run('after', 'big');
    assert(r.status === 'error' && /unbound variable: big/.test(r.error.text), 'big unbound: ' + J(r));
    eq(r.count, 1, 'counter restarted');
    assert(workers === before + 1, 'one respawn');
    W.k.dispose();
    current = C;
  });

  await check('C6 restart() kills the running cell; the counter restarts', async () => {
    const p = C.k.run('r1', '(let loop () (loop))');
    const q = C.k.run('r2', '1');
    await waitFor('busy', () => C.k.current === 'r1');
    await C.k.restart();
    eq([(await p).status, (await p).reason], ['killed', 'restart'], 'killed');
    eq((await q).reason, 'restart', 'queue cancelled');
    eq(C.k.execCount, 0, 'counter reset');
    const d = await C.k.run('r3', '(define nb 1) nb');
    eq([d.count, d.values], [1, ['1']], 'fresh kernel');
  });

  await check('C7 input: waiting, then the text fed ends it', async () => {
    const p = C.k.run('in', '(import (chicken io)) (read-line)');
    await waitFor('input', () => (C.cells.in || []).some(e => e.type === 'input' && e.waiting));
    eq(C.k.state, 'input', 'state input');
    C.k.input('x\n');
    const d = await p;
    eq(d.values, ['"x"'], 'value');
    const t = C.types('in');
    assert(t.indexOf('input') < t.lastIndexOf('input') && t[t.length - 1] === 'done', 'input true, input false, done: ' + J(t));
    eq(C.cells.in.filter(e => e.type === 'input').map(e => e.waiting), [true, false], 'waiting flags');
    C.k.input('ignored\n');                  // not waiting: ignored
    eq((await C.k.run('in2', '(+ 1 1)')).values, ['2'], 'next');
  });

  await check('C8 (exit 2): done exited, state dead; the next run respawns', async () => {
    const d = await C.k.run('ex', '(exit 2)');
    eq([d.status, d.code], ['exited', 2], 'exited');
    eq(C.k.state, 'dead', 'dead');
    const r = await C.k.run('again', '(+ 1 2)');
    eq(r.values, ['3'], 'respawned');
    assert(C.logs.some(([k, t]) => k === 'kernel' && t === 'kernel restarted'), 'logged ' + J(C.logs));
  });

  await check('C9 an output flood with batched acks: complete, ordered, done last', async () => {
    const d = await C.k.run('flood', '(do ((i 0 (+ i 1))) ((= i 200000)) (print i))');
    eq(d.status, 'ok', 'status');
    const s = C.stream('flood');
    let expect = '';
    for (let i = 0; i < 200000; i++) expect += i + '\n';
    assert(s === expect, 'all lines in order (' + s.length + ' of ' + expect.length + ')');
    eq(C.types('flood').slice(-1), ['done'], 'done last');
  });

  await check('C10 kernelArgs keeps only what the kernel can use', async () => {
    eq(Kernel.kernelArgs('-:s128k -R srfi-1 -e x -b -s y -n foo.scm -no-symbol-escape'),
       ['-:s128k', '-R', 'srfi-1', '-n', '-e', '(##webnb#kernel)'], 'kernelArgs');
    eq(Kernel.kernelArgs(''), ['-n', '-e', '(##webnb#kernel)'], 'empty');
    eq(Kernel.kernelArgs('  -w -K prefix -I /x -R -e -: '),
       ['-:', '-w', '-K', 'prefix', '-I', '/x', '-n', '-e', '(##webnb#kernel)'], 'mixed');
  });

  await check('C11 rich output and stderr reach the cell; cancel() removes queued cells', async () => {
    const p = C.k.run('slow', '(import notebook) (display "o") (display "e" (current-error-port)) (show (html "<i>h</i>") "id1") (clear-output) (sleep 1) 5');
    const q = C.k.run('gone', '1');
    C.k.cancel('gone');
    eq((await q).reason, 'removed', 'removed');
    const d = await p;
    eq(d.values, ['5'], 'value');
    eq(C.cells.slow.map(e => e.type), ['queued', 'start', 'stream', 'stream', 'display', 'clear', 'done'], 'events');
    eq(C.cells.slow[4], { type: 'display', mime: 'text/html', data: '<i>h</i>', id: 'id1' }, 'display');
    eq(C.cells.slow.slice(2, 4).map(e => e.name + ':' + e.text), ['stdout:o', 'stderr:e'], 'streams');
    assert(C.states.includes('sleeping'), 'sleeping seen');
  });

  await check('C11b a display too large to send has its size', async () => {
    const d = await C.k.run('big', '(import notebook) (show (svg (make-string 5000000 #\\x))) 1');
    eq(d.values, ['1'], 'value');
    eq(C.cells.big.filter(e => e.type === 'display'), [{ type: 'display', mime: 'image/svg+xml', data: '', id: null, size: 5000000 }], 'display');
  });

  await check('C12 .csirc and uploads through the client; the startup log', async () => {
    const U = client({ csirc: () => '(display "from rc")\n(define rc 1)\n' +
                                     '(import notebook) (show "rc show") (show (html "<b>x</b>"))\n',
                       files: () => [{ path: '/home/web_user/up.scm', data: new TextEncoder().encode('(define up 2)') }] });
    const d = await U.k.run('u', '(load "up.scm") (+ rc up)');
    eq(d.values, ['3'], 'values');
    assert(U.logs.some(([k, t]) => k === 'csirc' && t === '~/.csirc loaded'), 'csirc log ' + J(U.logs));
    assert(U.logs.some(([k, t]) => k === 'stdout' && /from rc/.test(t)), 'rc output in the log');
    // displays have no cell: logged, text as stdout
    assert(U.logs.some(([k, t]) => k === 'stdout' && t === 'rc show\n'), 'rc show in the log ' + J(U.logs));
    assert(U.logs.some(([k, t]) => k === 'display' && t === 'text/html output not shown (8 characters)'), 'rc html ' + J(U.logs));
    assert(!U.logs.some(([k]) => k === 'protocol'), 'no protocol error ' + J(U.logs));
    U.k.writeFile('/home/web_user/w.scm', new TextEncoder().encode('(define w 3)'));
    eq((await U.k.run('w', '(load "w.scm") w')).values, ['3'], 'writeFile');
    U.k.dispose();
    eq((await U.k.run('x', '1')).reason, 'disposed', 'disposed');
    current = C;
  });

  await check('C13 a kernel that cannot start rejects start() with a reason', async () => {
    const B = client({ getModule: () => Promise.reject(new Error('no module here')) });
    let why = null;
    await B.k.start().catch(e => { why = e; });
    assert(why && /no module here/.test(why.reason), 'rejected: ' + J(why));
    eq(B.k.state, 'unavailable', 'state');
    eq((await B.k.run('x', '1')).reason, 'kernel unavailable', 'run cancelled');
    B.k.dispose();
    current = C;
  });

  await check('C14 restart() while starting: both promises resolve on the new hello', async () => {
    const R = client();
    const p1 = R.k.start();
    const p2 = R.k.restart();
    await Promise.all([p1, p2]);
    eq(R.k.state, 'idle', 'idle');
    eq((await R.k.run('x', '(+ 1 1)')).values, ['2'], 'runs');
    R.k.dispose();
    current = C;
  });

  await check('C15 a kernel that exits while starting: start() rejects, its message is logged', async () => {
    const F = client({ args: () => '-R no-such-extension-here' });
    let why = null;
    await F.k.start().catch(e => { why = e; });
    assert(why && /exited/.test(why.reason), 'rejected: ' + J(why));
    eq(F.k.state, 'dead', 'dead');
    assert(F.logs.some(([k, t]) => k === 'stderr' && /no-such-extension-here/.test(t)), 'stderr logged ' + J(F.logs));
    eq((await F.k.run('x', '1')).reason, 'kernel exited', 'run cancelled');
    F.k.dispose();
    current = C;
  });

  // The slice that wakes from a sleep, or gets the input, runs into a
  // long primitive without reporting: the client still says sleeping or
  // input, and Stop must kill the kernel all the same.
  await check('C16 watchdog: Stop after a sleep, in a long primitive, kills the kernel', async () => {
    const W = client({ watchdogMs: 1000 });
    const p = W.k.run('big', '(sleep 1) (define big (expt 7 60000000))');
    await waitFor('sleeping', () => W.k.state === 'sleeping');
    await sleep(1500);
    eq(W.k.state, 'sleeping', 'still sleeping for the client');
    const t = now();
    W.k.stop();
    const d = await p;
    eq([d.status, d.reason], ['killed', 'unresponsive'], 'killed');
    { const [ok, ms] = fired(t); assert(ok, 'after watchdogMs: ' + ms); }
    eq((await W.k.run('after', '(+ 1 2)')).values, ['3'], 'respawned');
    W.k.dispose();
    current = C;
  });

  await check('C17 input: busy once it is sent; Stop in the primitive that follows kills the kernel', async () => {
    const W = client({ watchdogMs: 1000 });
    const p = W.k.run('in', '(import (chicken io)) (read-line) (define big (expt 7 60000000))');
    await waitFor('input', () => W.k.state === 'input');
    W.k.input('x\n');
    eq(W.k.state, 'busy', 'busy at once');
    await waitFor('the stdin box goes', () => W.cells.in.filter(e => e.type === 'input').length === 2);
    eq(W.cells.in.filter(e => e.type === 'input').map(e => e.waiting), [true, false], 'waiting flags');
    const t = now();
    W.k.stop();
    const d = await p;
    eq([d.status, d.reason], ['killed', 'unresponsive'], 'killed');
    { const [ok, ms] = fired(t); assert(ok, 'after watchdogMs: ' + ms); }
    W.k.dispose();
    current = C;
  });

  await check('C18 input read twice: the stdin box stays up between the lines', async () => {
    const p = C.k.run('in2x', '(import (chicken io)) (list (read-line) (read-line))');
    await waitFor('input', () => C.k.state === 'input');
    C.k.input('a\n');
    await waitFor('input again', () => C.k.state === 'input');
    C.k.input('b\n');
    eq((await p).values, ['("a" "b")'], 'values');
    eq(C.cells.in2x.filter(e => e.type === 'input').map(e => e.waiting), [true, false], 'waiting flags');
  });

  await check('C19 a cell re-entering a continuation of the .csirc ends; the kernel goes on', async () => {
    const R = client({ csirc: () => '(define kk #f)\n(call-with-current-continuation (lambda (k) (set! kk k)))\n' });
    const d = await R.k.run('a', '(kk #f) (display "after")');
    eq([d.type, d.count], ['done', 1], 'done');
    eq(R.logs.filter(([k]) => k === 'csirc').length, 1, 'one csirc event: ' + J(R.logs));
    assert(!R.logs.some(([k]) => k === 'protocol'), 'no protocol error: ' + J(R.logs));
    eq((await R.k.run('b', '(+ 1 2)')).values, ['3'], 'the next cell runs');
    eq(R.k.state, 'idle', 'idle');
    R.k.dispose();
    current = C;
  });

  // More input sent just after the read (the stdin box stays up for a
  // while) reaches a kernel already at IDLE: the worker reports IDLE
  // again for a slice that ran nothing.  The shim holds that second
  // input until the cell's done arrives, and the client sees done only
  // after both IDLE states, behind which the next cell is posted.
  await check('C20 IDLE from input sent after a cell ended does not end the next cell', async () => {
    let held = null, inputs = 0, hold = null, states = 0;
    const S = client({
      createWorker: () => {
        const w = createWorker(), real = w.postMessage;
        w.postMessage = m => {
          if (m.type === 'input' && ++inputs === 2) held = m; else real(m);
        };
        const shim = { onmessage: null, onerror: null, postMessage: m => w.postMessage(m),
                       terminate: () => w.terminate() };
        w.onerror = e => shim.onerror && shim.onerror(e);
        w.onmessage = e => {
          const m = e.data;
          if (!hold && held && m.type === 'output' && m.fd === 3 && m.text.includes('"ev":"done"')) {
            hold = [];
            real(held);
          }
          if (hold) {
            hold.push(e);
            if (m.type === 'state' && ++states === 2) {
              const q = hold;
              hold = held = null;
              for (const x of q) shim.onmessage && shim.onmessage(x);
            }
            return;
          }
          if (shim.onmessage) shim.onmessage(e);
        };
        return shim;
      },
    });
    const pa = S.k.run('a', '(import (chicken io)) (read-line) (display "A ran") 1');
    const pb = S.k.run('b', '(display "B ran") 42');
    const pc = S.k.run('c', '(+ 1 2)');
    await waitFor('input', () => S.k.state === 'input');
    S.k.input('x\n');
    S.k.input('', true);                      // the box is still up: posted
    eq(inputs, 2, 'both inputs posted');
    const a = await pa, b = await pb, c = await pc;
    eq([a.status, S.stream('a')], ['ok', 'A ran'], 'a');
    eq([b.status, b.values, S.stream('b')], ['ok', ['42'], 'B ran'], 'b');
    eq([c.status, c.values], ['ok', ['3']], 'c');
    eq(states, 2, 'both IDLE states held');
    assert(!S.logs.some(([k]) => k === 'protocol'), 'no protocol error: ' + J(S.logs));
    eq(S.k.state, 'idle', 'idle');
    S.k.dispose();
    current = C;
  });

  await check('C21 lazy events; lazy() pauses (state paused), steps and goes on; Stop', async () => {
    const lz = id => (C.cells[id] || []).filter(e => e.type === 'lazy');
    const d = await C.k.run('l1', '(delay (list 1 (delay (cons 2 3))))');
    eq([d.status, d.values], ['ok', null], 'done');
    eq(lz('l1').map(e => [e.op, e.op === 'item' ? e.data : e.op === 'open' ? e.parent === null : e.how, !!e.dot]),
       [['open', true, false], ['item', '1', false], ['open', false, false], ['item', '2', false],
        ['item', '3', true], ['end', 'end', false], ['end', 'end', false]], 'events');
    assert(lz('l1').filter(e => e.op === 'item').every(e => e.mime === 'text/plain'), 'text items');
    await C.k.run('l2', '(define (nats n) (delay (cons n (nats (+ n 1)))))');
    const p = C.k.run('l3', '(nats 0)');
    await waitFor('elements', () => lz('l3').length > 3);
    C.k.lazy(Kernel.LAZY_PAUSE);
    await waitFor('paused', () => C.k.state === 'paused');
    assert(C.k.lazyShown, 'a lazy stream is shown');
    const n0 = lz('l3').length;
    C.k.lazy(Kernel.LAZY_NEXT);
    await waitFor('the next element', () => lz('l3').length === n0 + 1 && C.k.state === 'paused');
    C.k.lazy(Kernel.LAZY_GO);
    await waitFor('busy', () => C.k.state === 'busy' && lz('l3').length > n0 + 10);
    C.k.stop();
    const e = await p;
    eq([e.status, lz('l3').pop().how], ['ok', 'stopped'], 'stopped');
    eq(C.k.lazyShown, false, 'none shown');
    eq((await C.k.run('l4', '(* 6 7)')).values, ['42'], 'next cell');
  });

  // ---- CJ: the JavaScript bridge through the client and the worker

  await check('CJ1 js-await: the state awaiting, then done ok', async () => {
    const s0 = C.states.length;
    const d = await C.k.run('cj1', '(import js) (js-await (js-eval "new Promise(r => setTimeout(() => r(1), 200))"))');
    eq([d.status, d.values], ['ok', ['1']], 'done');
    assert(C.states.slice(s0).includes('awaiting'), 'awaiting: ' + C.states.slice(s0));
  });

  await check('CJ2 Stop during js-await interrupts the cell', async () => {
    const p = C.k.run('cj2', '(js-await (js-eval "new Promise(() => {})"))');
    await waitFor('awaiting', () => C.k.state === 'awaiting');
    C.k.stop();
    eq((await p).status, 'interrupted', 'interrupted');
    eq((await C.k.run('cj2b', '(+ 1 2)')).values, ['3'], 'next cell');
  });

  const logged = (kind, re) => C.logs.some(([k, t]) => k === kind && re.test(t));
  // the async done event of cell ID
  const asyncDone = (id, ms) => waitFor('async done of ' + id, () => C.async(id).find(e => e.type === 'async' && e.op === 'done'), ms);
  await check('CJ3 an exception thrown in a timer is the error of its cell\'s callback; the kernel stays', async () => {
    const d = await C.k.run('cj3', '(js-eval "setTimeout(() => { throw new Error(\'boom\') }, 0), 1")');
    eq(d.status, 'ok', 'done');
    const a = await asyncDone('cj3', 1000);
    assert(a.status === 'error' && /Uncaught Error: boom/.test(a.error.text), 'async done: ' + J(a));
    assert(!logged('stderr', /boom/), 'not logged: ' + J(C.logs));
    assert(C.k.state !== 'dead', 'alive: ' + J(C.logs));
    eq((await C.k.run('cj3b', '(+ 1 2)')).values, ['3'], 'next cell');
  });

  await check('CJ4 a rejected promise nobody waits for is logged', async () => {
    const d = await C.k.run('cj4', '(js-eval "Promise.reject(new Error(\'nope\')), 1")');
    eq(d.status, 'ok', 'done');
    await waitFor('the log', () => logged('stderr', /Uncaught \(in promise\) Error: nope/), 1000);
    eq((await C.k.run('cj4b', '(+ 1 2)')).values, ['3'], 'next cell');
  }, { uncaught: true });

  await check('CJ5 the console writes in the cell, in order', async () => {
    let d = await C.k.run('cj5', '(begin (display "a") (js-eval "console.log(\'b\')") (display "c"))');
    eq(d.status, 'ok', 'done');
    eq(C.stream('cj5'), 'ab\nc', 'stream');
    d = await C.k.run('cj5b', '(js-eval "console.error(\'e\')")');
    eq(C.cells.cj5b.filter(e => e.type === 'stream').map(e => e.name + ':' + e.text), ['stderr:e\n'], 'stderr');
  });

  await check('CJ6 the console between cells reaches the cell that set the timer at once', async () => {
    await C.k.run('cj6', '(js-eval "setTimeout(() => console.log(\'idle\'), 20)")');
    await waitFor('the stream', () => C.async('cj6').some(e => e.type === 'stream' && e.text === 'idle\n'), 500);
    assert(!C.logs.some(([k, t]) => k === 'stdout' && /idle/.test(t)), 'not logged: ' + J(C.logs));
  });

  await check('CJ7 the worker\'s own state is out of reach', async () => {
    const d = await C.k.run('cj7', '(js->list (js-eval "[typeof drv, typeof handle, typeof queue, typeof writeFile, ' +
                                   'typeof postMessage, typeof ChickenReplDriver, onmessage === null]"))');
    eq(d.values, ['("undefined" "undefined" "undefined" "undefined" "undefined" "undefined" #t)'], 'typeof');
    const e = await C.k.run('cj7b', '(js-eval "onmessage = null; function handle(m) {}; var queue = 1; 2")');
    assert(e.status === 'ok' ? J(e.values) === '["2"]' : e.status === 'error', 'ok 2 or an error: ' + J(e));
    C.k.writeFile('/home/web_user/cj7.scm', new TextEncoder().encode('(define cj7 7)'));
    eq((await C.k.run('cj7c', '(load "cj7.scm") cj7')).values, ['7'], 'the next cell, and writeFile');
  });

  await check('CJ8 output that comes before a posted cell starts is its own cell\'s, not the posted one\'s', async () => {
    // the timer writes, then holds the worker until the cell is posted
    await C.k.run('cj8a', '(js-eval "setTimeout(() => { console.log(\'late\'); const t = Date.now(); ' +
                          'while (Date.now() - t < 300); }, 30), 1")');
    await sleep(100);
    const d = await C.k.run('cj8', '(+ 1 2)');
    eq(d.values, ['3'], 'done');
    await sleep(50);
    assert(!C.stream('cj8').includes('late'), 'not in the cell: ' + J(C.cells.cj8));
    assert(C.async('cj8a').some(e => e.type === 'stream' && e.text === 'late\n'), 'cj8a\'s: ' + J(C.cells.cj8a));
  });

  // ---- N-JSC: JavaScript cells and attribution through the client
  // and the worker

  await check('N-JSC1 a JavaScript cell; the global scheme is read-only', async () => {
    const d = await C.k.run('jsc1', '1 + 1', 'js');
    eq([d.status, d.values], ['ok', ['2']], 'done');
    eq((await C.k.run('jsc1b', 'typeof scheme', 'js')).values, ['"object"'], 'typeof scheme');
    eq((await C.k.run('jsc1c', 'scheme = 1; 2', 'js')).values, ['2'], 'assigned');
    eq((await C.k.run('jsc1d', 'typeof scheme.eval', 'js')).values, ['"function"'], 'still there');
  });

  await check('N-JSC2 a timer\'s output is its cell\'s', async () => {
    const d = await C.k.run('jsc2', "setTimeout(() => console.log('tick'), 30); 1", 'js');
    eq(d.values, ['1'], 'done');
    await asyncDone('jsc2', 2000);
    eq(C.async('jsc2').map(e => e.type === 'async' ? e.op + ':' + (e.status || '') : e.type + ':' + e.text),
       ['start:', 'stream:tick\n', 'done:ok'], 'events');
    assert(!logged('stdout', /tick/), 'nothing logged: ' + J(C.logs));
  });

  await check('N-JSC3 a timer that throws: an error of its cell, nothing left uncaught', async () => {
    const d = await C.k.run('jsc3', "setTimeout(() => { throw new Error('boom') }, 0); 1", 'js');
    const a = await asyncDone('jsc3', 2000);
    eq([a.status, a.error && a.error.text], ['error', 'Uncaught Error: boom'], 'async done');
    assert(a.error.chain.some(f => f.where === 'In[' + d.count + ']:1'), 'frame: ' + J(a.error.chain));
    eq(a.error.line, 1, 'line');
    eq((await C.k.run('jsc3b', '(+ 1 2)')).values, ['3'], 'next cell');
  });

  await check('N-JSC4 promise reactions and microtasks', async () => {
    await C.k.run('jsc4', "Promise.resolve().then(() => console.log('r')); queueMicrotask(() => console.log('m')); 1", 'js');
    await waitFor('both', () => /r\n/.test(C.stream('jsc4')) && /m\n/.test(C.stream('jsc4')), 2000);
    await C.k.run('jsc4b', "new Promise(r => setTimeout(r, 30)).then(() => console.log('later')); 1", 'js');
    await waitFor('later', () => C.async('jsc4b').some(e => e.type === 'stream' && e.text === 'later\n'), 2000);
  });

  await check('N-JSC5 scheme.show from a timer: a display of its cell', async () => {
    await C.k.run('jsc5', "setTimeout(() => scheme.show('shown'), 20); 1", 'js');
    await waitFor('two frames', () => C.async('jsc5').filter(e => e.type === 'async' && e.op === 'done').length === 2, 2000);
    eq(C.async('jsc5').map(e => e.type === 'async' ? e.op + ':' + (e.status || '') : e.type + ':' + e.mime + ':' + e.data),
       ['start:', 'done:ok', 'start:', 'display:text/plain:shown', 'done:ok'], 'events');
  });

  const callbackState = st => C.cb.some(([s, cb]) => s === st && cb === true);
  await check('N-JSC6 a callback holds the cells run meanwhile; Stop interrupts it', async () => {
    C.cb.length = 0;
    await C.k.run('jsc6', '(import js) (begin (js-call (js-eval "f => setTimeout(f, 20)") (lambda () (let loop () (loop)))) (void))');
    await waitFor('busy with a callback', () => callbackState('busy'), 5000);
    assert(C.k.callback, 'the callback getter');
    const p = C.k.run('held', '(+ 1 2)');
    await sleep(200);
    eq(C.types('held'), ['queued'], 'held');
    C.k.stop();
    eq((await p).reason, 'stopped', 'cancelled');
    const a = await waitFor('interrupted', () => C.async('jsc6').find(e => e.type === 'async' && e.op === 'done' &&
                                                                       e.status === 'interrupted'), 5000);
    assert(a, 'interrupted');
    eq((await C.k.run('jsc6b', '(+ 1 2)')).values, ['3'], 'next cell');
  });

  await check('N-JSC9 callbacks that come faster than they end hold a cell only until the call running ends', async () => {
    await C.k.run('jsc9w', '(define (work) (let loop ((i 0)) (if (< i 100000) (loop (+ i 1)))))');
    await C.k.run('jsc9', "globalThis.iv9 = setInterval(() => scheme.call('work'), 20); 'started'", 'js');
    await waitFor('busy with a callback', () => C.k.callback, 5000);
    await sleep(300);
    const d = await Promise.race([C.k.run('jsc9b', "clearInterval(iv9); 'cleared'", 'js'), sleep(10000).then(() => null)]);
    assert(d && d.status === 'ok' && d.values.join() === '"cleared"', 'the cell ran: ' + J(d) + ' ' + J(C.types('jsc9b')));
    await waitFor('idle', () => C.k.state === 'idle' && !C.k.callback, 30000);
    eq((await C.k.run('jsc9c', '(+ 1 2)')).values, ['3'], 'next cell');
  });

  await check('N-JSC7 the watchdog in a callback that sleeps, then runs a long primitive', async () => {
    const W = client();
    try {
      await W.k.run('w7', '(import js) (begin (js-call (js-eval "f => setTimeout(f, 20)") ' +
                          '(lambda () (sleep 1) (set! big (expt 7 60000000)))) (void))');
      await waitFor('sleeping with a callback', () => W.cb.some(([s, cb]) => s === 'sleeping' && cb === true), 5000);
      await sleep(1500);
      const t = now();
      W.k.stop();
      // (the first frame is the timer's, which queued the call)
      await waitFor('killed', () => W.async('w7').some(e => e.type === 'async' && e.op === 'done' && e.status !== 'ok'), 6000);
      const ms = now() - t;
      eq(W.async('w7').filter(e => e.type === 'async').map(e => e.op + ':' + (e.status || '')),
         ['start:', 'done:ok', 'start:', 'done:killed'], 'frames');
      assert(ms >= 2900 && ms < 6000, 'after the watchdog: ' + ms);
      assert(W.logs.some(([k, x]) => k === 'kernel' && /did not respond to Stop/.test(x)), 'logged: ' + J(W.logs));
      eq((await W.k.run('w7b', '(+ 1 2)')).values, ['3'], 'next cell');
    } finally { W.k.dispose(); current = C; }
  });

  await check('N-JSC8 the worker\'s names stay safe from JavaScript cells', async () => {
    const d = await C.k.run('jsc8', 'function handle(m) {}; var queue = 1; let drv = null; const writeFile = 0; 2', 'js');
    eq(d.values, ['2'], 'value');
    C.k.writeFile('/home/web_user/jsc8.scm', new TextEncoder().encode('(define jsc8 8)'));
    eq((await C.k.run('jsc8b', '(load "jsc8.scm") jsc8')).values, ['8'], 'writeFile and load');
  });

  C.k.dispose();
}

(async () => {
  const t0 = now();
  if (eggsOnly) await eggs();
  else if (packageDir) await packages();
  else {
    await partL();
    await partK();
    await partC();
  }
  console.log('# ' + passes + ' passed, ' + failures + ' failed in ' +
              ((now() - t0) / 1000).toFixed(1) + ' s');
  process.exit(failures ? 1 : 0);
})().catch(e => { console.log('not ok - ' + (e && e.stack || e)); process.exit(1); });
