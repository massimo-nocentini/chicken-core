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
;
; The JavaScript bridge (webjs.scm) runs Scheme called from JavaScript
; as callbacks, which never yield (see yield!): reading stdin there
; with no input pending is an error, the scheduler does not switch
; threads there, and a toplevel wait never drops a call from
; JavaScript that is still running.  The calls from JavaScript that
; come while Scheme waits on none are queued, and run at the console's
; prompt (webjs.scm sets ##webio#pending-hook), one at a time, after
; typed input.  webjs.scm also registers the console's ",js" at csi's
; first prompt (##webio#first-prompt-hook), and reads the lines
; entered with it (##webio#chunk-pending?).


(declare
  (unit webio)
  (uses wasm-units)
  (disable-interrupts)
  ;; every toplevel name but the ##webio# ones, so that the REPL's (or
  ;; a notebook cell's) definitions cannot clobber them (not "block":
  ;; it would take the ##sys# globals assigned here for this unit's own)
  (hide take-input! has-input? feed-rest? take-eof set-state! set-wakeup!
	slice-over? interrupted? js-write unbuffered make-web-output-port stdout+flush
	stderr+flush web-stdout web-stderr flush-stdout flush-stderr flush-std
	reopen-std! keep-restart! drop-callbacks! yield! in-bv pending
	eof-pending at-prompt stale-at-prompt abandon-input! fill! read-ch
	peek-ch web-stdin drop-input!
	set-lazy! take-lazy-command lazy-stepping lazy-printing force-1 lazy-poll!
	print-hook console-print-hook print-element js-calls drop-abandoned!
	run-pending! slice-yield!
	value-of display min open-output-string
	get-output-string string->utf8 bytevector-length
	current-process-milliseconds return-to-host force call/cc
	with-output-to-string)
  (foreign-declare "#include \"webrepl.h\""))

(import (except scheme display min)
	chicken.base
	(except chicken.bytevector string->utf8 bytevector-length)
	(except chicken.time current-process-milliseconds)
	(except chicken.platform return-to-host)
	(except chicken.port with-output-to-string)
	chicken.foreign chicken.fixnum)

;; The library procedures called after startup, taken now: a toplevel
;; define assigns the global of the name it defines, scheme#display
;; say.  (Not "(define display scheme#display)": a hidden global never
;; assigned again is an alias, which the compiler replaces with what
;; it names.)
(define (value-of global) (##sys#slot global 0))
(define display (value-of 'scheme#display))
(define min (value-of 'scheme#min))
(define open-output-string (value-of 'scheme#open-output-string))
(define get-output-string (value-of 'scheme#get-output-string))
(define string->utf8 (value-of 'chicken.bytevector#string->utf8))
(define bytevector-length (value-of 'chicken.bytevector#bytevector-length))
(define current-process-milliseconds (value-of 'chicken.time#current-process-milliseconds))
(define return-to-host (value-of 'chicken.platform#return-to-host))
(define force (value-of 'scheme#force))
;; (not ##sys#call-with-current-continuation, whose continuations skip
;; the after thunks of dynamic-wind)
(define call/cc (value-of 'scheme#call-with-current-continuation))
(define with-output-to-string (value-of 'chicken.port#with-output-to-string))

(define-constant ST-WAITING 1)
(define-constant ST-BUSY 2)
(define-constant ST-SLEEPING 4)
(define-constant ST-PAUSED 6)
(define-constant C_TIMER_INTERRUPT_NUMBER 255)

(define take-input!  (foreign-lambda int "webio_take_input" bytevector int))
(define has-input?   (foreign-lambda bool "webio_has_input"))
(define feed-rest?   (foreign-lambda bool "webio_feed_rest"))
(define take-eof     (foreign-lambda bool "webio_take_eof"))
(define set-state!   (foreign-lambda void "webio_set_state" int))
(define set-wakeup!  (foreign-lambda void "webio_set_wakeup" double))
(define slice-over?  (foreign-lambda bool "webio_slice_expired"))
(define interrupted? (foreign-lambda bool "webio_take_interrupt"))
(define js-write     (foreign-lambda void "webio_write" int bytevector int))
(define js-calls     (foreign-lambda int "webjs_live_calls"))


;;; Output: both ports are buffered (flushed when full, on every yield,
;;; on flush-output and on exit); writing to one flushes the other first,
;;; so the interleaving of stdout and stderr is kept.  Once `unbuffered'
;;; is set (by an error that will halt), every write goes out at once.
;;; A large string goes out at once, without being copied into the
;;; buffer (webrepl-main.c passes it to JavaScript in pieces).  The user
;;; may close the standard ports (call-with-port does): webio flushes
;;; the output ports with their own procedures, as flush-output would
;;; then signal an error, and reopens all three at the next prompt (the
;;; notebook kernel after each cell), as nothing could be shown or read
;;; any more.

(define unbuffered #f)

;; -> (port . its flush procedure)
(define (make-web-output-port fd before-write)
  (let ((buf (open-output-string))
	(n 0))
    (define (flush)
      (unless (fx= n 0)
	(let ((bv (string->utf8 (get-output-string buf))))
	  (set! buf (open-output-string))
	  (set! n 0)
	  (js-write fd bv (bytevector-length bv)))))
    (cons (make-output-port
	   (lambda (s)
	     (before-write)
	     (cond ((fx> (string-length s) 65536)
		    (flush)
		    (let ((bv (string->utf8 s)))
		      (js-write fd bv (bytevector-length bv))))
		   (else
		    (display s buf)
		    (set! n (fx+ n (string-length s)))
		    (when (or unbuffered (fx>= n 8192)) (flush)))))
	   flush
	   force-output: flush)
	  flush)))

(define stdout+flush (make-web-output-port 1 (lambda () (flush-stderr))))
(define stderr+flush (make-web-output-port 2 (lambda () (flush-stdout))))
(define web-stdout (car stdout+flush))
(define web-stderr (car stderr+flush))
(define flush-stdout (cdr stdout+flush))
(define flush-stderr (cdr stderr+flush))

(define (flush-std)
  (flush-stdout)
  (flush-stderr))

(define (reopen-std!)			; slot 8: the directions still open
  (##sys#setislot web-stdin 8 1)
  (##sys#setislot web-stdout 8 2)
  (##sys#setislot web-stderr 8 2))

(define keep-restart! (foreign-lambda void "webio_keep_restart"))
(define drop-callbacks! (foreign-lambda bool "webio_drop_callbacks"))

;; The host cannot run while a callback (Scheme called from C, as by a
;; foreign-safe-lambda) is in the C frames below: the runtime's restart
;; point (C_restart) is then the callback's, where a return to the host
;; lands and runs on, leaving the runtime to return to the host later,
;; at some collection in the code that called the C function, with its
;; temporary stack in disorder ("invalid temporary stack level" at the
;; next slice).  So a yield there returns at once (a sleep in a sort's
;; comparator waits as it did before webio, input in one would never
;; come).
;;
;; A non-local exit out of a callback (an error in a comparator, caught
;; outside the sort) never returns to its C frames, which stay below
;; with the restart point in them, so the REPL would never yield again.
;; At a TOPLEVEL wait -- the REPL's prompt, the notebook kernel's wait
;; for a request -- no callback can still be running, so the callbacks
;; left are such abandoned ones: the restart point of this slice's
;; CHICKEN_run, kept when the slice started, is put back, and the
;; return to the host drops their frames (whatever their C code held is
;; lost, as when a native program leaves a callback so).  A wait that
;; only looks toplevel -- a prompt reached inside a call from
;; JavaScript (webjs.scm), a (repl) in a callback -- may still have live
;; callbacks below it: while such a call runs, none is dropped (nor,
;; then, the frames that an unsupported escape left in one: see
;; webjs.scm).
(define (drop-abandoned!)
  (when (and (pair? ##sys#callback-continuation-stack)
	     (fx= (js-calls) 0)		; no call from JavaScript is running
	     (drop-callbacks!))
    (set! ##sys#callback-continuation-stack '())))

;; -> whether it returned to the host
(define (yield! state #!optional toplevel)
  (flush-std)
  (when toplevel (drop-abandoned!))
  (and (null? ##sys#callback-continuation-stack)
       (begin
	 (set-state! state)
	 (return-to-host)
	 (keep-restart!)			; a new slice
	 #t)))

(keep-restart!)				; the first slice: main's CHICKEN_run

;; A call from JavaScript waiting to run (webjs.scm sets the hook to
;; run one and say whether one ran): only at a toplevel wait, once the
;; abandoned callbacks are dropped.  Between two, the slice may end.
(define ##webio#pending-hook (lambda () #f))

(define (run-pending!)
  (drop-abandoned!)
  (and (null? ##sys#callback-continuation-stack) (##webio#pending-hook)))

(define (slice-yield!)
  (when (and (slice-over?) (null? ##sys#callback-continuation-stack))
    (yield! ST-BUSY)))


;;; Input: taken from webrepl-main.c in pieces of at most 64 KB, so no
;;; paste, however large, needs a block over the size limit or a huge
;;; character list, and of one feed (one submission) each.

(define in-bv (make-bytevector 65536))
(define pending '())			; characters fed but not yet read
(define eof-pending #f)
(define at-prompt #f)			; nothing read since the last prompt
(define stale-at-prompt #t)		; see abandon-input!

(define (abandon-input!)		; Ctrl-C while waiting for input
  (set! pending '())
  (set! eof-pending #f)
  ;; At a fresh prompt there is nothing to abandon (and the Stop may
  ;; be a stale one from an evaluation that just finished), so only a
  ;; partially read form is reported and reset.  Not in the notebook
  ;; kernel, where a prompt can only be a cell's (a nested repl), and
  ;; a Stop that came between cells never reaches here.
  (unless (and at-prompt stale-at-prompt) (##sys#user-interrupt-hook)))

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
	  ((and at-prompt stale-at-prompt (run-pending!))
	   (loop))			; the console's prompt: one ran
	  ((yield! ST-WAITING at-prompt)
	   (when (interrupted?) (abandon-input!))
	   (loop))
	  ;; input can never come there (see yield!)
	  ((fx> (js-calls) 0)
	   (##sys#error 'read "cannot read standard input inside a call from JavaScript"))
	  (else				; another callback: it waits so
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

;; Run once, at the first prompt: webjs.scm sets it to register ",js",
;; a command of the console's csi, whose body has run by then (the
;; notebook kernel never prompts but in a cell)
(define ##webio#first-prompt-hook void)

(set! ##sys#read-prompt-hook
  (let ((old ##sys#read-prompt-hook))
    (lambda ()
      (set! at-prompt #t)
      (reopen-std!)
      (console-print-hook!)
      (let ((h ##webio#first-prompt-hook))	; once csi's body has run
	(set! ##webio#first-prompt-hook void)
	(h))
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
;;; primitives never yield.  Nor does a callback (Scheme called from C
;;; code, as by a foreign-safe-lambda): returning to the host would
;;; unwind the C frames below it, and CHICKEN_continue cannot resume it
;;; (see yield!).  Inside a call from JavaScript, SRFI-18 threads do not
;;; switch either: another thread's callback could return before it,
;;; out of order ("unbalanced callback continuation stack"); the rest
;;; is what the library's own hook does.

(set! ##sys#interrupt-hook
  (let ((old ##sys#interrupt-hook))	; already wrapped by the scheduler
    (lambda (reason state)
      (when (eq? reason C_TIMER_INTERRUPT_NUMBER)
	(when (and (slice-over?) (null? ##sys#callback-continuation-stack))
	  (yield! ST-BUSY))
	(when (interrupted?) (##sys#user-interrupt-hook)))
      (if (and (eq? reason C_TIMER_INTERRUPT_NUMBER) (fx> (js-calls) 0))
	  (cond ((fx> (##sys#slot ##sys#pending-finalizers 0) 0)
		 (##sys#run-pending-finalizers state))
		((procedure? state) (state))
		(else (##sys#context-switch state)))
	  (old reason state)))))


;;; Hooks for the notebook kernel (webnb.scm) and the JavaScript bridge
;;; (webjs.scm).

(define drop-input! (foreign-lambda void "webio_drop_input"))
(define ##webio#flush flush-std)
(define ##webio#yield yield!)
(define ##webio#reopen-std! reopen-std!)
(define ##webio#run-pending! run-pending!)
(define ##webio#slice-yield! slice-yield!)
(define ##webio#web-stdout web-stdout)
(define ##webio#web-stderr web-stderr)

(define (##webio#prompts-are-cells!)	; Stop at a prompt interrupts
  (set! stale-at-prompt #f))

(define (##webio#discard-input!)	; between cells: no stdin leaks across
  (set! pending '())
  (set! eof-pending #f)
  (drop-input!))

;; whether the input the last characters read came with (what was
;; submitted with them: a take never goes past the end of one feed) is
;; not all read
(define (##webio#chunk-pending?)
  (and (eq? ##sys#standard-input web-stdin) (or (pair? pending) (feed-rest?))))


;;; Lazy streams.  The REPL prints a promise by forcing it, and the
;;; notebook kernel (webnb.scm) shows one so.  A stream -- a promise
;;; that forces to '() or to a pair whose cdr is a stream again, where
;;; a promise that forces to a promise is forced again, as those of
;;; (aux stream) are -- is printed element by element as each one
;;; arrives, "(0 1 2 3" and on, until it ends or Stop ends it: Stop is
;;; no error here, the elements printed so far stay, and
;;; the stream is closed with " ...)".  An element that is a promise
;;; is printed so in turn.  A promise that forces to anything else is
;;; printed "#<promise V>", V being its value (the first one).  A
;;; plain list in a stream is printed so too, element by element: the
;;; printer cannot tell it from a stream that was forced already.
;;;
;;; The page can pause the printer, and then ask for the next element
;;; or have it go on (webrepl_lazy): the printer takes the command
;;; before it forces the next element, and waits in state PAUSED.
;;; Inside a callback, which cannot yield (see yield!), it never waits.

(define-constant LAZY-NEXT 1)
(define-constant LAZY-GO 2)

(define set-lazy! (foreign-lambda void "webio_set_lazy" bool))
(define take-lazy-command (foreign-lambda int "webio_take_lazy_command"))

(define lazy-stepping #f)		; paused: one element per NEXT
(define lazy-printing #f)		; inside ##webio#print-lazy

;; the value of promise X, forced again while it is a promise
(define (force-1 x)
  (if (##sys#structure? x 'promise)
      (force-1 (##sys#call-with-values (lambda () (force x))
		 (lambda vs (if (pair? vs) (car vs) (void)))))
      x))

;; between two elements: a yield when the slice is over, Stop, and the
;; page's commands
(define (lazy-poll!)
  (when (null? ##sys#callback-continuation-stack)
    (when (slice-over?) (yield! ST-BUSY))
    (let ((c (take-lazy-command)))
      (cond ((fx= c LAZY-GO) (set! lazy-stepping #f))
	    ((fx> c 0) (set! lazy-stepping #t))))
    (when (interrupted?) (##sys#user-interrupt-hook))
    (when lazy-stepping
      (let wait ()
	(yield! ST-PAUSED)
	(when (interrupted?) (##sys#user-interrupt-hook))
	(let ((c (take-lazy-command)))
	  (cond ((fx= c LAZY-NEXT))
		((fx= c LAZY-GO) (set! lazy-stepping #f))
		(else (wait))))))))

;; Prints promise X with the procedures of a printer: (open) and
;; (close stopped?) around the elements of a stream, (item x) for each
;; one that is not a promise (an element that is one is printed in
;; turn, between its own open and close), (dot x) for the end of an
;; improper one, and (lone x) for a promise that is no stream, x being
;; its value.  Stop closes every stream still open, with #t, and
;; returns #f; else the result is #t.
(define (##webio#print-lazy x open item dot lone close)
  (let ((depth 0))
    (define (walk x)
      (let ((v (force-1 x)))
	(cond ((or (null? v) (pair? v))
	       (open)
	       (set! depth (fx+ depth 1))
	       (let loop ((v v))
		 (when (pair? v)
		   (let ((e (car v)))
		     (if (##sys#structure? e 'promise) (walk e) (item e)))
		   (lazy-poll!)
		   (let ((d (force-1 (cdr v))))
		     (if (or (null? d) (pair? d)) (loop d) (dot d)))))
	       (set! depth (fx- depth 1))
	       (close #f))
	      (else (lone v)))))
    (if (call/cc
	 (lambda (k)
	   (let ((outer #f) (was #f))
	     (##sys#dynamic-wind
		 (lambda ()
		   (set! outer ##sys#user-interrupt-hook)
		   (set! ##sys#user-interrupt-hook (lambda () (k #f)))
		   (set! was lazy-printing)
		   (unless was
		     (set! lazy-stepping #f)
		     (take-lazy-command))	; a stale one
		   (set! lazy-printing #t)
		   (set-lazy! #t))
		 (lambda () (walk x) #t)
		 (lambda ()
		   (set! ##sys#user-interrupt-hook outer)
		   (set! lazy-printing was)
		   (set-lazy! was))))))
	#t
	(let loop ()
	  (if (fx> depth 0)
	      (begin
		(set! depth (fx- depth 1))
		(close #t)
		(loop))
	      #f)))))

;; X as the REPL prints it, without the newline after it
(define (print-element x)
  (let* ((s (with-output-to-string (lambda () (print-hook x ##sys#standard-output))))
	 (n (string-length s)))
    (if (and (fx> n 0) (char=? (string-ref s (fx- n 1)) #\newline))
	(##sys#substring s 0 (fx- n 1))
	s)))

;; The REPL prints a promise among its results (on the standard output:
;; not the arguments of an error) with ##webio#print-lazy, and any
;; other value with the print hook it had.  Set at every prompt, as
;; csi's body sets its own after webio is loaded, and so that a print
;; hook the user sets is kept too.
(define print-hook ##sys#repl-print-hook)

(define (console-print-hook x port)
  (if (and (##sys#structure? x 'promise) (eq? port ##sys#standard-output))
      (let ((first #t))
	(define (put s) (##sys#print s #f port))
	(define (sep)
	  (if first (set! first #f) (put " ")))
	(##webio#print-lazy
	 x
	 (lambda () (sep) (put "(") (set! first #t))
	 (lambda (e) (sep) (put (print-element e)))
	 (lambda (e) (put " . ") (put (print-element e)))
	 (lambda (v) (sep) (put "#<promise ") (put (print-element v)) (put ">"))
	 (lambda (stopped?) (put (if stopped? " ...)" ")")) (set! first #f)))
	(##sys#write-char-0 #\newline port))
      (print-hook x port)))

(define (console-print-hook!)
  (unless (eq? ##sys#repl-print-hook console-print-hook)
    (set! print-hook ##sys#repl-print-hook)
    (set! ##sys#repl-print-hook console-print-hook)))

