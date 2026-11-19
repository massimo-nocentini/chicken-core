/* webrepl.h - glue between webio.scm and webrepl-main.c
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

#ifndef WEBREPL_H
#define WEBREPL_H

/* REPL states, as returned by webrepl_state() and webrepl_resume().
 * IDLE: the notebook kernel (webnb.scm) waits for a request
 * (webrepl_post); WAITING keeps meaning "Scheme reads stdin"; PAUSED:
 * the printer of a lazy stream waits for a command (webrepl_lazy);
 * AWAITING: js-await (webjs.scm) waits for a promise. */
enum { WEBREPL_RUNNING = 0, WEBREPL_WAITING = 1, WEBREPL_BUSY = 2,
       WEBREPL_EXITED = 3, WEBREPL_SLEEPING = 4, WEBREPL_IDLE = 5,
       WEBREPL_PAUSED = 6, WEBREPL_AWAITING = 7 };

/* the commands of webrepl_lazy */
enum { WEBREPL_LAZY_NEXT = 1, WEBREPL_LAZY_GO = 2, WEBREPL_LAZY_PAUSE = 3 };

/* copies up to MAX bytes of fed input (never splitting a UTF-8
 * sequence, nor going past the end of a feed) into BUF and returns
 * their number, 0 when there is none; feed_rest: whether the last take
 * left some of its feed (more than MAX bytes) */
int   webio_take_input(unsigned char *buf, int max);
int   webio_feed_rest(void);
int   webio_has_input(void);
/* one-shot: true once after JS fed an end-of-file */
int   webio_take_eof(void);
/* entering WAITING or IDLE from another state clears a stale Ctrl-C */
void  webio_set_state(int state);
void  webio_set_wakeup(double ms);
int   webio_slice_expired(void);
/* one-shot: true once after JS requested an interrupt */
int   webio_take_interrupt(void);
void  webio_write(int fd, const unsigned char *bytes, int n);

/* notebook kernel requests (webrepl_post): whole messages, FIFO.  The
 * length in bytes of the next one, -1 if there is none; take copies it
 * into BUF (of MAX bytes) and pops it, returning its length, or -1. */
int   webio_request_length(void);
int   webio_take_request(unsigned char *buf, int max);
/* drop fed stdin text and a pending EOF (between notebook cells) */
void  webio_drop_input(void);

/* lazy streams (webio.scm): whether one is being printed (as
 * webrepl_lazy_printing reports it), and the command JS gave last,
 * taken once (0 when there is none) */
void  webio_set_lazy(int on);
int   webio_take_lazy_command(void);

void  webio_keep_restart(void);
int   webio_drop_callbacks(void);

/* The JavaScript bridge (webjs.scm, webjs-main.c, webjs-pre.js) */
/* the calls from JavaScript into Scheme running now (webjs_dispatch),
 * and the bridge operations (webjs_op) */
int   webjs_live_calls(void);
int   webjs_ops_active(void);
/* every slice starts with neither (webrepl-main.c's run_slice) */
void  webjs_slice_start(void);
/* the trampoline, a define-external of webjs.scm */
int   webjs_callback(int index, int gen, int argc);
/* for webjs-main.c: whether csi exited, and how (see __wrap__exit) */
int   webrepl_exited(void);
int   webrepl_exit_code(void);

/* op OP on the ARGC values pushed last: runs the user's JavaScript,
 * which may call Scheme back (a foreign-safe-lambda); the result or the
 * error is left in the inbox, as the status says */
int   webjs_op(int op, int argc);
/* the argument stack: begin empties it, each push adds a value */
void  webjs_args_begin(void);
void  webjs_push_undefined(void);
void  webjs_push_null(void);
void  webjs_push_bool(int b);
void  webjs_push_number(double x);
void  webjs_push_bigint(const unsigned char *digits, int n);
void  webjs_push_string(const unsigned char *utf8, int n);
void  webjs_push_handle(int id);
void  webjs_push_scheme(int index, int gen, int kind);
void  webjs_push_array(int n);
void  webjs_push_bytes(int type, const unsigned char *bytes, int n);
/* the inbox, descriptors of JavaScript values (see webjs-pre.js) */
int   webjs_inbox_size(void);
int   webjs_kind(int i);
double webjs_number(int i);
int   webjs_length(int i);
void  webjs_copy(int i, unsigned char *buf);
int   webjs_bytes_type(int i);
int   webjs_id(int i);
int   webjs_gen(int i);
int   webjs_child(int i, int j);
/* how handle ID prints (WHAT 0) or its typeof (1): the length in
 * bytes, which text_copy copies */
int   webjs_text(int id, int what);
void  webjs_text_copy(unsigned char *buf);
/* a Scheme record of handle ID is gone */
void  webjs_unref(int id);
/* a callback's value, or its error (a SchemeError), from what was
 * pushed */
void  webjs_callback_result(void);
void  webjs_make_error(void);
/* js-function and js-method: the handle of a new function for a
 * Scheme procedure, and its release */
int   webjs_make_function(int index, int gen, int kind);
void  webjs_release_function(int id);
/* the entries of webjs.scm's table whose wrappers JavaScript freed */
int   webjs_released_count(void);
int   webjs_released_index(int k);
int   webjs_released_gen(int k);
void  webjs_released_clear(void);
/* the calls from JavaScript queued while no op ran: take gives the id
 * of the next one (0 if there is none) and leaves its procedure and
 * arguments in the inbox; drop rejects it (its procedure is gone);
 * settle resolves it with what was pushed (HOW 0) or rejects it (1: a
 * SchemeError, 2: an Error) */
int   webjs_pending_take(void);
void  webjs_pending_drop(int id);
void  webjs_settle(int id, int how);
/* the promise js-await waits for: its state (0 pending, 1 a value,
 * 2 a JavaScript error, 3 a Scheme one), the descriptors of the
 * settlement into the inbox, or the wait given up */
int   webjs_await_state(int id);
void  webjs_await_take(int id);
void  webjs_await_abandon(int id);
/* the entry of webjs.scm's table that the worker's console writes with */
void  webjs_set_console(int index, int gen);
/* the rid code runs for (webnb.scm), 0 for none */
void  webjs_set_context(int rid);
/* that of the call pending_take took, or 0 */
int   webjs_pending_rid(void);
/* the entry of webjs.scm's table for procedure CODE of `scheme' */
void  webjs_set_api(int code, int index, int gen);
/* the string pushed: an incomplete JavaScript source? */
int   webjs_incomplete(void);

#endif
