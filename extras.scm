;;; extras.scm - Optional non-standard extensions
;
; Copyright (c) 2008-2022, The CHICKEN Team
; Copyright (c) 2000-2007, Felix L. Winkelmann
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


(declare
 (unit extras)
 (uses data-structures))
             
(include "common-declarations.scm")

;;; Pretty print:
;
; Copyright (c) 1991, Marc Feeley
; Author: Marc Feeley (feeley@iro.umontreal.ca)
; Distribution restrictions: none
;
; Modified by felix for use with CHICKEN
;

(module chicken.pretty-print
  (pp pretty-print pretty-print-width)

(import scheme chicken.base chicken.fixnum chicken.keyword chicken.string)
(import (only (scheme base) make-parameter open-output-string get-output-string port?))

(define generic-write
  (lambda (obj display? width output)

    (define (read-macro? l)
      (define (length1? l) (and (pair? l) (null? (cdr l))))
      (let ((head (car l)) (tail (cdr l)))
	(case head
	  ((quote quasiquote unquote unquote-splicing) (length1? tail))
	  (else                                        #f))))

    (define (read-macro-body l)
      (cadr l))

    (define (read-macro-prefix l)
      (let ((head (car l)) (tail (cdr l)))
	(case head
	  ((quote)            "'")
	  ((quasiquote)       "`")
	  ((unquote)          ",")
	  ((unquote-splicing) ",@"))))

    (define (out str col)
      (and col (output str) (+ col (string-length str))))

    (define (wr obj col)

      (define (wr-expr expr col)
	(if (read-macro? expr)
	    (wr (read-macro-body expr) (out (read-macro-prefix expr) col))
	    (wr-lst expr col)))

      (define (wr-lst l col)
	(if (pair? l)
	    (let loop ((l (cdr l))
		       (col (and col (wr (car l) (out "(" col)))))
	      (cond ((not col) col)
		    ((pair? l)
		     (loop (cdr l) (wr (car l) (out " " col))))
		    ((null? l) (out ")" col))
		    (else      (out ")" (wr l (out " . " col))))))
	    (out "()" col)))

      (cond ((pair? obj)        (wr-expr obj col))
	    ((null? obj)        (wr-lst obj col))
	    ((eof-object? obj)  (out "#!eof" col))
	    ((bwp-object? obj)   (out "#!bwp" col))
	    ((vector? obj)      (wr-lst (vector->list obj) (out "#" col)))
	    ((boolean? obj)     (out (if obj "#t" "#f") col))
	    ((number? obj)      (out (##sys#number->string obj) col))
	    ((or (keyword? obj) (symbol? obj))
	     (let ((s (open-output-string)))
	       (##sys#print obj #t s)
	       (out (get-output-string s) col) ) )
	    ((procedure? obj)   (out (##sys#procedure->string obj) col))
	    ((string? obj)
             (if display?
		 (out obj col)
		 (let loop ((i 0) (j 0) (col (out "\"" col)))
		   (if (and col (fx< j (string-length obj)))
		       (let ((c (string-ref obj j)))
			 (cond
			  ((or (char=? c #\\)
			       (char=? c #\"))
			   (loop j
				 (+ j 1)
				 (out "\\"
				      (out (##sys#substring obj i j)
					   col))))
			  ((char<? c #\x20)
			   (loop (fx+ j 1)
				 (fx+ j 1)
				 (let ((col2
					(out (##sys#substring obj i j) col)))
				   (cond ((assq c '((#\tab . "\\t")
						    (#\newline . "\\n")
						    (#\return . "\\r")
						    (#\vtab . "\\v")
						    (#\page . "\\f")
						    (#\alarm . "\\a")
						    (#\backspace . "\\b")))
					  =>
					  (lambda (a)
					    (out (cdr a) col2)))
					 (else
					  (out (string-append
					  	 "\\x"
					  	 (number->string (char->integer c) 16)
					  	 ";")
					  	col2))))))
			  (else (loop i (fx+ j 1) col))))
		       (out "\""
			    (out (##sys#substring obj i j) col))))))
	    ((char? obj)        (if display?
				    (out (make-string 1 obj) col)
				    (let ((code (char->integer obj))
				          (col2 (out "#\\" col)))
				      (cond ((char-name obj)
					     => (lambda (cn)
						  (out (##sys#symbol->string/shared cn) col2) ) )
					    ((or (fx< code 32) (fx> code 127))
					     (out (number->string code 16)
					            (out "x" col2)))
					    (else (out (make-string 1 obj) col2)) ) ) ) )
	    ((##core#inline "C_undefinedp" obj) (out "#<unspecified>" col))
	    ((##core#inline "C_unboundvaluep" obj) (out "#<unbound value>" col))
	    ((##core#inline "C_immp" obj) (out "#<unprintable object>" col))
	    ((##core#inline "C_anypointerp" obj) (out (##sys#pointer->string obj) col))
	    ((##sys#generic-structure? obj)
	     (let ((o (open-output-string)))
	       (##sys#user-print-hook obj #t o)
	       (out (get-output-string o) col) ) )
	    ((port? obj) (out (string-append "#<port " (##sys#slot obj 3) ">") col))
	    ((##core#inline "C_bytevectorp" obj)
	     (out "#u8" col)
             (wr-lst (##sys#bytevector->list obj) col))
	    ((##core#inline "C_lambdainfop" obj)
	     (out ">"
	          (out (##sys#lambda-info->string obj)
	               (out "#<lambda info " col) )))
	    (else (out "#<unprintable object>" col)) ) )

    (define (pp obj col)

      (define (spaces n col)
	(if (> n 0)
	    (if (> n 7)
		(spaces (- n 8) (out "        " col))
		(out (##sys#substring "        " 0 n) col))
	    col))

      (define (indent to col)
	(and col
	     (if (< to col)
		 (and (out (make-string 1 #\newline) col) (spaces to 0))
		 (spaces (- to col) col))))

      (define (pr obj col extra pp-pair)
	(if (or (pair? obj) (vector? obj)) ; may have to split on multiple lines
	    (let ((result '())
		  (left (max (+ (- (- width col) extra) 1) max-expr-width)))
	      (generic-write obj display? #f
			     (lambda (str)
			       (set! result (cons str result))
			       (set! left (- left (string-length str)))
			       (> left 0)))
	      (if (> left 0)	      ; all can be printed on one line
		  (out (reverse-string-append result) col)
		  (if (pair? obj)
		      (pp-pair obj col extra)
		      (pp-list (vector->list obj) (out "#" col) extra pp-expr))))
	    (wr obj col)))

      (define (pp-expr expr col extra)
	(if (read-macro? expr)
	    (pr (read-macro-body expr)
		(out (read-macro-prefix expr) col)
		extra
		pp-expr)
	    (let ((head (car expr)))
	      (if (symbol? head)
		  (let ((proc (style head)))
		    (if proc
			(proc expr col extra)
			(if (> (string-length (##sys#symbol->string/shared head))
			       max-call-head-width)
			    (pp-general expr col extra #f #f #f pp-expr)
			    (pp-call expr col extra pp-expr))))
		  (pp-list expr col extra pp-expr)))))

					; (head item1
					;       item2
					;       item3)
      (define (pp-call expr col extra pp-item)
	(let ((col* (wr (car expr) (out "(" col))))
	  (and col
	       (pp-down (cdr expr) col* (+ col* 1) extra pp-item))))

					; (item1
					;  item2
					;  item3)
      (define (pp-list l col extra pp-item)
	(let ((col (out "(" col)))
	  (pp-down l col col extra pp-item)))

      (define (pp-down l col1 col2 extra pp-item)
	(let loop ((l l) (col col1))
	  (and col
	       (cond ((pair? l)
		      (let ((rest (cdr l)))
			(let ((extra (if (null? rest) (+ extra 1) 0)))
			  (loop rest
				(pr (car l) (indent col2 col) extra pp-item)))))
		     ((null? l)
		      (out ")" col))
		     (else
		      (out ")"
			   (pr l
			       (indent col2 (out "." (indent col2 col)))
			       (+ extra 1)
			       pp-item)))))))

      (define (pp-general expr col extra named? pp-1 pp-2 pp-3)

	(define (tail1 rest col1 col2 col3)
	  (if (and pp-1 (pair? rest))
	      (let* ((val1 (car rest))
		     (rest (cdr rest))
		     (extra (if (null? rest) (+ extra 1) 0)))
		(tail2 rest col1 (pr val1 (indent col3 col2) extra pp-1) col3))
	      (tail2 rest col1 col2 col3)))

	(define (tail2 rest col1 col2 col3)
	  (if (and pp-2 (pair? rest))
	      (let* ((val1 (car rest))
		     (rest (cdr rest))
		     (extra (if (null? rest) (+ extra 1) 0)))
		(tail3 rest col1 (pr val1 (indent col3 col2) extra pp-2)))
	      (tail3 rest col1 col2)))

	(define (tail3 rest col1 col2)
	  (pp-down rest col2 col1 extra pp-3))

	(let* ((head (car expr))
	       (rest (cdr expr))
	       (col* (wr head (out "(" col))))
	  (if (and named? (pair? rest))
	      (let* ((name (car rest))
		     (rest (cdr rest))
		     (col** (wr name (out " " col*))))
		(tail1 rest (+ col indent-general) col** (+ col** 1)))
	      (tail1 rest (+ col indent-general) col* (+ col* 1)))))

      (define (pp-expr-list l col extra)
	(pp-list l col extra pp-expr))

      (define (pp-lambda expr col extra)
	(pp-general expr col extra #f pp-expr-list #f pp-expr))

      (define (pp-if expr col extra)
	(pp-general expr col extra #f pp-expr #f pp-expr))

      (define (pp-cond expr col extra)
	(pp-call expr col extra pp-expr-list))

      (define (pp-case expr col extra)
	(pp-general expr col extra #f pp-expr #f pp-expr-list))

      (define (pp-and expr col extra)
	(pp-call expr col extra pp-expr))

      (define (pp-let expr col extra)
	(let* ((rest (cdr expr))
	       (named? (and (pair? rest) (symbol? (car rest)))))
	  (pp-general expr col extra named? pp-expr-list #f pp-expr)))

      (define (pp-begin expr col extra)
	(pp-general expr col extra #f #f #f pp-expr))

      (define (pp-do expr col extra)
	(pp-general expr col extra #f pp-expr-list pp-expr-list pp-expr))

      ;; define formatting style (change these to suit your style)

      (define indent-general 2)

      (define max-call-head-width 5)

      (define max-expr-width 50)

      (define (style head)
	(case head
	  ((lambda let* letrec letrec* define) pp-lambda)
	  ((if set!)                   pp-if)
	  ((cond)                      pp-cond)
	  ((case)                      pp-case)
	  ((and or)                    pp-and)
	  ((let)                       pp-let)
	  ((begin)                     pp-begin)
	  ((do)                        pp-do)
	  (else                        #f)))

      (pr obj col 0 pp-expr))

    (if width
	(out (make-string 1 #\newline) (pp obj 0))
	(wr obj 0))))

; (pretty-print obj port) pretty prints 'obj' on 'port'.  The current
; output port is used if 'port' is not specified.

(define pretty-print-width (make-parameter 79))

(define (pretty-print obj . opt)
  (let ((port (if (pair? opt) (car opt) (current-output-port))))
    (generic-write obj #f (pretty-print-width) (lambda (s) (display s port) #t))
    (##core#undefined) ) )

(define pp pretty-print))


;;; Write simple formatted output:

(module chicken.format
  (format fprintf printf sprintf)

(import scheme chicken.base chicken.fixnum chicken.platform)
(import (only (scheme base) open-output-string get-output-string))

(define fprintf0
  (lambda (loc port msg args)
    (when port (##sys#check-output-port port #t loc))
    (let ((out (if (and port (##sys#tty-port? port))
		   port
		   (open-output-string))))
      (let rec ([msg msg] [args args])
	(##sys#check-string msg loc)
	(let ((index 0)
	      (len (string-length msg)) )
	  (define (fetch)
	    (let ((c (string-ref msg index)))
	      (set! index (fx+ index 1))
	      c) )
	  (define (next)
	    (if (##core#inline "C_eqp" args '())
		(##sys#error loc "too few arguments to formatted output procedure")
		(let ((x (##sys#slot args 0)))
		  (set! args (##sys#slot args 1)) 
		  x) ) )
	  (let loop ()
	    (unless (fx>= index len)
	      (let ((c (fetch)))
		(if (and (eq? c #\~) (fx< index len))
		    (let ((dchar (fetch)))
		      (case (char-upcase dchar)
			((#\S) (write (next) out))
			((#\A) (display (next) out))
			((#\C) (##sys#write-char-0 (next) out))
			((#\B) (display (##sys#number->string (next) 2) out))
			((#\O) (display (##sys#number->string (next) 8) out))
			((#\X) (display (##sys#number->string (next) 16) out))
			((#\!) (##sys#flush-output out))
			((#\?)
			 (let* ([fstr (next)]
				[lst (next)] )
			   (##sys#check-list lst loc)
			   (rec fstr lst) out) )
			((#\~) (##sys#write-char-0 #\~ out))
			((#\% #\N) (newline out))
			(else
			 (if (char-whitespace? dchar)
			     (let skip ((c (fetch)))
			       (if (char-whitespace? c)
				   (skip (fetch))
				   (set! index (fx- index 1)) ) )
			     (##sys#error loc "illegal format-string character" dchar) ) ) ) )
		    (##sys#write-char-0 c out) )
		(loop) ) ) ) ) )
      (cond ((not port) (get-output-string out))
	    ((not (eq? out port))
	     (##sys#print (get-output-string out) #f port) ) ) ) ) )

(define (fprintf port fstr . args)
  (fprintf0 'fprintf port fstr args) )

(define (printf fstr . args)
  (fprintf0 'printf ##sys#standard-output fstr args) )

(define (sprintf fstr . args)
  (fprintf0 'sprintf #f fstr args) )

(define format
  (lambda (fmt-or-dst . args)
    (apply (cond [(not fmt-or-dst)		 sprintf]
		 [(boolean? fmt-or-dst)	 printf]
		 [(string? fmt-or-dst)	 (set! args (cons fmt-or-dst args)) sprintf]
		 [(output-port? fmt-or-dst)	 (set! args (cons fmt-or-dst args)) fprintf]
		 [else
		  (##sys#error 'format "illegal destination" fmt-or-dst args)])
	   args) ) )

(register-feature! 'srfi-28))


;;; Random numbers:

(module chicken.random
  (set-pseudo-random-seed! pseudo-random-integer pseudo-random-real random-bytes)

(import scheme chicken.base chicken.time chicken.io chicken.foreign)

(define (set-pseudo-random-seed! buf #!optional n)
  (cond (n (##sys#check-fixnum n 'set-pseudo-random-seed!)
           (when (##core#inline "C_fixnum_lessp" n 0)
             (##sys#error 'set-pseudo-random-seed! "invalid size" n)))
        (else (set! n (##sys#size buf))))
  (##sys#check-bytevector buf 'set-pseudo-random-seed!)
  (##core#inline "C_set_random_seed" buf
                 (##core#inline "C_i_fixnum_min" 
                                n 
                                (##sys#size buf))))

(define (pseudo-random-integer n)
  (cond ((##core#inline "C_fixnump" n)
         (##core#inline "C_random_fixnum" n))
        ((not (##core#inline "C_i_bignump" n))
         (##sys#error 'pseudo-random-integer "bad argument type" n))
        (else
          (##core#inline_allocate ("C_s_a_u_i_random_int" 2) n))))

(define (pseudo-random-real)
  (##core#inline_allocate ("C_a_i_random_real" 2)))

(define random-bytes
  (let ((nstate (foreign-value "C_RANDOM_STATE_SIZE" unsigned-int)))
    (lambda (#!optional buf size)
      (when size
        (##sys#check-fixnum size 'random-bytes)
        (when (< size 0) 
          (##sys#error 'random-bytes "invalid size" size)))
      (let* ((dest (cond (buf
                         (when (or (##sys#immediate? buf)
                                   (not (##core#inline "C_byteblockp" buf)))
                           (##sys#error 'random-bytes
                                        "invalid buffer type" buf))
                         buf)
                        (else (##sys#make-bytevector (or size nstate)))))
             (r (##core#inline "C_random_bytes" dest
                               (or size (##sys#size dest)))))
        (unless r
          (##sys#error 'random-bytes "unable to read random bytes"))
        dest))))

)


;;; Version comparison (used for egg versions)

(module chicken.version (version>=?)

(import scheme)
(import (chicken base)
        (chicken string)
        (chicken fixnum))

(define (version>=? v1 v2)
  (define (version->list s)
    (map (lambda (x) (or (string->number x) x))
      (let ((len (string-length s)))
        (let loop ((start 0) (pos 0))
          (cond ((fx>= pos len)  (list (substring s start len)))
                ((memv (string-ref s pos) '(#\- #\\ #\. #\_ #\/))
                 (cons (substring s start pos)
                       (let ((p2 (fx+ pos 1)))
                         (loop p2 p2))))
                (else (loop start (fx+ pos 1))))))))
  (##sys#check-string v1 'version>=?)
  (##sys#check-string v2 'version>=?)
  (let loop ((p1 (version->list v1))
             (p2 (version->list v2)))
    (cond ((null? p1) (null? p2))
          ((null? p2))
          ((number? (car p1))
           (and (number? (car p2))
                (or (> (car p1) (car p2))
                    (and (= (car p1) (car p2))
                         (loop (cdr p1) (cdr p2))))))
          ((number? (car p2)))
          ((string>? (car p1) (car p2)))
          (else
            (and (string=? (car p1) (car p2))
                 (loop (cdr p1) (cdr p2)))))))

) ;; end module
