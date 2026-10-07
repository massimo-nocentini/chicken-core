/* compiler-worker.js - run the WebAssembly chicken compiler in a Web Worker
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
/* Translates Scheme to C for the page's "Compile to C" tab.
 *
 *   page -> worker   compile {id, source, options}
 *   worker -> page   compiled {id, ok, code, log, ms}
 *
 * `options' are extra chicken command line arguments.  `code' is the
 * generated C (a string) when ok, else null; `log' is everything the
 * compiler printed.  The generated C is meant for csc-wasm or a native
 * csc; it cannot run in the page.
 *
 * chicken-compiler.js is linked with EXIT_RUNTIME=1, so an instance is
 * finished once main returns: every compile gets a fresh instance of
 * the WebAssembly module, which is compiled only once.
 *
 * As in repl-worker.js, the worker URL's ?v= is passed on to the module
 * URLs, and its dir= names the directory of the modules. */

'use strict';

const params = new URLSearchParams(self.location.search);
const V = params.get('v') || '';
const q = V ? '?v=' + encodeURIComponent(V) : '';
const D = params.get('dir') || '';
if (!/^([a-z0-9]+\/)?$/.test(D)) throw new Error('compiler-worker.js: bad module directory "' + D + '"');
importScripts(D + 'chicken-compiler.js' + q);

let modP = null;

async function compileModule() {
  const url = D + 'chicken-compiler.wasm' + q;
  if (WebAssembly.compileStreaming) {
    try { return await WebAssembly.compileStreaming(fetch(url)); }
    catch (e) { /* a server without the application/wasm type: retry below */ }
  }
  const r = await fetch(url);
  if (!r.ok) throw new Error('cannot fetch ' + url + ': HTTP ' + r.status);
  return WebAssembly.compile(await r.arrayBuffer());
}

async function translate(source, options) {
  const mod = await (modP || (modP = compileModule()));
  let log = '', loadFailed;
  // createChickenCompiler never settles when instantiation fails
  const loadFailure = new Promise((_, reject) => { loadFailed = reject; });
  const M = await Promise.race([loadFailure, createChickenCompiler({
    instantiateWasm: (imports, ok) => {
      WebAssembly.instantiate(mod, imports).then(i => ok(i, mod), loadFailed);
      return {};
    },
    print: t => { log += t + '\n'; },
    printErr: t => { log += t + '\n'; },
    thisProgram: 'chicken',
    stdin: () => null,
    preRun: [m => m.FS.mkdir('/work')],
  })]);
  M.FS.writeFile('/work/in.scm', source);
  let rc;
  try {
    // callMain returns the exit status (EXIT_RUNTIME=1 swallows ExitStatus)
    rc = M.callMain(['/work/in.scm', '-output-file', '/work/out.c', ...options]);
  } catch (e) {                         // a trap: RuntimeError, RangeError
    return { ok: false, code: null, log: log + '\n' + describe(e) };
  }
  const ok = rc === 0;
  // Options such as -check-syntax, -version or -analyze-only succeed
  // without writing any C: code is then null.
  const out = ok && M.FS.analyzePath('/work/out.c').exists;
  return { ok, code: out ? M.FS.readFile('/work/out.c', { encoding: 'utf8' }) : null, log };
}

// Emscripten's FS errors have no stack and print as [object Object];
// JavaScriptCore's and SpiderMonkey's stacks lack V8's first line, the
// message (as repl-driver.js's describe)
const describe = e => {
  const head = e instanceof Error ? String(e) : String((e && (e.message || e.code)) || e);
  const stack = e && e.stack ? String(e.stack) : '';
  return !stack || stack.startsWith(head) ? stack || head : head + '\n' + stack;
};

onmessage = async ({ data: m }) => {
  if (m.type !== 'compile') return;
  const t0 = performance.now();
  let r;
  try { r = await translate(String(m.source), (m.options || []).map(String)); }
  catch (e) { r = { ok: false, code: null, log: describe(e) }; }
  postMessage({ type: 'compiled', id: m.id, ok: r.ok, code: r.code, log: r.log,
                ms: Math.round(performance.now() - t0) });
};
