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
 * (webrepl_post); WAITING keeps meaning "Scheme reads stdin". */
enum { WEBREPL_RUNNING = 0, WEBREPL_WAITING = 1, WEBREPL_BUSY = 2,
       WEBREPL_EXITED = 3, WEBREPL_SLEEPING = 4, WEBREPL_IDLE = 5 };

/* copies up to MAX bytes of fed input (never splitting a UTF-8
 * sequence) into BUF and returns their number, 0 when there is none */
int   webio_take_input(unsigned char *buf, int max);
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

#endif
