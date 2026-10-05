/* webrepl-main.c - host side of the WebAssembly REPL
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

/* Runs csi (csi-web.c, translated with "-uses webio" and compiled with
 * -DC_EMBEDDED) and keeps the continuation that CHICKEN_run and
 * CHICKEN_continue return whenever Scheme calls return-to-host.  JS
 * drives it through the webrepl_* entry points below and never
 * re-enters Scheme while a slice is running.
 *
 * Every exit (exit, EOF, ",q", the end of -s or -e, an uncaught error,
 * a panic) ends in _exit -> proc_exit, which throws an ExitStatus out
 * of webrepl_resume (or, during main, into callMain, which swallows it:
 * webrepl_started() is then 0).  The link wraps _exit (--wrap=_exit),
 * so the status is recorded for webrepl_exited/webrepl_exit_code.
 *
 * The notebook kernel (webnb.scm, entered with -e "(##webnb#kernel)")
 * takes its requests from a mailbox that webrepl_post fills: whole
 * messages, copied in between slices.  While it has none it yields in
 * state IDLE, which only a posted request ends (the REPL never enters
 * IDLE). */

#include "chicken.h"
#include "webrepl.h"
#include <emscripten.h>
#include <stdlib.h>
#include <string.h>

extern void C_ccall C_toplevel(C_word c, C_word *av) C_noret;

static C_word repl_k;
static int state = WEBREPL_RUNNING, exited, exit_code, in_eof, intr, in_scheme, started;
static char *in_buf;
static size_t in_len, in_pos;
static double slice_start, slice_ms = 50.0, wakeup_ms;

struct req { struct req *next; int len; char data[]; };
static struct req *req_head, *req_tail;	/* the notebook kernel's mailbox */

/* Never let a JS exception unwind through CHICKEN frames.  A pointer
 * reaches JS as a BigInt on wasm64 (MEMORY64), as a Number on wasm32. */
EM_JS(void, js_emit, (int fd, const unsigned char *p, int n), {
  try {
    var a = typeof p === 'bigint' ? Number(p) : p >>> 0;
    if (Module['onSchemeOutput'])
      Module['onSchemeOutput'](fd, HEAPU8.slice(a, a + n));
  } catch (e) { console.error(e); }
});


/* Called from webio.scm */

void webio_write(int fd, const unsigned char *p, int n)
{
  js_emit(fd, p, n);
}

void webio_set_state(int s)
{
  /* A Stop that arrived while an evaluation ran and was never polled is
   * stale once the REPL waits for input again, or the notebook kernel
   * for its next request. */
  if((s == WEBREPL_WAITING || s == WEBREPL_IDLE) && state != s) intr = 0;
  state = s;
}

void webio_set_wakeup(double ms) { wakeup_ms = ms; }
int webio_slice_expired(void) { return emscripten_get_now() - slice_start > slice_ms; }
int webio_take_interrupt(void) { int i = intr; intr = 0; return i; }
int webio_take_eof(void) { int e = in_eof; in_eof = 0; return e; }
int webio_has_input(void) { return in_buf != NULL; }

int webio_request_length(void) { return req_head != NULL ? req_head->len : -1; }

int webio_take_request(unsigned char *buf, int max)
{
  struct req *r = req_head;
  int n;

  if(r == NULL || r->len > max) return -1;

  n = r->len;
  memcpy(buf, r->data, n);
  if((req_head = r->next) == NULL) req_tail = NULL;
  free(r);
  return n;
}

void webio_drop_input(void)
{
  free(in_buf);
  in_buf = NULL;
  in_len = in_pos = 0;
  in_eof = 0;
}

int webio_take_input(unsigned char *buf, int max)
{
  size_t n = in_len - in_pos;

  if(in_buf == NULL) return 0;

  if(n > (size_t)max) {
    size_t cut = max;

    /* Do not split a UTF-8 sequence: back up to its lead byte (unless
     * the input is not UTF-8 at all). */
    while(cut > 0 && (in_buf[ in_pos + cut ] & 0xc0) == 0x80) --cut;

    n = cut > 0 ? cut : (size_t)max;
  }

  memcpy(buf, in_buf + in_pos, n);
  in_pos += n;

  if(in_pos == in_len) {
    free(in_buf);
    in_buf = NULL;
    in_len = in_pos = 0;
  }

  return (int)n;
}


