;; Copyright (c) 1993-2001 by Richard Kelsey and Jonathan Rees.
;; All rights reserved.

;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met:
;; 1. Redistributions of source code must retain the above copyright
;;    notice, this list of conditions and the following disclaimer.
;; 2. Redistributions in binary form must reproduce the above copyright
;;    notice, this list of conditions and the following disclaimer in the
;;    documentation and/or other materials provided with the distribution.
;; 3. The name of the authors may not be used to endorse or promote products
;;    derived from this software without specific prior written permission.

;; THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS OR
;; IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
;; OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
;; IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY DIRECT, INDIRECT,
;; INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
;; NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
;; DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
;; THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

;;; [Hacked slightly by Taylor R. Campbell to make it work in his
;;; macro expander `riaxpander'.]

;; [Hacked even more by Felix L. Winkelmann to make it work in the
;; Hi-Lo expander]

; Example:
;
; (define-syntax or
;   (syntax-rules ()
;     ((or)          #f)
;     ((or e)        e)
;     ((or e1 e ...) (let ((temp e1))
;		       (if temp temp (or e ...))))))

(##sys#extend-macro-environment
 'syntax-rules
 '()
 (##sys#er-transformer
  (lambda (exp r c)
    (##sys#check-syntax 'syntax-rules exp '#(_ 2))
    (let ((subkeywords (cadr exp))
	  (rules (cddr exp))
	  (ellipsis '...))
      (when (symbol? subkeywords)
	(##sys#check-syntax 'syntax-rules exp '(_ _ list . #(_ 0)))
	(set! ellipsis subkeywords)
	(set! subkeywords (car rules))
	(set! rules (cdr rules)))
      (chicken.internal.syntax-rules#process-syntax-rules
       ellipsis rules subkeywords r c #t)))))

;; Runtime internal support module exclusively for syntax-rules
(module chicken.internal.syntax-rules
    (drop-right take-right safe-length syntax-rules-mismatch)

(import scheme)

(define (syntax-rules-mismatch input)
  (##sys#syntax-error "no rule matches form" input))

(define (drop-right input temp)
  (let loop ((len (safe-length input))
	     (input input))
    (cond
     ((> len temp)
      (cons (car input)
	    (loop (- len 1) (cdr input))))
     (else '()))))

(define (take-right input temp)
  (let loop ((len (safe-length input))
	     (input input))
    (cond
     ((> len temp)
      (loop (- len 1) (cdr input)))
     (else input))))

(define (safe-length lst)
  (let loop ((lst lst) (len 0))
    (if (pair? lst) 
        (loop (cdr lst) (+ 1 len))
        len)))

(define (process-syntax-rules ellipsis rules subkeywords r c r7ext)

  (define %append '##sys#append)
  (define %apply '##sys#apply)
  (define %and (r 'and))
  (define %car '##sys#car)
  (define %cdr '##sys#cdr)
  (define %length '##sys#length)
  (define %vector? '##sys#vector?)
  (define %vector-length '##sys#vector-length)
  (define %vector-ref '##sys#vector-ref)
  (define %vector->list '##sys#vector->list)
  (define %list->vector '##sys#list->vector)
  (define %>= '##sys#>=)
  (define %= '##sys#=)
  (define %+ '##sys#+)
  (define %compare (r 'compare))
  (define %cond (r 'cond))
  (define %cons '##sys#cons)
  (define %else (r 'else))
  (define %eq? '##sys#eq?)
  (define %equal? '##sys#equal?)
  (define %input (r 'input))
  (define %l (r 'l))
  (define %len (r 'len))
  (define %lambda (r 'lambda))
  (define %let (r 'let))
  (define %let* (r 'let*))
  (define %loop (r 'loop))
  (define %map1 '##sys#map)
  (define %map '##sys#map-n)
  (define %null? '##sys#null?)
  (define %or (r 'or))
  (define %pair? '##sys#pair?)
  (define %quote (r 'quote))
  (define %rename (r 'rename))
  (define %tail (r 'tail))
  (define %temp (r 'temp))
  (define %syntax-error '##sys#syntax-error)
  (define %ellipsis (r ellipsis))
  (define %safe-length (r 'chicken.internal.syntax-rules#safe-length))
  (define %take-right (r 'chicken.internal.syntax-rules#take-right))
  (define %drop-right (r 'chicken.internal.syntax-rules#drop-right))
  (define %syntax-rules-mismatch
    (r 'chicken.internal.syntax-rules#syntax-rules-mismatch))

  (define (ellipsis? x)
    (c x %ellipsis))

  ;; R7RS support: underscore matches anything
  (define (underscore? x)
    (c x (r '_)))

  (define (make-transformer rules)
    `(##sys#er-transformer
      (,%lambda (,%input ,%rename ,%compare)
	(,%let ((,%tail (,%cdr ,%input)))
	  (,%cond ,@(map process-rule rules)
		  (,%else (,%syntax-rules-mismatch ,%input)))))))

  (define (process-rule rule)
    (if (and (pair? rule)
	     (pair? (cdr rule))
	     (null? (cddr rule)))
	(let ((pattern (cdar rule))
	      (template (cadr rule)))
	  `((,%and ,@(process-match %tail pattern #f ellipsis?))
	    (,%let* ,(process-pattern pattern
				      %tail
				      (lambda (x) x) #f ellipsis?)
		    ,(process-template template
				       0 ellipsis?
				       (meta-variables pattern 0 ellipsis? '() #f)))))
	(##sys#syntax-error "ill-formed syntax rule" rule)))

  ;; Generate code to test whether input expression matches pattern

  (define (process-match input pattern seen-segment? el?)
    (cond ((symbol? pattern)
	   (if (memq pattern subkeywords)
	       `((,%compare ,input (,%rename (##core#syntax ,pattern))))
	       `()))
	  ((segment-pattern? pattern seen-segment? el?)
	   (process-segment-match input pattern el?))
	  ((pair? pattern)
	   `((,%let ((,%temp ,input))
               (,%and (,%pair? ,%temp)
                      ,@(process-match `(,%car ,%temp) (car pattern) #f el?)
                      ,@(process-match `(,%cdr ,%temp) (cdr pattern) #f el?)))))
	  ((vector? pattern)
           `((,%let ((,%temp ,input))
              (,%and (,%vector? ,%temp)
                     ,@(process-match `(,%vector->list ,%temp)
                                      (vector->list pattern) #f el?)))))
	  ((or (null? pattern) (boolean? pattern) (char? pattern))
	   `((,%eq? ,input ',pattern)))
	  (else
	   `((,%equal? ,input ',pattern)))))

  (define (process-segment-match input pattern el?)
    (let ((conjuncts (process-match `(,%car ,%l) (car pattern) #f el?))
          (plen (safe-length (cddr pattern))))
      `((,%let ((,%len (,%safe-length ,input)))
               (,%and (,%>= ,%len ,plen)
                      (,%let ,%loop ((,%l ,input)
                                     (,%len ,%len))
                             (,%cond ((,%= ,%len ,plen)
                                      ,@(process-match %l (cddr pattern) #t el?))
                                     (,%else (,%and ,@conjuncts
                                                    (,%loop (,%cdr ,%l) 
                                                            (,%+ ,%len -1)))))))))))

  ;; Generate code to take apart the input expression
  ;; This is pretty bad, but it seems to work (can't say why).

  (define (process-pattern pattern path mapit seen-segment? el?)
    (cond ((symbol? pattern)
	   (if (or (memq pattern subkeywords)
                   (and r7ext (underscore? pattern)))
	       '()
	       (list (list pattern (mapit path)))))
	  ((segment-pattern? pattern seen-segment? el?)
           (let* ((tail-length (safe-length (cddr pattern)))
                  (%match (if (and (list? (cddr pattern))
                                   (zero? tail-length) ) ; Simple segment?
                              path  ; No list traversing overhead at runtime!
                              `(,%drop-right ,path ,tail-length))))
             (append
              (process-pattern (car pattern)
                               %temp
                               (lambda (x) ;temp is free in x
                                 (mapit
                                  (if (eq? %temp x)
                                      %match ; Optimization: no map+lambda
                                      `(,%map1 (,%lambda (,%temp) ,x) ,%match))))
                               #f el?)
              (process-pattern (cddr pattern)
                               `(,%take-right ,path ,tail-length) 
                               mapit #t el?))))
	  ((pair? pattern)
	   (append (process-pattern (car pattern) `(,%car ,path) mapit #f el?)
		   (process-pattern (cdr pattern) `(,%cdr ,path) mapit #f el?)))
          ((vector? pattern)
           (process-pattern (vector->list pattern)
                            `(,%vector->list ,path) 
                            mapit #f el?))
	  (else '())))

  ;; Generate code to compose the output expression according to template

  (define (process-template template dim el? env)
    (cond ((symbol? template)
	   (let ((probe (assq template env)))
	     (if probe
		 (if (<= (cdr probe) dim)
		     template
		     (##sys#syntax-error "template dimension error (too few ellipses?)"
					      template))
		 `(,%rename (##core#syntax ,template)))))
          ((and r7ext
                (ellipsis-escaped-pattern? template el?))
            (if (or (not (pair? (cdr template))) (pair? (cddr template)))
                (##sys#syntax-error "Invalid escaped ellipsis template" template)
                (process-template (cadr template) dim (lambda _ #f) env)))
	  ((segment-template? template el?)
	   (let* ((depth (segment-depth template el?))
		  (seg-dim (+ dim depth))
		  (vars
		   (free-meta-variables (car template) seg-dim el? env '())))
	     (if (null? vars)
		 (##sys#syntax-error "too many ellipses" template)
		 (let* ((x (process-template (car template)
					     seg-dim el?
					     env))
			(gen (if (and (pair? vars)
				      (null? (cdr vars))
				      (symbol? x)
				      (eq? x (car vars)))
				 x	;+++
				 `(,%map (,%lambda ,vars ,x)
					 ,@vars)))
			(gen (do ((d depth (- d 1))
				  (gen gen `(,%apply ,%append ,gen)))
				 ((= d 1)
				  gen))))
		   (if (null? (segment-tail template el?))
		       gen		;+++
		       `(,%append ,gen ,(process-template (segment-tail template el?)
							  dim el? env)))))))
	  ((pair? template)
	   `(,%cons ,(process-template (car template) dim el? env)
		    ,(process-template (cdr template) dim el? env)))
	  ((vector? template)
	   `(,%list->vector
	     ,(process-template (vector->list template) dim el? env)))
	  (else
	   `(,%quote ,template))))

  ;; Return an association list of (var . dim)

  (define (meta-variables pattern dim el? vars seen-segment?)
    (cond ((symbol? pattern)
	   (if (or (memq pattern subkeywords)
                   (and r7ext (underscore? pattern))) 
	       vars
	       (cons (cons pattern dim) vars)))
	  ((segment-pattern? pattern seen-segment? el?)
	   (meta-variables (car pattern) (+ dim 1) el?
                           (meta-variables (cddr pattern) dim el? vars #t) #f))
	  ((pair? pattern)
	   (meta-variables (car pattern) dim el?
			   (meta-variables (cdr pattern) dim el? vars #f) #f))
	  ((vector? pattern)
	   (meta-variables (vector->list pattern) dim el? vars #f))
	  (else vars)))

  ;; Return a list of meta-variables of given higher dim

  (define (free-meta-variables template dim el? env free)
    (cond ((symbol? template)
	   (if (and (not (memq template free))
		    (let ((probe (assq template env)))
		      (and probe (>= (cdr probe) dim))))
	       (cons template free)
	       free))
	  ((segment-template? template el?)
	   (free-meta-variables (car template)
				dim el? env
				(free-meta-variables (cddr template)
						     dim el? env free)))
	  ((pair? template)
	   (free-meta-variables (car template)
				dim el? env
				(free-meta-variables (cdr template)
						     dim el? env free)))
	  ((vector? template)
	   (free-meta-variables (vector->list template) dim el? env free))
	  (else free)))

  (define (ellipsis-escaped-pattern? pattern el?)
     (and (pair? pattern) (el? (car pattern))))

  (define (segment-pattern? p seen-segment? el?)
    (and (segment-template? p el?)
         (if seen-segment?
             (##sys#syntax-error "Only one segment per level is allowed" p)
             #t)))

  (define (segment-template? pattern el?)
    (and (pair? pattern)
	 (pair? (cdr pattern))
         ((if r7ext el? ellipsis?) (cadr pattern))))

  ;; Count the number of `...'s in PATTERN.

  (define (segment-depth pattern el?)
    (if (segment-template? pattern el?)
	(+ 1 (segment-depth (cdr pattern) el?))
	0))

  ;; Get whatever is after the `...'s in PATTERN.

  (define (segment-tail pattern el?)
    (let loop ((pattern (cdr pattern)))
      (if (and (pair? pattern)
	       ((if r7ext el? ellipsis?) (car pattern)))
	  (loop (cdr pattern))
	  pattern)))

  (make-transformer rules))

) ; chicken.internal.syntax-rules
