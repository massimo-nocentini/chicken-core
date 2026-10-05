// jsc-stack.js - the wasm32 csi in JavaScriptCore with a small native stack
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
// usage: jsc --maxPerThreadStackUsage=BYTES jsc-stack.js -- MODULE_DIR REPL_DRIVER
//
// MODULE_DIR holds the wasm32 chicken-repl.{js,wasm} and
// chicken-compiler.{js,wasm} (the page's, or build-wasm/web/wasm32 with
// WASM_WEB_ARCHS="wasm64 wasm32"); REPL_DRIVER is
// emscripten/web/repl-driver.js.  jsc is JavaScriptCore's shell (WebKit's
// Tools/Scripts/generate-bundle --bundle=jsc makes one, macOS has it in
// JavaScriptCore.framework).  Safari and every iOS browser run the page's
// wasm32 build in JavaScriptCore, whose wasm frames are several times
// V8's, in a worker with the 512 KB stack of a Darwin thread.  Each case
// starts a csi (or a chicken) of its own and must end in the result it
// prints as (R ...), never in the engine's stack overflow nor in an
// error it did not expect.  Run it with 524288 (iOS) and 393216 (a
// margin).  Exits with status 3 if a case fails (an uncaught exception:
// jsc's quit() always exits with 0).

'use strict';
const [modDir, driverJs] = arguments;
if (!modDir || !driverJs) throw new Error('usage: jsc jsc-stack.js -- MODULE_DIR REPL_DRIVER');

// what the shell lacks and emscripten's glue and repl-driver.js use
globalThis.console = { log: (...a) => print(a.join(' ')), warn: (...a) => print('# ' + a.join(' ')),
                       error: (...a) => print('# ' + a.join(' ')) };
if (typeof performance.now !== 'function') performance.now = () => preciseTime() * 1000;
class TextDecoder {
  decode(b) {
    const u = !b ? new Uint8Array(0) : b instanceof Uint8Array ? b : new Uint8Array(b.buffer || b);
    let s = '', i = 0;
    while (i < u.length) {
      const c = u[i++];
      if (c < 0x80) s += String.fromCharCode(c);
      else if (c < 0xe0) s += String.fromCharCode(((c & 31) << 6) | (u[i++] & 63));
      else if (c < 0xf0) s += String.fromCharCode(((c & 15) << 12) | ((u[i++] & 63) << 6) | (u[i++] & 63));
      else s += String.fromCodePoint(((c & 7) << 18) | ((u[i++] & 63) << 12) | ((u[i++] & 63) << 6) | (u[i++] & 63));
    }
    return s;
  }
}
class TextEncoder {
  encode(s) {
    const out = [];
    for (const ch of s) {
      const c = ch.codePointAt(0);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | c >> 6, 0x80 | c & 63);
      else if (c < 0x10000) out.push(0xe0 | c >> 12, 0x80 | c >> 6 & 63, 0x80 | c & 63);
      else out.push(0xf0 | c >> 18, 0x80 | c >> 12 & 63, 0x80 | c >> 6 & 63, 0x80 | c & 63);
    }
    return new Uint8Array(out);
  }
  encodeInto(s, d) {
    const e = this.encode(s);
    d.set(e.subarray(0, d.length));
    return { read: s.length, written: Math.min(e.length, d.length) };
  }
}
globalThis.TextDecoder = TextDecoder;
globalThis.TextEncoder = TextEncoder;

load(modDir + '/chicken-repl.js');
load(modDir + '/chicken-compiler.js');
load(driverJs);
const replBytes = readFile(modDir + '/chicken-repl.wasm', 'binary');
const compilerBytes = readFile(modDir + '/chicken-compiler.wasm', 'binary');

