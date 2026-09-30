// egg-harness.js - headless test of eggs linked into the WebAssembly REPL
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
// usage: node egg-harness.js WEB_DIR [INPUT EXPECTED] ...
//
// WEB_DIR holds chicken-repl.js and chicken-repl.wasm, built with
// WASM_EGGS.  Each INPUT line is fed to one REPL session through
// repl-driver.js, and the output it gives before the next prompt must
// contain EXPECTED.  Without pairs, the cases for the eggs in
// tests/wasm/eggs are run.  Exits with status 1 if any case fails.

'use strict';
const fs = require('fs');
const path = require('path');

const webDir = path.resolve(process.argv[2] || 'web');
const createChickenRepl = require(path.join(webDir, 'chicken-repl.js'));
const Driver = require(path.join(__dirname, '..', '..', 'emscripten', 'web', 'repl-driver.js'));
const { WAITING } = Driver;
const wasmModule = new WebAssembly.Module(fs.readFileSync(path.join(webDir, 'chicken-repl.wasm')));

const fixtureCases = [
  // the import library is found in the embedded repository
  ['(import (chicken file) (chicken load)) (and (find-file "wasm-egg-b.import.scm" (repository-path)) #t)',
   '#t'],
  ['(import wasm-egg-b) (egg-b-report)', '(10 18 42 42 2 1)'],
  ['(egg-b-target?)', '#t'],
  ['(define x 1) (define y 2) (egg-a-swap! x y) (list x y)', '(2 1)'],
  ['(import wasm-egg-a) (list (egg-a-add 40 2) (egg-a-scale 5) (egg-a-twice 4))', '(42 15 8)'],
  ['(import wasm-egg-a-extra) (egg-a-extra)', 'extra'],
  ['(egg-b-included)', '(7 11)'],
];

const args = process.argv.slice(3);
if (args.length % 2) {
  console.log('usage: node egg-harness.js WEB_DIR [INPUT EXPECTED] ...');
  process.exit(2);
}
const cases = [];
for (let i = 0; i < args.length; i += 2) cases.push([args[i], args[i + 1]]);
if (!cases.length) cases.push(...fixtureCases);

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function waitFor(what, pred, ms = 30000) {
  const t0 = performance.now();
  for (;;) {
    if (pred()) return;
    if (performance.now() - t0 > ms) throw new Error('timed out after ' + ms + ' ms waiting for ' + what);
    await sleep(5);
  }
}

(async () => {
  let all = '', crash = null, states = [];
  const drv = await Driver.start(createChickenRepl, {
    args: ['-n'],
    wasmModule,
    schedule: f => setImmediate(f),
    later: (f, ms) => setTimeout(f, ms),
    onOutput: (fd, t) => { all += t; },
    onState: st => states.push(st),
    onExit: code => { crash = crash || 'csi exited with status ' + code; },
    onCrash: msg => { crash = msg; },
  });
  if (!drv) { console.log('not ok - start: ' + crash); process.exit(1); }
  drv.begin();
  const prompt = /#;\d+> $/;
  const ready = at => () => {
    if (crash) throw new Error(crash);
    return prompt.test(all.slice(at)) && drv.state() === WAITING;
  };
  let failures = 0;
  try {
    await waitFor('the first prompt', ready(0));
  } catch (e) {
    console.log('not ok - start: ' + e.message + '\n  | ' + all.slice(-600).split('\n').join('\n  | '));
    process.exit(1);
  }
  for (const [input, expected] of cases) {
    const at = all.length;
    try {
      drv.feed(input + '\n');
      await waitFor('the prompt after ' + input, ready(at));
      const out = all.slice(at);
      if (!out.includes(expected)) throw new Error('expected ' + expected);
      console.log('ok - ' + input);
    } catch (e) {
      failures++;
      console.log('not ok - ' + input + '\n  ' + e.message + '\n  | ' +
                  all.slice(at).slice(-600).split('\n').join('\n  | '));
    }
  }
  console.log(`${cases.length - failures} of ${cases.length} passed`);
  process.exit(failures ? 1 : 0);
})().catch(e => { console.log('not ok - ' + (e && e.stack || e)); process.exit(1); });
