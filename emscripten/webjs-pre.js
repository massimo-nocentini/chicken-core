// webjs-pre.js - --pre-js of chicken-repl.js: the JavaScript half of the bridge (webjs.scm)
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
// Emscripten puts this file inside the factory of chicken-repl.js
// (MODULARIZE), so every instance of the module gets a bridge of its
// own, Module['webjs'], which the EM_JS stubs of webjs-main.c call.
// Several instances in one realm (the node harnesses) share nothing.
//
// Scheme -> JavaScript.  webjs.scm pushes the arguments of an operation
// onto `args' (the pushers convert each value as it comes), then calls
// webjs_op, a foreign-safe-lambda, which runs op() below.  op() is the
// only place where Scheme makes JavaScript run code of the user's
// (calls, getters, Proxy traps, toString), and all the work that may
// run such code -- describing the result, the message of an error --
// is done there, while the user's code may call Scheme back.  The
// result is left in `inbox' as descriptors made of primitives
// (strings as UTF-8, numbers, handle ids), which the readers only copy.
//
// JavaScript -> Scheme.  A Scheme procedure crosses as a function
// (schemeFunction).  Called while an op runs user code (`reentry'), it
// describes its arguments into the inbox and calls the exported
// webjs_dispatch, which runs the procedure as a CHICKEN callback (the
// trampoline of webjs.scm); called at any other time it cannot run
// Scheme now: the call is queued (enqueue), with its arguments
// described at once, and gives a promise, which Scheme settles when it
// runs the call at its next toplevel wait (the REPL's prompt, the idle
// notebook kernel, js-await).  The driver is woken for it
// (webrepl_js_wake and Module.onJsWake), and so it is when a promise
// js-await waits for settles (op AWAIT, settle).  Any exception that leaves
// webjs_dispatch is an unwind -- an exit (ExitStatus), a longjmp out
// of the callback's frames, an engine error there, or a SchemeEscape
// (a continuation that leaves the callback, webjs.scm) -- and is
// judged by where it came from, never by its type.  It is kept in
// `unwinding', and rethrown by every function of the bridge until the
// op that called the user's code is left, whatever that code did with
// it: so a catch or a finally block in between cannot stop it, nor
// call Scheme again.
//
// JavaScript objects held by Scheme are interned: one id per object,
// counting the Scheme records (and the descriptors not read yet) that
// refer to it, so that two crossings of one object give records with
// the same id (equal?).  Scheme objects held by JavaScript are entries
// of webjs.scm's table, wrapped afresh at each crossing; a wrapper the
// garbage collector frees (FinalizationRegistry) releases its entry at
// the next op.  A descriptor of a Scheme object keeps its wrapper: the
// entry lives while a queued call, an await slot or the inbox holds it.
//
// console() is what the worker's console writes with (repl-worker.js):
// inside an op through the Scheme procedure webjs.scm registered for it,
// so the text goes through Scheme's current ports, in order with what
// Scheme wrote before; at any other time Scheme's buffers are empty,
// and it goes straight to the output (Module.onSchemeOutput).
//
// JavaScript cells (webnb.scm) and the REPL's ,js are op RUN_JS: their
// source, rewritten by js-lexer.js (Module.webjsLexer, which
// repl-driver.js passes) so that top-level let, const and class
// declarations become var and outlive the cell, is evaluated by an
// indirect eval, as a script named by its "//# sourceURL=" (In[N] or
// js[N]), whose names the frames of an error keep (lexer.frames).  Its
// completion value comes back with its JavaScript text (inspect), or
// none when Scheme shows it (undefined, a Scheme object); a thenable is
// waited for, as js-await does.  An error carries its frames, and
// whether the source was incomplete (a SyntaxError at its end).
//
// The context is the rid of the notebook cell that JavaScript runs for
// (webnb.scm sets it while a cell or a call attributed to one runs; 0
// in the REPL and between cells).  A queued call records it, so that
// the kernel runs it as that cell's; and the worker wraps setTimeout,
// setInterval, queueMicrotask and the reactions of promises
// (attribute, attributeReaction) so that a function registered in a
// cell runs in its context later too, between the events async-start
// and async-done on fd 3 when its cell no longer runs (framed): its
// output, and its uncaught error, are that cell's.
//
// `scheme' (B.scheme, the worker's global) is JavaScript's way into
// Scheme: eval, env (a Proxy of the toplevel), call, async, list,
// toArray and the notebook's rich output (html ... show, clearOutput),
// procedures of webjs.scm (setApi) called by the step-1 rule: at once
// while Scheme waits on the JavaScript that calls (a cell, js-call),
// else queued, giving a promise.  So scheme.env.fact(5) + 1 in a timer
// is "[object Promise]1": await scheme.call('fact', 5) there.  Each
// read of scheme.env crosses afresh (scheme.env.f !== scheme.env.f),
// and outside an op it throws: Scheme cannot be read then.
//
// The built-ins used after startup are taken now: user JavaScript runs
// in this realm and may replace them.  Their prototypes' methods are
// not, so replacing those can break the bridge (Restart mends it).