// results are printed as (R ...), which the echo of an expression in an
// error's call history is not
const MK = '(define (mk n) (if (= n 0) (list) (list (mk (- n 1)))))';
const RANGE = '(define (range n) (let loop ((i n) (l (list))) (if (= i 0) l (loop (- i 1) (cons (- i 1) l)))))';
const NEST = n => '(print ' + '(+ 1 '.repeat(n) + '0' + ')'.repeat(n) + ')';
// [name, csi input or chicken source, expected output]
const cases = [
  ['startup', "(display (list 'R 'ready))", /\(R ready\)/],
  // a deep non-tail recursion: many minor GCs, each starting the native
  // stack afresh
  ['deep recursion', "(define (f n) (if (= n 0) 0 (+ 1 (f (- n 1))))) (display (list 'R (f 200000)))",
   /\(R 200000\)/],
  // equal? recurses in C: it must stop with an error
  ['deep equal?', '(import (chicken condition)) ' + MK + " (display (list 'R (handle-exceptions e" +
   " ((condition-property-accessor 'exn 'message) e) (equal? (mk 20000) (mk 20000)))))", /\(R recursion too deep/],
  // the same with the nursery anywhere from empty to full
  ['deep equal?, every nursery phase', MK + ' (define a (mk 20000)) (define b (mk 20000))' +
   " (define (g n) (if (= n 0) (handle-exceptions e 'too-deep (equal? a b)) (let ((r (g (- n 1)))) r)))" +
   " (display (list 'R (let loop ((n 0) (k 0)) (if (= n 400) k (loop (+ n 1) (if (eq? (g n) 'too-deep) (+ k 1) k))))))",
   /\(R 400\)/],
  ['apply, 10000 arguments', RANGE + " (define (foo . a) (length a))" +
   " (display (list 'R (apply foo (range 10000)) (apply + (range 10000)) (vector-length (apply vector (range 10000)))))",
   /\(R 10000 49995000 10000\)/],
  // the compiler of the page's Compile to C: its units have the longest
  // literals, and the source a deep expression
  ['compile', { compile: '(print 1)' }, /^\(R 0 [1-9]/],
  ['compile, nested expression', { compile: NEST(2000) }, /^\(R 0 [1-9]/],
];

// A module of its own for each case: JavaScriptCore's frames shrink as
// the code tiers up, and a program that has not run yet is the worst
// case.
function run(input) {
  if (input.compile) return compile(input.compile);
  const wasmModule = new WebAssembly.Module(replBytes);
  return new Promise(resolve => {
    let out = '', over = false;
    const end = r => { if (!over) { over = true; resolve(r); } };
    const MARK = '\n#end\n';
    ChickenReplDriver.start(createChickenRepl, {
      args: ['-n'], csirc: null, files: [], sliceMs: 50, wasmModule,
      schedule: f => setTimeout(f, 0), later: (f, ms) => setTimeout(f, ms),
      onOutput: (fd, t) => {
        out += t;
        const i = out.indexOf(MARK);
        if (i >= 0) end({ out: out.slice(0, i).replace(/#;\d+> /g, '') });
      },
      onState: () => {},
      onExit: code => end({ fail: 'csi exited (' + code + ')', out }),
      onCrash: m => end({ fail: 'crashed: ' + String(m).split('\n')[0], out }),
      onDiag: () => {},
    }).then(d => {
      if (!d) return;                   // onExit/onCrash said why
      d.begin();
      d.feed(input + ' (display "' + MARK.replace(/\n/g, '\\n') + '")\n');
    }, e => end({ fail: 'startup failed: ' + ChickenReplDriver.describe(e).split('\n')[0], out }));
    setTimeout(() => end({ fail: 'timed out', out }), 120000);
  });
}

// as compiler-worker.js does: (R status bytes-of-C)
async function compile(source) {
  const mod = new WebAssembly.Module(compilerBytes);
  let log = '', loadFailed;
  // createChickenCompiler never settles when instantiation fails
  const loadFailure = new Promise((_, reject) => { loadFailed = reject; });
  try {
    const M = await Promise.race([loadFailure, createChickenCompiler({
      instantiateWasm: (imports, ok) => { WebAssembly.instantiate(mod, imports).then(i => ok(i, mod), loadFailed); return {}; },
      print: t => { log += t + '\n'; }, printErr: t => { log += t + '\n'; },
      thisProgram: 'chicken', stdin: () => null, preRun: [m => m.FS.mkdir('/work')],
    })]);
    M.FS.writeFile('/work/in.scm', source);
    const rc = M.callMain(['/work/in.scm', '-output-file', '/work/out.c']);
    const c = rc === 0 && M.FS.analyzePath('/work/out.c').exists ? M.FS.readFile('/work/out.c').length : 0;
    return { out: '(R ' + rc + ' ' + c + ')\n' + log };
  } catch (e) {
    return { fail: 'crashed: ' + ChickenReplDriver.describe(e).split('\n')[0], out: log };
  }
}

(async () => {
  let failures = 0;
  print('# wasm32 modules in ' + modDir);
  for (const [name, input, want] of cases) {
    const r = await run(input);
    if (!r.fail && (!want.test(r.out) || /Error:/.test(r.out)))
      r.fail = 'unexpected output: ' + JSON.stringify(r.out.slice(-200));
    if (r.fail) { failures++; print('not ok - ' + name + ': ' + r.fail); }
    else print('ok - ' + name);
  }
  print('# ' + (cases.length - failures) + ' passed, ' + failures + ' failed');
  // quit() (status 0) also ends the timers of the cases
  if (failures) setTimeout(() => { throw new Error(failures + ' case(s) failed'); }, 0);
  else quit();
})();
