;;;; webnb.scm - the kernel of the web page's Notebook tab
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


; The Notebook tab runs a csi of its own (in repl-worker.js, like the
; REPL tab) as
;
;   csi -:c [allowed options] -n -e "(##webnb#kernel)"
;
; and ##webnb#kernel never returns.  It takes requests from the mailbox
; of webrepl-main.c (webrepl_post), yielding in state IDLE while there
; is none, and reports on fd 3, one JSON object per line, after
; flushing stdout and stderr: a cell's output lies between its "start"
; and "done" events.  Requests (UTF-8):
;
;   run RID NAME\nSOURCE    evaluate SOURCE as cell RID, read as file NAME
;   ping RID                answered by {"ev":"pong","rid":RID}
;
; Events ("ev"): csirc, hello, start, display, clear, done, pong and
; bad-request; web/nb-kernel.js, the page's client, documents them.
;
; A cell is read whole first: if it is incomplete (an unterminated
; list or string, a stray ")"), nothing is evaluated.  Then its forms
; are evaluated one by one, as the REPL does, and the values of the
; last one are reported.  A form is read again when the one before it
; changed the reader, and read only when its turn comes from the first
; datum whose reading runs user code (read syntax, "#,").  The module
; `notebook' (evaluated when the kernel starts, not imported) emits
; rich output.
;
; The unit is linked into the web csi but only defines procedures:
; nothing changes until ##webnb#kernel is called.  It is compiled with
; -no-trace and with interrupts disabled, so its frames never show in
; a cell's call history and it is never time-sliced; only the ##webnb#
; globals are visible outside it, so cells cannot clobber its state.
; Nor can they break it by redefining a library procedure: it calls
; its own copies (see "Library procedures" below).


(declare
  (unit webnb)
  (uses webio)
  (disable-interrupts)
  ;; every toplevel name but the ##webnb# ones (not "block": it would
  ;; take the ##sys# globals assigned here for this unit's own)
  (hide request-length take-request! js-write clear-trace! running active
	started form reading json-string json event! next-request prefix?
	parse-rid valid-name? string-index bad-request! dispatch
	make-incomplete incomplete? incomplete-condition string-contains?
	incomplete-read-error? port-state restore-port-state! reader-state
	same-reader-state? reader-changers changes-reader? user-code
	no-user-code without-user-code precheck
	print-to-string notice-unbound!
	toplevel-command eval-cell ->string/null frame->json call-chain-of
	string-trim-both error-text error-line error-object fallback-error
	outcome->fields filter-list current-datum execute module-name
	alist->plist run-cell load-csirc! emit-display written markup name-ok?
	xml-escape void-elements skip-space notebook-module
	;; the library procedures it calls (see below)
	value-of call-with-current-continuation dynamic-wind eval display write
	reverse substring string->number symbol->string string-append
	inexact->exact round vector->list open-input-string
	open-output-string get-output-string error get-call-chain
	set-record-printer! case-sensitive keyword-style
	parentheses-synonyms symbol-escape abort condition?
	condition-predicate get-condition-property
	with-exception-handler with-input-from-port with-output-to-string
	string-chomp get-line-number read-with-source-info
	current-process-milliseconds bytevector-length bytevector-u8-set!
	make-bytevector string->utf8 utf8->string load-verbose
	chicken-version)
  (foreign-declare "#include \"webrepl.h\""))

(import (except scheme call-with-current-continuation dynamic-wind eval
		display write reverse substring string->number symbol->string
		string-append inexact->exact round vector->list)
	(except chicken.base error get-call-chain set-record-printer!
		case-sensitive keyword-style parentheses-synonyms symbol-escape)
	(except chicken.condition abort condition? condition-predicate
		get-condition-property with-exception-handler)
	(except chicken.port with-input-from-port with-output-to-string)
	(except chicken.string string-chomp)
	(except chicken.syntax get-line-number read-with-source-info)
	(except chicken.time current-process-milliseconds)
	(except chicken.bytevector bytevector-length bytevector-u8-set!
		make-bytevector string->utf8 utf8->string)
	(except chicken.load load-verbose)
	(except chicken.platform chicken-version)
	chicken.fixnum chicken.foreign)

;;; Library procedures
;
; A cell's toplevel define assigns the global of the name it defines,
; scheme#reverse say, as csi lets it.  The kernel calls these copies
; instead: its own hidden globals (the names are left out of the
; imports above), taken when the unit is loaded, after the units it
; uses and before any cell.  The procedures the compiler open-codes,
; car or fx+, need none.

;; not (define display scheme#display): a hidden global never assigned
;; again is an alias, which the compiler replaces with what it names
(define (value-of global) (##sys#slot global 0))

(define call-with-current-continuation (value-of 'scheme#call-with-current-continuation))
(define dynamic-wind (value-of 'scheme#dynamic-wind))
(define eval (value-of 'scheme#eval))
(define display (value-of 'scheme#display))
(define write (value-of 'scheme#write))
(define reverse (value-of 'scheme#reverse))
(define substring (value-of 'scheme#substring))
(define string->number (value-of 'scheme#string->number))
(define symbol->string (value-of 'scheme#symbol->string))
(define string-append (value-of 'scheme#string-append))
(define inexact->exact (value-of 'scheme#inexact->exact))
(define round (value-of 'scheme#round))
(define vector->list (value-of 'scheme#vector->list))
(define open-input-string (value-of 'scheme#open-input-string))
(define open-output-string (value-of 'scheme#open-output-string))
(define get-output-string (value-of 'scheme#get-output-string))
(define error (value-of 'chicken.base#error))
(define get-call-chain (value-of 'chicken.base#get-call-chain))
(define set-record-printer! (value-of 'chicken.base#set-record-printer!))
(define case-sensitive (value-of 'chicken.base#case-sensitive))
(define keyword-style (value-of 'chicken.base#keyword-style))
(define parentheses-synonyms (value-of 'chicken.base#parentheses-synonyms))
(define symbol-escape (value-of 'chicken.base#symbol-escape))
(define abort (value-of 'chicken.condition#abort))
(define condition? (value-of 'chicken.condition#condition?))
(define condition-predicate (value-of 'chicken.condition#condition-predicate))
(define get-condition-property (value-of 'chicken.condition#get-condition-property))
(define with-exception-handler (value-of 'chicken.condition#with-exception-handler))
(define with-input-from-port (value-of 'chicken.port#with-input-from-port))
(define with-output-to-string (value-of 'chicken.port#with-output-to-string))
(define string-chomp (value-of 'chicken.string#string-chomp))
(define get-line-number (value-of 'chicken.syntax#get-line-number))
(define read-with-source-info (value-of 'chicken.syntax#read-with-source-info))
(define current-process-milliseconds (value-of 'chicken.time#current-process-milliseconds))
(define bytevector-length (value-of 'chicken.bytevector#bytevector-length))
(define bytevector-u8-set! (value-of 'chicken.bytevector#bytevector-u8-set!))
(define make-bytevector (value-of 'chicken.bytevector#make-bytevector))
(define string->utf8 (value-of 'chicken.bytevector#string->utf8))
(define utf8->string (value-of 'chicken.bytevector#utf8->string))
(define load-verbose (value-of 'chicken.load#load-verbose))
(define chicken-version (value-of 'chicken.platform#chicken-version))


(define-constant ST-IDLE 5)
(define-constant max-string-print 100)	; call history forms, as csi

(define request-length (foreign-lambda int "webio_request_length"))
(define take-request!  (foreign-lambda int "webio_take_request" bytevector int))
(define js-write       (foreign-lambda void "webio_write" int bytevector int))
(define (clear-trace!) (foreign-code "C_clear_trace_buffer();"))

(define running #f)			; refuses nesting
;; The rid of the running cell, or #f.  Reports read this global, never
;; a rid closed over: a continuation of an earlier cell re-entered by
;; the running one finishes that cell's forms and reports to this one.
(define active #f)
(define started 0)			; when the running cell started (ms)
(define form #f)			; form index being evaluated, or "print"
(define reading #f)			; reading a form (errors have no history)


;;; JSON, one event per line on fd 3

;; Escapes work on the UTF-8 bytes: every byte of a multi-byte
;; sequence is >= #x80, so the runs between escapes stay valid UTF-8.
(define (json-string s out)
  (let* ((bv (string->utf8 s))
	 (n (bytevector-length bv)))
    (define (special? b) (or (fx< b 32) (fx= b 34) (fx= b 92)))
    (write-char #\" out)
    (let scan ((i 0))
      (cond ((fx= i n) (display s out))	; fast path: nothing to escape
	    ((special? (bytevector-u8-ref bv i))
	     (let loop ((start 0) (i 0))
	       (cond ((fx= i n)
		      (when (fx< start n) (display (##sys#buffer->string bv start (fx- n start)) out)))
		     ((special? (bytevector-u8-ref bv i))
		      (when (fx< start i) (display (##sys#buffer->string bv start (fx- i start)) out))
		      (let ((b (bytevector-u8-ref bv i)))
			(display (case b
				   ((34) "\\\"")
				   ((92) "\\\\")
				   ((10) "\\n")
				   ((13) "\\r")
				   ((9) "\\t")
				   (else (string-append (if (fx< b 16) "\\u000" "\\u001")
							(number->string (fxand b 15) 16))))
				 out))
		      (loop (fx+ i 1) (fx+ i 1)))
		     (else (loop start (fx+ i 1))))))
	    (else (scan (fx+ i 1)))))
    (write-char #\" out)))

;; strings, fixnums, flonums (rounded), #t (true), #f (null), symbols
;; (strings), lists (arrays) and alists with string keys (objects)
(define (json x out)
  (cond ((string? x) (json-string x out))
	((fixnum? x) (write x out))
	((and (real? x) (< (abs x) 1e15))	; rounded to an integer
	 (if (= x x) (write (inexact->exact (round x)) out) (display "null" out)))
	((eq? x #t) (display "true" out))
	((not x) (display "null" out))
	((symbol? x) (json-string (symbol->string x) out))
	((null? x) (display "[]" out))
	((and (pair? x) (pair? (car x)) (string? (caar x)))
	 (write-char #\{ out)
	 (let loop ((x x) (sep #f))
	   (when (pair? x)
	     (when sep (write-char #\, out))
	     (json-string (caar x) out)
	     (write-char #\: out)
	     (json (cdar x) out)
	     (loop (cdr x) #t)))
	 (write-char #\} out))
	((pair? x)
	 (write-char #\[ out)
	 (let loop ((x x) (sep #f))
	   (when (pair? x)
	     (when sep (write-char #\, out))
	     (json (car x) out)
	     (loop (cdr x) #t)))
	 (write-char #\] out))
	(else (json-string (with-output-to-string (lambda () (write x))) out))))

;; (event! "done" "rid" 3 "status" "ok" ...): one line, one write
(define (event! ev . kvs)
  (##webio#flush)
  (let ((out (open-output-string)))
    (json (cons (cons "ev" ev)
		(let loop ((kvs kvs))
		  (if (null? kvs)
		      '()
		      (cons (cons (car kvs) (cadr kvs)) (loop (cddr kvs))))))
	  out)
    (write-char #\newline out)
    (let ((bv (string->utf8 (get-output-string out))))
      (js-write 3 bv (bytevector-length bv)))))


;;; Requests

(define (next-request)			; yields IDLE until there is one
  (let ((n (request-length)))
    (if (fx< n 0)
	(begin (##webio#yield ST-IDLE) (next-request))
	(let ((bv (make-bytevector n)))
	  (take-request! bv n)
	  (utf8->string bv)))))

(define (prefix? p s)
  (let ((n (string-length p)))
    (and (fx>= (string-length s) n) (string=? p (substring s 0 n)))))

(define (parse-rid s)			; 1..2^30-1, decimal digits only
  (and (fx> (string-length s) 0)
       (fx<= (string-length s) 10)
       (let loop ((i 0))
	 (or (fx= i (string-length s))
	     (and (char-numeric? (string-ref s i))
		  (char<? (string-ref s i) #\x80)
		  (loop (fx+ i 1)))))
       (let ((n (string->number s)))
	 (and (fixnum? n) (fx> n 0) (< n 1073741824) n))))

(define (valid-name? s)
  (and (fx> (string-length s) 0)
       (fx<= (string-length s) 32)
       (let loop ((i 0))
	 (or (fx= i (string-length s))
	     (let ((c (string-ref s i)))
	       (and (or (and (char>=? c #\a) (char<=? c #\z))
			(and (char>=? c #\A) (char<=? c #\Z))
			(and (char>=? c #\0) (char<=? c #\9))
			(memv c '(#\_ #\. #\: #\[ #\] #\-)))
		    (loop (fx+ i 1))))))))

(define (string-index s c start)
  (let loop ((i start))
    (cond ((fx= i (string-length s)) #f)
	  ((char=? (string-ref s i) c) i)
	  (else (loop (fx+ i 1))))))

(define (bad-request! req)
  (event! "bad-request"
	  "text" (if (fx> (string-length req) 200) (substring req 0 200) req)))

(define (dispatch req restore-ports)
  (cond ((prefix? "run " req)
	 (let* ((nl (string-index req #\newline 4))
		(head (substring req 4 (or nl (string-length req))))
		(sp (string-index head #\space 0))
		(rid (and nl sp (parse-rid (substring head 0 sp))))
		(name (and rid (substring head (fx+ sp 1) (string-length head)))))
	   (if (and rid (valid-name? name))
	       (run-cell rid name (substring req (fx+ nl 1) (string-length req))
			 restore-ports)
	       (bad-request! req))))
	((and (prefix? "ping " req) (parse-rid (substring req 5 (string-length req)))) =>
	 (lambda (rid) (event! "pong" "rid" rid)))
	(else (bad-request! req))))


;;; Evaluating a cell

;; phase 1: the cell cannot be read
(define (make-incomplete c) (##sys#make-structure 'webnb-incomplete c))
(define (incomplete? x) (##sys#structure? x 'webnb-incomplete))
(define (incomplete-condition x) (##sys#slot x 1))

(define (string-contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (and (fx<= (fx+ i m) n)
	   (or (string=? sub (substring s i (fx+ i m)))
	       (loop (fx+ i 1)))))))

(define (incomplete-read-error? c)
  (and (condition? c)
       ((condition-predicate 'syntax) c)
       (let ((msg (get-condition-property c 'exn 'message #f)))
	 (and (string? msg)
	      (or (string-contains? msg "unterminated")
		  (string-contains? msg "unexpected end")
		  (string-contains? msg "unexpected list terminator"))))))

;; Where a string port is: line, column, EOF flag, position, case
;; folding.  Phase 2 restores it to read on after a datum of phase 1.
(define (port-state p)
  (vector (##sys#slot p 4) (##sys#slot p 5) (##sys#slot p 6)
	  (##sys#slot p 10) (##sys#slot p 13)))

(define (restore-port-state! p s)
  (##sys#setislot p 4 (vector-ref s 0))
  (##sys#setislot p 5 (vector-ref s 1))
  (##sys#setislot p 6 (vector-ref s 2))
  (##sys#setislot p 10 (vector-ref s 3))
  (##sys#setislot p 13 (vector-ref s 4)))

;; What the reader depends on besides the port.  The procedures of the
;; read table and read marks are copied: entries change in place.
(define (reader-state)
  (let ((rt (##sys#current-read-table)))
    (define (procs al) (map cdr al))
    (list rt (procs (##sys#slot rt 1)) (procs (##sys#slot rt 2))
	  (procs (##sys#slot rt 3)) (procs ##sys#read-marks)
	  ##sys#user-read-hook (case-sensitive) (keyword-style)
	  (parentheses-synonyms) (symbol-escape))))

(define (same-reader-state? a b)
  (or (eq? a b)
      (and (pair? a) (pair? b)
	   (same-reader-state? (car a) (car b))
	   (same-reader-state? (cdr a) (cdr b)))))

;; Whether datum X may change how the rest of its cell reads: it names
;; one of these (the part of a qualified name after its last "#").
(define reader-changers
  '("set-read-syntax!" "set-sharp-read-syntax!" "set-parameterized-read-syntax!"
    "current-read-table" "copy-read-table" "define-reader-ctor"
    "user-read-hook" "read-marks" "case-sensitive" "keyword-style"
    "parentheses-synonyms" "symbol-escape"))

(define (changes-reader? x)
  (let ((budget 100000))		; data may be big, or circular
    (let walk ((x x))
      (set! budget (fx- budget 1))
      (and (fx> budget 0)
	   (cond ((symbol? x)
		  (let* ((s (symbol->string x))
			 (n (string-length s)))
		    (let loop ((i (fx- n 1)))
		      (cond ((fx< i 0) (member s reader-changers))
			    ((char=? (string-ref s i) #\#)
			     (member (substring s (fx+ i 1) n) reader-changers))
			    (else (loop (fx- i 1)))))))
		 ((pair? x) (or (walk (car x)) (walk (cdr x))))
		 ((vector? x)
		  (let loop ((i 0))
		    (and (fx< i (vector-length x))
			 (or (walk (vector-ref x i)) (loop (fx+ i 1))))))
		 (else #f))))))

;; Phase 1 runs none of the user's read-time code: the procedures of
;; the read table and of read marks, and "#," constructors, abort with
;; this instead, which ends the scan before their datum.
(define user-code (##sys#make-structure 'webnb-user-code))

(define (no-user-code . _) (abort user-code))

(define (without-user-code thunk)
  (define (stubs al)
    (map (lambda (a) (cons (car a) (and (cdr a) no-user-code))) al))
  (let ((rt (##sys#current-read-table))
	(hook ##sys#user-read-hook))
    (parameterize ((##sys#current-read-table
		    (##sys#make-structure 'read-table (stubs (##sys#slot rt 1))
					  (stubs (##sys#slot rt 2))
					  (stubs (##sys#slot rt 3)))))
      (fluid-let ((##sys#read-marks (stubs ##sys#read-marks))
		  (##sys#user-read-hook
		   (lambda (c port)
		     (if (char=? c #\,) (no-user-code) (hook c port)))))
	(thunk)))))

;; Phase 1: read the data of the cell on P first; an incomplete cell
;; evaluates nothing.  Returns the data with the state of P after each,
;; and where to read on: phase 2 evaluates them while the reader stays
;; the same.  The scan stops before a datum whose reading would run the
;; user's code (read syntax, "#,"): phase 2 reads it when its turn
;; comes, after the forms before it, as csi does.  Other read errors
;; stop the scan too, and phase 2 reads on from there, reporting them
;; where they happen (read syntax defined by earlier forms may change
;; them).  So does an incomplete datum after one that may change the
;; reader: a cell may define read syntax and use it.
(define (precheck p name)
  (fluid-let ((##sys#read-error-with-line-number #t))
    (let loop ((acc '()) (at (port-state p)))
      (let ((x (call-with-current-continuation
		(lambda (k)
		  (with-exception-handler
		   (lambda (c)
		     (k (cond ((incomplete-read-error? c) (make-incomplete c))
			      ((and (condition? c)
				    ((condition-predicate 'user-interrupt) c))
			       (list c))
			      (else #f))))
		   (lambda ()
		     (vector (without-user-code
			      (lambda () (read-with-source-info p name))))))))))
	;; signalled here, outside the handler (which would get it)
	(cond ((vector? x)
	       (let* ((s (port-state p))
		      (acc (cons (cons (vector-ref x 0) s) acc)))
		 (if (eof-object? (vector-ref x 0))
		     (cons (reverse acc) s)
		     (loop acc s))))
	      ((and (incomplete? x)
		    (not (let any ((l acc))
			   (and (pair? l)
				(or (changes-reader? (caar l)) (any (cdr l)))))))
	       (abort x))
	      ((pair? x) (abort (car x)))	; interrupted
	      (else (cons (reverse acc) at)))))))

(define (print-to-string x)		; csi's way, with its length limit
  (string-chomp
   (with-output-to-string
     (lambda () (##sys#repl-print-hook x (current-output-port))))))

(define (notice-unbound!)		; as repl.scm does after each form
  (when (and ##sys#warnings-enabled (pair? ##sys#unbound-in-eval))
    (let loop ((vars ##sys#unbound-in-eval)
	       (u '()))
      (cond ((null? vars)
	     (when (pair? u)
	       (when ##sys#notices-enabled
		 (##sys#notice
		  "the following toplevel variables are referenced but unbound:\n")
		 (for-each
		  (lambda (v)
		    (##sys#print "  " #f ##sys#standard-error)
		    (##sys#print (car v) #t ##sys#standard-error)
		    (when (cdr v)
		      (##sys#print " (in " #f ##sys#standard-error)
		      (##sys#print (cdr v) #t ##sys#standard-error)
		      (##sys#write-char-0 #\) ##sys#standard-error))
		    (##sys#write-char-0 #\newline ##sys#standard-error))
		  u)
		 (##sys#flush-output ##sys#standard-error))))
	    ((or (memq (caar vars) u)
		 (##core#inline "C_u_i_namespaced_symbolp" (caar vars))
		 (##sys#symbol-has-toplevel-binding? (caar vars)))
	     (loop (cdr vars) u))
	    (else (loop (cdr vars) (cons (car vars) u)))))))

(define (toplevel-command x p)		; ",d x" and friends, as csi has them
  (let ((ev 'chicken.csi#default-evaluator))
    (unless (##sys#symbol-has-toplevel-binding? ev)
      (error "toplevel commands are not available"))
    (with-input-from-port p (lambda () ((##sys#slot ev 0) x)))))

;; Phase 2: evaluate form by form, reading on from where phase 1
;; stopped, or as soon as a form changed the reader.  The values of the
;; last form, as strings (printed inside the handler's extent: an error
;; there is one of form "print") or display objects; #f if unspecified.
(define (eval-cell src name)
  (define (begin-form! x)
    (set! current-datum x)
    (clear-trace!)
    (set! ##sys#unbound-in-eval '()))
  (let* ((p (open-input-string src))
	 (pre (precheck p name)))
    ;; AHEAD: data of phase 1 still to evaluate, each with the state
    ;; of P after it; once none is left, read from P, at AT if not #f
    (let loop ((i 1) (ahead (car pre)) (at (cdr pre))
	       (vals (list (##core#undefined))))
      (set! form i)
      (let ((x (if (pair? ahead)
		   (caar ahead)
		   (begin
		     (when at (restore-port-state! p at))
		     (set! reading #t)
		     (let ((x (fluid-let ((##sys#read-error-with-line-number #t))
				(read-with-source-info p name))))
		       (set! reading #f)
		       x))))
	    (after (and (pair? ahead) (cdar ahead))))
	(cond ((eof-object? x)
	       (set! form "print")
	       (and (not (and (pair? vals) (eq? (car vals) (##core#undefined))))
		    (map (lambda (v) (if (##webnb#display? v) v (print-to-string v)))
			 vals)))
	      ((and (pair? x) (eq? 'unquote (car x)))
	       ;; a command reads its arguments from P
	       (when after (restore-port-state! p after))
	       (begin-form! x)
	       (receive results (toplevel-command x p)
		 (notice-unbound!)
		 (loop (fx+ i 1) '() #f results)))
	      (else
	       (begin-form! x)
	       (let ((rs (and after (reader-state))))
		 (receive results (eval x)
		   (notice-unbound!)
		   (if (and after (same-reader-state? rs (reader-state)))
		       (loop (fx+ i 1) (cdr ahead) after results)
		       (loop (fx+ i 1) '() after results))))))))))

(define (->string/null x)
  (cond ((not x) #f)
	((string? x) x)
	((symbol? x) (symbol->string x))
	(else (with-output-to-string (lambda () (display x))))))

(define (frame->json fr)
  (let* ((more1 (##sys#slot fr 1))
	 (more2 (##sys#slot fr 2))
	 (fi (and more2 (##sys#structure? more2 'frameinfo))))
    (list (cons "where" (->string/null (##sys#slot fr 0)))
	  (cons "proc" (and fi (->string/null (##sys#slot more2 1))))
	  (cons "form" (and more1
			    (let ((o (open-output-string)))
			      (##sys#with-print-length-limit
			       max-string-print
			       (lambda () (##sys#print more1 #t o)))
			      (get-output-string o)))))))

(define (call-chain-of c)
  (or (and (condition? c) (get-condition-property c 'exn 'call-chain #f))
      (get-call-chain 0 ##sys#current-thread)))

(define (string-trim-both s)
  (let loop ((a 0) (b (string-length s)))
    (cond ((and (fx< a b) (char-whitespace? (string-ref s a))) (loop (fx+ a 1) b))
	  ((and (fx< a b) (char-whitespace? (string-ref s (fx- b 1)))) (loop a (fx- b 1)))
	  (else (substring s a b)))))

(define (error-text c)
  (let ((o (open-output-string)))
    ;; print-error-message's text; it calls the global display, which
    ;; a cell may have redefined
    (define (put x) (##sys#print x #f o))
    (define (put-written x limit)
      (##sys#with-print-length-limit limit (lambda () (##sys#print x #t o))))
    (put "Error")
    (if (condition? c)
	(let ((msg (get-condition-property c 'exn 'message #f))
	      (loc (get-condition-property c 'exn 'location #f))
	      (args (get-condition-property c 'exn 'arguments #f)))
	  (cond (msg
		 (put ": ")
		 (when (symbol? loc) (put "(") (put loc) (put ") "))
		 (put msg))
		((equal? '(user-interrupt) (##sys#slot c 1))
		 (put ": *** user interrupt ***"))
		(else (put ": <condition> ") (put (##sys#slot c 1))))
	  (when (list? args)
	    (put (if (and (pair? args) (null? (cdr args))) ": " #\newline))
	    (for-each (lambda (x) (put-written x 80) (put #\newline)) args)))
	(begin (put ": uncaught exception: ") (put-written c 2048)))
    (string-trim-both (get-output-string o))))

;; "(line N) ..." in the message of an error reading the cell (not a
;; file it loads), else the line of the form
(define (error-line c x read?)
  (or (let ((msg (and read? (condition? c)
		      (get-condition-property c 'exn 'message #f))))
	(and (string? msg) (prefix? "(line " msg)
	     (let ((e (string-index msg #\) 6)))
	       (and e (string->number (substring msg 6 e))))))
      (let ((ln (and x (get-line-number x))))
	(and (string? ln)
	     (let loop ((i (fx- (string-length ln) 1)))
	       (cond ((fx< i 0) #f)
		     ((char=? (string-ref ln i) #\:)
		      (string->number (substring ln (fx+ i 1) (string-length ln))))
		     (else (loop (fx- i 1)))))))))

(define (error-object c chain fm x read?)
  (list (cons "text" (error-text c))
	(cons "kind" (if (condition? c) (map symbol->string (##sys#slot c 1)) '()))
	(cons "location" (and (condition? c)
			      (->string/null (get-condition-property c 'exn 'location #f))))
	(cons "form" fm)
	(cons "line" (error-line c x read?))
	(cons "chain" (map frame->json chain))))

(define fallback-error
  '(("text" . "Error: an error occurred while reporting an error")
    ("kind") ("location" . #f) ("form" . #f) ("line" . #f) ("chain")))

;; outcome -> ((status . fields) . display objects to show)
(define (outcome->fields o)
  (case (car o)
    ((ok)
     (let* ((unspecified (not (cdr o)))
	    (vals (or (cdr o) '()))
	    (displays (filter-list ##webnb#display? vals))
	    (shown (filter-list (lambda (v) (not (##webnb#display? v))) vals)))
       (cons (list "ok"
		   (cons "values"
			 (cond (unspecified #f)
			       ;; only display objects: nothing else to show
			       ((and (null? shown) (pair? displays)) #f)
			       (else shown))))
	     displays)))
    ((reset) (list (list "reset")))
    ((incomplete)
     (let ((c (incomplete-condition (cadr o))))
       (list (list "incomplete" (cons "error" (error-object c '() #f #f #t))))))
    (else				; (raised c chain datum form reading?)
     (let ((c (list-ref o 1)) (chain (list-ref o 2)) (x (list-ref o 3))
	   (fm (list-ref o 4)) (read? (list-ref o 5)))
       (set! ##sys#repl-recent-call-chain chain)
       (when (condition? c) (set! ##sys#last-exception c)) ; for ",exn"
       (if (and (condition? c) ((condition-predicate 'user-interrupt) c))
	   (list (list "interrupted"))
	   (list (list "error" (cons "error" (error-object c chain fm x read?)))))))))

(define (filter-list ok? xs)
  (cond ((null? xs) '())
	((ok? (car xs)) (cons (car xs) (filter-list ok? (cdr xs))))
	(else (filter-list ok? (cdr xs)))))

(define current-datum #f)		; the form being evaluated (for its line)

;; Run SRC as NAME -> ((status . fields) . display objects)
(define (execute src name restore-ports)
  (set! form #f)
  (set! reading #f)
  (set! current-datum #f)
  (##webio#discard-input!)
  (clear-trace!)
  (let ((outcome
	 (call-with-current-continuation
	  (lambda (k)
	    (let ((old #f))
	      (dynamic-wind
		  (lambda ()
		    (set! old (##sys#reset-handler))
		    (##sys#reset-handler (lambda () (k '(reset)))))
		  (lambda ()
		    (with-exception-handler
		     (lambda (c)
		       (k (if (incomplete? c)
			      (list 'incomplete c)
			      (list 'raised c
				    (if reading '() (call-chain-of c))
				    (if reading #f current-datum)
				    form
				    reading))))
		     (lambda () (cons 'ok (eval-cell src name)))))
		  (lambda () (##sys#reset-handler old))))))))
    (restore-ports)
    (##webio#discard-input!)
    (set! ##sys#unbound-in-eval #f)
    ;; formatting runs user code (record printers): describe the outcome
    ;; only now, outside the cell, with a fallback
    (call-with-current-continuation
     (lambda (k)
       (with-exception-handler
	(lambda (e) (k (list (list "error" (cons "error" fallback-error)))))
	(lambda () (outcome->fields outcome)))))))

(define (module-name)
  (let ((m (##sys#current-module)))
    (and m (symbol->string (##sys#module-name m)))))

(define (alist->plist al)
  (if (null? al)
      '()
      (cons (caar al) (cons (cdar al) (alist->plist (cdr al))))))

(define (run-cell rid name src restore-ports)
  (set! active rid)
  (set! started (current-process-milliseconds))
  (event! "start" "rid" rid "name" name)
  (let* ((r (execute src name restore-ports))
	 (rid active)			; maybe a later cell's (see above)
	 (ms (- (current-process-milliseconds) started)))
    (set! active #f)
    (for-each (lambda (d) (emit-display d #f rid)) (cdr r))
    (apply event! "done" "rid" rid "ms" ms "module" (module-name)
	   "status" (caar r) (alist->plist (cdar r)))))

(define (load-csirc! restore-ports)
  (let ((rc "/home/web_user/.csirc"))
    (when (##sys#file-exists? rc #t #f 'load-csirc)
      (set! active #f)
      (let* ((r (execute (string-append "(load " (with-output-to-string (lambda () (write rc))) ")")
			 ".csirc" restore-ports))
	     (status (caar r)))
	(for-each (lambda (d) (emit-display d #f #f)) (cdr r))
	(if (string=? status "ok")
	    (event! "csirc" "status" "ok")
	    (event! "csirc" "status" "error"
		    "error" (cond ((assoc "error" (cdar r)) => cdr)
				  (else (cons (cons "text" (string-append "Error: " status))
					      (cdr fallback-error))))))))))


;;; Rich output: display objects and the module `notebook'

