/* webjs-main.c - C glue of the bridge between Scheme and JavaScript
;
; Copyright (c) 2026, The CHICKEN Team
; All rights reserved.
;
; Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following
; conditions are met:
;
;   Redistributions of source code must retain the above copyright notice, this list of conditions and the following
;     disclaimer.
;   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
;     disclaimer in the documentation and/or other materials provided with the distribution.
;   Neither the name of the author nor the names of its contributors may be used to endorse or promote
;     products derived from this software without specific prior written permission.
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
; AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
; CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
; OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
; POSSIBILITY OF SUCH DAMAGE.
*/

/* The C entries of the bridge, called by webjs.scm, and the EM_JS
 * stubs behind them, which call its JavaScript half (webjs-pre.js,
 * Module['webjs'] of this instance).  A pointer reaches JS as a BigInt
 * on wasm64 (MEMORY64), as a Number on wasm32; the bridge converts it.
 *
 * webjs_op, called through a foreign-safe-lambda, is the only entry
 * that runs JavaScript of the user's: the others only move values to
 * and from the bridge.  The user's code may call Scheme back through
 * webjs_dispatch, which runs the trampoline of webjs.scm (a
 * define-external) as a callback, as long as it is nested in an op of
 * its own and the nursery has room for one more level (see below).
 * Calls from JavaScript at any other time are queued there, and Scheme
 * takes them (webjs_pending_take) at its next toplevel wait. */

#include "chicken.h"
#include "webrepl.h"
#include <emscripten.h>

/* Each level of calls between Scheme and JavaScript keeps the frames
 * of an op and of a callback on the C stack, where CHICKEN's nursery
 * lies: the levels below a callback shrink the nursery it runs in,
 * until its minor collections free nothing and it hangs.  A call that
 * would leave less than WEBJS_NURSERY_MARGIN bytes, or nest deeper
 * than WEBJS_MAX_NESTING levels (which bounds the engine's stack, which
 * grows by a few JavaScript frames at each level), is refused, and the
 * caller gets a RangeError. */
#define WEBJS_MAX_NESTING    100
#define WEBJS_NURSERY_MARGIN (64 * 1024)

/* the statuses of webjs_dispatch, as webjs.scm's CB-... */
enum { WEBJS_CB_OK = 0, WEBJS_CB_ERROR = 1, WEBJS_CB_ESCAPE = 2, WEBJS_CB_TOO_DEEP = 3,
       WEBJS_CB_RELEASED = 4, WEBJS_CB_UNSAFE = 5 };

static int ops_active, live_calls;

extern void __real__exit(int code) C_noret;

EM_JS(int, js_op, (int op, int argc), { return Module['webjs'].op(op, argc); });
EM_JS(void, js_reset, (void), { Module['webjs'].reset(); });
EM_JS(void, js_args_begin, (void), { Module['webjs'].argsBegin(); });
EM_JS(void, js_push_undefined, (void), { Module['webjs'].pushUndefined(); });
EM_JS(void, js_push_null, (void), { Module['webjs'].pushNull(); });
EM_JS(void, js_push_bool, (int b), { Module['webjs'].pushBool(b); });
EM_JS(void, js_push_number, (double x), { Module['webjs'].pushNumber(x); });
EM_JS(void, js_push_bigint, (const unsigned char *p, int n), { Module['webjs'].pushBigint(p, n); });
EM_JS(void, js_push_string, (const unsigned char *p, int n), { Module['webjs'].pushString(p, n); });
EM_JS(void, js_push_handle, (int id), { Module['webjs'].pushHandle(id); });
EM_JS(void, js_push_scheme, (int index, int gen, int kind), { Module['webjs'].pushScheme(index, gen, kind); });
EM_JS(void, js_push_array, (int n), { Module['webjs'].pushArray(n); });
EM_JS(void, js_push_bytes, (int type, const unsigned char *p, int n), { Module['webjs'].pushBytes(type, p, n); });
EM_JS(int, js_inbox_size, (void), { return Module['webjs'].inboxSize(); });
EM_JS(int, js_kind, (int i), { return Module['webjs'].kind(i); });
EM_JS(double, js_number, (int i), { return Module['webjs'].number(i); });
EM_JS(int, js_length, (int i), { return Module['webjs'].length(i); });
EM_JS(void, js_copy, (int i, unsigned char *p), { Module['webjs'].copy(i, p); });
EM_JS(int, js_bytes_type, (int i), { return Module['webjs'].bytesType(i); });
EM_JS(int, js_id, (int i), { return Module['webjs'].id(i); });
EM_JS(int, js_gen, (int i), { return Module['webjs'].gen(i); });
EM_JS(int, js_child, (int i, int j), { return Module['webjs'].child(i, j); });
EM_JS(int, js_text, (int id, int what), { return Module['webjs'].text(id, what); });
EM_JS(void, js_text_copy, (unsigned char *p), { Module['webjs'].textCopy(p); });
EM_JS(void, js_unref, (int id), { Module['webjs'].unref(id); });
EM_JS(void, js_callback_result, (void), { Module['webjs'].callbackResult(); });
EM_JS(void, js_make_error, (void), { Module['webjs'].makeError(); });
EM_JS(int, js_make_function, (int index, int gen, int kind), { return Module['webjs'].makeFunction(index, gen, kind); });
EM_JS(void, js_release_function, (int id), { Module['webjs'].releaseFunction(id); });
EM_JS(int, js_released_count, (void), { return Module['webjs'].releasedCount(); });
EM_JS(int, js_released_index, (int k), { return Module['webjs'].releasedIndex(k); });
EM_JS(int, js_released_gen, (int k), { return Module['webjs'].releasedGen(k); });
EM_JS(void, js_released_clear, (void), { Module['webjs'].releasedClear(); });
EM_JS(int, js_pending_take, (void), { return Module['webjs'].pendingTake(); });
EM_JS(void, js_pending_drop, (int id), { Module['webjs'].pendingDrop(id); });
EM_JS(void, js_settle, (int id, int how), { Module['webjs'].settle(id, how); });
EM_JS(int, js_await_state, (int id), { return Module['webjs'].awaitState(id); });
EM_JS(void, js_await_take, (int id), { Module['webjs'].awaitTake(id); });
EM_JS(void, js_await_abandon, (int id), { Module['webjs'].awaitAbandon(id); });
EM_JS(void, js_set_console, (int index, int gen), { Module['webjs'].setConsole(index, gen); });
EM_JS(void, js_set_context, (int rid), { Module['webjs'].setContext(rid); });
EM_JS(int, js_pending_rid, (void), { return Module['webjs'].pendingRid(); });
EM_JS(void, js_set_api, (int code, int index, int gen), { Module['webjs'].setApi(code, index, gen); });
EM_JS(int, js_incomplete, (void), { return Module['webjs'].incomplete(); });


