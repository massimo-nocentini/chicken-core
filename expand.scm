;;;; expand.scm - The HI/LO expander
;
; Copyright (c) 2008-2022, The CHICKEN Team
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


;; this unit needs the "modules" unit, but must be initialized first, so it doesn't
;; declare "modules" as used - if you use "-explicit-use", take care of this.

(declare
  (unit expand)
  (uses internal)
  (disable-interrupts)
  (fixnum)
  (not inline ##sys#syntax-error-hook ##sys#compiler-syntax-hook))

(module chicken.syntax
  (expand
   expand1
   get-line-number
   read-with-source-info
   strip-syntax
   er-macro-transformer
   ir-macro-transformer
   sc-macro-transformer
   rsc-macro-transformer
   make-syntactic-closure
   make-syntactic-closure-list
   close-syntax
   capture-syntactic-environment
   identifier?
   identifier=?
   identifier->symbol
   syntactic-closure?
   syntactic-environment?
   strip-syntactic-closures
   expander-macro-transformer
   scheme-syntactic-environment
   core-syntactic-environment
   extend-syntactic-environment
   scheme-macrology)

(import scheme
	chicken.base
	chicken.condition
	chicken.fixnum
	chicken.internal
	chicken.keyword
	chicken.platform
	chicken.string)
(import (only (scheme base) make-parameter open-output-string get-output-string))

(include "common-declarations.scm")
(include "mini-srfi-1.scm")

(define-syntax d (syntax-rules () ((_ . _) (void))))
;(define-syntax d (syntax-rules () ((_ args ...) (print args ...))))

;; Macro to avoid "unused variable map-se" when "d" is disabled
(define-syntax map-se
  (syntax-rules ()
    ((_ ?se)
     (map (lambda (a)
	    (cons (car a) (if (symbol? (cdr a)) (cdr a) '<macro>)))
	  ?se))))

(define-alias dd d)
(define-alias dm d)
(define-alias dx d)

(define-inline (getp sym prop)
  (##core#inline "C_i_getprop" sym prop #f))

(define-inline (putp sym prop val)
  (##core#inline_allocate ("C_a_i_putprop" 8) sym prop val))

(define-inline (namespaced-symbol? sym)
  (##core#inline "C_u_i_namespaced_symbolp" sym))

;;; Source file tracking

(define ##sys#current-source-filename #f)

;;; Syntactic environments

(define ##sys#current-environment (make-parameter '()))
(define ##sys#current-meta-environment (make-parameter '()))

(define (lookup id se)
  (cond ((##core#inline "C_u_i_assq" id se) => cdr)
	((getp id '##core#macro-alias))
	(else #f)))

(define (macro-alias var se)
  (if (or (keyword? var) (namespaced-symbol? var))
      var
      (let* ((alias (gensym var))
	     (ua (or (lookup var se) var))
             (rn (or (getp var '##core#real-name) var)))
	(putp alias '##core#macro-alias ua)
	(putp alias '##core#real-name rn)
	(dd "aliasing " alias " (real: " var ") to "
	    (if (pair? ua)
		'<macro>
		ua))
	alias) ) )

(define (strip-syntax exp)
 (let ((seen '()))
   (let walk ((x exp))
     (cond ((assq x seen) => cdr)
	   ((keyword? x) x)
           ((symbol? x)
            (let ((x2 (getp x '##core#macro-alias) ) )
              (cond ((getp x '##core#real-name))
                    ((not x2) x)
                    ((pair? x2) x)
                    (else x2))))
           ((pair? x)
            (let ((cell (cons #f #f)))
              (set! seen (cons (cons x cell) seen))
              (set-car! cell (walk (car x)))
              (set-cdr! cell (walk (cdr x)))
              cell))
           ((vector? x)
            (let* ((len (##sys#size x))
		   (vec (make-vector len)))
              (set! seen (cons (cons x vec) seen))
              (do ((i 0 (fx+ i 1)))
                  ((fx>= i len) vec)
                (##sys#setslot vec i (walk (##sys#slot x i))))))
           ((##sys#structure? x 'syntactic-closure)
            (walk (##sys#slot x 3)))
           (else x)))))

;; A self-evaluating vector literal, stripped only if it holds a
;; renamed symbol or a syntactic closure.  Otherwise it is returned as
;; it is, so that a vector a macro puts into its output keeps its
;; identity, and a large table costs a walk rather than the quadratic
;; time of strip-syntax's sharing table.  The walk gives up, stripping
;; after all (strip-syntax handles sharing and cycles), when it has
;; visited more than `strip-check-budget' pairs and elements, or nests
;; deeper than `strip-check-depth' (data that is circular or shared
;; many times over).
(define-constant strip-check-budget 4000000)
(define-constant strip-check-depth 1000)

(define (##sys#strip-syntax-literal x)
  (let ((budget strip-check-budget))
    (define (renamed? x depth)
      (cond ((keyword? x) #f)
	    ((symbol? x)
	     (let ((rn (getp x '##core#real-name)))
	       (if rn
		   (not (eq? rn x))
		   (let ((m (getp x '##core#macro-alias)))
		     (and m (not (pair? m)) (not (eq? m x)))))))
	    ((or (pair? x) (vector? x))
	     (or (fx>= depth strip-check-depth)
		 (if (pair? x)
		     (let loop ((x x))
		       (cond ((fx<= budget 0))
			     ((pair? x)
			      (set! budget (fx- budget 1))
			      (or (renamed? (##sys#slot x 0) (fx+ depth 1))
				  (loop (##sys#slot x 1))))
			     (else (renamed? x (fx+ depth 1)))))
		     (let ((n (##sys#size x)))
		       (let loop ((i 0))
			 (and (fx< i n)
			      (or (fx<= budget 0)
				  (begin
				    (set! budget (fx- budget 1))
				    (renamed? (##sys#slot x i) (fx+ depth 1)))
				  (loop (fx+ i 1)))))))))
	    ((##sys#structure? x 'syntactic-closure))
	    (else #f)))
    (if (renamed? x 0) (strip-syntax x) x)))

(define (##sys#extend-se se vars #!optional (aliases (map gensym vars)))
  (for-each
   (lambda (alias sym)
     (let ((original-real-name (getp sym '##core#real-name)))
       (putp alias '##core#real-name (or original-real-name sym))))
   aliases vars)
  (append (map (lambda (x y) (cons x y)) vars aliases) se)) ; inline cons


;;; Macro handling

(define ##sys#macro-environment (make-parameter '()))

(define ##sys#scheme-macro-environment '()) ; reassigned below
;; These are all re-assigned by chicken-syntax.scm:
(define ##sys#chicken-ffi-macro-environment '()) ; used later in foreign.import.scm
(define ##sys#chicken.condition-macro-environment '()) ; used later in chicken.condition.import.scm
(define ##sys#chicken.time-macro-environment '()) ; used later in chicken.time.import.scm
(define ##sys#chicken.type-macro-environment '()) ; used later in chicken.type.import.scm
(define ##sys#chicken.syntax-macro-environment '()) ; used later in chicken.syntax.import.scm
(define ##sys#chicken.base-macro-environment '()) ; used later in chicken.base.import.scm

(define (##sys#ensure-transformer t #!optional loc)
  (if (##sys#structure? t 'transformer)
      (##sys#slot t 1)
      (##sys#error loc "expected syntax-transformer, but got" t)))

(define (##sys#extend-macro-environment name se transformer)
  (let ((me (##sys#macro-environment))
	(handler (##sys#ensure-transformer transformer name)))
    (cond ((lookup name me) =>
	   (lambda (a)
	     (set-car! a se)
	     (set-car! (cdr a) handler)
	     a))
	  (else
	   (let ((data (list se handler)))
	     (##sys#macro-environment
	      (cons (cons name data) me))
	     data)))))

(define (##sys#macro? sym #!optional (senv (##sys#current-environment)))
  (or (let ((l (lookup sym senv)))
	(pair? l))
      (and-let* ((l (lookup sym (##sys#macro-environment))))
	(pair? l))))

(define (##sys#undefine-macro! name)
  (##sys#macro-environment
    ;; this builds up stack, but isn't used often anyway...
    (let loop ((me (##sys#macro-environment)))
      (cond ((null? me) '())
	    ((eq? name (caar me)) (cdr me))
	    (else (cons (car me) (loop (cdr me))))))))

;; The basic macro-expander

(define (##sys#expand-0 exp dse cs?)
  (define (call-handler name handler exp se cs)
    (dd "invoking macro: " name)
    (dd `(STATIC-SE: ,@(map-se se)))
    (handle-exceptions ex
	;; modify error message in condition object to include
	;; currently expanded macro-name
	(abort
	 (if (and (##sys#structure? ex 'condition)
		  (memv 'exn (##sys#slot ex 1)) )
	     (##sys#make-structure
	      'condition
	      (##sys#slot ex 1)
	      (let copy ([ps (##sys#slot ex 2)])
		(if (null? ps)
		    '()
		    (let ([p (car ps)]
			  [r (cdr ps)])
		      (if (and (equal? '(exn . message) p)
			       (pair? r)
			       (string? (car r)) )
			  (cons
			   '(exn . message)
			   (cons (string-append
				  "during expansion of ("
				  (##sys#symbol->string/shared name)
				  " ...) - "
				  (car r) )
				 (cdr r) ) )
			  (copy r) ) ) ) ) )
	     ex) )
      (let ((exp2
	     (if cs
		 ;; compiler-syntax may "fall through"
		 (fluid-let ((chicken.internal.syntax-rules#syntax-rules-mismatch
			      (lambda (input) exp))) ; a bit of a hack
		   (handler exp se dse))
		 (handler exp se dse))) )
	(when (and (not cs) (eq? exp exp2))
	  (##sys#syntax-error
	   (string-append
	    "syntax transformer for `" (##sys#symbol->string/shared name)
	    "' returns original form, which would result in endless expansion")
	   exp))
	(dx `(,name ~~> ,exp2))
	(sc-propagate-context! exp exp2 handler dse)
	(expansion-result-hook exp exp2) ) ) )
  (define (expand head exp mdef)
    (dd `(EXPAND:
	  ,head
	  ,(cond ((getp head '##core#macro-alias) =>
		  (lambda (a) (if (symbol? a) a '<macro>)) )
		 (else '_))
	  ,exp
	  ,(if (pair? mdef)
	       `(SE: ,@(map-se (car mdef)))
	       mdef)))
    (if (pair? mdef)
        (values
	 ;; force ref. opaqueness by passing dynamic se [what does this comment mean? I forgot ...]
           (call-handler head (cadr mdef) exp (car mdef) #f)
           #t)
	(values exp #f)) )
  (let loop ((exp exp))
    (if (pair? exp)
      (let ((head (car exp))
	    (body (cdr exp)) )
	(if (symbol? head)
	    (let ((head2 (or (lookup head dse) head)))
	      (unless (pair? head2)
		(set! head2 (or (lookup head2 (##sys#macro-environment)) head2)) )
	      (cond ((and (pair? head2)
                          (eq? (##sys#get head '##sys#override) 'value))
                     (values exp #f))
                    ((eq? head2 '##core#let)
		     (##sys#check-syntax 'let body '#(_ 2) #f dse)
		     (let ((bindings (car body)))
		       (cond ((symbol? bindings) ; expand named let
			      (##sys#check-syntax 'let body '(_ #((variable _) 0) . #(_ 1)) #f dse)
			      (let ([bs (cadr body)])
				(values
				 `(##core#app
				   (##core#letrec*
				    ([,bindings
				      (##core#loop-lambda
				       ,(map (lambda (b) (car b)) bs) ,@(cddr body))])
				    ,bindings)
				   ,@(##sys#map cadr bs) )
				 #t) ) )
			     (else (values exp #f)) ) ) )
		    ((and cs? (symbol? head2) (getp head2 '##compiler#compiler-syntax)) =>
		     (lambda (cs)
		       (let ((result (call-handler head (car cs) exp (cdr cs) #t)))
			 (cond ((eq? result exp) (expand head exp head2))
			       (else
				(when ##sys#compiler-syntax-hook
				  (##sys#compiler-syntax-hook head2 result))
				(loop result))))))
		    (else (expand head exp head2)) ) )
	    (values exp #f) ) )
      (values exp #f) ) ) )

(define ##sys#compiler-syntax-hook #f)
(define ##sys#enable-runtime-macros #f)
(define expansion-result-hook (lambda (input output) output))


;;; User-level macroexpansion

(define (expand exp #!optional (se (##sys#current-environment)) cs?)
  (let loop ((exp exp))
    (let-values (((exp2 m) (##sys#expand-0 exp se cs?)))
      (if m
	  (loop exp2)
	  exp2) ) ) )

(define (expand1 exp #!optional (se (##sys#current-environment)) cs?)
  (nth-value 0 (##sys#expand-0 exp se cs?)) )


;;; Extended (DSSSL-style) lambda lists
;
; Assumptions:
;
; 1) #!rest must come before #!key
; 2) default values may refer to earlier variables
; 3) optional/key args may be either variable or (variable default)
; 4) an argument marker may not be specified more than once
; 5) no special handling of extra keywords (no error)
; 6) default value of optional/key args is #f
; 7) mixing with dotted list syntax is allowed

(define (##sys#extended-lambda-list? llist)
  (let loop ([llist llist])
    (and (pair? llist)
	 (case (##sys#slot llist 0)
	   [(#!rest #!optional #!key) #t]
	   [else (loop (cdr llist))] ) ) ) )

(define ##sys#expand-extended-lambda-list
  (let ((reverse reverse))
    (lambda (llist0 body errh se)
      (define (err msg) (errh msg llist0))
      (define (->keyword s) (string->keyword (##sys#symbol->string/shared s)))
      (let ((rvar #f)
	    (hasrest #f)
	    ;; These might not exist in se, use default or chicken env:
	    (%let* (macro-alias 'let* ##sys#default-macro-environment))
	    (%lambda '##core#lambda)
	    (%opt (macro-alias 'optional ##sys#chicken.base-macro-environment))
	    (%let-optionals* (macro-alias 'let-optionals* ##sys#chicken.base-macro-environment))
	    (%let '##core#let))
	(let loop ([mode 0]		; req=0, opt=1, rest=2, key=3, end=4
		   [req '()]
		   [opt '()]
		   [key '()]
		   [llist llist0] )
	  (cond [(null? llist)
		 (values
		  (if rvar (##sys#append (reverse req) rvar) (reverse req))
		  (let ([body
			 (if (null? key)
			     body
			     `((,%let*
				,(map (lambda (k)
					(let ((s (car k)))
					  `(,s (##sys#get-keyword
						(##core#quote ,(->keyword (strip-syntax s))) ,(or hasrest rvar)
						,@(if (pair? (cdr k))
						      `((,%lambda () ,@(cdr k)))
						      '())))))
				      (reverse key) )
				,@body) ) ) ] )
		    (cond [(null? opt) body]
			  [(and (not hasrest) (null? key) (null? (cdr opt)))
			   `((,%let
			      ([,(caar opt) (,%opt ,rvar ,(cadar opt))])
			      ,@body) ) ]
			  [(and (not hasrest) (null? key))
			   `((,%let-optionals*
			      ,rvar ,(reverse opt) ,@body))]
			  [else
			   `((,%let-optionals*
			      ,rvar ,(##sys#append (reverse opt) (list (or hasrest rvar)))
			      ,@body))] ) ) ) ]
		[(symbol? llist)
		 (if (fx> mode 2)
		     (err "rest argument list specified more than once")
		     (begin
		       (unless rvar (set! rvar llist))
		       (set! hasrest llist)
		       (loop 4 req opt '() '()) ) ) ]
		[(not (pair? llist))
		 (err "invalid lambda list syntax") ]
		[else
		 (let* ((var (car llist))
			(x (or (and (symbol? var) (not (eq? 3 mode)) (lookup var se)) var))
			(r (cdr llist)))
		   (case x
		     [(#!optional)
		      (unless rvar (set! rvar (macro-alias 'rest se)))
		      (if (eq? mode 0)
			  (loop 1 req '() '() r)
			  (err "`#!optional' argument marker in wrong context") ) ]
		     [(#!rest)
		      (if (fx<= mode 1)
			  (if (and (pair? r) (symbol? (car r)))
			      (begin
				(if (not rvar) (set! rvar (car r)))
				(set! hasrest (car r))
				(loop 2 req opt '() (cdr r)) )
			      (err "invalid syntax of `#!rest' argument") )
			  (err "`#!rest' argument marker in wrong context") ) ]
		     [(#!key)
		      (if (not rvar) (set! rvar (macro-alias 'rest se)))
		      (if (fx<= mode 2)
			  (loop 3 req opt '() r)
			  (err "`#!key' argument marker in wrong context") ) ]
		     [else
		      (cond [(symbol? var)
			     (case mode
			       [(0) (loop 0 (cons var req) '() '() r)]
			       [(1) (loop 1 req (cons (list var #f) opt) '() r)]
			       [(2) (err "invalid lambda list syntax after `#!rest' marker")]
			       [else (loop 3 req opt (cons (list var) key) r)] ) ]
			    [(and (list? var) (eq? 2 (length var)) (symbol? (car var)))
			     (case mode
			       [(0) (err "invalid required argument syntax")]
			       [(1) (loop 1 req (cons var opt) '() r)]
			       [(2) (err "invalid lambda list syntax after `#!rest' marker")]
			       [else (loop 3 req opt (cons var key) r)] ) ]
			    [else (err "invalid lambda list syntax")] ) ] ) ) ] ) ) ) ) ) )


;;; Error message for redefinition of currently used defining form
;
; (i.e.`"(define define ...)")

(define (defjam-error form)
  (##sys#syntax-error
   "redefinition of currently used defining form" ; help me find something better
   form))

;;; Expansion of multiple values assignments.
;
; Given a lambda list and a multi-valued expression, returns a form that
; will `set!` each variable to its corresponding value in order.

(define (##sys#expand-multiple-values-assignment formals expr)
  (##sys#decompose-lambda-list
   formals
   (lambda (vars argc rest)
     (let ((aliases    (if (symbol? formals) '() (map gensym formals)))
	   (rest-alias (if (not rest) '() (gensym rest))))
       `(##sys#call-with-values
	 (##core#lambda () ,expr)
	 (##core#lambda
	  ,(append aliases rest-alias)
	  ,@(map (lambda (v a) `(##core#set! ,v ,a)) vars aliases)
	  ,@(cond
	      ((null? formals) '((##core#undefined)))
	      ((null? rest-alias) '())
	      (else `((##core#set! ,rest ,rest-alias))))))))))

;;; Expansion of bodies (and internal definitions)
;
; This code is disgustingly complex.

(define define-definition)
(define define-syntax-definition)
(define define-values-definition)
(define import-definition)

(define ##sys#canonicalize-body
  (lambda (body #!optional (se (##sys#current-environment)) cs?)
    (define (comp s id)
      (let ((f (or (lookup id se)
                   (lookup id (##sys#macro-environment)))))
        (and (or (not (symbol? f))
                 (not (eq? (##sys#get id '##sys#override) 'value)))
             (or (eq? f s) (eq? s id)))))
    (define (comp-def def)
      (lambda (id)
        (let repeat ((id id))
          (let ((f (or (lookup id se)
                       (lookup id (##sys#macro-environment)))))
            (and (or (not (symbol? f))
                     (not (eq? (##sys#get id '##sys#override) 'value)))
                 (or (eq? f def)
                     (and (symbol? f)
                          (not (eq? f id))
                          (repeat f))))))))
    (define comp-define (comp-def define-definition))
    (define comp-define-syntax (comp-def define-syntax-definition))
    (define comp-define-values (comp-def define-values-definition))
    (define comp-import (comp-def import-definition))
    ;; Definitions of names closed in the usage environment of a macro
    ;; used in this body (see sc-body-classes): un-rename the usage
    ;; aliases of the defined names before the body is built.  SC-BODY
    ;; identifies this body to the expansions made while its forms are
    ;; scanned (see sc-current-body).
    (define sc-body (vector #f))
    (define (sc-fini vars vals mvars body more-names k)
      (let* ((names (if (and (null? vars) (null? more-names))
			'()
			(foldl (lambda (names ll)
				 (##sys#append
				  (##sys#decompose-lambda-list ll (lambda (a _ _) a))
				  names))
			       more-names
			       vars)))
	     (classes (if (null? names)
			  '()
			  (sc-body-classes names se sc-body))))
	(if (null? classes)
	    (k vars vals mvars body)
	    (let ((se2 (sc-body-se names se)))
	      (k (sc-body-unrename vars classes sc-body)
		 (sc-body-unrename vals classes sc-body se2)
		 mvars
		 (sc-body-unrename body classes sc-body se2))))))
    (define (fini vars vals mvars body)
      (sc-fini vars vals mvars body '() fini0))
    (define (fini0 vars vals mvars body)
      (if (and (null? vars) (null? mvars))
	  ;; Macro-expand body, and restart when defines are found.
	  (let loop ((body body) (exps '()))
	    (if (not (pair? body))
		(cons
		 '##core#begin
		 (reverse exps)) ; no more defines, otherwise we would have called `expand'
		(let loop2 ((body body))
		  (let ((x (car body))
			(rest (cdr body)))
		    (if (and (pair? x)
			     (let ((d (car x)))
			       (and (symbol? d)
				    (or (comp '##core#begin d)
                                        (comp-define d)
					(comp-define-values d)
					(comp-define-syntax d)
					(comp-import d)))))
			;; Stupid hack to avoid expanding imports
			(if (comp-import (car x))
			    (loop rest (cons x exps))
			    (cons
			     '##core#begin
			     (##sys#append (reverse exps) (list (expand body)))))
			(let ((x2 (##sys#expand-0 x se cs?)))
			  (if (eq? x x2)
			      ;; Modules and includes must be processed before
			      ;; we can continue with other forms, so hand
			      ;; control back to the compiler
			      (if (and (pair? x)
				       (symbol? (car x))
				       (or (comp '##core#module (car x))
					   (comp '##core#include (car x))))
				  `(##core#begin
				    ,@(reverse exps)
				    ,@(if (comp '##core#module (car x))
					  (if (null? rest)
					      `(,x)
					      `(,x (##core#let () ,@rest)))
					  `((##core#include ,@(cdr x) ,rest))))
				  (loop rest (cons x exps)))
			      (loop2 (cons x2 rest)) )) ))) ))
	  ;; We saw defines.  Translate to letrec, and let compiler
	  ;; call us again for the remaining body by wrapping the
	  ;; remaining body forms in a ##core#let.
	  (let* ((result
		  `(##core#let
		    ,(##sys#map
		      (lambda (v) (##sys#list v '(##core#undefined)))
		      ;; vars are all normalised to lambda-lists: flatten them
		      (foldl (lambda (l v)
			       (##sys#append l (##sys#decompose-lambda-list
						v (lambda (a _ _) a))))
			     '()
			     (reverse vars))) ; not strictly necessary...
		    ,@(map (lambda (var val is-mvar?)
			     ;; Non-mvars should expand to set! for
			     ;; efficiency, but also because they must be
			     ;; implicit multi-value continuations.
			     (if is-mvar?
				 (##sys#expand-multiple-values-assignment var val)
				 `(##core#set! ,(car var) ,val)))
			   (reverse vars)
			   (reverse vals)
			   (reverse mvars))
		    ,@body) ) )
	    (dd `(BODY: ,result))
	    result)))
    (define (define-syntax-names body)
      (let loop ((body body) (names '()))
	(if (and (pair? body)
		 (list? (car body))
		 (>= 3 (length (car body)))
		 (symbol? (caar body))
		 (comp-define-syntax (caar body)))
	    (loop (cdr body)
		  (if (and (pair? (cdar body)) (symbol? (cadar body)))
		      (cons (cadar body) names)
		      names))
	    names)))
    (define (fini/syntax vars vals mvars body)
      (sc-fini vars vals mvars body (define-syntax-names body) fini/syntax0))
    (define (fini/syntax0 vars vals mvars body)
      (fini0
       vars vals mvars
       (let loop ((body body) (defs '()) (done #f))
	 (cond (done `((##core#letrec-syntax
			,(map cdr (reverse defs)) ,@body) ))
	       ((not (pair? body)) (loop body defs #t))
	       ((and (list? (car body))
		     (>= 3 (length (car body)))
		     (symbol? (caar body))
		     (comp-define-syntax (caar body)))
		(let ((def (car body)))
		  ;; This check is insufficient, if introduced by
		  ;; different expansions, but better than nothing:
		  (when (eq? (car def) (cadr def))
		    (defjam-error def))
		  (loop (cdr body) (cons def defs) #f)))
	       (else (loop body defs #t))))))
    ;; Expand a run of defines or define-syntaxes into letrec.  As
    ;; soon as we encounter something else, finish up.
    (define (expand body)
      ;; Each #t in "mvars" indicates an MV-capable "var".  Non-MV
      ;; vars (#f in mvars) are 1-element lambda-lists for simplicity.
      (let loop ((body body) (vars '()) (vals '()) (mvars '()))
        (d "BODY: " body)
	(if (not (pair? body))
	    (fini vars vals mvars body)
	    (let* ((x (car body))
		   (rest (cdr body))
		   (exp1 (and (pair? x) (car x)))
		   (head (and exp1 (symbol? exp1) exp1)))
	      (if (not (symbol? head))
		  (fini vars vals mvars body)
		  (cond
		   ((comp-define head)
		     (##sys#check-syntax 'define x '(_ _ . #(_ 0)) #f se)
		     (let loop2 ((x x))
		       (let ((head (cadr x)))
			 (cond ((not (pair? head))
				(##sys#check-syntax 'define x '(_ variable . #(_ 0)) #f se)
				(when (eq? (car x) head) ; see above
				  (defjam-error x))
				(loop rest (cons (list head) vars)
				      (cons (if (pair? (cddr x))
						(caddr x)
						'(##core#undefined) )
					    vals)
				      (cons #f mvars)))
			       ((pair? (car head))
				(##sys#check-syntax
				 'define x '(_ (_ . lambda-list) . #(_ 1)) #f se)
				(loop2
				 (chicken.syntax#expand-curried-define head (cddr x) se)))
			       (else
				(##sys#check-syntax
				 'define x
				 '(_ (variable . lambda-list) . #(_ 1)) #f se)
				(loop rest
				      (cons (list (car head)) vars)
				      (cons `(##core#lambda ,(cdr head) ,@(cddr x)) vals)
				      (cons #f mvars)))))))
		    ((comp-define-syntax head)
		     (##sys#check-syntax 'define-syntax x '(_ _ . #(_ 1)) se)
		     (fini/syntax vars vals mvars body))
		    ((comp-define-values head)
		     ;;XXX check for any of the variables being `define-values'
		     (##sys#check-syntax 'define-values x '(_ lambda-list _) #f se)
		     (loop rest (cons (cadr x) vars) (cons (caddr x) vals) (cons #t mvars)))
		    ((comp '##core#begin head)
		     (loop (##sys#append (cdr x) rest) vars vals mvars))
		    (else
		     ;; Do not macro-expand local definitions we are
		     ;; in the process of introducing.
		     (if (member (list head) vars)
			 (fini vars vals mvars body)
			 (let ((x2 (##sys#expand-0 x se cs?)))
			   (if (eq? x x2)
			       (fini vars vals mvars body)
			       (loop (cons x2 rest) vars vals mvars)))))))))))
    ;; Restored also when the expansion raises an exception: a
    ;; transformer may catch it and go on expanding the enclosing body.
    (let ((outer (sc-current-body)))
      (dynamic-wind
	  (lambda () (sc-current-body sc-body))
	  (lambda () (expand body))
	  (lambda () (sc-current-body outer)))) ) )


;;; A simple expression matcher

;; Used by "quasiquote", below
(define chicken.syntax#match-expression
  (lambda (exp pat vars)
    (let ((env '()))
      (define (mwalk x p)
	(cond ((not (pair? p))
	       (cond ((assq p env) => (lambda (a) (equal? x (cdr a))))
		     ((memq p vars)
		      (set! env (cons (cons p x) env))
		      #t)
		     (else (eq? x p)) ) )
	      ((pair? x)
	       (and (mwalk (car x) (car p))
		    (mwalk (cdr x) (cdr p)) ) )
	      (else #f) ) )
      (and (mwalk exp pat) env) ) ) )


;;; Expand "curried" lambda-list syntax for `define'

;; Used by "define", below
(define (chicken.syntax#expand-curried-define head body se)
  (let ((name #f))
    (define (loop head body)
      (if (symbol? (car head))
	  (begin
	    (set! name (car head))
	    `(##core#lambda ,(cdr head) ,@body) )
	  (loop (car head) `((##core#lambda ,(cdr head) ,@body)) ) ))
    (let ([exp (loop head body)])
      (list 'define name exp) ) ) )


;;; Line-number database management:

(define ##sys#line-number-database #f)


;;; General syntax checking routine:

(define ##sys#syntax-error-culprit #f)
(define ##sys#syntax-context '())

(define (##sys#syntax-error-hook . args)
  (apply ##sys#signal-hook #:syntax-error
	 (strip-syntax args)))

(define (##sys#syntax-error . args)
  (apply ##sys#syntax-error-hook args))

(define ##sys#syntax-error/context
  (lambda (msg arg)
    (define (syntax-imports sym)
      (let loop ((defs (or (##sys#get (strip-syntax sym) '##core#db) '())))
	(cond ((null? defs) '())
	      ((eq? 'syntax (caar defs))
	       (cons (cadar defs) (loop (cdr defs))))
	      (else (loop (cdr defs))))))
    (if (null? ##sys#syntax-context)
	(##sys#syntax-error-hook msg arg)
	(let ((out (open-output-string)))
	  (define (outstr str)
	    (##sys#print str #f out))
	  (let loop ((cx ##sys#syntax-context))
	    (cond ((null? cx)		; no unimported syntax found
		   (outstr msg)
		   (outstr ": ")
		   (##sys#print arg #t out)
		   (outstr "\ninside expression `(")
		   (##sys#print (strip-syntax (car ##sys#syntax-context)) #t out)
		   (outstr " ...)'"))
		  (else
		   (let* ((sym (strip-syntax (car cx)))
			  (us (syntax-imports sym)))
		     (cond ((pair? us)
			    (outstr msg)
			    (outstr ": ")
			    (##sys#print arg #t out)
			    (outstr "\n\n  Perhaps you intended to use the syntax `(")
			    (##sys#print sym #t out)
			    (outstr " ...)' without importing it first.\n")
			    (if (fx= 1 (length us))
				(outstr
				 (string-append
				  "  Suggesting: `(import "
				  (symbol->string (car us))
				  ")'"))
				(outstr
				 (string-append
				  "  Suggesting one of:\n"
				  (let loop ((lst us))
				    (if (null? lst)
					""
					(string-append
					 "\n      (import " (symbol->string (car lst)) ")'"
					 (loop (cdr lst)))))))))
			   (else (loop (cdr cx))))))))
	  (##sys#syntax-error-hook (get-output-string out))))))

;;; Hook for source information

;; The line-number database maps a source expression to its source
;; location.  It is a hash table keyed on a bounded structural hash of
;; the expression; candidates in a bucket are compared with `eq?', so a
;; weak hash can only cost time, never correctness.  Buckets are the very
;; same association lists (expression . line-info), most recent first,
;; that the head-symbol-keyed table used before, with the same guards.
;;
;;   db = #(count buckets names)
;;   names: symbol-keyed table, head symbol -> name of the most recent
;;          registration, used only by `##sys#get-line-2'.

(define-constant line-number-database-size 997) ; Copied from core.scm
(define-constant lndb-hash-budget 32)
(define-constant lndb-initial-size 1024)	; power of two

(define lndb-budget 0)

(define-inline (lndb-mix h v)
  (fxand (fx+ (fx* (fxand h #xfffff) 33) (fxand v #xfffff)) #x3ffffff))

(define (lndb-atom-key y)
  (cond ((symbol? y)
	 (let ((bv (##sys#slot y 1)))
	   (##core#inline "C_u_i_bytevector_hash" bv 0 (fx- (##sys#size bv) 1) 0)))
	((fixnum? y) (fx+ y 1013))
	((null? y) 7919)
	((eq? y #t) 104729)
	((eq? y #f) 15485863)
	((string? y) (fx+ 3571 (##sys#size y)))
	((char? y) (fx+ 2237 (char->integer y)))
	((vector? y) (fx+ 6151 (##sys#size y)))
	(else 32452843)))

(define (lndb-walk-hash x h)
  (cond ((fx<= lndb-budget 0) h)
	(else
	 (set! lndb-budget (fx- lndb-budget 1))
	 (if (pair? x)
	     (lndb-walk-hash (##sys#slot x 1)
			     (lndb-walk-hash (##sys#slot x 0) (lndb-mix h 5)))
	     (lndb-mix h (lndb-atom-key x))))))

;; Structural hash of X, looking at no more than `lndb-hash-budget'
;; sub-objects.  Terminates on circular structure because of the budget.
(define (##sys#lndb-hash x)
  (set! lndb-budget lndb-hash-budget)
  (lndb-walk-hash x 5381))

(define (##sys#make-line-number-database)
  (vector 0 (make-vector lndb-initial-size '())
	  (make-hash-table line-number-database-size)))

(define-inline (lndb-bucket db h)
  (let ((v (##sys#slot db 1)))
    (##sys#slot v (fxand h (fx- (##sys#size v) 1)))))

(define (lndb-grow! db)
  (let* ((old (##sys#slot db 1))
	 (n (##sys#size old))
	 (n2 (fx* n 4))
	 (mask (fx- n2 1))
	 (new (make-vector n2 '()))
	 (cnt 0))
    (do ((i 0 (fx+ i 1)))
	((fx>= i n))
      ;; reversed, so that the rebuilt bucket is most-recent-first again
      (let loop ((b (reverse (##sys#slot old i))))
	(unless (null? b)
	  (let ((a (##sys#slot b 0)))
	    (unless (##core#inline "C_bwpp" (##sys#slot a 0))
	      (let ((j (fxand (##sys#lndb-hash (##sys#slot a 0)) mask)))
		(##sys#setslot new j (cons a (##sys#slot new j)))
		(set! cnt (fx+ cnt 1)))))
	  (loop (##sys#slot b 1)))))
    (##sys#setslot db 1 new)
    (##sys#setslot db 0 cnt)))

(define (lndb-push! db h a)
  (let* ((v (##sys#slot db 1))
	 (i (fxand h (fx- (##sys#size v) 1)))
	 (cnt (fx+ (##sys#slot db 0) 1)))
    (##sys#setslot v i (cons a (##sys#slot v i)))
    (##sys#setslot db 0 cnt)
    (when (fx> cnt (fx* 2 (##sys#size v)))
      (lndb-grow! db))))

;; Register X under LN; NAME, when given, is recorded for `##sys#get-line-2'.
(define (##sys#lndb-set! db x ln name)
  (when name
    (hash-table-set! (##sys#slot db 2) (car x) name))
  (lndb-push! db (##sys#lndb-hash x) (cons x ln)))

(define-inline (lndb-weak-cons k v)
  (##core#inline_allocate ("C_a_i_weak_cons" 3) k v))

(define (assq/drop-bwp! x lst)
  (let lp ((lst lst)
	   (prev #f))
    (cond ((null? lst) #f)
	  ((eq? x (caar lst)) (car lst))
	  ((and prev
		(##core#inline "C_bwpp" (caar lst)))
	   (set-cdr! prev (cdr lst))
	   (lp (cdr lst) prev))
	  (else (lp (cdr lst) lst)))))

(define (read-with-source-info-hook class data val)
  (when (and (eq? 'list-info class) (symbol? (car data)))
    (lndb-push!
     ##sys#line-number-database (##sys#lndb-hash data)
     (lndb-weak-cons
      data (conc (or ##sys#current-source-filename "<stdin>") ":" val))))
  data)

(define (read-with-source-info #!optional (in ##sys#standard-input) fname)
  ;; Initialize line number db on first use
  (unless ##sys#line-number-database
    (set! ##sys#line-number-database (##sys#make-line-number-database)))
  (##sys#check-input-port in #t 'read-with-source-info)
  (fluid-let ((##sys#current-source-filename (or fname ##sys#current-source-filename)))
    (##sys#read in read-with-source-info-hook) ) )


(define (get-line-number sexp)
  (and ##sys#line-number-database
       (pair? sexp)
       (symbol? (##sys#slot sexp 0))
       (let ((a (assq/drop-bwp!
		 sexp
		 (lndb-bucket ##sys#line-number-database
			      (##sys#lndb-hash sexp)))))
	 (and a (cdr a)))))

;; TODO: Needs a better name - it extracts the name(?) and the source expression
(define (##sys#get-line-2 exp)
  (let* ((name (car exp))
	 (db ##sys#line-number-database)
	 (a (and db
		 (assq/drop-bwp! exp (lndb-bucket db (##sys#lndb-hash exp))))))
    (if a
	(values (or (hash-table-ref (##sys#slot db 2) name) name) (cdr a))
	(values name #f))))

(define (##sys#display-line-number-database)
  ;; Reconstruct the old head-symbol-keyed grouping for the "-debug n" dump;
  ;; the database itself is no longer grouped that way.
  (let* ((buckets (##sys#slot ##sys#line-number-database 1))
	 (nb (##sys#size buckets))
	 (ht (make-hash-table line-number-database-size)))
    (do ((i 0 (fx+ i 1)))
	((fx>= i nb))
      (let loop ((b (##sys#slot buckets i)))
	(unless (null? b)
	  (let* ((a (##sys#slot b 0))
		 (k (##sys#slot a 0)))
	    (unless (##core#inline "C_bwpp" k)
	      (let ((key (car k)))
		(hash-table-set!
		 ht key (cons a (or (hash-table-ref ht key) '()))))))
	  (loop (##sys#slot b 1)))))
    (hash-table-for-each
     (lambda (key val)
       (when val
	 (let ((port (current-output-port)))
	   (##sys#print key #t port)
	   (##sys#print " " #f port)
	   (##sys#print (map cdr val) #t port)
	   (##sys#print "\n" #f port))))
     ht)))

;;; Traverse expression and update line-number db with all contained calls:

(define (##sys#update-line-number-database! exp ln)
  (define (mapupdate xs)
    (let loop ((xs xs))
      (when (pair? xs)
        (walk (car xs))
        (loop (cdr xs)) ) ))
  (define (walk x)
    (cond ((not (pair? x)))
          ((symbol? (car x))
           (let ((h (##sys#lndb-hash x)))
             (unless (assq x (lndb-bucket ##sys#line-number-database h))
               (lndb-push! ##sys#line-number-database h (cons x ln))))
           (when (list? x) (mapupdate (cdr x)) ))
          (else (mapupdate x)) ) )
  (walk exp))


(define-constant +default-argument-count-limit+ 99999)

(define ##sys#check-syntax
  (lambda (id exp pat #!optional culprit (se (##sys#current-environment)))

    (define (test x pred msg)
      (unless (pred x) (err msg)) )

    (define (err msg)
      (let* ([sexp ##sys#syntax-error-culprit]
	     [ln (get-line-number sexp)] )
	(##sys#syntax-error
	 (if ln
	     (string-append "(" ln ") in `" (symbol->string id) "' - " msg)
	     (string-append "in `" (symbol->string id) "' - " msg) )
	 exp) ) )

    (define (lambda-list? x)
      (or (##sys#extended-lambda-list? x)
	  (let loop ((x x))
	    (cond ((null? x))
		  ((symbol? x))
		  ((pair? x)
		   (let ((s (car x)))
		     (and (symbol? s)
			  (loop (cdr x)) ) ) )
		  (else #f) ) ) ) )

    (define (variable? v)
      (symbol? v))

    (define (proper-list? x)
      (let loop ((x x))
	(cond ((eq? x '()))
	      ((pair? x) (loop (cdr x)))
	      (else #f) ) ) )

    (when culprit (set! ##sys#syntax-error-culprit culprit))
    (let walk ((x exp) (p pat))
      (cond ((vector? p)
	     (let* ((p2 (vector-ref p 0))
		    (vlen (##sys#size p))
		    (min (if (fx> vlen 1)
			     (vector-ref p 1)
			     0) )
		    (max (cond ((eq? vlen 1) 1)
			       ((fx> vlen 2) (vector-ref p 2))
			       (else +default-argument-count-limit+) ) ) )
	       (do ((x x (cdr x))
		    (n 0 (fx+ n 1)) )
		   ((eq? x '())
		    (if (fx< n min)
			(err "not enough arguments") ) )
		 (cond ((fx>= n max)
			(err "too many arguments") )
		       ((not (pair? x))
			(err "not a proper list") )
		       (else (walk (car x) p2) ) ) ) ) )
	    ((##sys#immediate? p)
	     (if (not (eq? p x)) (err "unexpected object")) )
	    ((symbol? p)
	     (case p
	       ((_) #t)
	       ((pair) (test x pair? "pair expected"))
	       ((variable) (test x variable? "identifier expected"))
	       ((symbol) (test x symbol? "symbol expected"))
	       ((list) (test x proper-list? "proper list expected"))
	       ((number) (test x number? "number expected"))
	       ((string) (test x string? "string expected"))
	       ((lambda-list) (test x lambda-list? "lambda-list expected"))
	       (else
		(test
		 x
		 (lambda (y)
		   (let ((y2 (and (symbol? y) (lookup y se))))
		     (eq? (if (symbol? y2) y2 y) p)))
		 "missing keyword")) ) )
	    ((not (pair? p))
	     (err "incomplete form") )
	    ((not (pair? x)) (err "pair expected"))
	    (else
	     (walk (car x) (car p))
	     (walk (cdr x) (cdr p)) ) ) ) ) )


;;; explicit/implicit-renaming transformer

;; Give the copy NEW of the pair OLD the line number of OLD, if any.
(define (inherit-pair-line-numbers old new)
  (and-let* ((name (car new))
	     ((symbol? name))
	     (ln (get-line-number old)))
    (let ((h (##sys#lndb-hash new)))
      (unless (assq new (lndb-bucket ##sys#line-number-database h))
	(lndb-push! ##sys#line-number-database h
		    (lndb-weak-cons new ln)))))
  new)

;; Do D1 and D2, what two identifiers resolve to, denote the same
;; thing?  Two symbols (free or global names, or lexical gensyms) must
;; be the same; a global name equals a macro if it names that macro in
;; the global macro environment.  Used by er's `compare' and by
;; identifier=?.
(define (same-denotation? d1 d2)
  (cond ((symbol? d1)
	 (cond ((symbol? d2) (eq? d1 d2))
	       ((assq d1 (##sys#macro-environment)) =>
		(lambda (a) (eq? (cdr a) d2)))
	       (else #f)))
	((symbol? d2)
	 (cond ((assq d2 (##sys#macro-environment)) =>
		(lambda (a) (eq? d1 (cdr a))))
	       (else #f)))
	(else (eq? d1 d2))))

(define (make-er/ir-transformer handler explicit-renaming?)
  (##sys#make-structure
   'transformer
   (lambda (form se dse)
     (let ((renv '()))	  ; keep rename-environment for this expansion
       (define (rename sym)
	 (cond ((pair? sym)
		(inherit-pair-line-numbers sym (cons (rename (car sym)) (rename (cdr sym)))))
	       ((vector? sym)
		(list->vector (rename (vector->list sym))))
	       ((not (symbol? sym)) sym)
	       ((assq sym renv) =>
		(lambda (a)
		  (dd `(RENAME/RENV: ,sym --> ,(cdr a)))
		  (cdr a)))
	       (else
		(let ((a (macro-alias sym se)))
		  (dd `(RENAME: ,sym --> ,a))
		  (set! renv (cons (cons sym a) renv))
		  a))))
       (define (compare s1 s2)
	 (let ((result
		(cond ((pair? s1)
		       (and (pair? s2)
			    (compare (car s1) (car s2))
			    (compare (cdr s1) (cdr s2))))
		      ((vector? s1)
		       (and (vector? s2)
			    (let ((len (vector-length s1)))
			      (and (fx= len (vector-length s2))
				   (do ((i 0 (fx+ i 1))
					(f #t (compare (vector-ref s1 i) (vector-ref s2 i))))
				       ((or (fx>= i len) (not f)) f))))))
		      ((and (symbol? s1)
			    (symbol? s2))
		       (let ((ss1 (or (getp s1 '##core#macro-alias)
				      (lookup2 1 s1 dse)
				      s1) )
			     (ss2 (or (getp s2 '##core#macro-alias)
				      (lookup2 2 s2 dse)
				      s2) ) )
			 (same-denotation? ss1 ss2)))
		      (else (eq? s1 s2))) ) )
	   (dd `(COMPARE: ,s1 ,s2 --> ,result))
	   result))
       (define (lookup2 n sym dse)
	 (let ((r (lookup sym dse)))
	   (dd "  (lookup/DSE " (list n) ": " sym " --> "
	       (if (and r (pair? r))
		   '<macro>
		   r)
	       ")")
	   r))
       (define (assq-reverse s l)
	 (cond
	  ((null? l) #f)
	  ((eq? (cdar l) s) (car l))
	  (else (assq-reverse s (cdr l)))))
       (define (mirror-rename sym)
	 (cond ((pair? sym)
		(inherit-pair-line-numbers
		 sym (cons (mirror-rename (car sym)) (mirror-rename (cdr sym)))))
	       ((vector? sym)
		(list->vector (mirror-rename (vector->list sym))))
	       ((not (symbol? sym)) sym)
	       (else		 ; Code stolen from strip-syntax
		(let ((renamed (lookup sym se) ) )
		  (cond ((assq-reverse sym renv) =>
			 (lambda (a)
			   (dd "REVERSING RENAME: " sym " --> " (car a)) (car a)))
			((not renamed)
			 (dd "IMPLICITLY RENAMED: " sym) (rename sym))
			((pair? renamed)
			 (dd "MACRO: " sym) (rename sym))
			((getp sym '##core#real-name) =>
			 (lambda (name)
			   (dd "STRIP SYNTAX ON " sym " ---> " name)
			   name))
                        ;; Rename builtin aliases so strip-syntax can still
                        ;; access symbols as entered by the user
			(else (let ((implicitly-renamed (rename sym)))
                                (dd "BUILTIN ALIAS: " sym " as " renamed
                                    " --> " implicitly-renamed)
                                implicitly-renamed)))))))
       (assert (list? se) "not a list" se) ;XXX remove later
       (if explicit-renaming?
	   ;; Let the user handle renaming
	   (handler form rename compare)
	   ;; Implicit renaming:
	   ;; Rename everything in the input first, feed it to the transformer
	   ;; and then swap out all renamed identifiers by their non-renamed
	   ;; versions, and vice versa.  User can decide when to inject code
	   ;; unhygienically this way.
	   (mirror-rename (handler (rename form) rename compare)) ) ) )))

(define (er-macro-transformer handler) (make-er/ir-transformer handler #t))
(define (ir-macro-transformer handler) (make-er/ir-transformer handler #f))

(define ##sys#er-transformer er-macro-transformer)
(define ##sys#ir-transformer ir-macro-transformer)


;;; Syntactic closures (Bawden & Rees, "Syntactic Closures", LFP 1988)
;
; A syntactic closure (make-syntactic-closure ENV FREE FORM) is FORM
; together with the syntactic environment ENV in which it is to be
; interpreted; the names in FREE are left to be interpreted where the
; closure is placed.  An "expander" (here: the procedure given to
; sc-macro-transformer, rsc-macro-transformer or
; expander-macro-transformer) builds its output from closures of the
; input closed in the usage environment and of its own text closed in
; the macro environment (or in an advertised environment such as
; scheme-syntactic-environment, sec. 4.2 of the paper), so that, as the
; paper puts it, a syntactic closure carries its own context with it.
;
; Syntactic closures are layered on top of the renaming expander.
; When an sc/rsc transformer returns, its result is "lowered": every
; identifier is replaced by a symbol that the renaming expander will
; interpret with the intended meaning, and every syntactic closure by
; its lowered form.  Lowered output is ordinary renamed output, so sc
; and rsc macros mix freely with er, ir and syntax-rules macros.
;
; As in the paper's appendix, every closure object is a separate
; identifier context: a symbol occurring in the form of closure C (and
; not in C's free names) is lowered to a fresh alias, made once per
; closure and symbol, that denotes what the symbol means in C's
; environment.  So nothing the surrounding output binds can capture
; it, and two closures of the same symbol are different identifiers.
; Free names are lowered by the context in which the closure is
; placed (the paper's filter-syntactic-env).  Raw symbols in the
; transformer's result form one more context (the macro environment
; for sc, the usage environment for rsc).
;
; An alias made for a name of the usage environment is turned back
; into the name itself (it is "un-renamed") when no other identifier
; made by the same expansion for that name occurs in the output: the
; two then denote the same binding.  So in the common case the user's
; names stay as they were written (which keeps definitions, nested
; non-hygienic macros and `eq?'-ness working).  A name is not
; un-renamed if another alias in the output refers to the toplevel
; variable of that name, since CHICKEN resolves such an alias by its
; name.  To know which aliases occur, the output is walked twice: the
; first walk builds nothing, the second one builds the lowered output
; with the un-renamed names.  The usage aliases that are left, of
; expansions made while ##sys#canonicalize-body scans a body, are
; un-renamed by it when the body defines the name they denote (see
; sc-body-unrename); the paper leaves definitions unspecified (its
; sec. 6), this keeps (define ,(close-syntax name env) ...) and
; (set! ,(close-syntax name env) ...) in a body referring to one
; variable.
;
; In the paper, a macro called inside a closure has the closure's
; environment as its usage environment.  Here the closure has been
; lowered before the macro runs, so every form made by lowering
; remembers the context that lowered it (sc-form-context; only forms
; that may be calls of sc macros are recorded, and forms that other
; macros build from them inherit it, see sc-propagate-context!), and
; the names a macro writes in its usage environment, in particular the
; free names of its closures, are taken in that context (see
; sc-usage-base and sc-lower-closure).  A name that came from a
; closure nested in the macro form, and was un-renamed, is not free
; text of that form, so free names do not capture it (sc-protected?).
;
; capture-syntactic-environment is MIT Scheme's extension, not in the
; paper.  As in MIT, a capture that is a whole transformer result (or
; a whole closure form) gets the environment of that level, and a
; capture placed inside the output gets the environment at that place,
; so its closures see the bindings made by the output around it.  The
; capture procedure is called once, when the output is lowered, so
; identifier=? in that environment does not see those bindings.  The
; closures made in it are lowered to "twins" that binders in the
; capture's own result cannot capture (see sc-twin).
;
; Section 4 of the paper (advertised environments, extending
; environments, macrologies, expanders) is at the end:
; expander-macro-transformer, scheme-syntactic-environment,
; core-syntactic-environment, extend-syntactic-environment and
; scheme-macrology.
;
; The objects are
;
;   #<syntactic-environment KIND A B C EXP>
;	usage	A = usage environment (dse), B = #(ALIASES CHOSEN), the
;		usage aliases made for this environment and a table of
;		the ones that were un-renamed, C = #f or the "K-info"
;		#(K K-IDS K-UENV SYMBOLS FORM EXTRA): the macro form
;		FORM was made by the context K of an earlier expansion,
;		maybe through non-sc macros that put the symbols EXTRA
;		around it (see sc-form-context)
;	macro	A = macro environment (se)
;	scheme	scheme-syntactic-environment (paper sec. 4.2)
;	core	core-syntactic-environment (paper appendix)
;	extend	A = outer environment, B = keyword, C = macro binding
;		(extend-syntactic-environment, paper sec. 4.1)
;	derived	A = environment, B = free names, C = placement context;
;		what a capture gets at the top of a closure with free
;		names
;	here	A = placement context, B = environment of the level;
;		what a capture placed inside the output gets
;     EXP is the expansion record of the expansion the environment
;     belongs to, or #f for the advertised environments.
;   #<syntactic-closure ENV FREE FORM IDS SE>
;	IDS	#(TABLE PLACED USAGE): TABLE maps symbols to the
;		closure's own identifiers, PLACED is the IDS of the
;		context in which the closure was last placed, USAGE
;		#f or the usage aliases by base (see sc-usage-alias)
;	SE	the macro environment of the expansion that made the
;		closure (used by scheme/core environments, see below)
;   #<syntactic-capture PROC>	   result of capture-syntactic-environment
;
; A "context" is a procedure mapping an identifier (a symbol or a
; syntactic closure) to its lowered form; it has an IDS record that
; identifies it (the raw output of an expansion has one too).  The
; records kept beyond an expansion (contexts, environments) never
; refer to the forms they lowered, so that the weak table of
; sc-form-context does not keep them alive.
;
; Environments can be used to make closures only while the expansion
; they belong to runs, or later within its scope (see
; sc-environment-live?); closures made then may be placed in the
; output of later expansions (the paper's expanders keep closures in
; the expanders they put in environments, see its `contorted').
;
; The exported procedures are thin wrappers, so that a user redefining
; e.g. `identifier?' at toplevel does not break the expander; the
; expander, extend-syntactic-environment and scheme-macrology only call
; the internal sc-* procedures.

(define (sc-closure? x) (##sys#structure? x 'syntactic-closure))
(define (sc-environment? x) (##sys#structure? x 'syntactic-environment))
(define (sc-capture? x) (##sys#structure? x 'syntactic-capture))

(define (sc-identifier? x)
  (cond ((symbol? x))
	((sc-closure? x) (sc-identifier? (##sys#slot x 3)))
	(else #f)))

;;; Tables of identifiers
;
; The output of a macro can have very many distinct symbols, so an
; association list becomes a hash table once it has `sc-table-limit'
; entries.  Keys are symbols; #f is never stored.

(define-constant sc-table-limit 32)

(define (sc-make-table) (vector 0 '() #f))

(define (sc-table-ref t key)
  (let ((ht (##sys#slot t 2)))
    (if ht
	(hash-table-ref ht key)
	(let ((a (assq key (##sys#slot t 1))))
	  (and a (cdr a))))))

;; KEY must not be in T yet.
;; Call (PROC KEY VAL) for each entry of T.
(define (sc-table-for-each proc t)
  (let ((ht (##sys#slot t 2)))
    (if ht
	(hash-table-for-each proc ht)
	(for-each (lambda (a) (proc (car a) (cdr a))) (##sys#slot t 1)))))

(define (sc-table-set! t key val)
  (let ((ht (##sys#slot t 2))
	(n (##sys#slot t 0)))
    (cond (ht (hash-table-set! ht key val))
	  ((fx< n sc-table-limit)
	   (##sys#setslot t 0 (fx+ n 1))
	   (##sys#setslot t 1 (cons (cons key val) (##sys#slot t 1))))
	  (else
	   (let ((ht (make-hash-table 1021)))
	     (for-each (lambda (a) (hash-table-set! ht (car a) (cdr a)))
		       (##sys#slot t 1))
	     (hash-table-set! ht key val)
	     (##sys#setslot t 1 '())
	     (##sys#setslot t 2 ht))))))

;;; Expansions and environments

;; The expansion running now, or #f.  An expansion record is
;; #(SE DSE UENV PASS CAPTURES LIVE? SYNTAX-NAMES HEADS GLOBALS TWINS
;; BODY).
;; PASS is 0 while the handler runs, 1 while the output is walked the
;; first time (to find out which usage aliases occur, building nothing)
;; and 2 while it is lowered; CAPTURES holds the results of capture
;; procedures, so that they are called only once; SYNTAX-NAMES and
;; HEADS serve sc-note-context!, GLOBALS sc-choose-unrenamed, TWINS
;; lists the twins made (see sc-twin), BODY is the body that was being
;; scanned when the expansion ran (see sc-current-body).  A
;; parameter, so that each thread has its own (as for
;; ##sys#current-environment).
(define sc-expansion (make-parameter #f))

;; The body whose forms ##sys#canonicalize-body is scanning for
;; definitions, or #f: a record #(LEFT), where LEFT is #f or a table of
;; the names of which expansions made during the scan left usage
;; aliases in their output (see sc-usage-alias-left! and
;; sc-body-classes).  Only the usage aliases of those expansions can
;; be un-renamed by a definition of the body: a closure made in an
;; environment outside the body, e.g. by a macro whose output contains
;; the body, keeps the meaning it has there.
(define sc-current-body (make-parameter #f))

(define (sc-current-se)
  (let ((exp (sc-expansion)))
    (if exp (vector-ref exp 0) (##sys#current-environment))))

(define (sc-current-dse)
  (let ((exp (sc-expansion)))
    (if exp (vector-ref exp 1) (##sys#current-environment))))

(define (sc-make-environment kind a b c exp)
  (##sys#make-structure 'syntactic-environment kind a b c exp))

;; An environment can be used while its expansion runs, and later in
;; the expansion of code within its scope (e.g. by an expander bound
;; with extend-syntactic-environment, as the paper's with-macro does):
;; then the CHICKEN syntactic environment it stands for is part of the
;; one in effect.  The environment a capture gets (see sc-lower) stands
;; for bindings in the output around the capture, which that test
;; cannot see, so it can only be used while its expansion runs.
(define (sc-environment-live? env)
  (let ((exp (##sys#slot env 5)))
    (or (not exp)
	(vector-ref exp 5)
	(let ((cur-exp (sc-expansion)))
	  (and cur-exp
	       (not (sc-captured-environment? env))
	       (let ((e (sc-environment-se env)))
		 (let loop ((cur (vector-ref cur-exp 1)))
		   (or (eq? cur e)
		       (and (pair? cur) (loop (cdr cur)))))))))))

;; Is ENV, or the one it extends, an environment of a capture placed
;; inside the output or at the top of a closure with free names?
(define (sc-captured-environment? env)
  (case (##sys#slot env 1)
    ((here derived) #t)
    ((extend) (sc-captured-environment? (##sys#slot env 2)))
    (else #f)))

;; With LIVE, ENV must be usable now (see sc-environment-live?).
(define (sc-check-environment env loc #!optional live)
  (unless (sc-environment? env)
    (##sys#signal-hook
     #:type-error loc "bad argument type - not a syntactic environment" env))
  (when (and live (not (sc-environment-live? env)))
    (##sys#error
     loc "syntactic environment used outside of the expansion that created it"
     env)))

(define (sc-make-ids) (vector (sc-make-table) #f #f))

(define (sc-make-closure env free form loc)
  (sc-check-environment env loc #t)
  (unless (and (list? free) (every sc-identifier? free))
    (##sys#signal-hook
     #:type-error loc "bad argument type - not a list of identifiers" free))
  (if (or (and (memq form free)
	       ;; F closed with F free is F, unless it came from a
	       ;; closure nested in the macro form (see sc-protected?)
	       (not (and (symbol? form)
			 (eq? 'usage (##sys#slot env 1))
			 (##sys#slot env 4)
			 (sc-protected? form (##sys#slot env 4)))))
	  (not (or (symbol? form) (pair? form) (vector? form)
		   (sc-closure? form) (sc-capture? form))))
      form
      (##sys#make-structure 'syntactic-closure env free form (sc-make-ids)
			    (sc-current-se))))

;;; Fresh identifiers

(define (sc-alias sym meaning)
  (let ((a (gensym sym)))
    (putp a '##core#macro-alias meaning)
    (putp a '##core#real-name (or (getp sym '##core#real-name) sym))
    a))

;; The symbols occurring in the macro form of a K-info, as a table,
;; and those around it in the output of the non-sc macros that built it
;; (EXTRA, see sc-propagate-context!).  The form is dropped once they
;; are known (see make-sc-transformer).  Quoted data too large to look
;; through, e.g. circular, is skipped (as sc-lower strips it).
(define (sc-kinfo-symbols ki)
  (or (vector-ref ki 3)
      (let ((t (sc-make-table)))
	(when (vector-ref ki 5)
	  (sc-table-for-each (lambda (s _) (sc-table-set! t s #t))
			     (vector-ref ki 5))
	  (vector-set! ki 5 #f))
	(let walk ((x (vector-ref ki 4)))
	  (cond ((symbol? x)
		 (unless (sc-table-ref t x) (sc-table-set! t x #t)))
		((and (sc-quote-form? x) (sc-big-datum? (cdr x))))
		((pair? x) (walk (car x)) (walk (cdr x)))
		((vector? x) (for-each walk (vector->list x)))))
	(vector-set! ki 3 t)
	(vector-set! ki 4 #f)
	t)))

;; How SYM, a name the macro writes in its usage environment UENV, is
;; written in the code that calls the macro.  If the macro form was
;; made by lowering, in context K, the code of an enclosing closure or
;; expansion, then (as in the paper, where the usage environment of a
;; macro called in a closure is the closure's environment) SYM is the
;; identifier K has for it.  But a symbol that occurs as it is in the
;; macro form is taken to be that occurrence: it came from user code
;; that a different context has lowered already.
(define (sc-usage-base uenv sym)
  (or (sc-k-identifier uenv sym #f) sym))

;; The identifier, as it occurs in the output, that the context K of
;; the macro form of usage environment UENV has for SYM, called as (K
;; SYM PEEK); #f if the form has no context, SYM occurs in the form as
;; it is, or K has no identifier for it.
(define (sc-k-identifier uenv sym peek)
  (let ((ki (##sys#slot uenv 4)))
    (and ki
	 (not (sc-table-ref (sc-kinfo-symbols ki) sym))
	 (let ((id ((vector-ref ki 0) sym peek)))
	   (and (symbol? id) (sc-output-identifier id))))))

;; ID as it occurs in the output: a usage alias that was un-renamed is
;; its base name there, a twin what it stands for (see sc-twin).
(define (sc-output-identifier id0)
  (let* ((id (let loop ((id id0))
	       (let ((tw (getp id '##core#sc-twin)))
		 (if tw (loop (car tw)) id))))
	 (info (getp id '##core#sc-usage)))
    (if (and info (vector-ref info 4))
	(vector-ref info 0)
	id)))

;; Note that a usage alias of BASE for the usage environment UENV stays
;; in some output, so that the body that was being scanned when UENV
;; was made looks for it if it defines BASE (see sc-body-classes).
(define (sc-usage-alias-left! base uenv)
  (let ((b (sc-usage-environment-body uenv)))
    (when b
      (let ((t (or (vector-ref b 0)
		   (let ((t (sc-make-table)))
		     (vector-set! b 0 t)
		     t))))
	(unless (sc-table-ref t base) (sc-table-set! t base #t))))))

;; The body (see sc-current-body) that was being scanned when the usage
;; environment UENV was made, or #f.
(define (sc-usage-environment-body uenv)
  (let ((exp (##sys#slot uenv 5)))
    (and exp (vector-ref exp 10))))

;; A fresh alias for SYM as a name of the usage environment UENV, made
;; by the context identified by OWNER.  Its property ##core#sc-usage
;; is #(BASE UENV RAW? SEEN? UNRENAME? OWNER), where BASE is what the
;; alias is un-renamed to.
;;
;; A context has one alias per base, not per symbol: the `x' the macro
;; writes and the `x1' that the context K of the macro form (see
;; sc-usage-base) made of `x' in the user's code are one name in the
;; usage environment, so a binder of one captures the other.  OWNER's
;; IDS record keeps them in its third slot, a table from base to alias
;; (an owner only ever makes aliases for one usage environment: that of
;; its expansion, or the one at the bottom of its closure's environment).
(define (sc-usage-alias sym uenv raw? owner)
  (let* ((base (sc-usage-base uenv sym))
	 (memo (and owner
		    (or (vector-ref owner 2)
			(let ((t (sc-make-table)))
			  (vector-set! owner 2 t)
			  t)))))
    (or (and memo (sc-table-ref memo base))
	(let ((a (macro-alias base (##sys#slot uenv 2))))
	  (unless (eq? a base)		; keyword or namespaced symbol
	    (let ((box (##sys#slot uenv 3)))
	      (putp a '##core#sc-usage (vector base uenv raw? #f #f owner))
	      (vector-set! box 0 (cons a (vector-ref box 0)))
	      (unless (let ((exp (sc-expansion)))
			(and exp (eq? uenv (vector-ref exp 2))))
		;; made for an expansion that has returned: never un-renamed
		(sc-usage-alias-left! base uenv))))
	  (when memo (sc-table-set! memo base a))
	  a))))

;; The values and keywords of the `scheme' module.
(define sc-scheme-values #f)

(define (sc-scheme-value sym)
  (unless sc-scheme-values
    (set! sc-scheme-values
      (let ((m (##sys#find-module (##sys#resolve-module-name 'scheme #f) #f)))
	(if m
	    (call-with-values (lambda () (##sys#module-exports m))
	      (lambda (el vexps sexps) vexps))
	    '()))))
  (cond ((assq sym sc-scheme-values) => cdr)
	(else #f)))

(define (sc-scheme-keyword sym)
  (cond ((assq sym ##sys#scheme-macro-environment) => cdr)
	(else #f)))

(define sc-core-keywords '(quote if begin set! lambda))

;; The binding of a keyword that core-syntactic-environment lacks.
(define sc-core-missing-keyword
  (list '()
	(lambda (form se dse)
	  (##sys#syntax-error
	   "keyword is not defined in `core-syntactic-environment'"
	   (strip-syntax (car form))))))

;; SYM in scheme-syntactic-environment (CORE? = #f) or
;; core-syntactic-environment.  Names of the `scheme' module have their
;; standard meaning: keywords are aliases of the standard bindings and
;; variables are absolute names (e.g. scheme#cons), so no local or
;; module binding of the name can change them.  Other names mean what
;; they mean in SE, the macro environment of the expansion that made
;; the closure (for a toplevel macro, the toplevel).
(define (sc-scheme-fresh sym se core?)
  (cond ((or (keyword? sym) (namespaced-symbol? sym)) sym)
	((and (or (not core?) (memq sym sc-core-keywords))
	      (sc-scheme-keyword sym))
	 => (lambda (b) (sc-alias sym b)))
	((sc-scheme-value sym))
	((and core?
	      (pair? (or (lookup sym se) (lookup sym (##sys#macro-environment)))))
	 (sc-alias sym sc-core-missing-keyword))
	(else (macro-alias sym se))))

;; A fresh identifier for SYM as a name of ENV, made by the context
;; identified by OWNER.  SE is the macro environment recorded in the
;; closure being lowered.
(define (sc-fresh env sym se owner)
  (let ((a (##sys#slot env 2)))
    (case (##sys#slot env 1)
      ((usage) (sc-usage-alias sym env #f owner))
      ((macro) (macro-alias sym a))
      ((scheme) (sc-scheme-fresh sym se #f))
      ((core) (sc-scheme-fresh sym se #t))
      ((here) (sc-twin (a sym) env))
      ((extend)
       (if (sc-extend-keyword? env sym)
	   (sc-alias sym (##sys#slot env 4))
	   (sc-fresh a sym se owner)))
      ((derived)
       (if (memq sym (##sys#slot env 3))
	   (sc-twin ((##sys#slot env 4) sym) env)
	   (sc-fresh a sym se owner)))
      (else (##sys#error 'sc-fresh "bad syntactic environment" env)))))

;; How SYM, a name of the usage environment at the bottom of ENV, is
;; written in the text of a closure in ENV, if not as SYM itself: when
;; the macro form was made by lowering, in context K, the code of an
;; enclosing closure or expansion, SYM was lowered by K (see
;; sc-usage-base), and the result may have passed through further
;; closures unchanged.  Contexts answer this as (CTX SYMBOL 'chain): the
;; identifier they have for SYMBOL, or the one they have for the symbol
;; that stands for SYMBOL in their text.  So the free name `it' of a
;; closure in an inner (aif ...) matches the `it1' that the free names
;; of the outer aif made of `it', even when an identity macro or `or'
;; between the two has closed the inner form in its usage environment.
;; Returns #f if SYM is written as it is, or if nothing stands for it.
(define (sc-text-identifier env sym)
  (case (##sys#slot env 1)
    ((usage)
     (let ((x (sc-k-identifier env sym 'chain)))
       (and x (not (eq? x sym)) x)))
    ;; an extension changes what names mean, not how they are written
    ((extend) (sc-text-identifier (##sys#slot env 2) sym))
    (else #f)))

;; Does SYM, a symbol in the text of a closure in the extended
;; environment ENV, stand for its keyword?  It does if it is the
;; keyword, or the identifier that stands for the keyword in that text
;; (see sc-text-identifier): in (with-k a (with-k b (k))), where both
;; with-k extend their usage environment with `k', the outer closure
;; has already lowered the inner `k' when the inner with-k runs.
(define (sc-extend-keyword? env sym)
  (let ((kw (##sys#slot env 3)))
    (or (eq? sym kw)
	(let ((x (sc-text-identifier (##sys#slot env 2) kw)))
	  (and x (eq? sym x))))))

;; The CHICKEN syntactic environment in which raw output of an
;; expander bound by extend-syntactic-environment is interpreted.
(define (sc-environment-se env)
  (case (##sys#slot env 1)
    ((usage macro) (##sys#slot env 2))
    ((extend derived) (sc-environment-se (##sys#slot env 2)))
    ((here) (sc-environment-se (##sys#slot env 3)))
    (else (sc-current-se))))

;;; Twins
;
; A closure in the environment that a capture placed inside the output
; receives (a `here' environment), or of a free name in the one a
; capture receives at the top of a closure with free names (a
; `derived' environment), denotes what the identifier ID of the
; placement context denotes at the capture place.  It is lowered to a
; "twin" of ID, a fresh alias that the expansion replaces by ID at the
; end (sc-untwin).  Before that, the binders of ID in the capture's
; result whose scope holds a twin of ID are renamed apart, with the
; references in their scope (sc-rename-apart), so that they do not
; capture the twin: in MIT's loop-until, `(lambda (,id) ... (,loop
; ...))' does not capture the closure of `loop' when the user's ID is
; `loop'.  Binding forms are recognized by their keyword, if it
; denotes the standard lambda, let (also named let), let*, letrec,
; letrec*, do or (in the bodies of these) define; binders made by
; other macros in the capture's result can still capture a twin.

;; A twin of ID for a closure in ENV.
(define (sc-twin id env)
  (let ((h (if (symbol? id) (macro-alias id '()) id)))
    (if (eq? h id)			; keyword or namespaced symbol
	id
	(let ((exp (sc-expansion)))
	  (putp h '##core#sc-twin (cons id env))
	  (when exp (vector-set! exp 9 (cons h (vector-ref exp 9))))
	  h))))

;; What S stands for in the output: S itself if it is no twin.
(define (sc-twin-target s)
  (let ((tw (getp s '##core#sc-twin)))
    (if tw (sc-twin-target (sc-emit (car tw))) s)))

;; A copy of pair OLD with car A and cdr D that keeps OLD's line number
;; and context (see sc-form-context), or OLD if A and D are its own.
(define (sc-copy-pair old a d)
  (if (and (eq? a (car old)) (eq? d (cdr old)))
      old
      (let ((new (inherit-pair-line-numbers old (cons a d)))
	    (k (sc-form-context old)))
	(when (and k (symbol? a)) (sc-register-context! new k #t))
	new)))

;; X with every symbol S in it replaced by (F S).
;; Quoted data too large to look through, e.g. circular, is left as it
;; is.
(define (sc-subst-symbols x f)
  (let walk ((x x))
    (cond ((symbol? x) (f x))
	  ((and (sc-quote-form? x) (sc-big-datum? (cdr x))) x)
	  ((pair? x) (sc-copy-pair x (walk (car x)) (walk (cdr x))))
	  ((vector? x)
	   (let* ((l (vector->list x))
		  (l2 (walk l)))
	     (if (eq? l l2) x (list->vector l2))))
	  (else x))))

;; X, the lowered output of the expansion, with its twins replaced.
(define (sc-untwin x)
  (if (null? (vector-ref (sc-expansion) 9))
      x
      (sc-subst-symbols x sc-twin-target)))

(define sc-binding-keywords '(lambda let let* letrec letrec* do define))

;; The standard binding keyword (one of sc-binding-keywords) that ID
;; denotes in DSE, or #f.
(define (sc-binding-keyword id dse)
  (case id
    ((##core#lambda) 'lambda)
    ((##core#let) 'let)
    ((##core#letrec ##core#letrec*) 'letrec)
    (else (sc-standard-keyword id dse sc-binding-keywords))))

;; The one among KEYWORDS whose standard binding ID denotes in DSE, or #f.
(define (sc-standard-keyword id dse keywords)
  (and (symbol? id)
       (let ((b (let loop ((id id) (n 0))
		  (let ((m (lookup id dse)))
		    (cond ((pair? m) m)
			  ((and (symbol? m) (not (eq? m id)) (fx< n 8))
			   (loop m (fx+ n 1)))
			  (else
			   (let ((b (lookup (or m id) (##sys#macro-environment))))
			     (and (pair? b) b))))))))
	 (and b
	      (pair? (cdr b))
	      (let ((h (cadr b)))
		(find (lambda (k)
			(any (lambda (me)
			       (let ((a (assq k me)))
				 (and a (pair? (cdr a)) (pair? (cddr a))
				      (eq? (caddr a) h))))
			     (list ##sys#scheme-macro-environment
				   ##sys#chicken.base-macro-environment
				   ##sys#default-macro-environment)))
		      keywords))))))

;; The variables of lambda list LL.
(define (sc-lambda-list-vars ll)
  (let loop ((ll ll) (vs '()))
    (cond ((symbol? ll) (cons ll vs))
	  ((pair? ll)
	   (loop (cdr ll)
		 (let ((v (if (pair? (car ll)) (caar ll) (car ll))))
		   (if (symbol? v) (cons v vs) vs))))
	  (else vs))))

;; R, the lowered result of a capture that received environment ENV,
;; with the binders of what the twins in ENV stand for renamed apart
;; where their scope holds such a twin.  A twin in such a scope made for
;; a capture placed inside R, which stands for the renamed binder, is
;; replaced by a twin of the new name.
(define (sc-rename-apart r env)
  (let* ((exp (sc-expansion))
	 (dse (vector-ref exp 1))
	 (twins (filter (lambda (h) (eq? (cdr (getp h '##core#sc-twin)) env))
			(vector-ref exp 9))))
    (if (null? twins)
	r
	(let* ((tmap (map (lambda (h) (cons h (sc-twin-target h))) twins))
	       (targets (map cdr tmap))
	       (new-twins '()))		; (((TWIN . NEW-NAME) . NEW-TWIN) ...)
	  (sc-alpha-apart
	   r dse
	   (lambda (v) (memq v targets))
	   (lambda (v x)
	     (sc-any-symbol?
	      (lambda (s) (let ((p (assq s tmap))) (and p (eq? (cdr p) v))))
	      x dse))
	   (lambda (s al)
	     (let ((tw (getp s '##core#sc-twin)))
	       (and tw
		    (not (eq? (cdr tw) env))
		    (sc-environment-within? (cdr tw) env)
		    (let ((a (assq (sc-twin-target s) al)))
		      (and a
			   (let ((k (find (lambda (p)
					    (and (eq? (caar p) s)
						 (eq? (cdar p) (cdr a))))
					  new-twins)))
			     (if k
				 (cdr k)
				 (let ((h (sc-twin (cdr a) (cdr tw))))
				   (set! new-twins
				     (cons (cons (cons s (cdr a)) h) new-twins))
				   h)))))))))))))

;; Is ENV2 an environment that a capture placed inside the result of a
;; capture that received ENV (or inside a closure there) gets?
(define (sc-environment-within? env2 env)
  (let loop ((e env2) (n 0))
    (cond ((eq? e env) #t)
	  ((fx> n 1000) #f)
	  (else
	   (case (##sys#slot e 1)
	     ((here) (loop (##sys#slot e 3) (fx+ n 1)))
	     ((derived extend) (loop (##sys#slot e 2) (fx+ n 1)))
	     (else #f))))))

;; Is X a quotation?  Without SE, any form whose head strips to `quote'
;; is taken to be one; with SE, the syntactic environment of X, its
;; head must also denote the standard `quote' there (as in
;; sc-quotation), so that a local variable named `quote' is not taken
;; for it.
(define (sc-quote-form? x #!optional se)
  (and (pair? x)
       (symbol? (car x))
       (memq (or (getp (car x) '##core#real-name) (car x))
	     '(quote ##core#quote))
       (or (not se)
	   (eq? (car x) '##core#quote)
	   (eq? 'quote (sc-standard-keyword (car x) se '(quote))))
       #t))

;; Does X, quotations aside, hold a symbol for which PRED is true?  SE
;; is as for sc-quote-form?.
(define (sc-any-symbol? pred x #!optional se)
  (let walk ((x x))
    (cond ((symbol? x) (pred x))
	  ((sc-quote-form? x se) #f)
	  ((pair? x) (or (walk (car x)) (walk (cdr x))))
	  ((vector? x) (walk (vector->list x)))
	  (else #f))))

;; X, code in syntactic environment DSE, with the binders V for which
;; (BINDER? V) is true renamed apart, together with the references in
;; their scope, where (AT-RISK? V SCOPE) is true.  Binding forms are
;; recognized by their keyword (see sc-binding-keyword); quotations are
;; not looked into.  With RETARGET, a symbol S in the scope of renamings
;; AL ((V . NEW) ...) that is no V is replaced by (RETARGET S AL), if
;; that is true.
(define (sc-alpha-apart r dse binder? at-risk? #!optional retarget)
  ;; the variables among VS to rename in SCOPE, with new names
  (define (renaming vs scope)
    (map (lambda (v) (cons v (macro-alias v '())))
	 (filter (lambda (v) (and (binder? v) (at-risk? v scope)))
		 (delete-duplicates vs eq?))))
  (define (rn al x)
    (if (null? al)
	x
	(sc-subst-symbols
	 x (lambda (s)
	     (let ((a (assq s al)))
	       (cond (a (cdr a))
		     ((and retarget (retarget s al)))
		     (else s)))))))
  ;; binding list BS with only its binders renamed
  (define (rn-binders al bs)
    (if (null? al)
	bs
	(map (lambda (b)
	       (cond ((symbol? b) (rn al b))
		     ((pair? b) (cons (rn al (car b)) (cdr b)))
		     (else b)))
	     bs)))
  (define (binders bs)
    (filter-map (lambda (b)
		  (cond ((symbol? b) b)
			((and (pair? b) (symbol? (car b))) (car b))
			(else #f)))
		bs))
  (define (body-defines body)
    (filter-map
     (lambda (f)
       (and (pair? f)
	    (pair? (cdr f))
	    (eq? 'define (sc-binding-keyword (car f) dse))
	    (let loop ((h (cadr f)))
	      (cond ((symbol? h) h)
		    ((pair? h) (loop (car h)))
		    (else #f)))))
     (if (list? body) body '())))
  (define (apart-body body)
    (rn (renaming (body-defines body) body) body))
  ;; the cdr of binding form X, renamed apart
  (define (apart x)
    (let ((args (cdr x)))
      (case (sc-binding-keyword (car x) dse)
	((lambda)
	 (if (pair? args)
	     (let ((args (rn (renaming (sc-lambda-list-vars (car args)) args)
			     args)))
	       (cons (car args) (apart-body (cdr args))))
	     args))
	((define)
	 (if (and (pair? args) (pair? (car args)))
	     ;; (define (name . ll) . body), maybe curried
	     (let* ((vs (let loop ((h (car args)) (vs '()))
			  (if (pair? h)
			      (loop (car h)
				    (append (sc-lambda-list-vars (cdr h)) vs))
			      vs)))
		    (al (renaming vs (cons (cdar args) (cdr args))))
		    (head (let loop ((h (car args)))
			    (if (pair? h)
				(cons (loop (car h)) (rn al (cdr h)))
				h))))
	       (cons head (apart-body (rn al (cdr args)))))
	     args))
	((let)
	 (cond ((and (pair? args) (symbol? (car args))
		     (pair? (cdr args)) (list? (cadr args)))
		;; named let: the name and the binders scope the body
		(let* ((bs (cadr args))
		       (body (cddr args))
		       (al (renaming (cons (car args) (binders bs)) body)))
		  (cons (rn al (car args))
			(cons (rn-binders al bs) (apart-body (rn al body))))))
	       ((and (pair? args) (list? (car args)))
		(let* ((bs (car args))
		       (body (cdr args))
		       (al (renaming (binders bs) body)))
		  (cons (rn-binders al bs) (apart-body (rn al body)))))
	       (else args)))
	((let*)
	 (if (and (pair? args) (list? (car args)))
	     (let loop ((bs (car args)) (body (cdr args)) (k cons))
	       (if (null? bs)
		   (k '() (apart-body body))
		   (loop (cdr bs) body
			 (lambda (rest body)
			   (let* ((b (car bs))
				  (al (renaming (binders (list b))
						(cons rest body))))
			     (k (cons (car (rn-binders al (list b)))
				      (rn al rest))
				(rn al body)))))))
	     args))
	((letrec)
	 (if (and (pair? args) (list? (car args)))
	     (let ((args (rn (renaming (binders (car args)) args) args)))
	       (cons (car args) (apart-body (cdr args))))
	     args))
	((do)
	 (if (and (pair? args) (list? (car args)) (pair? (cdr args)))
	     (let* ((specs (car args))
		    (al (renaming
			 (binders specs)
			 (cons (map (lambda (s)
				      (if (and (pair? s) (pair? (cdr s))) (cddr s) '()))
				    specs)
			       (cdr args)))))
	       (cons (map (lambda (s)
			    (if (and (pair? s) (pair? (cdr s)))
				(cons (rn al (car s))
				      (cons (cadr s) (rn al (cddr s))))
				s))
			  specs)
		     (rn al (cdr args))))
	     args))
	(else args))))
  (let walk ((x r))
    (cond ((sc-quote-form? x dse) x)
	  ((pair? x)
	   (let* ((args (if (symbol? (car x)) (apart x) (cdr x)))
		  (a (walk (car x)))
		  (d (let loop ((d args))
		       (if (pair? d)
			   (sc-copy-pair d (walk (car d)) (loop (cdr d)))
			   d))))
	     (sc-copy-pair x a d)))
	  ((vector? x)
	   (let* ((l (vector->list x))
		  (l2 (walk l)))
	     (if (eq? l l2) x (list->vector l2))))
	  (else x))))

;;; Lowering

;; Is F, a free name of a closure in the usage environment of a macro
;; whose form has K-info KI, a name that came from a closure nested in
;; the macro form (and was un-renamed there)?  Then it is not free text
;; of the macro form: in the paper it would still be a closure there,
;; and free names never capture what is inside a closure.  The alias
;; that F was un-renamed from is the only identifier for F in the
;; output of the expansion that made the macro form; it counts if it
;; was made by a closure that was placed, directly or not, inside the
;; text of K, not by K itself, by a context around K (through free
;; names) or for raw rsc output (which is free text).
(define (sc-protected? f ki)
  (and (symbol? f)
       (let* ((kuenv (vector-ref ki 2))
	      (chosen (vector-ref (##sys#slot kuenv 3) 1))
	      (info (and chosen (sc-table-ref chosen f))))
	 (and info
	      (not (vector-ref info 2))
	      (let ((kids (vector-ref ki 1))
		    (owner (vector-ref info 5)))
		(and owner
		     (not (eq? owner kids))
		     (let loop ((p (vector-ref owner 1)))
		       (cond ((not p) #f)
			     ((eq? p kids) #t)
			     (else (loop (vector-ref p 1)))))))))))

;; Lower closure C, placed where PCTX is the context; PIDS identifies
;; PCTX.  Its free names are lowered by PCTX, every other symbol to the
;; closure's own alias; closures nested in C see the free names of C
;; through C's context.
;;
;; A context is called as (CTX ID), (CTX SYMBOL #t) or (CTX SYMBOL
;; 'chain); the second only returns the identifier the context already
;; has for SYMBOL, or #f, the third also the one it has for what stands
;; for SYMBOL in its text (see sc-text-identifier).
;;
;; If C is closed in the usage environment of an expansion whose form
;; was lowered by a context K (see sc-form-context), a free name F also
;; matches the identifier K has for F: in the paper, the free names of
;; a closure made by a nested macro capture the names as written in the
;; code that calls it, and that code has been lowered by K already.
;; This is how (aif a (aif b it 'no) 'no) gets the inner `it', and,
;; through 'chain, (aif a (or b (aif c it 'no)) 'no) as well.
(define (sc-lower-closure c pctx pids)
  (let* ((env (##sys#slot c 1))
	 (free (##sys#slot c 2))
	 (ids (##sys#slot c 4))
	 (table (vector-ref ids 0))
	 (se (##sys#slot c 5))
	 (ki (and (pair? free)
		  (eq? 'usage (##sys#slot env 1))
		  (##sys#slot env 4)))
	 (k (and ki (vector-ref ki 0)))
	 (kfree (if k
		    (let loop ((fs free) (r '()))
		      (cond ((null? fs) r)
			    ((and (symbol? (car fs)) (k (car fs) 'chain)) =>
			     (lambda (id0)
			       (define id (sc-output-identifier id0))
			       (loop (cdr fs)
				     (if (eq? id (car fs))
					 r
					 (cons (cons id (car fs)) r)))))
			    (else (loop (cdr fs) r))))
		    '()))
	 (free2 (if ki
		    (remove (lambda (f) (sc-protected? f ki)) free)
		    free)))
    (vector-set! ids 1 pids)
    (letrec ((own (lambda (sym peek)
		    (or (sc-table-ref table sym)
			(cond ((not peek)
			       (let ((a (sc-fresh env sym se ids)))
				 (sc-table-set! table sym a)
				 a))
			      ((eq? peek 'chain)
			       (let ((x (sc-text-identifier env sym)))
				 (and x (sc-table-ref table x))))
			      (else #f)))))
	     (ctx (lambda (id #!optional peek)
		    (cond ((and (pair? free2) (memq id free2)) (pctx id peek))
			  ((not (symbol? id))
			   (and (not peek) (sc-lower-closure id ctx ids)))
			  ((and (pair? kfree) (assq id kfree)) =>
			   (lambda (p) (pctx (cdr p) peek)))
			  (else (own id peek))))))
      (sc-lower (##sys#slot c 3)
		ctx
		ids
		(if (null? free)
		    env
		    (sc-make-environment 'derived env free pctx (sc-expansion)))))))

;; Contexts of the forms made by lowering, so that a macro call among
;; them knows the context it was written in: a weak table keyed on the
;; form, hashed like the line-number database.  The value is #(K K-IDS
;; K-UENV), the context, its IDS and the usage environment of the
;; expansion that made the form.  A form lowered again (e.g. a
;; constant in a macro's code) keeps the latest context.  Unlike the
;; line-number database, most entries die soon (when the output has
;; been compiled), and the value of a dead entry, which holds the usage
;; environment and through it macro bindings and their transformers,
;; stays until the entry is dropped.  So the table is swept of dead
;; entries before it grows, and after the first major garbage
;; collection that follows a registration (see sc-arm-sweeper!).
;;
;; The table is #(COUNT BUCKETS).  A bucket is '() or #(HEAD TAIL
;; CURSOR): a list of weak pairs (FORM . VALUE) in the order they were
;; registered, its last pair, and the pair of the list where the last
;; lookup found its form.  The hash is structural, and identical forms
;; are common (one context makes one alias per symbol, so N copies of
;; `(m 1)' in an output are `equal?'); they are registered in the order
;; of the output, which is the order in which they are expanded, so a
;; lookup that starts after the last one finds its form at once.
(define sc-context-db (vector 0 (make-vector 256 '())))

;; Arm, unless it is armed already, a finalizer that sweeps the table
;; after the next major garbage collection.  It does not arm itself
;; again (`(gc #t)' collects until no finalizers are pending), the next
;; registration does.  It runs between interrupts, so never inside the
;; code of this unit (which disables them).
(define sc-sweeper-armed #f)

(define (sc-arm-sweeper!)
  (unless sc-sweeper-armed
    (set! sc-sweeper-armed #t)
    (##sys#init-finalizer
     (##sys#make-vector 1 #f)
     (lambda (x)
       (set! sc-sweeper-armed #f)
       (when (fx> (##sys#slot sc-context-db 0) 0)
	 (sc-context-sweep!))))))

;; The bucket of FORM in table vector V, made if MAKE? and needed.
(define (sc-context-bucket v form make?)
  (let* ((i (fxand (##sys#lndb-hash form) (fx- (##sys#size v) 1)))
	 (b (##sys#slot v i)))
    (cond ((vector? b) b)
	  (make? (let ((b (vector '() #f #f))) (##sys#setslot v i b) b))
	  (else #f))))

(define (sc-context-append! b a)
  (let ((cell (cons a '())))
    (if (null? (##sys#slot b 0))
	(##sys#setslot b 0 cell)
	(##sys#setslot (##sys#slot b 1) 1 cell))
    (##sys#setslot b 1 cell)))

;; The weak pair of FORM in bucket B, or #f.
(define (sc-context-entry b form)
  (define (scan l stop)
    (let loop ((l l))
      (cond ((or (null? l) (eq? l stop)) #f)
	    ((eq? (##sys#slot (##sys#slot l 0) 0) form)
	     (##sys#setslot b 2 l)
	     (##sys#slot l 0))
	    (else (loop (##sys#slot l 1))))))
  (let ((cur (##sys#slot b 2)))
    (if cur
	(or (scan (##sys#slot cur 1) '())
	    (scan (##sys#slot b 0) (##sys#slot cur 1)))
	(scan (##sys#slot b 0) '()))))

(define (sc-context-sweep!)
  (let* ((v (##sys#slot sc-context-db 1))
	 (live '())
	 (count 0))
    (do ((i 0 (fx+ i 1)))
	((fx>= i (##sys#size v)))
      (let ((b (##sys#slot v i)))
	(when (vector? b)
	  (for-each (lambda (a)
		      (unless (##core#inline "C_bwpp" (##sys#slot a 0))
			(set! live (cons a live))
			(set! count (fx+ count 1))))
		    (##sys#slot b 0)))))
    ;; rebuild, at a size fit for the live entries, keeping their order
    (let* ((n (let loop ((n 256)) (if (fx< n count) (loop (fx* n 2)) n)))
	   (new (make-vector n '())))
      (for-each (lambda (a)
		  (sc-context-append! (sc-context-bucket new (##sys#slot a 0) #t) a))
		(reverse live))
      (##sys#setslot sc-context-db 1 new)
      (##sys#setslot sc-context-db 0 count))))

;; FRESH? tells that FORM has not been registered (it was just made).
(define (sc-register-context! form v #!optional fresh?)
  (let ((a (and (not fresh?)
		(let ((b (sc-context-bucket (##sys#slot sc-context-db 1) form #f)))
		  (and b (sc-context-entry b form))))))
    (cond (a (##sys#setslot a 1 v))
	  (else
	   (when (fx>= (##sys#slot sc-context-db 0)
		       (fx* 2 (##sys#size (##sys#slot sc-context-db 1))))
	     (sc-context-sweep!))
	   (sc-context-append!
	    (sc-context-bucket (##sys#slot sc-context-db 1) form #t)
	    (lndb-weak-cons form v))
	   (##sys#setslot sc-context-db 0 (fx+ (##sys#slot sc-context-db 0) 1))
	   (sc-arm-sweeper!)))))

;; Only forms that may be calls of syntactic-closure macros, directly or
;; through other macros, are registered: their head (the identifier ID
;; that the context made for it) denotes an sc macro or a macro that is
;; not one of CHICKEN's (see sc-context-identifier?), or is bound by a
;; syntax definition in the same output (pass 1 collects those, see
;; sc-note-syntax-binders!).  HEADS caches the answer for each head of
;; the expansion.
(define (sc-note-context! form id ctx ids fresh?)
  (let* ((exp (sc-expansion))
	 (heads (vector-ref exp 7))
	 (sc? (let ((c (sc-table-ref heads id)))
		(if c
		    (eq? c 'yes)
		    (let ((sc? (or (memq id (vector-ref exp 6))
				   (sc-context-identifier? id (vector-ref exp 1)))))
		      (sc-table-set! heads id (if sc? 'yes 'no))
		      sc?)))))
    (when sc?
      (sc-register-context! form (vector ctx ids (vector-ref exp 2)) fresh?))))

;; Handlers of sc/rsc transformers carry this tag (see sc-tag-handler).
(define sc-handler-tag (list 'syntactic-closure-transformer))

(define (sc-tag-handler h)
  (##sys#decorate-lambda
   h
   (lambda (x) (eq? x sc-handler-tag))
   (lambda (p i) (##sys#setslot p i sc-handler-tag) p)))

(define (sc-macro-binding? b)
  (and (pair? b)
       (pair? (cdr b))
       (procedure? (cadr b))
       (##sys#lambda-decoration (cadr b) (lambda (x) (eq? x sc-handler-tag)))
       #t))

;; The macro binding that identifier ID denotes in DSE, or #f.
(define (sc-macro-binding-of id dse)
  (let* ((m (getp id '##core#macro-alias))
	 (b (if (pair? m)
		m
		(or (lookup (or m id) dse)
		    (lookup (or m id) (##sys#macro-environment))))))
    (and (pair? b) (pair? (cdr b)) (procedure? (cadr b)) b)))

;; Is the transformer procedure H one of CHICKEN's own macros?
(define (sc-standard-handler? h)
  (any (lambda (me)
	 (any (lambda (a) (and (pair? (cdr a)) (pair? (cddr a)) (eq? (caddr a) h)))
	      me))
       (list ##sys#scheme-macro-environment
	     ##sys#chicken.base-macro-environment
	     ##sys#default-macro-environment
	     ##sys#chicken.syntax-macro-environment
	     ##sys#chicken.condition-macro-environment
	     ##sys#chicken.time-macro-environment
	     ##sys#chicken.type-macro-environment
	     ##sys#chicken-ffi-macro-environment
	     ##sys#chicken.module-macro-environment)))

;; Does ID, in DSE, denote an sc macro, or a macro that may build a call
;; of one, that is, one that is not CHICKEN's own (those keep the forms
;; of their input as they are)?
(define (sc-context-identifier? id dse)
  (let ((b (sc-macro-binding-of id dse)))
    (and b
	 (or (sc-macro-binding? b)
	     (not (sc-standard-handler? (cadr b)))))))

;; The macro form EXP, which has a context (see sc-form-context), was
;; expanded into EXP2 in DSE by a macro that is not an sc macro: give
;; the forms that macro built (in a wrapper such as
;; `(syntax-rules () ((_ c t) (aif c t #f)))', the call of `aif') the
;; context of EXP, so that a nested sc macro called through it sees the
;; code that calls it as the paper says.  The forms of EXP that it
;; passes on have their own context or are not macro calls; the walk
;; stops at those that have one.  The symbols of EXP2 outside them are
;; added to the context's value (its fourth slot, a table), as symbols
;; that occur as they are around the call (see sc-kinfo-symbols): a
;; plain `x' bound by a non-hygienic er macro around the call is that
;; `x'.
(define (sc-propagate-context! exp exp2 handler dse)
  (when (and (pair? exp2)
	     (not (eq? exp exp2))
	     (fx> (##sys#slot sc-context-db 0) 0)
	     (not (##sys#lambda-decoration
		   handler (lambda (x) (eq? x sc-handler-tag)))))
    (let ((k (sc-form-context exp)))
      (when (and k (not (sc-standard-handler? handler)))
	(let ((budget strip-check-budget)
	      (syms (let ((old (and (fx> (##sys#size k) 3) (vector-ref k 3)))
			  (t (sc-make-table)))
		      (when old
			(sc-table-for-each (lambda (s _) (sc-table-set! t s #t)) old))
		      t))
	      (forms '()))
	  (let walk ((x exp2))
	    (cond ((fx<= budget 0))
		  ((symbol? x)
		   (unless (sc-table-ref syms x) (sc-table-set! syms x #t)))
		  ((and (pair? x)
			(not (sc-quote-form? x))
			(not (sc-form-context x)))
		   (when (and (symbol? (car x))
			      (sc-context-identifier? (car x) dse))
		     (set! forms (cons x forms)))
		   (let loop ((l x))
		     (cond ((pair? l)
			    (set! budget (fx- budget 1))
			    (walk (car l))
			    (loop (cdr l)))
			   (else (walk l)))))))
	  (unless (null? forms)
	    (let ((v (vector (vector-ref k 0) (vector-ref k 1) (vector-ref k 2)
			     syms)))
	      (for-each (lambda (x) (sc-register-context! x v #t))
			(reverse forms)))))))))

(define sc-syntax-binders
  '(let-syntax letrec-syntax define-syntax
    ##core#let-syntax ##core#letrec-syntax ##core#define-syntax))

;; In pass 1, X is a form whose head HEAD is an identifier made by
;; context CTX: if it binds keywords, note their identifiers.
(define (sc-note-syntax-binders! x head ctx)
  (when (memq (or (getp head '##core#real-name) head) sc-syntax-binders)
    (let ((ident (lambda (b)
		   (cond ((symbol? b) (ctx b #t))
			 ((and (sc-closure? b) (symbol? (##sys#slot b 3)))
			  (if (memq (##sys#slot b 3) (##sys#slot b 2))
			      (ctx (##sys#slot b 3) #t)
			      (sc-table-ref (vector-ref (##sys#slot b 4) 0)
					    (##sys#slot b 3))))
			 (else #f))))
	  (exp (sc-expansion)))
      (define (note! b)
	(let ((id (ident b)))
	  (when id (vector-set! exp 6 (cons id (vector-ref exp 6))))))
      (when (pair? (cdr x))
	(let ((b (cadr x)))
	  (cond ((list? b)		; let-syntax, letrec-syntax
		 (for-each (lambda (b) (when (pair? b) (note! (car b)))) b))
		(else (note! b))))))))

(define (sc-form-context form)
  (and (pair? form)
       (symbol? (car form))
       (fx> (##sys#slot sc-context-db 0) 0)
       (let* ((b (sc-context-bucket (##sys#slot sc-context-db 1) form #f))
	      (a (and b (sc-context-entry b form))))
	 (and a (##sys#slot a 1)))))

;; Lower X in context CTX, identified by IDS; PENV is the environment a
;; capture that is all of X receives, a capture inside X gets one that
;; resolves names as CTX does at that place.  In pass 1 nothing is
;; built.  Unchanged subforms are returned as they are, so that
;; line-number information and `eq?'-ness (which compiler syntax
;; relies on) are kept.  Quoted data too large to walk, e.g. circular,
;; is stripped (see sc-quotation); other circular structure is not
;; handled (as in ir).
(define (sc-lower x ctx ids penv)
  (let* ((exp (sc-expansion))
	 (here #f)
	 (dry (eqv? 1 (vector-ref exp 3))))
    (define (lower-capture x top?)
      (let ((env (cond (top? penv)
		       (here)
		       (else
			(set! here (sc-make-environment
				    'here ctx penv #f exp))
			here))))
	(let* ((c (sc-call-capture x env))
	       (r (sc-lower (car c) ctx ids env)))
	  ;; the twins of the capture's environment are those of the
	  ;; one given to it in pass 1
	  (if dry r (sc-rename-apart r (cdr c))))))
    ;; One walk for both passes; in pass 1 it only notes and returns X,
    ;; but the head of a form is lowered in both (HEAD?), so that both
    ;; passes agree on what the form is.  A form whose head lowers to a
    ;; symbol (also a closed keyword) remembers its context.
    (let walk ((x x) (form? #t) (top? #t) (head? #f))
      (cond ((symbol? x) (sc-emit (ctx x)))
	    ((pair? x)
	     (let* ((a (walk (car x) #t #f form?))
		    (id (and (not dry)
			     form?
			     (if (symbol? (car x))
				 (ctx (car x))
				 (and (symbol? a) a))))
		    (d (if (and form? (sc-quotation a x))
			    (if dry (cdr x) (strip-syntax (cdr x)))
			    (walk (cdr x) #f #f #f))))
	       (cond (dry
		      (when (and form? (symbol? a))
			(sc-note-syntax-binders! x a ctx))
		      x)
		     (else
		      (let ((r (if (and (eq? a (car x)) (eq? d (cdr x)))
				   x
				   (inherit-pair-line-numbers x (cons a d)))))
			(when (and id (symbol? id))
			  (sc-note-context! r id ctx ids (not (eq? r x))))
			r)))))
	    ((vector? x)
	     (let* ((lst (vector->list x))
		    (lst2 (walk lst #f #f #f)))
	       (if (or dry (eq? lst lst2)) x (list->vector lst2))))
	    ((sc-closure? x)
	     (let ((r (ctx x))) (if (and dry (not head?)) x r)))
	    ((sc-capture? x)
	     (let ((r (lower-capture x top?))) (if (and dry (not head?)) x r)))
	    (else x)))))

;; Is X, a form whose head lowers to A, a quotation whose data are too
;; large or deep to walk, e.g. circular?  Then the data are stripped
;; rather than lowered: closures in them are replaced by their forms,
;; as the compiler does when it strips quoted data, and strip-syntax
;; handles cycles.  Other quoted data are lowered like the rest, as the
;; symbols in them keep their identity (the templates of
;; scheme-macrology's with-macro rely on that).
(define (sc-quotation a x)
  (and (symbol? a)
       (memq (or (getp a '##core#real-name) a) '(quote ##core#quote))
       (or (eq? a '##core#quote)
	   (eq? 'quote (sc-standard-keyword a (sc-current-dse) '(quote))))
       (sc-big-datum? (cdr x))))

;; Does X have more than `strip-check-budget' pairs, or nest deeper
;; than `strip-check-depth' (see ##sys#strip-syntax-literal)?
(define (sc-big-datum? x)
  (let ((budget strip-check-budget))
    (let walk ((x x) (depth 0))
      (cond ((or (fx<= budget 0) (fx>= depth strip-check-depth)) #t)
	    ((pair? x)
	     (set! budget (fx- budget 1))
	     (or (walk (car x) (fx+ depth 1))
		 (walk (cdr x) depth)))
	    ((vector? x)
	     (let ((n (##sys#size x)))
	       (let loop ((i 0))
		 (and (fx< i n)
		      (or (walk (##sys#slot x i) (fx+ depth 1))
			  (loop (fx+ i 1)))))))
	    (else #f)))))

;; The result of capture X and the environment it got, as a pair.  The
;; procedure is called in pass 1; its continuation cannot be called
;; again once it has returned (or escaped), as the results of the
;; captures are consumed in order.
(define (sc-call-capture x penv)
  (let ((exp (sc-expansion)))
    (cond ((eqv? 1 (vector-ref exp 3))
	   (let ((c (cons (let ((done #f))
			    (dynamic-wind
			     (lambda ()
			       (when done
				 (##sys#error
				  'capture-syntactic-environment
				  "continuation of a capture procedure called after it has returned"
				  (##sys#slot x 1))))
			     (lambda () ((##sys#slot x 1) penv))
			     (lambda () (set! done #t))))
			  penv)))
	     (vector-set! exp 4 (cons c (vector-ref exp 4)))
	     c))
	  (else
	   (let ((rs (vector-ref exp 4)))
	     (vector-set! exp 4 (cdr rs))
	     (car rs))))))

;; Called for every symbol put into the output.  In pass 1 it notes
;; which usage aliases of the running expansion occur; in pass 2 it
;; un-renames those that were found not to conflict.
(define (sc-emit s)
  (let ((exp (sc-expansion))
	(info (getp s '##core#sc-usage)))
    (cond ((getp s '##core#sc-twin) =>
	   (lambda (tw)
	     ;; pass 1 notes what the twin stands for, pass 2 keeps it
	     ;; (see sc-untwin)
	     (when (eqv? 1 (vector-ref exp 3)) (sc-emit (car tw)))
	     s))
	  ((or (not info)
	       (not (eq? (vector-ref info 1) (vector-ref exp 2))))
	   (when (eqv? 1 (vector-ref exp 3))
	     (let ((m (getp s '##core#macro-alias)))
	       (when (and (symbol? m)
			  (not (sc-table-ref (vector-ref exp 8) m)))
		 (sc-table-set! (vector-ref exp 8) m #t))))
	   s)
	  ((eqv? 1 (vector-ref exp 3))
	   (vector-set! info 3 #t)
	   s)
	  ((vector-ref info 4) (vector-ref info 0))
	  (else s))))

;; Decide which usage aliases of UENV that occur in the output are
;; un-renamed: for every name, the alias if it is the only one that
;; occurs, otherwise the alias made for the raw output of an rsc
;; transformer, if any.  The chosen ones are kept in UENV for
;; sc-protected?.  A name is not un-renamed at all if another alias in
;; the output refers to the global variable of that name: the
;; un-renamed name could be bound around it, and CHICKEN resolves an
;; alias of a global by its name.
(define (sc-choose-unrenamed uenv)
  (let ((box (##sys#slot uenv 3))
	(groups (sc-make-table))
	(bases '()))
    (for-each
     (lambda (a)
       (let ((info (getp a '##core#sc-usage)))
	 (when (vector-ref info 3)
	   (let* ((sym (vector-ref info 0))
		  (g (sc-table-ref groups sym)))
	     (if g
		 (set-cdr! g (cons info (cdr g)))
		 (begin
		   (sc-table-set! groups sym (list info))
		   (set! bases (cons sym bases))))))))
     (vector-ref box 0))
    (let ((chosen (sc-make-table)))
      (for-each
       (lambda (sym)
	 (let* ((infos (sc-table-ref groups sym))
		(pick (cond ((sc-table-ref (vector-ref (sc-expansion) 8) sym)
			     (sc-usage-alias-left! sym uenv)
			     #f)
			    ((null? (cdr infos)) (car infos))
			    (else
			     (sc-usage-alias-left! sym uenv)
			     (find (lambda (i) (vector-ref i 2)) infos)))))
	   (when pick
	     (vector-set! pick 4 #t)
	     (sc-table-set! chosen sym pick))))
       bases)
      (vector-set! box 1 chosen))
    (pair? bases)))

;; What identifier ID means in environment ENV: a lexical variable (its
;; gensym), a macro (its `(se handler)' binding) or a global name.
(define (sc-resolve s dse)
  (or (lookup s dse) s))

(define (sc-denotation id env)
  (cond ((sc-closure? id)
	 (if (memq (##sys#slot id 3) (##sys#slot id 2))
	     (sc-denotation (##sys#slot id 3) env)
	     (sc-denotation (##sys#slot id 3) (##sys#slot id 1))))
	(else
	 (case (##sys#slot env 1)
	   ((usage) (sc-resolve (sc-usage-base env id) (##sys#slot env 2)))
	   ((extend)
	    (if (sc-extend-keyword? env id)
		(##sys#slot env 4)
		(sc-denotation id (##sys#slot env 2))))
	   ((derived)
	    (if (memq id (##sys#slot env 3))
		(sc-resolve ((##sys#slot env 4) id) (sc-current-dse))
		(sc-denotation id (##sys#slot env 2))))
	   ((here) (sc-resolve ((##sys#slot env 2) id) (sc-current-dse)))
	   (else
	    (sc-resolve (sc-fresh env id (sc-current-se) #f)
			(sc-current-dse)))))))

(define (sc-identifier=? env1 id1 env2 id2)
  (sc-check-environment env1 'identifier=? #t)
  (sc-check-environment env2 'identifier=? #t)
  (and (sc-identifier? id1)
       (sc-identifier? id2)
       (same-denotation? (sc-denotation id1 env1) (sc-denotation id2 env2))))

;; The transformer.  The handler gets the usage environment (sc) or the
;; macro environment (rsc); raw symbols of its result are interpreted
;; in the other one: in the macro environment like er's `rename' (one
;; alias per symbol), in the usage environment through one usage alias
;; per symbol.  A result `eq?' to the input form is returned unchanged,
;; which lets compiler syntax decline and lets the expander report
;; endless expansion.
(define (make-sc-transformer handler reverse? loc)
  (##sys#check-closure handler loc)
  (##sys#make-structure
   'transformer
   (sc-tag-handler
   (lambda (form se dse)
     (let* ((exp (vector se dse #f 0 '() #t '() (sc-make-table) (sc-make-table) '()
			 (sc-current-body)))
	    (k (sc-form-context form))
	    (uenv (sc-make-environment
		   'usage dse (vector '() #f)
		   (and k (vector (vector-ref k 0) (vector-ref k 1)
				  (vector-ref k 2) #f form
				  (and (fx> (##sys#size k) 3) (vector-ref k 3))))
		   exp))
	    (menv (sc-make-environment 'macro se #f #f exp)))
       (vector-set! exp 2 uenv)
       (let ((outer #f))
	 (dynamic-wind
	  (lambda ()
	    (set! outer (sc-expansion))
	    (unless (vector-ref exp 5)
	      ;; a continuation of the handler is called after the
	      ;; expansion has returned: its result is lowered afresh
	      (vector-set! exp 3 0)
	      (vector-set! exp 4 '())
	      (vector-set! exp 5 #t)
	      (vector-set! exp 7 (sc-make-table))
	      (vector-set! exp 8 (sc-make-table)))
	    (sc-expansion exp))
	  (lambda ()
	    (let ((result (handler form (if reverse? menv uenv))))
	      (if (eq? result form)
		  form
		  (let* ((ids (sc-make-ids))
			 (table (vector-ref ids 0))
			 (oenv (if reverse? uenv menv)))
		    (letrec ((raw (lambda (sym peek)
				    (or (sc-table-ref table sym)
					(cond ((not peek)
					       (let ((a (if reverse?
							    (sc-usage-alias sym uenv #t ids)
							    (macro-alias sym se))))
						 (sc-table-set! table sym a)
						 a))
					      ((and reverse? (eq? peek 'chain))
					       (let ((x (sc-text-identifier uenv sym)))
						 (and x (sc-table-ref table x))))
					      (else #f)))))
			     (ctx (lambda (id #!optional peek)
				    (cond ((symbol? id) (raw id peek))
					  (peek #f)
					  (else (sc-lower-closure id ctx ids))))))
		      ;; (also when the handler's continuation is called again)
		      (vector-set! exp 3 1)
		      (vector-set! exp 4 '())
		      (vector-set! exp 6 '())
		      (vector-set! exp 9 '())
		      (sc-lower result ctx ids oenv)
		      (sc-choose-unrenamed uenv)
		      (vector-set! exp 3 2)
		      (vector-set! exp 4 (reverse (vector-ref exp 4)))
		      (sc-untwin (sc-lower result ctx ids oenv)))))))
	  (lambda ()
	    (sc-expansion outer)
	    ;; The expansion is over, also when the handler or a capture
	    ;; procedure raised an exception: its environments can no
	    ;; longer make closures, and nothing kept refers to the forms
	    ;; involved.
	    (vector-set! exp 4 '())
	    (vector-set! exp 5 #f)
	    (vector-set! exp 6 '())
	    (vector-set! exp 7 #f)
	    (vector-set! exp 8 #f)
	    (vector-set! exp 9 '())
	    (vector-set! (##sys#slot uenv 3) 0 '())
	    (let ((ki (##sys#slot uenv 4)))
	      (when ki (sc-kinfo-symbols ki)))))))))))

(define (sc-macro-transformer handler)
  (make-sc-transformer handler #f 'sc-macro-transformer))

(define (rsc-macro-transformer handler)
  (make-sc-transformer handler #t 'rsc-macro-transformer))

;; The paper's protocol: EXPANDER is (lambda (syntactic-env form) ...)
;; and returns a syntactic closure, e.g. one closed in
;; scheme-syntactic-environment.  Unclosed output is interpreted in the
;; macro environment, as with sc-macro-transformer.
(define (sc-expander-transformer expander loc)
  (##sys#check-closure expander loc)
  (make-sc-transformer (lambda (form env) (expander env form)) #f loc))

(define (expander-macro-transformer expander)
  (sc-expander-transformer expander 'expander-macro-transformer))

(define (make-syntactic-closure env free form)
  (sc-make-closure env free form 'make-syntactic-closure))

(define (sc-make-closure-list env free forms loc)
  ;; checked here, as FORMS may be empty (types.db says #:enforce)
  (sc-check-environment env loc #t)
  (unless (and (list? free) (every sc-identifier? free))
    (##sys#signal-hook
     #:type-error loc "bad argument type - not a list of identifiers" free))
  (unless (list? forms)
    (##sys#signal-hook
     #:type-error loc "bad argument type - not a proper list" forms))
  (map (lambda (form) (sc-make-closure env free form loc)) forms))

(define (make-syntactic-closure-list env free forms)
  (sc-make-closure-list env free forms 'make-syntactic-closure-list))

(define (close-syntax form env)
  (sc-make-closure env '() form 'close-syntax))

(define (capture-syntactic-environment proc)
  (##sys#check-closure proc 'capture-syntactic-environment)
  (##sys#make-structure 'syntactic-capture proc))

(define scheme-syntactic-environment
  (sc-make-environment 'scheme #f #f #f #f))

(define core-syntactic-environment
  (sc-make-environment 'core #f #f #f #f))

;; Paper sec. 4.1: ENV in which (KEYWORD ...) is expanded by EXPANDER,
;; either a procedure (lambda (syntactic-env form) ...) as for
;; expander-macro-transformer, or a transformer such as those made by
;; sc-macro-transformer, er-macro-transformer or syntax-rules.
(define (sc-extend-environment env keyword expander loc)
  (sc-check-environment env loc #t)
  (##sys#check-symbol keyword loc)
  (let ((handler (if (##sys#structure? expander 'transformer)
		     (##sys#slot expander 1)
		     (##sys#slot (sc-expander-transformer expander loc) 1))))
    ;; The macro environment of the keyword is that of the expansion
    ;; that defines it, as for a let-syntax in its output.
    (sc-make-environment 'extend env keyword
			 (list (if (sc-expansion)
				   (sc-current-se)
				   (sc-environment-se env))
			       handler)
			 (##sys#slot env 5))))

(define (extend-syntactic-environment env keyword expander)
  (sc-extend-environment env keyword expander 'extend-syntactic-environment))

;; Paper sec. 4.3 and appendix: the macrology that defines the derived
;; keywords delay, or, and, let, cond, case, with-macro and
;; with-macro-rec in terms of the primitive keywords of
;; BASE-SYNTACTIC-ENV (lambda, quote, if, begin and set!).  The
;; expanders are the paper's: they close their output in the final
;; environment, so the derived keywords are built from BASE's
;; primitives and from each other.  Templates of with-macro are
;; standard Scheme, evaluated at expansion time.
(define (scheme-macrology base-syntactic-env)
  ;; The paper's text, but with the procedures of this unit rather than
  ;; the exported ones, which a program can assign.
  (define (make-syntactic-closure env free form)
    (sc-make-closure env free form 'make-syntactic-closure))
  (define (make-syntactic-closure-list env free forms)
    (sc-make-closure-list env free forms 'make-syntactic-closure-list))
  (define (identifier=? env1 id1 env2 id2)
    (sc-identifier=? env1 id1 env2 id2))
  (define (extend-syntactic-environment env keyword expander)
    (sc-extend-environment env keyword expander 'extend-syntactic-environment))
  (define final-syntactic-env #f)
  (define (close-final form)
    (make-syntactic-closure final-syntactic-env '() form))
  (define (delay-expander syntactic-env exp)
    (let ((delayed (make-syntactic-closure syntactic-env '() (cadr exp))))
      (close-final
       `(##sys#make-promise
	 (lambda ()
	   (##sys#make-promise
	    (##sys#call-with-values (lambda () ,delayed) ##sys#list)))))))
  (define (and-expander syntactic-env exp)
    (let ((operands (make-syntactic-closure-list syntactic-env '() (cdr exp))))
      (cond ((null? operands) (close-final '#t))
	    ((null? (cdr operands)) (car operands))
	    (else
	     (close-final
	      `(let ((temp ,(car operands)))
		 (if temp (and ,@(cdr operands)) temp)))))))
  (define (or-expander syntactic-env exp)
    (let ((operands (make-syntactic-closure-list syntactic-env '() (cdr exp))))
      (cond ((null? operands) (close-final '#f))
	    ((null? (cdr operands)) (car operands))
	    (else
	     (close-final
	      `(let ((temp ,(car operands)))
		 (if temp temp (or ,@(cdr operands)))))))))
  (define (let-expander syntactic-env exp)
    (let ((identifiers (map car (cadr exp))))
      (close-final
       `((lambda ,identifiers
	   ,@(make-syntactic-closure-list syntactic-env identifiers (cddr exp)))
	 ,@(make-syntactic-closure-list syntactic-env '() (map cadr (cadr exp)))))))
  ;; ELSE is compared with identifier=? rather than `eq?', as clauses
  ;; may come from the output of other macros.
  (define (else? syntactic-env x)
    (identifier=? syntactic-env x scheme-syntactic-environment 'else))
  (define (cond-expander syntactic-env exp)
    (close-final (process-cond-clauses syntactic-env (cdr exp))))
  (define (process-cond-clauses syntactic-env clauses)
    (let ((body (make-syntactic-closure-list syntactic-env '() (cdar clauses))))
      (cond ((not (null? (cdr clauses)))
	     (let ((test (make-syntactic-closure syntactic-env '() (caar clauses)))
		   (rest (process-cond-clauses syntactic-env (cdr clauses))))
	       (if (null? body)
		   `(or ,test ,rest)
		   `(if ,test (begin ,@body) ,rest))))
	    ((else? syntactic-env (caar clauses)) `(begin ,@body))
	    (else
	     (let ((test (make-syntactic-closure syntactic-env '() (caar clauses))))
	       (if (null? body)
		   test
		   `(if ,test (begin ,@body))))))))
  (define (case-expander syntactic-env exp)
    (close-final
     `(let ((temp ,(make-syntactic-closure syntactic-env '() (cadr exp))))
	,(process-case-clauses syntactic-env (cddr exp)))))
  (define (process-case-clauses syntactic-env clauses)
    (let ((data (caar clauses))
	  (body (make-syntactic-closure-list syntactic-env '() (cdar clauses))))
      (cond ((not (null? (cdr clauses)))
	     (let ((rest (process-case-clauses syntactic-env (cdr clauses))))
	       `(if (memv temp ',data) (begin ,@body) ,rest)))
	    ((else? syntactic-env data) `(begin ,@body))
	    (else `(if (memv temp ',data) (begin ,@body))))))
  ;; The template is evaluated as standard Scheme; the symbols it puts
  ;; into the replacement get back the identity they have in the
  ;; with-macro form, which may have been renamed by enclosing macros.
  ;; A name is taken to be its first identity in the template; another
  ;; identity of the same name in quoted data (e.g. a closure of the
  ;; caller's `temp' that an expander quoted into a template binding
  ;; its own `temp') is given a fresh name in the template, so that
  ;; the two stay distinct.
  (define (macro-transformer exp)
    (let* ((ids (sc-make-table))
	   (fresh '())			; ((NAME . IDENTITY) ...)
	   (template
	    ;; MODE: #f in code, quote or quasiquote in data
	    (let walk ((x (caddr exp)) (mode #f))
	      (cond ((symbol? x)
		     (let* ((s (strip-syntax x))
			    (old (sc-table-ref ids s)))
		       (cond ((not old) (sc-table-set! ids s x) x)
			     ((or (eq? old x) (not mode)) x)
			     ((find (lambda (p) (eq? (cdr p) x)) fresh) => car)
			     (else
			      (let ((g (gensym s)))
				(set! fresh (cons (cons g x) fresh))
				g)))))
		    ((pair? x)
		     (let ((h (and (symbol? (car x)) (strip-syntax (car x)))))
		       (cond ((and (not mode) (memq h '(quote ##core#quote)))
			      (cons (walk (car x) #f) (walk (cdr x) 'quote)))
			     ((and (not mode) (eq? h 'quasiquote))
			      (cons (walk (car x) #f) (walk (cdr x) 'quasiquote)))
			     ((and (eq? mode 'quasiquote)
				   (memq h '(unquote unquote-splicing)))
			      (cons (walk (car x) #f) (walk (cdr x) #f)))
			     (else
			      (cons (walk (car x) mode) (walk (cdr x) mode))))))
		    ((vector? x)
		     (list->vector
		      (map (lambda (y) (walk y (or mode 'quote))) (vector->list x))))
		    (else x))))
	   (proc (##sys#eval/meta
		  (strip-syntax `(lambda ,(cdadr exp) ,template)))))
      (lambda args
	(let walk ((x (apply proc args)))
	  (cond ((symbol? x)
		 (cond ((assq x fresh) => cdr)
		       (else (or (sc-table-ref ids x) x))))
		((pair? x) (cons (walk (car x)) (walk (cdr x))))
		((vector? x) (list->vector (map walk (vector->list x))))
		(else x))))))
  (define (with-macro-expander with-macro-syntactic-env exp)
    (let* ((keyword (caadr exp))
	   (transformer (macro-transformer exp))
	   (expander
	    (lambda (syntactic-env exp)
	      (make-syntactic-closure
	       with-macro-syntactic-env '()
	       (apply transformer
		      (make-syntactic-closure-list syntactic-env '() (cdr exp)))))))
      (close-final
       `(begin ,@(make-syntactic-closure-list
		  (extend-syntactic-environment
		   with-macro-syntactic-env keyword expander)
		  '() (cdddr exp))))))
  (define (with-macro-rec-expander with-macro-syntactic-env exp)
    (let* ((keyword (caadr exp))
	   (transformer (macro-transformer exp))
	   (extended-syntactic-env #f)
	   (expander
	    (lambda (syntactic-env exp)
	      (make-syntactic-closure
	       extended-syntactic-env '()
	       (apply transformer
		      (make-syntactic-closure-list syntactic-env '() (cdr exp)))))))
      (set! extended-syntactic-env
	(extend-syntactic-environment with-macro-syntactic-env keyword expander))
      (close-final
       `(begin ,@(make-syntactic-closure-list extended-syntactic-env '() (cdddr exp))))))
  (sc-check-environment base-syntactic-env 'scheme-macrology)
  (set! final-syntactic-env
    (foldl (lambda (env p) (extend-syntactic-environment env (car p) (cdr p)))
	   base-syntactic-env
	   (list (cons 'delay delay-expander)
		 (cons 'or or-expander)
		 (cons 'and and-expander)
		 (cons 'let let-expander)
		 (cons 'cond cond-expander)
		 (cons 'case case-expander)
		 (cons 'with-macro with-macro-expander)
		 (cons 'with-macro-rec with-macro-rec-expander))))
  final-syntactic-env)

(define (identifier? x) (sc-identifier? x))

(define (identifier=? env1 id1 env2 id2)
  (sc-identifier=? env1 id1 env2 id2))

(define (identifier->symbol id)
  (let loop ((x id))
    (cond ((sc-closure? x) (loop (##sys#slot x 3)))
	  ((symbol? x) (strip-syntax x))
	  (else
	   (##sys#signal-hook
	    #:type-error 'identifier->symbol
	    "bad argument type - not an identifier" id)))))

(define (syntactic-closure? x) (sc-closure? x))
(define (syntactic-environment? x) (sc-environment? x))
(define (strip-syntactic-closures x) (strip-syntax x))

(define ##sys#sc-transformer sc-macro-transformer)
(define ##sys#rsc-transformer rsc-macro-transformer)

;;; Definitions in bodies
;
; A body that defines a name X (written by the user, or a usage alias
; of X that denotes what X denotes in the body) binds X itself, and
; every usage alias of X in the body that denotes what X denotes
; outside it, and was made for a macro used in the body (an expansion
; made while ##sys#canonicalize-body scanned the body's forms, see
; sc-current-body), is replaced by X, so that it refers to the
; definition.  This makes a macro's (define ,(close-syntax name env)
; ...) and (set! ,(close-syntax name env) ...) refer to the same
; variable, even when the two closures are different identifiers.
; Closures made in an environment outside the body (by a macro whose
; output contains the body, or kept from an earlier expansion) are not
; affected, as with letrec*.  Binders of X inside the body that would
; capture the replaced aliases are renamed apart first (see
; sc-body-unrename).

;; NAMES are the names defined by BODY, a body with syntactic
;; environment SE.  Returns ((X . DENOTATION) ...).  A name X written by
;; the user only needs a look when an expansion made for the body left a
;; usage alias of X in its output.
(define (sc-body-classes names se body)
  (let ((left (vector-ref body 0)))
    (let loop ((names names) (classes '()))
      (if (null? names)
	  classes
	  (let* ((n (car names))
		 (info (and (symbol? n) (getp n '##core#sc-usage)))
		 (x (if info (vector-ref info 0) n))
		 (den (and (symbol? x)
			   (if info
			       (eq? body (sc-usage-environment-body
					  (vector-ref info 1)))
			       (and left (sc-table-ref left x)))
			   (or (lookup x se) x))))
	    (loop (cdr names)
		  ;; duplicates are harmless: classes are only searched
		  (if (and den
			   (or (not info)
			       (eq? (getp n '##core#macro-alias) den)))
		      (cons (cons x den) classes)
		      classes)))))))

;; SE, the syntactic environment of a body, with the NAMES the body
;; defines as variables (they are not keywords there).
(define (sc-body-se names se)
  (foldl (lambda (se n)
	   (if (symbol? n) (cons (cons n (gensym n)) se) se))
	 se
	 names))

;; Quoted data is not walked: aliases in it are stripped anyway, and it
;; may be circular.
;;
;; With SE, the syntactic environment of the body (see sc-body-se), X is
;; code of the body, and binding forms in it that bind a name of a class
;; (a usage alias of the class, or X itself) are first renamed apart
;; where their scope holds another identifier of the class (see
;; sc-alpha-apart): in `(lambda (x1) x2)', where x1 and x2 are aliases
;; of a defined `x' made by different closures, x2 refers to the
;; definition.  SE also tells quotations from calls of a local variable
;; named `quote'.
(define (sc-body-unrename x classes body #!optional se)
  ;; the name of the class of identifier V, or #f
  (define (class-of v)
    (let ((info (getp v '##core#sc-usage)))
      (if info
	  (let ((sym (vector-ref info 0))
		(den (getp v '##core#macro-alias)))
	    (and (eq? body (sc-usage-environment-body (vector-ref info 1)))
		 (any (lambda (c) (and (eq? (car c) sym) (eq? (cdr c) den)))
		      classes)
		 sym))
	  (and (assq v classes) v))))
  (let walk ((x (if se
		    (sc-alpha-apart
		     x se class-of
		     (lambda (v scope)
		       (let ((c (class-of v)))
			 (sc-any-symbol?
			  (lambda (s) (and (not (eq? s v)) (eq? (class-of s) c)))
			  scope se))))
		    x)))
    (cond ((sc-quote-form? x se) x)
	  ((symbol? x)
	   (if (getp x '##core#sc-usage)
	       (or (class-of x) x)
	       x))
	  ((pair? x)
	   (let ((a (walk (car x)))
		 (d (walk (cdr x))))
	     (if (and (eq? a (car x)) (eq? d (cdr x)))
		 x
		 (inherit-pair-line-numbers x (cons a d)))))
	  (else x))))

(set-record-printer! 'syntactic-closure
  (lambda (x p)
    (##sys#print "#<syntactic-closure " #f p)
    (##sys#print (strip-syntax (##sys#slot x 3)) #t p)
    (##sys#write-char-0 #\> p)))

(set-record-printer! 'syntactic-environment
  (lambda (x p)
    (##sys#print "#<syntactic-environment>" #f p)))


;; Expose some internals for use in core.scm and chicken-syntax.scm:

(define chicken.syntax#define-definition define-definition)
(define chicken.syntax#define-syntax-definition define-syntax-definition)
(define chicken.syntax#define-values-definition define-values-definition)
(define chicken.syntax#expansion-result-hook expansion-result-hook)

) ; chicken.syntax module

(import scheme chicken.base chicken.bytevector chicken.fixnum)
(import chicken.syntax chicken.internal chicken.platform)
(import (only (scheme base) make-parameter))

;;; Macro definitions:

(##sys#extend-macro-environment
 'import-syntax '()
 (##sys#er-transformer
  (cut ##sys#expand-import <> <> <>
       ##sys#current-environment ##sys#macro-environment
       #f #f 'import-syntax)))

(##sys#extend-macro-environment
 'import-syntax-for-syntax '()
 (##sys#er-transformer
  (cut ##sys#expand-import <> <> <>
       ##sys#current-meta-environment ##sys#meta-macro-environment
       #t #f 'import-syntax-for-syntax)))

(set! chicken.syntax#import-definition
  (##sys#extend-macro-environment
   'import '()
   (##sys#er-transformer
    (lambda (x r c)
      `(##core#begin
	,@(map (lambda (x)
		 (let-values (((name lib spec v s i) (##sys#decompose-import x r c 'import))
			      ((mod) (##sys#current-module)))
		   (when (and mod (eq? name (##sys#module-name mod)))
		     (##sys#syntax-error
		      'import "cannot import from module currently being defined" name))
		   (if (not spec)
		       (##sys#syntax-error
			'import "cannot import from undefined module" name)
		       (##sys#import
			spec v s i
			##sys#current-environment ##sys#macro-environment #f #f 'import))
		   (if (not lib)
		       '(##core#undefined)
		       `(##core#require ,lib ,name))))
	       (cdr x)))))))

(##sys#extend-macro-environment
 'import-for-syntax '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#register-meta-expression `(,(r 'import) ,@(cdr x)))
    `(##core#elaborationtimeonly (,(r 'import) ,@(cdr x))))))

(define (process-cond-expand clauses)
      (define (err x)
	(##sys#syntax-error "syntax error in `cond-expand' form"
		     x
		     (cons 'cond-expand clauses)))
      (define (file-exists? fname)
        (##sys#file-exists? fname #f #f 'cond-expand))
      (define (locate-library name)
        (let* ((name2 (library-id name))
               (sname2 (symbol->string name2)))
          (or (##sys#find-module name2 #f)
              (let loop ((rp (repository-path)))
                (and (pair? rp)
                     (let ((p (car rp)))
                       (or (file-exists? (string-append p "/" sname2 ".import.so"))
                           (file-exists? (string-append p "/" sname2 ".import.scm"))
                           (loop (cdr rp)))))))))
      (define (test fx)
	(cond ((symbol? fx) (feature? (strip-syntax fx)))
	      ((not (pair? fx)) (err fx))
	      (else
	       (let ((head (car fx))
		     (rest (cdr fx)))
		 (case (strip-syntax head)
		   ((and)
		    (or (eq? rest '())
			(if (pair? rest)
			    (and (test (car rest))
				 (test `(and ,@(cdr rest))))
			    (err fx))))
		   ((or)
		    (and (not (eq? rest '()))
			 (if (pair? rest)
			     (or (test (car rest))
				 (test `(or ,@(cdr rest))))
			     (err fx))))
		   ((not) (not (test (cadr fx))))
                   ((library)
                    (if (and (pair? rest)
                             (null? (cdr rest)))
                        (locate-library (strip-syntax (car rest)))
                        (err fx)))
		   (else (err fx)))))))
      (let expand ((cls clauses))
	(cond ((eq? cls '())
	       (##sys#apply
		##sys#error "no matching clause in `cond-expand' form"
		(map (lambda (x) (car x)) clauses)))
	      ((not (pair? cls)) (err cls))
	      (else
	       (let ((clause (car cls))
		    (rclauses (cdr cls)))
		 (if (not (pair? clause))
		     (err clause)
		     (let ((id (car clause)))
		       (cond ((eq? (strip-syntax id) 'else)
			      (let ((rest (cdr clause)))
				(if (eq? rest '())
				    '(##core#undefined)
				    `(##core#begin ,@rest))))
			     ((test id) `(##core#begin ,@(cdr clause)))
			     (else (expand rclauses))))))))))

(##sys#extend-macro-environment
 'cond-expand
 '()
 (##sys#er-transformer
  (lambda (form r c)
    (process-cond-expand (cdr form)))))

;; The "initial" macro environment, containing only import forms and
;; cond-expand.  TODO: Eventually, cond-expand should move to the
;; (chicken base) module to match r7rs.  Keeping it in the initial env
;; makes it a whole lot easier to write portable CHICKEN 4 & 5 code.
(define ##sys#initial-macro-environment (##sys#macro-environment))

(##sys#extend-macro-environment
 'module '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'module x '(_ _ _ . #(_ 0)))
    (let ((len (length x))
	  (name (library-id (cadr x))))
      ;; We strip syntax here instead of doing a hygienic comparison
      ;; to "=".  This is a tradeoff; either we do this, or we must
      ;; include a mapping of (= . scheme#=) in our syntax env.  In
      ;; the initial environment, = is bound to scheme#=, but when
      ;; using -explicit-use that's not the case.  Doing an unhygienic
      ;; comparison ensures module will work in both cases.
      (cond ((and (fx>= len 4) (eq? '= (strip-syntax (caddr x))))
	     (let* ((x (strip-syntax x))
		    (app (cadddr x)))
	       (cond ((fx> len 4)
		      ;; feature suggested by syn:
		      ;;
		      ;; (module NAME = FUNCTORNAME BODY ...)
		      ;; ~>
		      ;; (begin
		      ;;   (module _NAME * BODY ...)
		      ;;   (module NAME = (FUNCTORNAME _NAME)))
		      ;;
		      ;; - the use of "_NAME" is a bit stupid, but it must be
		      ;;   externally visible to generate an import library from
		      ;;   and compiling "NAME" separately may need an import-lib
		      ;;   for stuff in "BODY" (say, syntax needed by syntax exported
		      ;;   from the functor, or something like this...)
		      (let ((mtmp (string->symbol
				   (##sys#string-append
				    "_"
				    (symbol->string name))))
			    (%module (r 'module)))
			`(##core#begin
			  (,%module ,mtmp * ,@(cddddr x))
			  (,%module ,name = (,app ,mtmp)))))
		     (else
		      (##sys#check-syntax
		       'module x '(_ _ _ (_ . #(_ 0))))
		      (##sys#instantiate-functor
		       name
		       (library-id (car app))
		       (cdr app)))))) ; functor arguments
	    (else
	     ;;XXX use module name in "loc" argument?
	     (let ((exports (##sys#validate-exports (strip-syntax (caddr x)) 'module)))
	       `(##core#module
		 ,name
		 ,(if (eq? '* exports)
		      #t
		      exports)
		 ,@(let ((body (cdddr x)))
		     (if (and (pair? body)
			      (null? (cdr body))
			      (string? (car body)))
			 `((##core#include ,(car body) ,##sys#current-source-filename))
			 body))))))))))

;;; R7RS define-library

(##sys#extend-macro-environment
  'define-library '()
  (##sys#er-transformer
   (lambda (x r c)
     (define (register-r7rs-module name)
       (let ((dummy (string->symbol (string-append (string #\x04) "r7rs" (symbol->string name)))))
         (##sys#put! name '##r7rs#module dummy)
         dummy))
     (define implicit-r7rs-library-bindings
       '(begin
          cond-expand
          export
          import
          import-for-syntax
          include
          include-ci
          syntax-rules))
     (##sys#check-syntax 'define-library x '(_ . #(_ 0)))
     (let* ((x (strip-syntax x))
            (name (cadr x))
            (real-name (library-id name))
            (decls (cddr x))
            (all #f)
            (dummy (register-r7rs-module real-name)))
       (define (parse-exports specs)
         (map (lambda (spec)
                (cond ((and (list? spec)
                            (= 3 (length spec))
                            (eq? 'rename (car spec)))
                       `(export/rename ,(cdr spec)))
                      ((symbol? spec) `(export ,spec))
                      (else
                        (##sys#syntax-error 'define-library "invalid export specifier" spec name))))
            specs))
       (define (parse-imports specs)
         ;; XXX TODO: Should be import-for-syntax'ed as well?
         `(import ,@specs))
       (define (process-includes fnames ci?)
         `(##core#begin
           ,@(map (lambda (fname)
                    (if (string? fname)
                        `(##core#begin ,@(read-forms fname ci?))
                        (##sys#syntax-error 'include "invalid filename"
                          fname)))
                  fnames)))
       (define (expand/begin e)
         (let ((e2 (expand e '())))
           (if (and (pair? e2) (eq? '##core#begin (car e2)))
               (cons '##core#begin (map expand/begin (cdr e2)))
               e2)))
       (define (read-forms filename ci?)
         (fluid-let ((##sys#default-read-info-hook
                       (let ((name 'chicken.compiler.support#read-info-hook))
                         (and (feature? 'compiling)
                              (##sys#symbol-has-toplevel-binding? name)
                              (##sys#slot name 0)))))
           (##sys#include-forms-from-file
               filename
               ##sys#current-source-filename ci?
               (lambda (forms path) forms))))
       (define (process-include-decls fnames)
         (parse-decls
           (let loop ((fnames fnames) (all '()))
             (if (null? fnames)
                 (reverse all)
                 (let ((forms (read-forms (car fnames) #t)))
                   (loop (cdr fnames)
                         (append (reverse forms) all)))))))
       (define (fail spec)
         (##sys#syntax-error 'define-library "invalid library declaration" spec))
       (define (parse-decls decls)
         (cond ((null? decls) '(##core#begin))
               ((and (pair? decls) (pair? (car decls)))
                (let ((spec (car decls))
                      (more (cdr decls)))
                 (case (car spec)
                  ((export)
                   (##sys#check-syntax 'export spec '(_ . #(_ 0)))
                   `(##core#begin ,@(parse-exports (cdr spec))
                                  ,(parse-decls more)))
                  ((export-all)
                   (##sys#check-syntax 'export-all spec '(_))
                   (set! all #t)
                   (parse-decls more))
                  ((import)
                   (##sys#check-syntax 'import spec '(_ . #(_ 0)))
                   `(##core#begin ,(parse-imports (cdr spec))
                                  ,(parse-decls more)))
                  ((include)
                   (##sys#check-syntax 'include spec '(_ . #(_ 0)))
                   `(##core#begin ,(process-includes (cdr spec) #f)
                                  ,(parse-decls more)))
                  ((include-ci)
                   (##sys#check-syntax 'include-ci spec '(_ . #(_ 0)))
                   `(##core#begin ,(process-includes (cdr spec) #t)
                                  ,(parse-decls more)))
                  ((include-library-declarations)
                   `(##core#begin ,(process-include-decls (cdr spec))
                                  ,(parse-decls more)))
                  ((cond-expand)
                   (parse-decls
                     `((##core#begin
                        ,(process-cond-expand (cdr spec))
                        ,@more))))
                  ((##core#begin)
                    (parse-decls (append (cdr spec) more)))
                  ((##core#undefined)	; residue from cond-expand
                    (parse-decls more))
                  ((begin)
                   `(##core#begin ,@(cdr spec)
                                  ,(parse-decls more)))
                  (else (fail spec)))))
                (else (fail (car decls)))))
       (let ((pd (parse-decls decls)))
         `(##core#module ,real-name ,(if all #t `((,dummy)))
           ;; gruesome hack: we add a dummy export for adding indirect exports,
           ;; see ##sys#register-export, which does the other half.
           ,@(if all
                 '()
                 `((##core#define-syntax ,dummy
                    (##sys#er-transformer (##core#lambda (x r c) (##core#undefined))))))
           ;; Set up an R7RS environment for the module's body.
           (import-for-syntax (only scheme.base ,@implicit-r7rs-library-bindings))
           (import (only scheme.base ,@implicit-r7rs-library-bindings)
                   (only chicken.module export/rename))
           ;; Now process all toplevel library declarations
           ,pd))))))

(##sys#extend-macro-environment
 'export '()
 (##sys#er-transformer
  (lambda (x r c)
    (let ((exps (##sys#validate-exports (strip-syntax (cdr x)) 'export))
	  (mod (##sys#current-module)))
      (when mod
	(##sys#add-to-export-list mod exps))
      '(##core#undefined)))))

(##sys#extend-macro-environment
 'export/rename '()
 (##sys#er-transformer
  (lambda (x r c)
    (let ((exps (map (lambda (ren)
                       (if (and (pair? ren)
                                (symbol? (car ren))
                                (pair? (cdr ren))
                                (symbol? (cadr ren))
                                (null? (cddr ren)))
                           (cons (car ren) (cadr ren))
                           (##sys#syntax-error "invalid item in export rename list"
                                                    ren)))
                  (strip-syntax (cdr x))))
          (mod (##sys#current-module)))
      (when mod
	(##sys#add-to-export/rename-list mod exps))
      '(##core#undefined)))))

(##sys#extend-macro-environment
 'reexport '()
 (##sys#er-transformer
  (cut ##sys#expand-import <> <> <>
       ##sys#current-environment ##sys#macro-environment
       #f #t 'reexport)))

;;; functor definition

(##sys#extend-macro-environment
 'functor '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'functor x '(_ (_ . #((_ _) 0)) _ . _))
    (let* ((x (strip-syntax x))
	   (head (cadr x))
	   (name (car head))
	   (args (cdr head))
	   (exps (caddr x))
	   (body (cdddr x))
	   (registration
	    `(##sys#register-functor
	      (##core#quote ,(library-id name))
	      (##core#quote
	       ,(map (lambda (arg)
		       (let ((argname (car arg))
			     (exps (##sys#validate-exports (cadr arg) 'functor)))
			 (unless (or (symbol? argname)
				     (and (list? argname)
					  (= 2 (length argname))
					  (symbol? (car argname))
					  (valid-library-specifier? (cadr argname))))
			   (##sys#syntax-error "invalid functor argument" name arg))
			 (cons argname exps)))
		     args))
	      (##core#quote ,(##sys#validate-exports exps 'functor))
	      (##core#quote ,body))))
      `(##core#module ,(library-id name)
	#t
	(import scheme chicken.syntax) ;; TODO: Is this correct?
	(begin-for-syntax ,registration))))))

;;; interface definition

(##sys#extend-macro-environment
 'define-interface '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'define-interface x '(_ variable _))
    (let ((name (strip-syntax (cadr x))))
      (when (eq? '* name)
	(##sys#syntax-error
	 'define-interface "`*' is not allowed as a name for an interface"))
      `(##core#elaborationtimeonly
	(##sys#put/restore!
	 (##core#quote ,name)
	 (##core#quote ##core#interface)
	 (##core#quote
	  ,(let ((exps (strip-syntax (caddr x))))
	     (cond ((eq? '* exps) '*)
		   ((symbol? exps) `(#:interface ,exps))
		   ((list? exps)
		    (##sys#validate-exports exps 'define-interface))
		   (else
		    (##sys#syntax-error
		     'define-interface "invalid exports" (caddr x))))))))))))

(##sys#extend-macro-environment
 'current-module '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'current-module x '(_))
    (and-let* ((mod (##sys#current-module)))
      `(##core#quote ,(##sys#module-name mod))))))

;; The chicken.module syntax environment
(define ##sys#chicken.module-macro-environment (##sys#macro-environment))

(set! ##sys#scheme-macro-environment
  (let ((me0 (##sys#macro-environment)))

(##sys#extend-macro-environment
 'lambda
 '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'lambda x '(_ lambda-list . #(_ 1)))
    `(##core#lambda ,@(cdr x)))))

(##sys#extend-macro-environment
 'quote
 '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'quote x '(_ _))
    `(##core#quote ,(cadr x)))))

(##sys#extend-macro-environment
 'if
 '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'if x '(_ _ _ . #(_)))
    `(##core#if ,@(cdr x)))))

(##sys#extend-macro-environment
 'begin
 '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'begin x '(_ . #(_ 0)))
    `(##core#begin ,@(cdr x)))))

(set! chicken.syntax#define-definition
  (##sys#extend-macro-environment
   'define
   '()
   (##sys#er-transformer
    (lambda (x r c)
      (##sys#check-syntax 'define x '(_ . #(_ 1)))
      (let loop ((form x))
	(let ((head (cadr form))
	      (body (cddr form)) )
	  (cond ((not (pair? head))
		 (##sys#check-syntax 'define form '(_ variable . #(_ 0 1)))
                 (let ((name (or (getp head '##core#macro-alias) head)))
                   (##sys#register-export name (##sys#current-module)))
		 (when (c (r 'define) head)
		   (chicken.syntax#defjam-error x))
		 `(##core#begin
		    (##core#ensure-toplevel-definition ,head)
		    (##core#set!
		     ,head
		     ,(if (pair? body) (car body) '(##core#undefined)))))
		((pair? (car head))
		 (##sys#check-syntax 'define form '(_ (_ . lambda-list) . #(_ 1)))
		 (loop (chicken.syntax#expand-curried-define head body '()))) ;XXX '() should be se
		(else
		 (##sys#check-syntax 'define form '(_ (variable . lambda-list) . #(_ 1)))
		 (loop (list (car x) (car head) `(##core#lambda ,(cdr head) ,@body)))))))))))

(set! chicken.syntax#define-syntax-definition
  (##sys#extend-macro-environment
   'define-syntax
   '()
   (##sys#er-transformer
    (lambda (form r c)
      (##sys#check-syntax 'define-syntax form '(_ variable _))
      (let ((head (cadr form))
	    (body (caddr form)))
	(let ((name (or (getp head '##core#macro-alias) head)))
	  (##sys#register-export name (##sys#current-module)))
	(when (c (r 'define-syntax) head)
	  (chicken.syntax#defjam-error form))
	`(##core#define-syntax ,head ,body))))))

(##sys#extend-macro-environment
 'let
 '()
 (##sys#er-transformer
  (lambda (x r c)
    (cond ((and (pair? (cdr x)) (symbol? (cadr x)))
	   (##sys#check-syntax 'let x '(_ variable #((variable _) 0) . #(_ 1)))
           (check-for-multiple-bindings (caddr x) x "let"))
	  (else
	   (##sys#check-syntax 'let x '(_ #((variable _) 0) . #(_ 1)))
           (check-for-multiple-bindings (cadr x) x "let")))
    `(##core#let ,@(cdr x)))))

(##sys#extend-macro-environment
 'letrec
 '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'letrec x '(_ #((variable _) 0) . #(_ 1)))
    (check-for-multiple-bindings (cadr x) x "letrec")
    `(##core#letrec ,@(cdr x)))))

(##sys#extend-macro-environment
 'let-syntax
 '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'let-syntax x '(_ #((variable _) 0) . #(_ 1)))
    (check-for-multiple-bindings (cadr x) x "let-syntax")
    `(##core#let-syntax ,@(cdr x)))))

(##sys#extend-macro-environment
 'letrec-syntax
 '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'letrec-syntax x '(_ #((variable _) 0) . #(_ 1)))
    (check-for-multiple-bindings (cadr x) x "letrec-syntax")
    `(##core#letrec-syntax ,@(cdr x)))))

(##sys#extend-macro-environment
 'set!
 '()
 (##sys#er-transformer
  (lambda (x r c)
    (##sys#check-syntax 'set! x '(_ _ _))
    (let ((dest (cadr x))
	  (val (caddr x)))
      (cond ((pair? dest)
	     `((##sys#setter ,(car dest)) ,@(cdr dest) ,val))
	    (else `(##core#set! ,dest ,val)))))))

(##sys#extend-macro-environment
 'and
 '()
 (##sys#er-transformer
  (lambda (form r c)
    (let ((body (cdr form)))
      (if (null? body)
	  #t
	  (let ((rbody (cdr body))
		(hbody (car body)) )
	    (if (null? rbody)
		hbody
		`(##core#if ,hbody (,(r 'and) ,@rbody) #f) ) ) ) ) ) ) )

(##sys#extend-macro-environment
 'or
 '()
 (##sys#er-transformer
  (lambda (form r c)
    (let ((body (cdr form)))
     (if (null? body)
	 #f
	 (let ((rbody (cdr body))
	       (hbody (car body)))
	   (if (null? rbody)
	       hbody
	       (let ((tmp (r 'tmp)))
		 `(##core#let ((,tmp ,hbody))
		    (##core#if ,tmp ,tmp (,(r 'or) ,@rbody)) ) ) ) ) ) ) ) ) )

(##sys#extend-macro-environment
 'cond
 '()
 (##sys#er-transformer
  (lambda (form r c)
    (let ((body (cdr form))
	  (%=> (r '=>))
	  (%or (r 'or))
	  (%else (r 'else)))
      (let expand ((clauses body) (else? #f))
	(if (not (pair? clauses))
	    '(##core#undefined)
	    (let ((clause (car clauses))
		  (rclauses (cdr clauses)) )
	      (##sys#check-syntax 'cond clause '#(_ 1))
	      (cond (else?
		     (##sys#warn
		      (chicken.format#sprintf "clause following `~S' clause in `cond'" else?)
		      (strip-syntax clause))
		     (expand rclauses else?)
		     '(##core#begin))
		    ((or (c %else (car clause))
                         (eq? #t (car clause))
                         ;; Like "constant?" from support.scm
                         (number? (car clause))
                         (char? (car clause))
                         (string? (car clause))
                         (eof-object? (car clause))
                         (bytevector? (car clause))
                         (bwp-object? (car clause))
                         (vector? (car clause))
                         (##sys#srfi-4-vector? (car clause))
                         (and (pair? (car clause))
                              (c (r 'quote) (caar clause))))
		     (expand rclauses (strip-syntax (car clause)))
		     (cond ((and (fx= (length clause) 3)
				 (c %=> (cadr clause)))
			    `(,(caddr clause) ,(car clause)))
			   ((pair? (cdr clause))
			    `(##core#begin ,@(cdr clause)))
			   ((c %else (car clause))
			    `(##core#undefined))
			   (else (car clause))))
		    ((null? (cdr clause))
		     `(,%or ,(car clause) ,(expand rclauses #f)))
		    ((and (fx= (length clause) 3)
			  (c %=> (cadr clause)))
		     (let ((tmp (r 'tmp)))
		       `(##core#let ((,tmp ,(car clause)))
				    (##core#if ,tmp
					       (,(caddr clause) ,tmp)
					       ,(expand rclauses #f) ) ) ) )
		    ((and (fx= (length clause) 4)
			  (c %=> (caddr clause)))
		     (let ((tmp (r 'tmp)))
		       `(##sys#call-with-values
			 (##core#lambda () ,(car clause))
			 (##core#lambda
			  ,tmp
			  (if (##sys#apply ,(cadr clause) ,tmp)
			      (##sys#apply ,(cadddr clause) ,tmp)
			      ,(expand rclauses #f) ) ) ) ) )
		    (else `(##core#if ,(car clause)
				      (##core#begin ,@(cdr clause))
				      ,(expand rclauses #f) ) ) ) ) ) ) ) ) ) )

(##sys#extend-macro-environment
 'case
 '((eqv? . scheme#eqv?))
 (##sys#er-transformer
  (lambda (form r c)
    (##sys#check-syntax 'case form '(_ _ . #(_ 0)))
    (let ((exp (cadr form))
	  (body (cddr form)) )
      (let ((tmp (r 'tmp))
	    (%or (r 'or))
	    (%=> (r '=>))
	    (%eqv? (r 'eqv?))
	    (%else (r 'else)))
	`(let ((,tmp ,exp))
	   ,(let expand ((clauses body) (else? #f))
	      (if (not (pair? clauses))
		  '(##core#undefined)
		  (let ((clause (car clauses))
			(rclauses (cdr clauses)) )
		    (##sys#check-syntax 'case clause '#(_ 1))
		    (cond (else?
			   (##sys#warn
			    "clause following `else' clause in `case'"
			    (strip-syntax clause))
			   (expand rclauses #t)
			   '(##core#begin))
			  ((c %else (car clause))
			   (expand rclauses #t)
			   (cond ((null? (cdr clause))
				  `(##core#undefined))
				 ((and (fx= (length clause) 3) ; (else => expr)
				       (c %=> (cadr clause)))
				  `(,(caddr clause) ,tmp))
				 (else
				  `(##core#begin ,@(cdr clause)))))
			  (else
			   `(##core#if (,%or ,@(##sys#map
						(lambda (x) `(,%eqv? ,tmp ',x))
						(car clause)))
				       ,(if (and (fx= (length clause) 3) ; ((...) => expr)
						 (c %=> (cadr clause)))
					    `(,(caddr clause) ,tmp)
					    `(##core#begin ,@(cdr clause)))
				       ,(expand rclauses #f) ) ) ) ) ) ) ) ) ) ) ) )

(##sys#extend-macro-environment
 'let*
 '()
 (##sys#er-transformer
  (lambda (form r c)
    (##sys#check-syntax 'let* form '(_ #((variable _) 0) . #(_ 1)))
    (let ((bindings (cadr form))
	  (body (cddr form)) )
      (let expand ((bs bindings))
	(if (eq? bs '())
	    `(##core#let () ,@body)
	    `(##core#let (,(car bs)) ,(expand (cdr bs))) ) ) ) ) ) )

(##sys#extend-macro-environment
 'do
 '()
 (##sys#er-transformer
  (lambda (form r c)
    (##sys#check-syntax 'do form '(_ #((variable _ . #(_)) 0) . #(_ 1)))
    (let ((bindings (cadr form))
	  (test (caddr form))
	  (body (cdddr form))
	  (dovar (r 'doloop)))
      `(##core#let
	,dovar
	,(##sys#map (lambda (b) (list (car b) (car (cdr b)))) bindings)
	(##core#if ,(car test)
		   ,(let ((tbody (cdr test)))
		      (if (eq? tbody '())
			  '(##core#undefined)
			  `(##core#begin ,@tbody) ) )
		   (##core#begin
		    ,(if (eq? body '())
			 '(##core#undefined)
			 `(##core#let () ,@body) )
		    (##core#app
		     ,dovar ,@(##sys#map (lambda (b)
					   (if (eq? (cdr (cdr b)) '())
					       (car b)
					       (car (cdr (cdr b))) ) )
					 bindings) ) ) ) ) ) ) ) )

(##sys#extend-macro-environment
 'quasiquote
 '()
 (##sys#er-transformer
  (lambda (form r c)
    (let ((%quasiquote (r 'quasiquote))
	  (%unquote (r 'unquote))
	  (%unquote-splicing (r 'unquote-splicing)))
      (define (walk x n) (simplify (walk1 x n)))
      (define (walk1 x n)
	(cond ((vector? x)
	       `(##sys#list->vector ,(walk (vector->list x) n)) )
	      ((not (pair? x)) `(##core#quote ,x))
	      (else
	       (let ((head (car x))
		     (tail (cdr x)))
		 (cond ((c %unquote head)
                        (cond ((eq? n 0)
                               (##sys#check-syntax 'unquote x '(_ _))
                               (car tail))
                              (else (list '##sys#cons `(##core#quote ,%unquote)
                                          (walk tail (fx- n 1)) ) )))
		       ((c %quasiquote head)
			(list '##sys#cons `(##core#quote ,%quasiquote)
                              (walk tail (fx+ n 1)) ) )
		       ((and (pair? head) (c %unquote-splicing (car head)))
                        (cond ((eq? n 0)
                               (##sys#check-syntax 'unquote-splicing head '(_ _))
                               `(##sys#append ,(cadr head) ,(walk tail n)))
                              (else
                               `(##sys#cons
                                 (##sys#cons (##core#quote ,%unquote-splicing)
                                             ,(walk (cdr head) (fx- n 1)) )
                                 ,(walk tail n)))))
		       (else
			`(##sys#cons ,(walk head n) ,(walk tail n)) ) ) ) ) ) )
      (define (simplify x)
	(cond ((chicken.syntax#match-expression x '(##sys#cons a (##core#quote ())) '(a))
	       => (lambda (env) (simplify `(##sys#list ,(cdr (assq 'a env))))) )
	      ((chicken.syntax#match-expression x '(##sys#cons a (##sys#list . b)) '(a b))
	       => (lambda (env)
		    (let ((bxs (assq 'b env)))
		      (if (fx< (length bxs) 32)
			  (simplify `(##sys#list ,(cdr (assq 'a env))
						 ,@(cdr bxs) ) )
			  x) ) ) )
	      ((chicken.syntax#match-expression x '(##sys#append a (##core#quote ())) '(a))
	       => (lambda (env) (cdr (assq 'a env))) )
	      (else x) ) )
      (##sys#check-syntax 'quasiquote form '(_ _))
      (walk (cadr form) 0) ) ) ) )

(##sys#extend-macro-environment
 'delay
 '()
 (##sys#er-transformer
  (lambda (form r c)
    (##sys#check-syntax 'delay form '(_ _))
      `(##sys#make-promise 
         (##core#lambda () 
           (##sys#make-promise
             (##sys#call-with-values (##core#lambda () ,(cadr form)) ##sys#list)))))))

(##sys#extend-macro-environment
 'syntax-error
 '()
 (##sys#er-transformer
  (lambda (form r c)
    (##sys#check-syntax 'syntax-error form '(_ string . #(_ 0)))
    (apply ##sys#syntax-error (cadr form) (cddr form)))))

;;; syntax-rules

(include "synrules.scm")

(macro-subset me0)))

;;; the base macro environment (the old "scheme", essentially)
;;; TODO: Remove this

(define ##sys#default-macro-environment
  (fixup-macro-environment (##sys#macro-environment)))

(define ##sys#meta-macro-environment (make-parameter (##sys#macro-environment)))

;; register features

(register-feature! 'srfi-0 'srfi-46 'srfi-61 'srfi-87)