(define (##webnb#make-display mime data)
  (##sys#check-string mime 'make-display)
  (##sys#check-string data 'make-display)
  (##sys#make-structure 'notebook-display mime data))

(define (##webnb#display? x) (##sys#structure? x 'notebook-display))

(define (emit-display d id rid)
  (event! "display" "rid" rid "mime" (##sys#slot d 1) "data" (##sys#slot d 2) "id" id))

(define (written x) (with-output-to-string (lambda () (write x))))

(define (##webnb#text s)
  (##webnb#make-display "text/plain" (if (string? s) s (written s))))

;; emits X now (a display object, a string as text, else written);
;; a later show with the same ID in the same cell replaces it
(define (##webnb#show x #!optional id)
  (emit-display (if (##webnb#display? x) x (##webnb#text x))
		(and id (->string/null id))
		active)
  (void))

(define (##webnb#clear)
  (event! "clear" "rid" active)
  (void))

(define (markup x) (if (string? x) x (##webnb#sxml->xml x)))

(define (##webnb#html x) (##webnb#make-display "text/html" (markup x)))
(define (##webnb#svg x) (##webnb#make-display "image/svg+xml" (##webnb#svg-ns (markup x))))

(define (##webnb#markdown s)
  (##sys#check-string s 'markdown)
  (##webnb#make-display "text/markdown" s))

(define (##webnb#image bv #!optional (mime "image/png"))
  (##sys#check-bytevector bv 'image)
  (unless (member mime '("image/png" "image/jpeg" "image/gif" "image/webp"))
    (error 'image "unsupported image type" mime))
  (##webnb#make-display mime (##webnb#base64 bv)))

(define (##webnb#table rows #!optional header)
  (define (row->list r)
    (cond ((list? r) r)
	  ((vector? r) (vector->list r))
	  (else (list r))))
  (define (cell tag c)
    (list tag (cond ((or (string? c) (number? c) (char? c)) c)
		    ((and (##webnb#display? c) (equal? (##sys#slot c 1) "text/html"))
		     (list '*raw* (##sys#slot c 2)))
		    (else (written c)))))
  (##webnb#html
   `(table
     ,@(if header
	   `((thead (tr ,@(map (lambda (h) (cell 'th h)) (row->list header)))))
	   '())
     (tbody ,@(map (lambda (r) `(tr ,@(map (lambda (c) (cell 'td c)) (row->list r))))
		   (row->list rows))))))

(define (name-ok? s)			; [A-Za-z][A-Za-z0-9:_.-]*
  (and (fx> (string-length s) 0)
       (let loop ((i 0))
	 (or (fx= i (string-length s))
	     (let ((c (string-ref s i)))
	       (and (or (and (char>=? c #\a) (char<=? c #\z))
			(and (char>=? c #\A) (char<=? c #\Z))
			(and (fx> i 0)
			     (or (and (char>=? c #\0) (char<=? c #\9))
				 (memv c '(#\: #\_ #\. #\-)))))
		    (loop (fx+ i 1))))))))

(define (xml-escape s attr? out)
  (let ((n (string-length s)))
    (do ((i 0 (fx+ i 1))) ((fx= i n))
      (let ((c (string-ref s i)))
	(case c
	  ((#\&) (display "&amp;" out))
	  ((#\<) (display "&lt;" out))
	  ((#\>) (display "&gt;" out))
	  ((#\") (display (if attr? "&quot;" "\"") out))
	  (else (write-char c out)))))))

(define void-elements
  '("area" "base" "br" "col" "embed" "hr" "img" "input" "link" "meta" "source" "track" "wbr"))

;; SXML: (tag (@ (attr value) ...) child ...); strings, characters and
;; numbers are text; (*raw* "markup") is copied as it is
(define (##webnb#sxml->xml x)
  (let ((o (open-output-string)))
    (define (text x)
      (cond ((string? x) x)
	    ((char? x) (string x))
	    ((number? x) (number->string x))
	    ((symbol? x) (symbol->string x))
	    (else #f)))
    (define (attr a)
      (unless (and (pair? a) (symbol? (car a)) (name-ok? (symbol->string (car a))))
	(error 'sxml->xml "invalid SXML attribute" a))
      (let ((v (if (pair? (cdr a)) (cadr a) #t)))
	(when v
	  (write-char #\space o)
	  (display (symbol->string (car a)) o)
	  (write-char #\= o)
	  (write-char #\" o)
	  (unless (eq? v #t)
	    (xml-escape (or (text v) (error 'sxml->xml "invalid SXML attribute value" a)) #t o))
	  (write-char #\" o))))
    (let node ((x x))
      (cond ((or (string? x) (char? x) (number? x)) (xml-escape (text x) #f o))
	    ((null? x))
	    ((and (pair? x) (eq? (car x) '*raw*))
	     (for-each (lambda (s) (##sys#check-string s 'sxml->xml) (display s o)) (cdr x)))
	    ((and (pair? x) (symbol? (car x)))
	     (let ((tag (symbol->string (car x))))
	       (unless (name-ok? tag) (error 'sxml->xml "invalid SXML element name" (car x)))
	       (let* ((rest (cdr x))
		      (attrs? (and (pair? rest) (pair? (car rest)) (eq? (caar rest) '@)))
		      (kids (if attrs? (cdr rest) rest)))
		 (write-char #\< o)
		 (display tag o)
		 (when attrs? (for-each attr (cdar rest)))
		 (cond ((and (null? kids) (member tag void-elements)) (display "/>" o))
		       (else
			(write-char #\> o)
			(for-each node kids)
			(display "</" o)
			(display tag o)
			(write-char #\> o))))))
	    ((pair? x) (for-each node x))	; a list of nodes
	    (else (error 'sxml->xml "invalid SXML node" x))))
    (get-output-string o)))

(define (skip-space s i)
  (if (and (fx< i (string-length s)) (char-whitespace? (string-ref s i)))
      (skip-space s (fx+ i 1))
      i))

;; adds the SVG namespace to a root <svg> without one
(define (##webnb#svg-ns s)
  (##sys#check-string s 'svg)
  (let* ((n (string-length s))
	 (i (skip-space s 0))
	 (j (fx+ i 4)))
    (if (and (fx<= j n)
	     (string=? (substring s i j) "<svg")
	     (or (fx= j n) (memv (string-ref s j) '(#\space #\tab #\newline #\return #\> #\/)))
	     (not (string-contains? (substring s i (or (string-index s #\> i) n)) "xmlns=")))
	(string-append (substring s 0 j) " xmlns=\"http://www.w3.org/2000/svg\"" (substring s j n))
	s)))

(define (##webnb#base64 bv)
  (##sys#check-bytevector bv 'base64)
  (let* ((abc "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
	 (n (bytevector-length bv))
	 (out (make-bytevector (fx* 4 (fx/ (fx+ n 2) 3)) 61))) ; "="
    (define (put! i six) (bytevector-u8-set! out i (char->integer (string-ref abc six))))
    (let loop ((i 0) (j 0))
      (when (fx< i n)
	(let* ((b0 (bytevector-u8-ref bv i))
	       (b1 (if (fx< (fx+ i 1) n) (bytevector-u8-ref bv (fx+ i 1)) 0))
	       (b2 (if (fx< (fx+ i 2) n) (bytevector-u8-ref bv (fx+ i 2)) 0)))
	  (put! j (fxshr b0 2))
	  (put! (fx+ j 1) (fxior (fxshl (fxand b0 3) 4) (fxshr b1 4)))
	  (when (fx< (fx+ i 1) n)
	    (put! (fx+ j 2) (fxior (fxshl (fxand b1 15) 2) (fxshr b2 6))))
	  (when (fx< (fx+ i 2) n)
	    (put! (fx+ j 3) (fxand b2 63)))
	  (loop (fx+ i 3) (fx+ j 4)))))
    (utf8->string out)))

;; evaluated when the kernel starts: no import library is needed
(define notebook-module
  '(module notebook
     (show html svg markdown text image table sxml->xml clear-output display-object?)
     (import (only scheme define))
     (define show ##webnb#show)
     (define html ##webnb#html)
     (define svg ##webnb#svg)
     (define markdown ##webnb#markdown)
     (define text ##webnb#text)
     (define image ##webnb#image)
     (define table ##webnb#table)
     (define sxml->xml ##webnb#sxml->xml)
     (define clear-output ##webnb#clear)
     (define display-object? ##webnb#display?)))


;;; The kernel

(define (##webnb#kernel)
  (when running (error '##webnb#kernel "the notebook kernel is already running"))
  (set! running #t)
  ;; as repl does; -e left them off
  (set! ##sys#notices-enabled #t)
  (load-verbose #t)
  (set-record-printer! 'notebook-display
    (lambda (d p)
      (display "#<notebook-display " p)
      (display (##sys#slot d 1) p)
      (write-char #\space p)
      (display (string-length (##sys#slot d 2)) p)
      (display " chars>" p)))
  (let* ((in ##sys#standard-input)
	 (out ##sys#standard-output)
	 (err ##sys#standard-error)
	 (restore-ports (lambda ()
			  (set! ##sys#standard-input in)
			  (set! ##sys#standard-output out)
			  (set! ##sys#standard-error err))))
    (eval notebook-module)
    (load-csirc! restore-ports)
    (event! "hello" "proto" 1 "version" (chicken-version))
    (let loop ()
      (dispatch (next-request) restore-ports)
      (loop))))