/* Called from webjs.scm (through a foreign-safe-lambda) */

int webjs_op(int op, int argc)
{
  int st;

  ++ops_active;
  st = js_op(op, argc);
  --ops_active;
  /* An exit inside a callback goes on out of the bridge (webjs-pre.js
   * rethrows it), whatever the user's code did with it: this is a last
   * resort. */
  if(webrepl_exited()) __real__exit(webrepl_exit_code());
  return st;
}


/* Called from webjs.scm (through plain foreign-lambdas: no user code) */

void webjs_args_begin(void) { js_args_begin(); }
void webjs_push_undefined(void) { js_push_undefined(); }
void webjs_push_null(void) { js_push_null(); }
void webjs_push_bool(int b) { js_push_bool(b); }
void webjs_push_number(double x) { js_push_number(x); }
void webjs_push_bigint(const unsigned char *p, int n) { js_push_bigint(p, n); }
void webjs_push_string(const unsigned char *p, int n) { js_push_string(p, n); }
void webjs_push_handle(int id) { js_push_handle(id); }
void webjs_push_scheme(int index, int gen, int kind) { js_push_scheme(index, gen, kind); }
void webjs_push_array(int n) { js_push_array(n); }
void webjs_push_bytes(int type, const unsigned char *p, int n) { js_push_bytes(type, p, n); }
int webjs_inbox_size(void) { return js_inbox_size(); }
int webjs_kind(int i) { return js_kind(i); }
double webjs_number(int i) { return js_number(i); }
int webjs_length(int i) { return js_length(i); }
void webjs_copy(int i, unsigned char *buf) { js_copy(i, buf); }
int webjs_bytes_type(int i) { return js_bytes_type(i); }
int webjs_id(int i) { return js_id(i); }
int webjs_gen(int i) { return js_gen(i); }
int webjs_child(int i, int j) { return js_child(i, j); }
int webjs_text(int id, int what) { return js_text(id, what); }
void webjs_text_copy(unsigned char *buf) { js_text_copy(buf); }
void webjs_unref(int id) { js_unref(id); }
void webjs_callback_result(void) { js_callback_result(); }
void webjs_make_error(void) { js_make_error(); }
int webjs_make_function(int index, int gen, int kind) { return js_make_function(index, gen, kind); }
void webjs_release_function(int id) { js_release_function(id); }
int webjs_released_count(void) { return js_released_count(); }
int webjs_released_index(int k) { return js_released_index(k); }
int webjs_released_gen(int k) { return js_released_gen(k); }
void webjs_released_clear(void) { js_released_clear(); }
int webjs_pending_take(void) { return js_pending_take(); }
void webjs_pending_drop(int id) { js_pending_drop(id); }
void webjs_settle(int id, int how) { js_settle(id, how); }
int webjs_await_state(int id) { return js_await_state(id); }
void webjs_await_take(int id) { js_await_take(id); }
void webjs_await_abandon(int id) { js_await_abandon(id); }
void webjs_set_console(int index, int gen) { js_set_console(index, gen); }
void webjs_set_context(int rid) { js_set_context(rid); }
int webjs_pending_rid(void) { return js_pending_rid(); }
void webjs_set_api(int code, int index, int gen) { js_set_api(code, index, gen); }
int webjs_incomplete(void) { return js_incomplete(); }
int webjs_live_calls(void) { return live_calls; }
int webjs_ops_active(void) { return ops_active; }


/* Called from webrepl-main.c: no op lives across slices (an op never
 * returns to the host, and yields are refused inside a callback) */

void webjs_slice_start(void)
{
  ops_active = live_calls = 0;
  js_reset();
}


/* The API for the bridge's JavaScript: a call of the Scheme procedure
 * of entry INDEX (generation GEN) of webjs.scm's table, with the ARGC
 * arguments of the inbox.  Only while an op of its own runs the user's
 * code: CHICKEN cannot take a callback anywhere else (and webjs-pre.js
 * does not ask then).  The stack grows downward on wasm. */

EMSCRIPTEN_KEEPALIVE int webjs_dispatch(int index, int gen, int argc)
{
  C_word left = (C_byte *)C_stack_pointer_test - (C_byte *)C_stack_hard_limit;
  int st;

  if(ops_active == 0 || live_calls >= ops_active) return WEBJS_CB_UNSAFE;

  if(live_calls >= WEBJS_MAX_NESTING || left < WEBJS_NURSERY_MARGIN)
    return WEBJS_CB_TOO_DEEP;

  ++live_calls;
  st = webjs_callback(index, gen, argc);
  --live_calls;
  return st;
}
