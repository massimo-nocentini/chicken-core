;;;; r7lib.scm - R7RS library code
;
; Copyright (c) 2022, The CHICKEN Team
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
  (unit r7lib)
  (disable-interrupts))

(include "common-declarations.scm")

(module scheme.write (display
		      write
		      write-shared
		      write-simple)
  (import (rename scheme (display display-simple) (write write-simple))
	  (only chicken.base foldl when optional)
	  (only chicken.fixnum fx+ fx= fx<= fx-))

  (define (interesting? o)
    (or (pair? o)
	(and (vector? o)
	     (fx<= 1 (##sys#size o)))))

  (define (uninteresting? o)
    (not (interesting? o)))

  (define (display-char c p)
    ((##sys#slot (##sys#slot p 2) 2) p c))

  (define (display-string s p)
    (let ((bv (##sys#slot s 0)))
      ((##sys#slot (##sys#slot p 2) 3) p bv 0 (fx- (##sys#size bv) 1))))

  ;; Build an alist mapping `interesting?` objects to boolean values
  ;; indicating whether those objects occur shared in `o`.
  (define (find-shared o cycles-only?)

    (define seen '())
    (define (seen? x) (assq x seen))
    (define (seen! x) (set! seen (cons (cons x 1) seen)))

    ;; Walk the form, tallying the number of times each object is
    ;; encountered. This has the effect of filling `seen` with
    ;; occurence counts for all objects satisfying `interesting?`.
    (let walk! ((o o))
      (when (interesting? o)
	(cond ((seen? o) =>
	       (lambda (p)
		 (##sys#setislot p 1 (fx+ (cdr p) 1))))
	      ((pair? o)
	       (seen! o)
	       (walk! (car o))
	       (walk! (cdr o)))
	      ((vector? o)
	       (seen! o)
	       (let ((len (##sys#size o)))
		 (do ((i 0 (fx+ i 1)))
		     ((fx= i len))
		   (walk! (##sys#slot o i))))))
	;; If we're only interested in cycles and this object isn't
	;; self-referential, discount it (resulting in `write` rather
	;; than `write-shared` behavior).
	(when cycles-only?
	  (let ((p (seen? o)))
	    (when (fx<= (cdr p) 1)
	      (##sys#setislot p 1 0))))))

    ;; Mark shared objects #t, unshared objects #f.
    (foldl (lambda (a p)
	     (if (fx<= (cdr p) 1)
		 (cons (cons (car p) #f) a)
		 (cons (cons (car p) #t) a)))
	   '()
	   seen))

  (define (write-with-shared-structure writer obj cycles-only? port)

    (define label 0)
    (define (assign-label! pair)
      (##sys#setslot pair 1 label)
      (set! label (fx+ label 1)))

    (define shared
      (find-shared obj cycles-only?))

    (define (write-interesting/shared o)
      (cond ((pair? o)
	     (display-char #\( port)
	     (write/shared (car o))
	     (let loop ((o (cdr o)))
	       (cond ((null? o)
		      (display-char #\) port))
		     ((and (pair? o)
			   (not (cdr (assq o shared))))
		      (display-char #\space port)
		      (write/shared (car o))
		      (loop (cdr o)))
		     (else
		      (display-string " . " port)
		      (write/shared o)
		      (display-char #\) port)))))
	    ((vector? o)
	     (display-string "#(" port)
	     (write/shared (##sys#slot o 0))
	     (let ((len (##sys#size o)))
	       (do ((i 1 (fx+ i 1)))
		   ((fx= i len)
		    (display-char #\) port))
		 (display-char #\space port)
		 (write/shared (##sys#slot o i)))))))

    (define (write/shared o)
      (if (uninteresting? o)
	  (writer o port)
	  (let* ((p (assq o shared))
		 (d (cdr p)))
	    (cond ((not d)
		   (write-interesting/shared o))
		  ((number? d)
		   (display-char #\# port)
		   (writer d port)
		   (display-char #\# port))
		  (else
		   (display-char #\# port)
		   (writer label port)
		   (display-char #\= port)
		   (assign-label! p)
		   (write-interesting/shared o))))))

    (write/shared obj))

  (define (display o #!optional (p ##sys#standard-output))
    (write-with-shared-structure
     display-simple
     o
     #t
     p))

  (define (write o  #!optional (p ##sys#standard-output))
    (write-with-shared-structure
     write-simple
     o
     #t
     p))

  (define (write-shared o #!optional (p ##sys#standard-output))
    (write-with-shared-structure
     write-simple
     o
     #f
     p))

)

(module scheme.time (current-second
                     current-jiffy
                     jiffies-per-second)
  (import (only chicken.base define-constant)
          (chicken foreign)
          (only chicken.time current-seconds)
          (only scheme + define inexact->exact))

  ;; As of 2012-06-30.
  (define-constant tai-offset 37.)

  (define (current-second) (+ (current-seconds) tai-offset))

  (define current-jiffy (foreign-lambda long "C_current_jiffy"))

  (define jiffies-per-second (foreign-lambda long "C_jiffies_per_second"))

)

(module scheme.file (file-exists? delete-file
                     open-input-file open-binary-input-file
                     open-output-file open-binary-output-file
                     call-with-input-file call-with-output-file
                     with-input-from-file with-output-to-file)
  (import (only scheme and define quote let apply open-input-file open-output-file call-with-input-file
                call-with-output-file with-input-from-file with-output-to-file)
          (rename (only (chicken file) delete-file file-exists?) (file-exists? file-exists?/base)))

  (define (open-binary-input-file fname . args)
    (let ((p (apply open-input-file fname #:binary args)))
      (##sys#setslot p 14 'binary)
      p))

  (define (open-binary-output-file fname . args)
    (let ((p (apply open-output-file fname #:binary args)))
      (##sys#setslot p 14 'binary)
      p))

  (define (file-exists? fname)
    (and (file-exists?/base fname) #t))

)

(module scheme.process-context (command-line
				emergency-exit
				exit
				get-environment-variable
				get-environment-variables)
  (import scheme
          chicken.process-context
          chicken.type
	  (rename chicken.base (exit chicken-exit)))

(define (command-line)
  ;; Don't cache these; they may be parameterized at any time!
  (cons (program-name) (command-line-arguments)))

(define (->exit-status obj)
  (cond ((integer? obj) obj)
        ((eq? obj #f) 1)
        (else 0)))

(define (exit #!optional (obj 0))
  ;; ##sys#dynamic-unwind is hidden, have to unwind manually.
  ; (##sys#dynamic-unwind '() (length ##sys#dynamic-winds))
  (let unwind ()
    (unless (null? ##sys#dynamic-winds)
      (let ((after (cdar ##sys#dynamic-winds)))
        (set! ##sys#dynamic-winds (cdr ##sys#dynamic-winds))
        (after)
        (unwind))))
  ;; The built-in exit runs cleanup handlers for us.
  (chicken-exit (->exit-status obj)))

)

