;;;; webio.scm - browser I/O for the WebAssembly REPL
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

; Standard ports talk to JavaScript through webrepl-main.c.  Reading with
; no input pending returns to the host (`return-to-host') and resumes
; when JS feeds more text.  The timer interrupt hook returns to the host
; whenever the time slice is over, so that output streams and Ctrl-C (a
; flag polled here) work without SharedArrayBuffer; `sleep' yields with
; a wakeup time instead of busy-waiting.
;
; Must be initialised before csi's body (csi-web.c is translated with
; "-uses webio"), so that the REPL captures these ports and the
; scheduler's sleep and interrupt hooks already exist when we wrap them.


(declare
  (unit webio)
  (uses wasm-units)
  (disable-interrupts)
  (foreign-declare "#include \"webrepl.h\""))

(import scheme chicken.base chicken.foreign chicken.fixnum chicken.port
	chicken.platform chicken.bytevector chicken.time
	(only (scheme base) open-output-string get-output-string))

(define-constant ST-WAITING 1)
(define-constant ST-BUSY 2)
(define-constant ST-SLEEPING 4)
(define-constant C_TIMER_INTERRUPT_NUMBER 255)

(define take-input!  (foreign-lambda int "webio_take_input" bytevector int))
(define has-input?   (foreign-lambda bool "webio_has_input"))
(define take-eof     (foreign-lambda bool "webio_take_eof"))
(define set-state!   (foreign-lambda void "webio_set_state" int))
(define set-wakeup!  (foreign-lambda void "webio_set_wakeup" double))
(define slice-over?  (foreign-lambda bool "webio_slice_expired"))
(define interrupted? (foreign-lambda bool "webio_take_interrupt"))
(define js-write     (foreign-lambda void "webio_write" int bytevector int))


;;; Output: both ports are buffered (flushed when full, on every yield,
;;; on flush-output and on exit); writing to one flushes the other first,
;;; so the interleaving of stdout and stderr is kept.  Once `unbuffered'
;;; is set (by an error that will halt), every write goes out at once.

(define unbuffered #f)

(define (make-web-output-port fd before-write)
  (let ((buf (open-output-string))
	(n 0))
    (define (flush)
      (unless (fx= n 0)
	(let ((bv (string->utf8 (get-output-string buf))))
	  (set! buf (open-output-string))
	  (set! n 0)
	  (js-write fd bv (bytevector-length bv)))))
    (make-output-port
     (lambda (s)
       (before-write)
       (display s buf)
       (set! n (fx+ n (string-length s)))
       (when (or unbuffered (fx>= n 8192)) (flush)))
     flush
     force-output: flush)))

(define web-stdout (make-web-output-port 1 (lambda () (flush-output web-stderr))))
(define web-stderr (make-web-output-port 2 (lambda () (flush-output web-stdout))))

(define (flush-std)
  (flush-output web-stdout)
  (flush-output web-stderr))

(define (yield! state)
  (flush-std)
  (set-state! state)
  (return-to-host))


;;; Input: taken from webrepl-main.c in pieces of at most 64 KB, so no
;;; paste, however large, needs a block over the size limit or a huge
;;; character list.

(define in-bv (make-bytevector 65536))
(define pending '())			; characters fed but not yet read
(define eof-pending #f)
(define at-prompt #f)			; nothing read since the last prompt

(define (abandon-input!)		; Ctrl-C while waiting for input
  (set! pending '())
  (set! eof-pending #f)
  ;; At a fresh prompt there is nothing to abandon (and the Stop may
  ;; be a stale one from an evaluation that just finished), so only a
  ;; partially read form is reported and reset.
  (unless at-prompt (##sys#user-interrupt-hook)))

(define (fill!)
  (let loop ()
    (cond ((pair? pending) #t)
	  (eof-pending #t)
	  ((let ((n (take-input! in-bv (bytevector-length in-bv))))
	     (and (fx> n 0) n)) =>
	   (lambda (n)
	     (set! pending (string->list (##sys#buffer->string in-bv 0 n)))
	     (loop)))
	  ((take-eof) (set! eof-pending #t) #t)
	  (else
	   (yield! ST-WAITING)
	   (when (interrupted?) (abandon-input!))
	   (loop)))))

(define (read-ch)
  (fill!)
  (set! at-prompt #f)
  (if (pair? pending)
      (let ((c (car pending)))
	(set! pending (cdr pending))
	c)
      (begin (set! eof-pending #f) #!eof)))

(define (peek-ch)
  (fill!)
  (if (pair? pending) (car pending) #!eof))

(define web-stdin
  (make-input-port read-ch
		   (lambda () (or (pair? pending) (has-input?)))
		   void
		   peek-char: peek-ch))

(set! ##sys#standard-input web-stdin)
(set! ##sys#standard-output web-stdout)
(set! ##sys#standard-error web-stderr)

(set! ##sys#read-prompt-hook
  (let ((old ##sys#read-prompt-hook))
    (lambda ()
      (set! at-prompt #t)
      (old))))


;;; Exit: flush on every exit path (explicit exit, EOF, ",q", the end of
;;; "-s" or "-e").  `emergency-exit' bypasses this, so unflushed stdout
;;; is lost there.  The default error handler (for an error outside the
;;; REPL: in .csirc, -s or -e) ends in C_halt, which skips `on-exit':
;;; flush first, and let its message and call chain through unbuffered.
;;; (webrepl-main.c records the exit status of every path.)

(on-exit flush-std)

(##sys#error-handler
 (let ((old (##sys#error-handler)))
   (lambda args
     (flush-std)
     (set! unbuffered #t)
     (apply old args))))


;;; Sleep: yield with a wakeup instead of busy-waiting, but let the
;;; scheduler's (thread-aware) version run other threads in short
;;; chunks of at most 5 ms.

(set! chicken.base#sleep-hook
  (let ((old chicken.base#sleep-hook))
    (lambda (n)
      (let ((deadline (+ (current-process-milliseconds) (* 1000.0 n))))
	(let loop ()
	  (let ((rem (- deadline (current-process-milliseconds))))
	    (when (> rem 0)
	      (old (/ (min rem 5.0) 1000.0))
	      (let ((rem (- deadline (current-process-milliseconds))))
		(when (> rem 0)
		  (set-wakeup! (min rem 50.0))
		  (yield! ST-SLEEPING)
		  (when (interrupted?) (##sys#user-interrupt-hook))
		  (loop))))))))))


;;; Time slicing and Ctrl-C.  Timer interrupts only happen in
;;; interruptible code (interpreted and user-compiled code); library
;;; primitives never yield.

(set! ##sys#interrupt-hook
  (let ((old ##sys#interrupt-hook))	; already wrapped by the scheduler
    (lambda (reason state)
      (when (eq? reason C_TIMER_INTERRUPT_NUMBER)
	(when (slice-over?) (yield! ST-BUSY))
	(when (interrupted?) (##sys#user-interrupt-hook)))
      (old reason state))))