/* All exits end here (see above) */

extern void __real__exit(int code) C_noret;

void __wrap__exit(int code)
{
  exited = 1;
  exit_code = code;
  __real__exit(code);
}


/* Run Scheme until its next return-to-host */

static int run_slice(void)
{
  in_scheme = 1;
  slice_start = emscripten_get_now();
  state = WEBREPL_RUNNING;
  repl_k = CHICKEN_continue(repl_k);
  in_scheme = 0;
  /* a user's own (return-to-host) leaves the state unchanged */
  if(state == WEBREPL_RUNNING) state = WEBREPL_BUSY;
  return state;
}

int main(int argc, char **argv)
{
  C_word h, s, n;

  /* "-:" options must come first, as for any CHICKEN program */
  CHICKEN_parse_command_line(argc, argv, &h, &s, &n);

  if(!CHICKEN_initialize(h, s, n, (void *)C_toplevel)) return 1;

  in_scheme = 1;
  slice_start = emscripten_get_now();
  repl_k = CHICKEN_run(NULL);	/* banner, imports, .csirc, first prompt */
  in_scheme = 0;
  started = 1;
  if(state == WEBREPL_RUNNING) state = WEBREPL_BUSY;
  return 0;			/* with EXIT_RUNTIME=0 the instance stays alive */
}


/* The API for JS (see web/repl-driver.js) */

/* TEXT is LEN bytes of UTF-8, and may contain NUL characters.  On wasm64
 * the link's -sSIGNATURE_CONVERSIONS lets JS pass TEXT as a Number. */
EMSCRIPTEN_KEEPALIVE void webrepl_feed(const char *text, int len, int eof)
{
  if(len > 0) {
    char *p;

    if(in_pos > 0) {		/* drop what was already taken */
      memmove(in_buf, in_buf + in_pos, in_len - in_pos);
      in_len -= in_pos;
      in_pos = 0;
    }

    if((p = realloc(in_buf, in_len + len)) == NULL) return;

    memcpy(p + in_len, text, len);
    in_buf = p;
    in_len += len;
  }

  in_eof |= eof;
}

/* A notebook kernel request: MSG is LEN bytes of UTF-8 (it may contain
 * NUL characters), copied, so JS may free it at once. */
EMSCRIPTEN_KEEPALIVE void webrepl_post(const char *msg, int len)
{
  struct req *r;

  if(len < 0 || (r = malloc(sizeof *r + len)) == NULL) return;

  r->next = NULL;
  r->len = len;
  memcpy(r->data, msg, len);
  if(req_tail != NULL) req_tail->next = r; else req_head = r;
  req_tail = r;
}

EMSCRIPTEN_KEEPALIVE int webrepl_resume(void)
{
  if(in_scheme || !started || state == WEBREPL_EXITED) return state;

  if(state == WEBREPL_BUSY || state == WEBREPL_SLEEPING ||
     (state == WEBREPL_WAITING && (in_buf != NULL || in_eof || intr)) ||
     (state == WEBREPL_IDLE && req_head != NULL))
    return run_slice();

  return state;
}

/* An idle notebook kernel has nothing to stop, unless a request is
 * about to run (Run, then Stop before the worker pumped): the new
 * request is then interrupted at its first poll. */
EMSCRIPTEN_KEEPALIVE void webrepl_interrupt(void)
{
  if(state != WEBREPL_IDLE || req_head != NULL) intr = 1;
}
EMSCRIPTEN_KEEPALIVE int webrepl_state(void) { return state; }
EMSCRIPTEN_KEEPALIVE int webrepl_started(void) { return started; }
EMSCRIPTEN_KEEPALIVE int webrepl_exited(void) { return exited; }
EMSCRIPTEN_KEEPALIVE int webrepl_exit_code(void) { return exit_code; }
EMSCRIPTEN_KEEPALIVE double webrepl_wakeup_ms(void) { return wakeup_ms; }
EMSCRIPTEN_KEEPALIVE void webrepl_set_slice_ms(double ms) { slice_ms = ms; }
