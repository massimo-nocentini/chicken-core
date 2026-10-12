/* repl-driver.js - drive the WebAssembly csi (chicken-repl.js) from JavaScript
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

/* UMD: a CommonJS module in node (tests), the global ChickenReplDriver in
 * a worker (importScripts).
 *
 *   const drv = await ChickenReplDriver.start(createChickenRepl, options);
 *
 * starts csi (main runs the banner, imports, .csirc and prints the first
 * prompt) and returns a driver object, or null when csi already exited or
 * crashed during startup (onExit/onCrash have then been called).  It
 * rejects only when the module itself fails to load or instantiate, and
 * then calls neither.  Options:
 *
 *   args         extra csi arguments; "-:" runtime options must come first
 *                (they follow the "-:c" added here)
 *   csirc        text for /home/web_user/.csirc, or null for none
 *   files        [{path, data}] written into MEMFS before main runs
 *   sliceMs      time slice in ms (default 50)
 *   wasmModule   a precompiled WebAssembly.Module (optional)
 *   locateFile   emscripten's locateFile hook (optional)
 *   schedule(f)  run f soon (a macrotask, so JS events get a turn)
 *   later(f,ms)  run f after ms milliseconds
 *   canRun()     optional backpressure: false stops pumping BUSY slices
 *                until resumeOutput() is called
 *   onOutput(fd, text)  Scheme output, fd 1 or 2, decoded UTF-8; fd 3
 *                carries the notebook kernel's events (webnb.scm), one
 *                JSON object per line
 *   onState(st)  after every slice; st is one of the state constants
 *                (IDLE: the notebook kernel waits for a request)
 *   onExit(code), onCrash(message)  called once; the driver is then dead
 *   onDiag(text) C-level stderr before the REPL is ready (default
 *                console.warn)
 *
 * feed() does not add a newline: after reading a datum csi peeks for the
 * newline that ends the line, so input should be "\n"-terminated.
 * post(text) hands the notebook kernel (csi -e "(##webnb#kernel)") one
 * whole request, as webnb.scm describes; requests queue in order.
 * describe(e) gives an error's message and stack, as onCrash has them. */

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ChickenReplDriver = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const RUNNING = 0, WAITING = 1, BUSY = 2, EXITED = 3, SLEEPING = 4, IDLE = 5;

  // An error's message and stack: V8's stack begins with the message,
  // JavaScriptCore's and SpiderMonkey's have the frames only.
  function describe(e) {
    if (!e || typeof e !== 'object') return String(e);
    const head = String(e), stack = e.stack ? String(e.stack) : '';
    return !stack || stack.startsWith(head) ? stack || head : head + '\n' + stack;
  }

  async function start(createModule, o) {
    let M = null, dead = false, scheduled = false, ready = false;
    const earlyErr = [];
    const dec = { 1: new TextDecoder(), 2: new TextDecoder(), 3: new TextDecoder() };

    function finish(kind, v) {
      if (dead) return;
      dead = true;
      if (kind === 'exit') o.onExit(v); else o.onCrash(v);
    }
    // The ExitStatus thrown by proc_exit is the only in-slice exit signal.
    function fail(e) {
      if (e && e.name === 'ExitStatus') finish('exit', e.status);
      else finish('crash', describe(e));
    }
    function guard(f) {
      if (dead) return EXITED;
      try { return f(); } catch (e) { fail(e); return EXITED; }
    }
    function kick(ms) {
      if (scheduled || dead) return;
      scheduled = true;
      if (ms) o.later(pump, ms); else o.schedule(pump);
    }
    function report(st) {
      if (dead) return;
      o.onState(st);
      if (st === BUSY) { if (!o.canRun || o.canRun()) kick(); }   // else resumeOutput()
      else if (st === SLEEPING) kick(Math.max(1, M._webrepl_wakeup_ms()));
    }
    function pump() {
      scheduled = false;
      report(guard(() => M._webrepl_resume()));
    }

    const opts = {
      arguments: ['-:c', ...(o.args || [])],
      thisProgram: 'csi',
      stdin: () => null,                    // never window.prompt()
      onSchemeOutput: (fd, bytes) =>
        o.onOutput(fd, dec[fd].decode(bytes, { stream: true })),
      print: t => o.onOutput(1, t + '\n'),  // C-level stdio (panic, -:d)
      printErr: t => {
        if (ready) o.onOutput(2, t + '\n');
        else { earlyErr.push(t); (o.onDiag || console.warn)(t + '\n'); }
      },
      // before main returned, start() reports the failure instead
      onAbort: what => {
        if (ready) fail(new Error('abort: ' + what)); else earlyErr.push('abort: ' + what);
      },
      preRun: [mod => {
        mod.FS.chdir('/home/web_user');
        if (o.csirc != null) mod.FS.writeFile('/home/web_user/.csirc', o.csirc);
        for (const f of o.files || []) mod.FS.writeFile(f.path, f.data);
      }],
    };
    if (o.locateFile) opts.locateFile = o.locateFile;
    let loadFailed;
    const loadFailure = new Promise((_, reject) => { loadFailed = reject; });
    if (o.wasmModule) opts.instantiateWasm = (imports, ok) => {
      WebAssembly.instantiate(o.wasmModule, imports)
        .then(inst => ok(inst, o.wasmModule), loadFailed);
      return {};
    };

    M = await Promise.race([createModule(opts), loadFailure]);
    if (!M._webrepl_started()) {            // exited or panicked inside main
      if (M._webrepl_exited()) {
        // C-level messages (a panic) went to onDiag only so far
        if (earlyErr.length) o.onOutput(2, earlyErr.join('\n') + '\n');
        finish('exit', M._webrepl_exit_code());
      } else finish('crash', 'runtime exited during startup\n' + earlyErr.join('\n'));
      return null;
    }
    ready = true;
    if (o.sliceMs) M._webrepl_set_slice_ms(o.sliceMs);

    const api = {
      feed(text, eof) {
        if (dead) return;
        // with an explicit length, so that NUL characters get through
        const p = M.stringToNewUTF8(text);
        M._webrepl_feed(p, M.lengthBytesUTF8(text), eof ? 1 : 0);
        M._free(p);
        kick();
      },
      post(text) {
        if (dead) return;
        const p = M.stringToNewUTF8(text);
        M._webrepl_post(p, M.lengthBytesUTF8(text));
        M._free(p);
        kick();
      },
      interrupt() {
        if (dead) return;
        M._webrepl_interrupt();
        kick();
      },
      resumeOutput() { if (!dead && M._webrepl_state() === BUSY) kick(); },
      state() { return dead ? EXITED : M._webrepl_state(); },
      get FS() { return M.FS; },
      get module() { return M; },
      get dead() { return dead; },
      initialState() { return guard(() => M._webrepl_state()); },
      begin() { report(api.initialState()); },   // after posting 'ready'
    };
    return api;
  }

  return { start, describe, RUNNING, WAITING, BUSY, EXITED, SLEEPING, IDLE };
});