Module['webjs'] = (() => {
  'use strict';

  const M = Module;
  const global = globalThis, geval = eval;
  const apply = Reflect.apply, construct = Reflect.construct, deleteProperty = Reflect.deleteProperty;
  const arrayFrom = Array.from, isArray = Array.isArray;
  const is = Object.is, keys = Object.keys, entries = Object.entries, freeze = Object.freeze;
  const defineProperty = Object.defineProperty, getPrototypeOf = Object.getPrototypeOf;
  const isInteger = Number.isInteger, toNumber = Number, toBigInt = BigInt, toStr = String;
  const toStringTag = Symbol.toStringTag;
  const isView = ArrayBuffer.isView, AB = ArrayBuffer, U8 = Uint8Array, U8C = Uint8ClampedArray;
  const encoder = new TextEncoder(), decoder = new TextDecoder();
  const MapC = Map, WeakMapC = WeakMap, WeakSetC = WeakSet, ErrorC = Error, TypeErrorC = TypeError;
  const RangeErrorC = RangeError, EvalErrorC = EvalError, SyntaxErrorC = SyntaxError, PromiseC = Promise;
  const SetC = Set, DateC = Date, RegExpC = RegExp, ProxyC = Proxy, DataViewC = DataView;
  const create = Object.create, getOwnPropertyNames = Object.getOwnPropertyNames;
  const getOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
  const then = Promise.prototype.then, promiseResolve = Promise.resolve, stringify = JSON.stringify;
  const microtask = queueMicrotask.bind(global);
  const objectToString = Object.prototype.toString, symbolToString = Symbol.prototype.toString;
  const ObjectProto = Object.prototype;
  const fnToString = Function.prototype.toString, dateToISO = Date.prototype.toISOString;
  const regexToString = RegExp.prototype.toString;
  const mapEntries = Map.prototype.entries, mapSize = getOwnPropertyDescriptor(Map.prototype, 'size').get;
  const setValues = Set.prototype.values, setSize = getOwnPropertyDescriptor(Set.prototype, 'size').get;
  // the names of Object.prototype, which scheme.env answers as an object
  const OBJECT_NAMES = new SetC(getOwnPropertyNames(ObjectProto));
  const Registry = typeof FinalizationRegistry === 'function' ? FinalizationRegistry : null;
  // the element types of SRFI-4 vectors (webjs.scm's srfi-4-tags)
  const ELEMENTS = [Uint8Array, Int8Array, Uint16Array, Int16Array, Uint32Array, Int32Array,
                    BigUint64Array, BigInt64Array, Float32Array, Float64Array];
  const MAX_SAFE = 9007199254740991;

  // descriptor kinds (webjs.scm's K-...)
  const UNDEFINED = 0, NULL = 1, FALSE = 2, TRUE = 3, INTEGER = 4, FLONUM = 5, BIGINT = 6,
        STRING = 7, HANDLE = 8, SCHEME = 9, LIST = 10, BYTES = 11, RELEASED = 12;
  // ops (OP-...) and their statuses
  const GLOBAL = 1, REF = 2, SET = 3, HAS = 4, DELETE = 5, KEYS = 6, CALL = 7, INVOKE = 8,
        NEW = 9, EVAL = 10, AWAIT = 11, INSTANCEOF = 12, SAME = 13, TOSTRING = 14, FROM = 15,
        ENTRIES = 16, OBJECT = 17, BYTESOF = 18, VALUE_OF = 19, RUN_JS = 20;
  const VALUE = 0, JS_ERROR = 1, SCHEME_ERROR = 2, ESCAPE = 3, PENDING = 4;
  // the statuses of webjs_dispatch (CB-...)
  const CB_OK = 0, CB_ERROR = 1, CB_ESCAPE = 2, CB_TOO_DEEP = 3, CB_RELEASED = 4;
  // what a Scheme object crosses as (KIND-...): ASYNC always queues
  const OBJECT_KIND = 0, FUNCTION = 1, METHOD = 2, ASYNC = 3;
  // how a queued call is settled (webjs_settle): with the value pushed,
  // or rejected with a SchemeError (the object and message pushed), or
  // with an Error of the message pushed
  const RESOLVE = 0, REJECT_SCHEME = 1, REJECT = 2;
  // the procedures of `scheme' (webjs.scm's API-...)
  const API_EVAL = 0, API_ENV_REF = 1, API_ENV_SET = 2, API_ENV_HAS = 3, API_CALL = 4, API_LIST = 5,
        API_TO_ARRAY = 6, API_SHOW = 7, API_CLEAR = 8, API_HTML = 9, API_SVG = 10, API_MARKDOWN = 11,
        API_TEXT = 12, API_TABLE = 13, API_IMAGE = 14;
  // inspect's limits: the text, the nesting, the entries of each object
  const INSPECT_MAX = 100000, INSPECT_DEPTH = 3, INSPECT_ENTRIES = 100;

  // A Scheme object that is no number, string, boolean, procedure or
  // vector: opaque, it comes back as itself.
  class SchemeObject {}
  defineProperty(SchemeObject.prototype, toStringTag, { value: 'SchemeObject' });
  freeze(SchemeObject.prototype);
  // A Scheme error crossing JavaScript: raised again as itself in Scheme
  // if nothing catches it.  Only those of this instance (`errors') are.
  class SchemeError extends ErrorC {}
  defineProperty(SchemeError.prototype, 'name', { value: 'SchemeError', writable: true, configurable: true });
  freeze(SchemeError.prototype);
  // A continuation leaving a call from JavaScript (see webjs.scm)
  class SchemeEscape extends ErrorC {}
  defineProperty(SchemeEscape.prototype, 'name', { value: 'SchemeEscape' });
  freeze(SchemeEscape.prototype);

  let args = [];                        // the argument stack
  let inbox = [];                       // descriptors for Scheme to read
  let scratch = new U8(0);              // webjs_text's
  let reentry = false;                  // an op runs user code: Scheme may be called
  let depth = 0;                        // ops running
  let unwinding = null;                 // an unwind on its way out (see above)
  let cbResult, cbError = null;         // a callback's result, or its SchemeError
  let context = 0;                      // the rid JavaScript runs for (see above)
  let takenRid = 0;                     // that of the call pendingTake took
  // js-lexer.js, which RUN_JS needs (none in JavaScriptCore's lane)
  const lexer = M['webjsLexer'] || null;

  // the handle table: JavaScript objects held by Scheme, ids from 1
  const ids = new MapC(), objs = [undefined], counts = [0], descs = [undefined], types = [undefined];
  const freeIds = [];
  // wrappers of Scheme objects -> {index, gen, kind, released}
  const wrappers = new WeakMapC();
  const errors = new WeakMapC();        // SchemeError -> the wrapper of what was raised
  const unwinds = new WeakSetC();
  const incompletes = new WeakSetC();   // SyntaxErrors of a source that is not finished
  let released = [];                    // index, gen, ... freed by the garbage collector
  let schemeIds = 0;                    // wrappers made and not released
  const registry = Registry ? new Registry(h => {
    released[released.length] = h.index;
    released[released.length] = h.gen;
    schemeIds--;
  }) : null;
  // calls of Scheme waiting to run (FIFO), those Scheme took and has not
  // settled yet, and the promises js-await waits for (id -> slot)
  const queue = [], calls = new MapC(), awaits = new MapC();
  let callSeq = 0, awaitSeq = 0;
  let consoleEnt = null;                // webjs.scm's writer for console()
  const apiEnts = [];                   // webjs.scm's procedures for `scheme'
  const noop = () => {};

  const addr = p => typeof p === 'bigint' ? toNumber(p) : p >>> 0;
  const text = (kind, s) => ({ kind, bytes: encoder.encode(s) });
  const readText = (p, n) => n > 0 ? decoder.decode(HEAPU8.subarray(addr(p), addr(p) + n)) : '';
  const isObject = x => x !== null && (typeof x === 'object' || typeof x === 'function');

  // DESC, how a record prints the object: may run the user's getters
  function descOf(v) {
    try {
      let d;
      if (typeof v === 'function') {
        const n = v.name;
        d = typeof n === 'string' && n !== '' ? 'function ' + n : 'function';
      } else if (typeof v === 'symbol') d = toStr(v);
      else if (isArray(v)) d = 'Array(' + v.length + ')';
      else {
        const t = v[toStringTag];
        if (typeof t === 'string') d = t;
        else {
          const p = getPrototypeOf(v), c = p && p.constructor, n = c && c.name;
          d = typeof n === 'string' && n !== '' ? n : 'Object';
        }
      }
      return d.length > 64 ? d.slice(0, 64) : d;
    } catch (e) { return 'object'; }
  }

  function intern(v) {
    let id = ids.get(v);
    if (id === undefined) {
      id = freeIds.length > 0 ? freeIds.pop() : objs.length;
      ids.set(v, id);
      objs[id] = v;
      counts[id] = 1;
      types[id] = typeof v;
    } else counts[id]++;
    descs[id] = descOf(v);
    return id;
  }

  function unref(id) {
    if (counts[id] > 1) counts[id]--;
    else if (counts[id] === 1) {
      counts[id] = 0;
      ids.delete(objs[id]);
      objs[id] = descs[id] = types[id] = undefined;
      freeIds.push(id);
    }
  }

  // JS -> Scheme: the descriptor of V (a HANDLE holds a count until
  // read, a SCHEME the wrapper, in `ref')
  function describe(v) {
    switch (typeof v) {
    case 'undefined': return { kind: UNDEFINED };
    case 'boolean': return { kind: v ? TRUE : FALSE };
    case 'number':
      return { kind: isInteger(v) && v <= MAX_SAFE && v >= -MAX_SAFE && !is(v, -0) ? INTEGER : FLONUM, num: v };
    case 'bigint': return text(BIGINT, toStr(v));
    case 'string': return text(STRING, v);
    case 'object':
      if (v === null) return { kind: NULL };
      // falls through
    default: {
      const w = wrappers.get(v);
      if (w !== undefined) return w.released ? { kind: RELEASED } : { kind: SCHEME, num: w.index, gen: w.gen, ref: v };
      return { kind: HANDLE, id: intern(v), taken: false };
    }
    }
  }

  const list = xs => {
    const c = [];
    for (let i = 0; i < xs.length; i++) c[i] = describe(xs[i]);
    return { kind: LIST, children: c };
  };

  // releases the counts of the handles never read
  function drop(ds) {
    for (let i = 0; i < ds.length; i++) {
      const d = ds[i];
      if (d.kind === HANDLE && !d.taken) { d.taken = true; unref(d.id); }
      else if (d.kind === LIST && d.at === undefined) drop(d.children);
    }
  }

  // The children of a LIST follow the top-level descriptors, so that
  // Scheme reads them with the same readers.
  function setInbox(ds) {
    drop(inbox);
    inbox = ds;
    for (let i = 0; i < inbox.length; i++) {
      const d = inbox[i];
      if (d.kind === LIST) {
        const c = d.children, at = [];
        for (let j = 0; j < c.length; j++) { at[j] = inbox.length; inbox[inbox.length] = c[j]; }
        d.at = at;
      }
    }
  }

  // the exception every function of the bridge rethrows while it is set
  // (an op returns ESCAPE for a SchemeEscape instead)
  function unwound() {
    const u = unwinding;
    if (u instanceof SchemeEscape) {
      unwinding = null;
      setInbox([]);
      return ESCAPE;
    }
    throw u;
  }

  // A Scheme procedure as a function: KIND is FUNCTION, METHOD to pass
  // `this' first, or ASYNC to queue every call.
  function schemeFunction(kind) {
    const f = function (...a) {
      if (unwinding !== null) throw unwinding;
      const ent = wrappers.get(f);
      if (ent.released) throw new ErrorC('released Scheme procedure');
      const ds = [];
      if (kind === METHOD) ds[0] = describe(this);
      for (let i = 0; i < a.length; i++) ds[ds.length] = describe(a[i]);
      if (unwinding !== null) { drop(ds); throw unwinding; }
      return kind === ASYNC || !reentry ? enqueue(ent, ds, f) : dispatch(ent, ds);
    };
    defineProperty(f, 'name', { value: '' });
    return f;
  }

  function wrap(index, gen, kind) {
    const w = kind === OBJECT_KIND ? freeze(new SchemeObject()) : schemeFunction(kind);
    wrappers.set(w, { index, gen, kind, released: false });
    if (registry) registry.register(w, { index, gen }, w);
    schemeIds++;
    return w;
  }

  // Runs ENT now, as a callback (webjs_dispatch), with arguments DS.
  // Scheme does not run user code: while it runs, a call of another
  // wrapper is no call it waits for (reentry is false), unless an op of
  // its own runs user code again.
  function dispatch(ent, ds) {
    const saved = reentry;
    let st;
    setInbox(ds);
    reentry = false;
    try {
      st = M['_webjs_dispatch'](ent.index, ent.gen, ds.length);
    } catch (e) {
      unwinding = e;
      if (isObject(e)) unwinds.add(e);
      throw e;
    } finally {
      reentry = saved;
    }
    switch (st) {
    case CB_OK: { const r = cbResult; cbResult = undefined; return r; }
    case CB_ERROR: { const e = cbError; cbError = null; throw e; }
    case CB_ESCAPE:
      unwinding = new SchemeEscape('a Scheme continuation leaves JavaScript');
      unwinds.add(unwinding);
      throw unwinding;
    case CB_TOO_DEEP: throw new RangeErrorC('too many nested calls between Scheme and JavaScript');
    case CB_RELEASED: throw new ErrorC('released Scheme procedure');
    default: throw new ErrorC('internal error: Scheme called outside a bridge operation');
    }
  }

  // the driver may have Scheme run: a call was queued, or a promise
  // js-await waits for settled
  function wake() {
    const w = M['_webrepl_js_wake'], f = M['onJsWake'];
    if (typeof w === 'function') w();
    if (typeof f === 'function') f();
  }

  // A call of Scheme while Scheme waits on no op: it cannot run now, and
  // is queued with its arguments DS, keeping its wrapper W.  Its promise
  // never counts as unhandled: Scheme reports an error itself, and a
  // caller that waits for the promise still sees it rejected.
  function enqueue(ent, ds, w) {
    let resolve, reject;
    const p = new PromiseC((res, rej) => { resolve = res; reject = rej; });
    apply(then, p, [undefined, noop]);
    queue[queue.length] = { id: ++callSeq, ent, ds, w, resolve, reject, rid: context };
    wake();
    return p;
  }

  // Settles a queued call's promise with F (its resolve or reject) and
  // X, later, at depth 0, in a microtask: resolving reads the `then' of
  // X, which may be the user's code (Promise.prototype.then would read
  // Promise[Symbol.species] now).  Every settlement goes so, in the
  // order Scheme ran the calls.
  function later(f, x) { microtask(() => f(x)); }

  // (its fields defined, not assigned: no setter of the user's runs)
  function schemeError(w, msg) {
    const e = new SchemeError(msg);
    defineProperty(e, 'schemeMessage', { value: msg, writable: true, enumerable: true, configurable: true });
    defineProperty(e, 'condition', { value: w, writable: true, enumerable: true, configurable: true });
    errors.set(e, w);
    return e;
  }

  // the bytes of an ArrayBuffer, a typed array or a DataView (WANT 0),
  // or of a typed array of a SRFI-4 element type (WANT -1), with it
  function bytesOf(x, want) {
    let type = 0, bytes;
    if (want === 0 && x instanceof AB) bytes = new U8(x).slice();
    else if (isView(x)) {
      if (want < 0) {
        type = x instanceof U8C ? 0 : -1;
        for (let t = 0; t < ELEMENTS.length && type < 0; t++) if (x instanceof ELEMENTS[t]) type = t;
        if (type < 0) throw new TypeErrorC('not a typed array of a SRFI-4 element type: ' + descOf(x));
      }
      bytes = new U8(x.buffer, x.byteOffset, x.byteLength).slice();
    } else throw new TypeErrorC((want < 0 ? 'not a typed array: ' : 'not an ArrayBuffer, a typed array or a DataView: ') +
                                (isObject(x) ? descOf(x) : toStr(x)));
    return { kind: BYTES, bytes, type };
  }

  const rest = (a, i) => { const r = []; for (let j = i; j < a.length; j++) r[r.length] = a[j]; return r; };

  // the user's code: the descriptor of the result of op CODE on A
  function run(code, a) {
    switch (code) {
    case GLOBAL: {
      let o = global;
      if (a.length > 0) {
        const path = toStr(a[0]).split('.');
        for (let i = 0; i < path.length; i++) o = o[path[i]];
      }
      return describe(o);
    }
    case REF: return describe(a[0][a[1]]);
    case SET: a[0][a[1]] = a[2]; return { kind: UNDEFINED };
    case HAS: return describe(a[1] in a[0]);
    case DELETE: return describe(deleteProperty(a[0], a[1]));
    case KEYS: return list(keys(a[0]));
    case CALL: return describe(apply(a[0], undefined, rest(a, 1)));
    case INVOKE: {
      const o = a[0], f = o[a[1]];
      if (typeof f !== 'function') throw new TypeErrorC(toStr(a[1]) + ' is not a function');
      return describe(apply(f, o, rest(a, 2)));
    }
    case NEW: return describe(construct(a[0], rest(a, 1)));
    case EVAL: return describe(geval(a[0]));
    case AWAIT: {
      // A[1]: whether js-await can wait (no callback is running); X when
      // it is no thenable, which Scheme has (nothing to read)
      const x = a[0];
      if (!isObject(x) || typeof x.then !== 'function') return { kind: UNDEFINED };
      if (!a[1]) return { kind: UNDEFINED, pending: true };
      const id = ++awaitSeq;
      awaits.set(id, { state: 0, ds: null });
      apply(then, apply(promiseResolve, PromiseC, [x]), [v => settle(id, v, false), e => settle(id, e, true)]);
      return { kind: INTEGER, num: id, pending: true };
    }
    case INSTANCEOF: return describe(a[0] instanceof a[1]);
    case SAME: return describe(is(a[0], a[1]));
    case TOSTRING: return describe(toStr(a[0]));
    case FROM: return list(arrayFrom(a[0]));
    case ENTRIES: {
      const es = entries(a[0]), c = [];
      for (let i = 0; i < es.length; i++) c[i] = list(es[i]);
      return { kind: LIST, children: c };
    }
    case OBJECT: {
      const o = {};
      for (let i = 0; i + 1 < a.length; i += 2)
        defineProperty(o, a[i], { value: a[i + 1], writable: true, enumerable: true, configurable: true });
      return describe(o);
    }
    case BYTESOF: return bytesOf(a[0], a[1]);
    case VALUE_OF: return describe(a[0]);
    case RUN_JS: {
      // A: the source, its name, whether it is the REPL's (,js) and
      // whether Scheme can wait (no callback is running)
      if (lexer === null) throw new ErrorC('JavaScript cells need js-lexer.js, which the worker did not load');
      const r = lexer.rewrite(toStr(a[0]));
      let v;
      try { v = geval(r.code + '\n//# sourceURL=' + toStr(a[1])); }
      catch (e) {
        if (e instanceof SyntaxErrorC) {
          if (r.incomplete) incompletes.add(e);
          else if (r.topAwait) e = topAwaitError();
        }
        throw e;
      }
      if (isObject(v) && typeof v.then === 'function') {
        if (!a[3]) return { kind: UNDEFINED, pending: true };     // Scheme raises
        const id = ++awaitSeq;
        awaits.set(id, { state: 0, ds: null, inspect: true });
        apply(then, apply(promiseResolve, PromiseC, [v]), [x => settle(id, x, false), e => settle(id, e, true)]);
        return { kind: INTEGER, num: id, pending: true };
      }
      return shown(v);
    }
    default: throw new ErrorC('internal error: no bridge operation ' + code);
    }
  }

  // the message ("Name: message"), name and stack of exception E: may
  // run the user's getters
  function messageOf(e) {
    let msg = 'uncaught JavaScript exception', name, stack;
    try {
      if (isObject(e)) {
        const n = e.name;
        if (typeof n === 'string') {
          name = n;
          const m = e.message;
          msg = m === undefined || m === '' ? n : n + ': ' + toStr(m);
        } else msg = toStr(e);
        const s = e.stack;
        if (s !== undefined && s !== null) stack = toStr(s);
      } else msg = toStr(e);
    } catch (x) { /* the fallback message */ }
    return { msg, name, stack };
  }

  const framesOf = stack => lexer !== null && stack !== undefined ? lexer.frames(stack) : [];

  // An exception E the user's code threw, as the status of an op and
  // the descriptors of the inbox: a SchemeError of this instance as what
  // was raised, else the value, its message, name, stack, frames
  // ([where, proc] lists, the innermost last) and whether it is the
  // SyntaxError of an unfinished source
  function errorOf(code, e) {
    const w = errors.get(e);
    if (w !== undefined) return { st: SCHEME_ERROR, ds: [describe(w)] };
    let { msg, name, stack } = messageOf(e);
    if ((code === EVAL || code === RUN_JS) && e instanceof EvalErrorC && /Content.Security.Policy/i.test(msg)) {
      e = new EvalErrorC("the server's Content-Security-Policy for repl-worker.js forbids eval: " +
                         "JavaScript cells, ,js and js-eval need script-src 'unsafe-eval' there");
      msg = 'EvalError: ' + e.message;
      name = 'EvalError';
      stack = undefined;
    }
    const fs = framesOf(stack), frames = [];
    for (let i = 0; i < fs.length; i++) frames[i] = list(fs[i]);
    return { st: JS_ERROR,
             ds: [describe(e), text(STRING, msg),
                  name === undefined ? { kind: UNDEFINED } : text(STRING, name),
                  stack === undefined ? { kind: UNDEFINED } : text(STRING, stack),
                  { kind: LIST, children: frames },
                  { kind: incompletes.has(e) ? TRUE : FALSE }] };
  }

  function topAwaitError() {
    return new SyntaxErrorC('await is not allowed at the top level of a JavaScript cell or a ,js line: ' +
                            'make the value a promise, as in (async () => { const x = await f(); return x })(), ' +
                            'and it is waited for');
  }

  // what op returns for an exception E the user's code threw
  function thrown(code, e) {
    const r = errorOf(code, e);
    if (unwinding !== null) { drop(r.ds); return unwound(); }
    setInbox(r.ds);
    return r.st;
  }

  // A promise js-await waits for (slot ID) settled, at depth 0: its
  // value, or why it was rejected, is described now (states 1, or 2 for
  // a JavaScript error and 3 for a Scheme one, as an op's statuses);
  // that of a cell (RUN_JS) with its text.  A slot js-await left (Stop,
  // an error) is gone already.
  function settle(id, v, rejected) {
    const slot = awaits.get(id);
    if (slot === undefined) return;
    const r = rejected ? errorOf(0, v) : { st: VALUE, ds: [slot.inspect ? shown(v) : describe(v)] };
    slot.ds = r.ds;
    slot.state = r.st + 1;
    wake();
  }

  // console(): its arguments as text, the way a console shows them
  // (there is no %s substitution)
  function brief(x, d) {
    switch (typeof x) {
    case 'string': return d === 0 ? x : stringify(x);
    case 'bigint': return toStr(x) + 'n';
    case 'symbol': return apply(symbolToString, x, []);
    case 'function': return '[Function' + (typeof x.name === 'string' && x.name !== '' ? ' ' + x.name : '') + ']';
    case 'object': {
      if (x === null) return 'null';
      if (x instanceof ErrorC) {
        const s = x.stack;
        return typeof s === 'string' && s !== '' ? s : toStr(x.name) + ': ' + toStr(x.message);
      }
      const plain = isArray(x) || getPrototypeOf(x) === ObjectProto || getPrototypeOf(x) === null;
      if (!plain) return apply(objectToString, x, []);
      if (d >= 2) return isArray(x) ? '[Array]' : '[Object]';
      let s = '', n = 0;
      if (isArray(x)) {
        for (; n < x.length && n < 100; n++) s += (n ? ',' : '') + brief(x[n], d + 1);
        return '[' + s + (x.length > 100 ? ',...' : '') + ']';
      }
      const ks = keys(x);
      for (; n < ks.length && n < 100; n++) s += (n ? ',' : '') + stringify(ks[n]) + ':' + brief(x[ks[n]], d + 1);
      return '{' + s + (ks.length > 100 ? ',...' : '') + '}';
    }
    default: return toStr(x);
    }
  }
  function format(a) {
    let s = '';
    for (let i = 0; i < a.length; i++) {
      let t;
      try { t = brief(a[i], 0); } catch (e) { t = '[object]'; }
      s += (i ? ' ' : '') + t;
    }
    return s + '\n';
  }

  // The JavaScript text of a cell's value V, as a console shows it:
  // strings quoted, arrays and objects by their entries (at most
  // INSPECT_ENTRIES each, INSPECT_DEPTH levels deep), a cycle as
  // [Circular].  May run the user's getters.
  function inspect(v) {
    const path = new SetC();
    let room = INSPECT_MAX;
    const IDENT = /^[A-Za-z_$][\w$]*$/;
    const key = k => IDENT.test(k) ? k : stringify(k);
    // the entries of X, from EACH (which takes a function to call with
    // each one's text until it returns false), N in all
    function entries(x, d, n, each) {
      if (path.has(x)) return null;
      path.add(x);
      const parts = [];
      each(t => {
        if (parts.length === INSPECT_ENTRIES || room < 0) return false;
        parts[parts.length] = t;
        room -= t.length + 2;
        return true;
      });
      path.delete(x);
      if (n > parts.length) parts[parts.length] = '... ' + (n - parts.length) + ' more items';
      return parts.join(', ');
    }
    function nameOf(x) {
      const p = getPrototypeOf(x), c = p && p.constructor, n = c && c.name;
      return typeof n === 'string' && n !== '' ? n : 'Object';
    }
    function ins(x, d) {
      switch (typeof x) {
      case 'undefined': return 'undefined';
      case 'boolean': return x ? 'true' : 'false';
      case 'number': return is(x, -0) ? '-0' : toStr(x);
      case 'bigint': return toStr(x) + 'n';
      case 'string': return stringify(x);
      case 'symbol': return apply(symbolToString, x, []);
      case 'function': {
        let src = '';
        try { src = apply(fnToString, x, []); } catch (e) { /* a revoked proxy, say */ }
        const n = typeof x.name === 'string' && x.name !== '' ? x.name : '(anonymous)';
        return /^class\b/.test(src) ? '[class ' + n + ']' : '[Function ' + n + ']';
      }
      }
      if (x === null) return 'null';
      const w = wrappers.get(x);
      if (w !== undefined) return '[SchemeObject]';
      if (path.has(x)) return '[Circular]';
      if (isArray(x)) {
        if (d >= INSPECT_DEPTH) return '[Array]';
        const s = entries(x, d, x.length, f => { for (let i = 0; i < x.length && f(ins(x[i], d + 1)); i++); });
        return '[' + s + ']';
      }
      if (isView(x) && !(x instanceof DataViewC)) {
        const t = apply(objectToString, x, []).slice(8, -1), n = x.length;
        if (d >= INSPECT_DEPTH) return '[' + t + ']';
        return t + '(' + n + ') [' + entries(x, d, n, f => { for (let i = 0; i < n && f(ins(x[i], d + 1)); i++); }) + ']';
      }
      if (x instanceof ErrorC) {
        const s = x.stack;
        return typeof s === 'string' && s !== '' ? s : toStr(x.name) + ': ' + toStr(x.message);
      }
      if (x instanceof DateC) {
        try { return apply(dateToISO, x, []); } catch (e) { return 'Invalid Date'; }
      }
      if (x instanceof RegExpC) return apply(regexToString, x, []);
      if (x instanceof MapC) {
        const n = apply(mapSize, x, []);
        if (d >= INSPECT_DEPTH) return '[Map]';
        return 'Map(' + n + ') {' + entries(x, d, n, f => {
          for (const [k, v] of apply(mapEntries, x, [])) if (!f(ins(k, d + 1) + ' => ' + ins(v, d + 1))) break;
        }) + '}';
      }
      if (x instanceof SetC) {
        const n = apply(setSize, x, []);
        if (d >= INSPECT_DEPTH) return '[Set]';
        return 'Set(' + n + ') {' + entries(x, d, n, f => {
          for (const v of apply(setValues, x, [])) if (!f(ins(v, d + 1))) break;
        }) + '}';
      }
      if (x instanceof PromiseC) return 'Promise {}';
      const p = getPrototypeOf(x);
      const head = p === ObjectProto ? '' : p === null ? '[Object: null prototype] ' : nameOf(x) + ' ';
      if (d >= INSPECT_DEPTH) return '[' + (p === ObjectProto || p === null ? 'Object' : nameOf(x)) + ']';
      const ks = keys(x);
      if (ks.length === 0) return head + '{}';
      return head + '{' + entries(x, d, ks.length, f => {
        for (let i = 0; i < ks.length && f(key(ks[i]) + ': ' + ins(x[ks[i]], d + 1)); i++);
      }) + '}';
    }
    const s = ins(v, 0);
    return s.length > INSPECT_MAX ? s.slice(0, INSPECT_MAX) + '\u2026' : s;
  }

  // the descriptor of a cell's value V: a list of V and its text, or
  // undefined when Scheme shows it (undefined, a Scheme object)
  function shown(v) {
    let t;
    if (v === undefined || wrappers.has(v)) t = { kind: UNDEFINED };
    else {
      let s;
      try { s = inspect(v); } catch (e) { s = '[object]'; }
      t = text(STRING, s);
    }
    return { kind: LIST, children: [describe(v), t] };
  }

  // Attribution (see above).  The events of a frame go straight to fd
  // 3, after what was written there before: outside an op Scheme's
  // buffers are empty.
  function emit(obj) {
    const out = M['onSchemeOutput'];
    if (typeof out === 'function') out(3, encoder.encode(stringify(obj) + '\n'));
  }

  // an exception X a function of cell RID left uncaught, as the error of
  // a cell (webnb.scm's error-object), with the frames of its stack
  function jsErrorObject(x, rid) {
    const { msg, stack } = messageOf(x), fs = framesOf(stack), chain = [];
    const cell = 'In[' + rid + ']:';
    let line = null;
    for (let i = 0; i < fs.length; i++) chain[i] = { where: fs[i][0], proc: fs[i][1], form: null };
    for (let i = fs.length - 1; i >= 0 && line === null; i--)
      if (fs[i][0].startsWith(cell)) line = toNumber(fs[i][0].slice(cell.length));
    return { text: 'Uncaught ' + msg, kind: ['exn', 'js'], location: null, form: null, line, chain };
  }

  // F, a function of RID called later: in its context, framed by
  // async-start and async-done when another one is current.  CATCHING
  // (timers, microtasks): an exception it throws is reported there and
  // swallowed; else (promise reactions) it goes on, rejecting the
  // derived promise.  An unwind goes on at once.
  function framed(rid, f, self, a, catching) {
    if (rid === context) return apply(f, self, a);
    const saved = context;
    context = rid;
    emit({ ev: 'async-start', rid });
    try {
      const r = apply(f, self, a);
      emit({ ev: 'async-done', rid, status: 'ok' });
      return r;
    } catch (x) {
      if (isObject(x) && unwinds.has(x)) throw x;
      if (!catching) {
        emit({ ev: 'async-done', rid, status: 'ok' });
        throw x;
      }
      emit({ ev: 'async-done', rid, status: 'error', error: jsErrorObject(x, rid) });
      return undefined;
    } finally {
      context = saved;
    }
  }

  function attributed(f, catching) {
    if (context === 0 || typeof f !== 'function') return f;
    const rid = context;
    return function (...a) { return framed(rid, f, this, a, catching); };
  }

  // `scheme': procedure CODE of webjs.scm on A, at once or queued
  function callApi(code, a) {
    if (unwinding !== null) throw unwinding;
    const ent = apiEnts[code];
    if (ent === undefined) throw new ErrorC('scheme: the bridge is not ready');
    const ds = [];
    for (let i = 0; i < a.length; i++) ds[i] = describe(a[i]);
    if (unwinding !== null) { drop(ds); throw unwinding; }
    return reentry ? dispatch(ent, ds) : enqueue(ent, ds, null);
  }

  // what scheme.text and scheme.show take: a string or a Scheme object
  // as itself, any other value as its JavaScript text
  const textOf = x => typeof x === 'string' || wrappers.has(x) ? x : inspect(x);

  // scheme.env: a Proxy of the toplevel, whose reads and writes are
  // Scheme's, but for symbols, then, toJSON and the names of
  // Object.prototype, which are those of a plain object (so that it
  // prints as [object SchemeEnvironment], and is no thenable)
  const envTarget = freeze(create(null));
  const envPlain = freeze(create(ObjectProto, { [toStringTag]: { value: 'SchemeEnvironment' } }));
  const outside = k => new ErrorC('scheme.env.' + toStr(k) + ': Scheme can be read only while it waits on ' +
                                  'this JavaScript (a cell, js-call); use scheme.call or scheme.async here');
  const env = new ProxyC(envTarget, {
    get(t, k) {
      if (typeof k === 'symbol' || k === 'then' || k === 'toJSON' || OBJECT_NAMES.has(k)) return envPlain[k];
      if (!reentry) throw outside(k);
      const r = callApi(API_ENV_REF, [k]);
      return isArray(r) ? r[0] : undefined;
    },
    set(t, k, v) {
      if (typeof k === 'symbol') return false;
      if (!reentry) throw outside(k);
      callApi(API_ENV_SET, [k, v, typeof v === 'function' && !wrappers.has(v)]);
      return true;
    },
    has(t, k) { return typeof k !== 'symbol' && reentry && callApi(API_ENV_HAS, [k]) === true; },
    ownKeys() { return []; },
    getOwnPropertyDescriptor() { return undefined; },
    defineProperty() { return false; },
    deleteProperty() { return false; },
    getPrototypeOf() { return null; },
  });

  const scheme = freeze({
    eval(src) { return callApi(API_EVAL, [toStr(src)]); },
    env,
    call(name, ...a) { return callApi(API_CALL, [toStr(name), ...a]); },
    // a function that always queues its calls (a promise, even in a cell)
    async(f) {
      if (typeof f === 'string') {
        const name = f;
        return (...a) => {
          if (unwinding !== null) throw unwinding;
          const ent = apiEnts[API_CALL];
          if (ent === undefined) throw new ErrorC('scheme: the bridge is not ready');
          const ds = [describe(name)];
          for (let i = 0; i < a.length; i++) ds[ds.length] = describe(a[i]);
          return enqueue(ent, ds, null);
        };
      }
      const w = typeof f === 'function' ? wrappers.get(f) : undefined;
      if (w === undefined || w.kind === OBJECT_KIND) throw new TypeErrorC('scheme.async: not a Scheme procedure or name');
      return function (...a) {
        if (unwinding !== null) throw unwinding;
        if (w.released) throw new ErrorC('released Scheme procedure');
        const ds = [];
        if (w.kind === METHOD) ds[0] = describe(this);
        for (let i = 0; i < a.length; i++) ds[ds.length] = describe(a[i]);
        return enqueue(w, ds, f);
      };
    },
    list(...xs) { return callApi(API_LIST, xs); },
    toArray(x, deep) { return callApi(API_TO_ARRAY, [x, !!deep]); },
    html(s) { return callApi(API_HTML, [s]); },
    svg(s) { return callApi(API_SVG, [s]); },
    markdown(s) { return callApi(API_MARKDOWN, [s]); },
    text(x) { return callApi(API_TEXT, [textOf(x)]); },
    table(rows, header) { return callApi(API_TABLE, header === undefined ? [rows] : [rows, header]); },
    image(bytes, mime) { return callApi(API_IMAGE, mime === undefined ? [bytes] : [bytes, mime]); },
    show(x, id) { return callApi(API_SHOW, id === undefined ? [textOf(x)] : [textOf(x), id]); },
    clearOutput() { return callApi(API_CLEAR, []); },
  });

  const B = {
    SchemeError,
    scheme,

    // (webjs_op) op CODE on the ARGC values on top of the stack
    op(code, argc) {
      const a = args.splice(args.length - argc, argc);
      args.length = 0;
      setInbox([]);
      const saved = reentry;
      reentry = true;
      depth++;
      try {
        const d = run(code, a);
        if (unwinding !== null) {
          if (d.pending && d.num !== undefined) awaits.delete(d.num);
          drop([d]);
          return unwound();
        }
        setInbox([d]);
        return d.pending ? PENDING : VALUE;
      } catch (e) {
        if (unwinding !== null) return unwound();
        return thrown(code, e);
      } finally {
        reentry = saved;
        depth--;
        // the outermost op: nothing of the user's lies between here and
        // where the unwind lands (a longjmp's C frames, the driver's guard)
        if (depth === 0 && unwinding !== null && !(unwinding instanceof SchemeEscape)) unwinding = null;
      }
    },

    // (webjs_slice_start) no op lives across slices
    reset() {
      args.length = 0;
      setInbox([]);
      depth = 0;
      reentry = false;
      unwinding = null;
      cbResult = undefined;
      cbError = null;
    },

    // the pushers (Scheme -> JS)
    argsBegin() { args.length = 0; },
    pushUndefined() { args[args.length] = undefined; },
    pushNull() { args[args.length] = null; },
    pushBool(b) { args[args.length] = b !== 0; },
    pushNumber(x) { args[args.length] = x; },
    pushBigint(p, n) { args[args.length] = toBigInt(readText(p, n)); },
    pushString(p, n) { args[args.length] = readText(p, n); },
    pushHandle(id) { args[args.length] = objs[id]; },
    pushScheme(index, gen, kind) { args[args.length] = wrap(index, gen, kind); },
    pushArray(n) { const a = args.splice(args.length - n, n); args[args.length] = a; },
    pushBytes(type, p, n) {
      const a = addr(p), bytes = HEAPU8.slice(a, a + n);
      args[args.length] = type === 0 ? bytes : new ELEMENTS[type](bytes.buffer);
    },

    // the readers (JS -> Scheme)
    inboxSize() { return inbox.length; },
    kind(i) { return inbox[i].kind; },
    number(i) { return inbox[i].num; },
    length(i) { const d = inbox[i]; return d.kind === LIST ? d.children.length : d.bytes.length; },
    copy(i, p) { HEAPU8.set(inbox[i].bytes, addr(p)); },
    bytesType(i) { return inbox[i].type; },
    id(i) {
      const d = inbox[i];
      if (d.kind !== HANDLE) return d.num;
      d.taken = true;                   // the record has its count now
      return d.id;
    },
    gen(i) { return inbox[i].gen; },
    child(i, j) { return inbox[i].at[j]; },
    // DESC (WHAT 0) or the typeof (1) of handle ID, for textCopy
    text(id, what) {
      const s = what === 0 ? descs[id] : types[id];
      scratch = encoder.encode(s === undefined ? '' : s);
      return scratch.length;
    },
    textCopy(p) { HEAPU8.set(scratch, addr(p)); },

    unref,
    // the result of a callback, or its error: what Scheme pushed
    callbackResult() { cbResult = args.pop(); args.length = 0; },
    // (undefined pushed for what was raised: an Error of the message)
    makeError() {
      const msg = args.pop(), w = args.pop();
      args.length = 0;
      cbError = w === undefined ? new ErrorC(msg) : schemeError(w, msg);
    },
    // js-function, js-method and js-async-function: a wrapper for good,
    // as a handle
    makeFunction(index, gen, kind) { return intern(wrap(index, gen, kind)); },
    releaseFunction(id) {
      const w = objs[id], ent = w === undefined ? undefined : wrappers.get(w);
      if (ent === undefined || ent.released) return;
      ent.released = true;
      if (registry) registry.unregister(w);
      schemeIds--;
      for (let i = 0; i < queue.length;) {
        const c = queue[i];
        if (c.ent !== ent) { i++; continue; }
        queue.splice(i, 1);
        drop(c.ds);
        later(c.reject, new ErrorC('released Scheme procedure'));
      }
    },

    // The queued calls (webjs.scm's run-one-pending!).  pendingTake gives
    // the id of the first one, 0 if there is none, and leaves the
    // procedure (SCHEME, or RELEASED) and its arguments in the inbox.
    pendingTake() {
      takenRid = 0;
      if (queue.length === 0) return 0;
      const c = queue.shift(), e = c.ent;
      takenRid = c.rid;
      calls.set(c.id, c);
      setInbox([e.released ? { kind: RELEASED } : { kind: SCHEME, num: e.index, gen: e.gen }, ...c.ds]);
      return c.id;
    },
    // the context it was queued in (0 for none)
    pendingRid() { return takenRid; },
    // its procedure is gone
    pendingDrop(id) {
      const c = calls.get(id);
      calls.delete(id);
      if (c !== undefined) later(c.reject, new ErrorC('released Scheme procedure'));
    },
    // HOW: RESOLVE, REJECT_SCHEME or REJECT, with what was pushed
    settle(id, how) {
      const c = calls.get(id);
      const msg = how === RESOLVE ? undefined : args.pop(), v = how === REJECT ? undefined : args.pop();
      args.length = 0;
      calls.delete(id);
      if (c === undefined) return;
      if (how === RESOLVE) later(c.resolve, v);
      else later(c.reject, how === REJECT ? new ErrorC(msg) : schemeError(v, msg));
    },

    // js-await's slots: 0 while pending, then 1 (a value), 2 (a
    // JavaScript error) or 3 (a Scheme error), and -1 once it is gone;
    // take moves its descriptors into the inbox, abandon drops it (a
    // settlement then goes nowhere)
    awaitState(id) { const s = awaits.get(id); return s === undefined ? -1 : s.state; },
    awaitTake(id) {
      const s = awaits.get(id);
      awaits.delete(id);
      setInbox(s === undefined || s.ds === null ? [] : s.ds);
    },
    awaitAbandon(id) {
      const s = awaits.get(id);
      awaits.delete(id);
      if (s !== undefined && s.ds !== null) drop(s.ds);
    },

    // the worker's console (FD 1 or 2, the arguments A): see above
    setConsole(index, gen) { consoleEnt = { index, gen, kind: FUNCTION, released: false }; },
    console(fd, a) {
      const s = format(a);
      if (unwinding !== null) throw unwinding;
      fd = fd === 2 ? 2 : 1;
      if (reentry && consoleEnt !== null) {
        try { dispatch(consoleEnt, [describe(fd), describe(s)]); return; }
        catch (e) { if (unwinding !== null) throw unwinding; }     // (too deep, say) go straight
      }
      const out = M['onSchemeOutput'];
      if (typeof out === 'function') out(fd, encoder.encode(s));
    },
    // the wrappers the garbage collector freed (index, gen), drained by Scheme
    releasedCount() { return released.length >> 1; },
    releasedIndex(k) { return released[2 * k]; },
    releasedGen(k) { return released[2 * k + 1]; },
    releasedClear() { released = []; },

    // the procedure of webjs.scm for `scheme''s CODE, for good
    setApi(code, index, gen) { apiEnts[code] = { index, gen, kind: FUNCTION, released: false }; },

    // (webjs_set_context) the rid of the cell that runs, 0 for none
    setContext(rid) { context = rid >>> 0; },
    // F (a function) to call later in this context: a timer's or a
    // microtask's, whose exception is reported, or a promise reaction's,
    // whose exception goes on
    attribute(f) { return attributed(f, true); },
    attributeReaction(f) { return attributed(f, false); },

    // (webjs_incomplete) whether the source Scheme pushed is unfinished
    incomplete() {
      const src = args.pop();
      args.length = 0;
      return lexer !== null && lexer.incomplete(toStr(src)) ? 1 : 0;
    },
    frames(stack) { return framesOf(toStr(stack)); },

    isUnwind(x) { return isObject(x) && unwinds.has(x); },
    // for the tests
    stats() {
      let handles = 0, total = 0;
      for (let i = 1; i < counts.length; i++) if (counts[i] > 0) { handles++; total += counts[i]; }
      return { handles, counts: total, schemeIds, queued: queue.length, running: calls.size,
               awaits: awaits.size, depth, unwinding: unwinding !== null };
    },
  };
  return B;
})();
