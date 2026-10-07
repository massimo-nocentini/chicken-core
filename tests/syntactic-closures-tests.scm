;;;; syntactic-closures-tests.scm - syntactic closures (Bawden & Rees 1988)
;;;; Expected values follow the paper and MIT Scheme unless marked [CHICKEN].
;;;; Every test defines its own macros; names never clash across tests.

(import (chicken base) (chicken syntax) (chicken condition))

(define *pass* 0)
(define *fail* 0)
(define-syntax check
  (syntax-rules ()
    ((_ name expected expr)
     (let ((v (handle-exceptions e
                  (list 'error ((condition-property-accessor 'exn 'message #f) e)
                        ((condition-property-accessor 'exn 'arguments '()) e))
                (call-with-values (lambda () expr) (lambda (x . _) x)))))
       (if (equal? v expected)
           (begin (set! *pass* (+ *pass* 1)) (print "ok   " 'name))
           (begin (set! *fail* (+ *fail* 1))
                  (print "FAIL " 'name " got: " v " expected: " expected)))))))

;;; ------------------------------------------------------------------
;;; Paper section 1/3: push, or, catch and the four hygiene cases

;; T01 case 1: macro-introduced free reference (cons) is not captured
(define-syntax push-01
  (sc-macro-transformer
   (lambda (exp env)
     (let ((obj-exp (make-syntactic-closure env '() (cadr exp)))
           (list-var (make-syntactic-closure env '() (caddr exp))))
       `(set! ,list-var (cons ,obj-exp ,list-var))))))
(check t01-push-cons-shadowed '(foo)
  (let ((stack '()))
    (let ((cons 6))
      (push-01 'foo stack))
    stack))

;; T02 case 2: macro-introduced binder (temp) does not capture user's temp
(define-syntax or-02
  (sc-macro-transformer
   (lambda (exp env)
     (let ((exp-1 (make-syntactic-closure env '() (cadr exp)))
           (exp-2 (make-syntactic-closure env '() (caddr exp))))
       `((lambda (temp) (if temp temp ,exp-2)) ,exp-1)))))
(check t02-or-temp 5
  (let ((temp 5)) (or-02 (memq 'x '(a b)) temp)))

;; T03 case 3: local keyword rebinding of set! does not capture push's set!
(define-syntax push-03
  (sc-macro-transformer
   (lambda (exp env)
     (let ((obj (close-syntax (cadr exp) env))
           (lv (close-syntax (caddr exp) env)))
       `(set! ,lv (cons ,obj ,lv))))))
(check t03-keyword-capture-let-syntax '((foo) ())
  (let ((stack '()) (flags '()))
    (let-syntax ((set! (syntax-rules ()
                         ((_ v e) (set! flags (cons 'v flags))))))
      (push-03 'foo stack))
    (list stack flags)))

;; T04 case 4 ("contorted"): the macro's auxiliary keyword `use` does not
;; capture the user's variable `use` in test/x/y
(define-syntax contorted-04
  (sc-macro-transformer
   (lambda (form env)
     (let ((test (close-syntax (cadr form) env))
           (x (close-syntax (caddr form) env))
           (y (close-syntax (cadddr form) env)))
       `(let-syntax ((use (syntax-rules () ((_ op a b) (op a b)))))
          (if ,test (use and ,x ,y) (use or ,x ,y)))))))
(check t04-contorted '(user-use user-use b)
  (let ((use (lambda (a b) 'user-use)))
    (list (contorted-04 #t #t (use 1 2))
          (contorted-04 #f (use 3 4) #f)
          (contorted-04 (use 5 6) 'a 'b))))

;; T05 catch: free-names list deliberately lets `throw` be captured
(define-syntax catch-05
  (sc-macro-transformer
   (lambda (exp env)
     (let ((body (make-syntactic-closure env '(throw) (cadr exp))))
       `(call-with-current-continuation (lambda (throw) ,body))))))
(check t05-catch 'x (catch-05 (+ 5 (throw 'x))))
(check t05b-catch-normal-return 7 (catch-05 (+ 5 2)))

;; T06 catch: a `throw` introduced by another (hygienic) macro is NOT in
;; the free list sense the same name, so it is not captured
(define-syntax catch-06
  (sc-macro-transformer
   (lambda (exp env)
     (let ((body (make-syntactic-closure env '(throw) (cadr exp))))
       `(call-with-current-continuation (lambda (throw) ,body))))))
(check t06-catch-vs-hygienic-throw '((outer 1) 2)
  (let ((throw (lambda (v) (list 'outer v))))
    (let-syntax ((sr-throw (syntax-rules () ((_ v) (throw v)))))
      (list (catch-06 (sr-throw 1))
            (catch-06 (throw 2))))))

;;; ------------------------------------------------------------------
;;; Paper section 4.4: local macros close over the definition environment

;; T07 (let ((adjoin cons)) (with-macro push ...) (let ((adjoin +)) (push ...)))
(define (t07 n m)
  (let ((sum-stack '()))
    (let ((adjoin cons))
      (let-syntax ((push (sc-macro-transformer
                          (lambda (form env)
                            (let ((frob (close-syntax (cadr form) env))
                                  (stack (close-syntax (caddr form) env)))
                              `(set! ,stack (adjoin ,frob ,stack)))))))
        (let ((adjoin +))
          (push (adjoin n m) sum-stack))))
    sum-stack))
(check t07-with-macro-adjoin '(3) (t07 1 2))

;; T08 with-macro-rec: letrec-syntax, recursive n-ary or with temp
(check t08-letrec-syntax-recursive-or 7
  (letrec-syntax
      ((my-or (sc-macro-transformer
               (lambda (form env)
                 (if (null? (cdr form))
                     #f
                     (let ((e (close-syntax (cadr form) env))
                           (rest (make-syntactic-closure-list env '() (cddr form))))
                       `(let ((temp ,e)) (if temp temp (my-or ,@rest)))))))))
    (let ((temp 7)) (my-or #f #f temp))))

;;; ------------------------------------------------------------------
;;; MIT reference-manual examples

;; T09 loop with exit (sc, free name `exit`); user's f is not captured
(define-syntax loop-09
  (sc-macro-transformer
   (lambda (exp env)
     (let ((body (cdr exp)))
       `(call-with-current-continuation
         (lambda (exit)
           (let f ()
             ,@(map (lambda (e) (make-syntactic-closure env '(exit) e)) body)
             (f))))))))
(check t09-loop-exit '(5 user-f)
  (let ((f 'user-f) (i 0))
    (loop-09 (set! i (+ i 1))
             (if (= i 5) (exit (list i f))))))

;; T10 loop-until: raw usage identifier used as binder in sc output, body
;; closed with that identifier free
(define-syntax loop-until-10
  (sc-macro-transformer
   (lambda (exp env)
     (let ((id (cadr exp)) (init (caddr exp)) (test (cadddr exp))
           (return (cadddr (cdr exp))) (step (cadddr (cddr exp)))
           (close (lambda (e free) (make-syntactic-closure env free e))))
       `(letrec ((loop (lambda (,id)
                         (if ,(close test (list id))
                             ,(close return (list id))
                             (loop ,(close step (list id)))))))
          (loop ,(close init '())))))))
(check t10-loop-until 40 (loop-until-10 i 0 (> i 3) (* i 10) (+ i 1)))
;; T11 macro's `loop` does not capture user's loop; only `i` is free
(check t11-loop-until-hygiene '(3 3)
  (let ((loop 3)) (loop-until-10 i 0 (>= i loop) (list i loop) (+ i 1))))

;; T12 rsc swap!: introduced names closed in the macro environment
(define-syntax swap!-12
  (rsc-macro-transformer
   (lambda (form env)
     (let ((a (cadr form)) (b (caddr form))
           (tmp (close-syntax 'tmp env))
           (%let (close-syntax 'let env))
           (%set! (close-syntax 'set! env)))
       `(,%let ((,tmp ,a))
          (,%set! ,a ,b)
          (,%set! ,b ,tmp))))))
(check t12-rsc-swap '(2 1)
  (let ((tmp 1) (other 2)) (swap!-12 tmp other) (list tmp other)))
;; T13 ... even where the user shadows let and set! as variables
(check t13-rsc-swap-shadowed-keywords '(b a)
  (let ((x 'a) (y 'b))
    (let ((let #f) (set! #f)) (swap!-12 x y))
    (list x y)))

;; T14 rsc: raw symbols in the output are interpreted in the usage
;; environment, so an intentional capture (anaphoric `it`) is trivial
(define-syntax aif-14
  (rsc-macro-transformer
   (lambda (f env)
     `(,(close-syntax 'let env) ((it ,(cadr f)))
       (,(close-syntax 'if env) it ,(caddr f) ,(cadddr f))))))
(check t14-rsc-anaphoric '(2 3) (aif-14 (memq 2 '(1 2 3)) it 'no))

;; T15 the same with sc + free names
(define-syntax aif-15
  (sc-macro-transformer
   (lambda (f env)
     `(let ((it ,(close-syntax (cadr f) env)))
        (if it
            ,(make-syntactic-closure env '(it) (caddr f))
            ,(make-syntactic-closure env '(it) (cadddr f)))))))
(check t15-sc-anaphoric-free-names '((2 3) no)
  (list (aif-15 (memq 2 '(1 2 3)) it 'no)
        (aif-15 (memq 9 '(1 2 3)) it 'no)))

;;; ------------------------------------------------------------------
;;; identifier=? and literal matching

;; T16-T18 cond-like macro recognising `else` with identifier=? against the
;; macro environment obtained via capture-syntactic-environment
(define-syntax my-cond-16
  (sc-macro-transformer
   (lambda (form env)
     (capture-syntactic-environment
      (lambda (menv)
        (let loop ((clauses (cdr form)))
          (if (null? clauses)
              '(if #f #f)
              (let* ((c (car clauses))
                     (body (make-syntactic-closure-list env '() (cdr c))))
                (if (and (identifier? (car c))
                         (identifier=? env (car c) menv 'else))
                    `(begin ,@body)
                    `(if ,(close-syntax (car c) env)
                         (begin ,@body)
                         ,(loop (cdr clauses))))))))))))
(check t16-cond-else 2 (my-cond-16 (#f 1) (else 2)))
(check t17-cond-else-shadowed 2 (let ((else #f)) (my-cond-16 (else 1) (#t 2))))
(check t18-cond-if-shadowed 3 (let ((if list) (begin vector)) (my-cond-16 (#f 1) (else 3))))

;; T19/T20 literal matcher in the style of the egg's cond-expand
(define-syntax my-feature-case-19
  (sc-macro-transformer
   (lambda (form env)
     (capture-syntactic-environment
      (lambda (tenv)
        (define (every p l) (or (null? l) (and (p (car l)) (every p (cdr l)))))
        (define (any p l) (and (pair? l) (or (p (car l)) (any p (cdr l)))))
        (define (lit? id sym)
          (and (identifier? id) (identifier=? env id tenv sym)))
        (define (test fx)
          (cond ((identifier? fx) (memq (identifier->symbol fx) '(foo bar)))
                ((not (pair? fx)) #f)
                ((lit? (car fx) 'and) (every test (cdr fx)))
                ((lit? (car fx) 'or) (any test (cdr fx)))
                ((lit? (car fx) 'not) (not (test (cadr fx))))
                (else #f)))
        (let expand ((cls (cdr form)))
          (cond ((null? cls) '(if #f #f))
                ((lit? (caar cls) 'else)
                 `(begin ,@(make-syntactic-closure-list env '() (cdar cls))))
                ((test (caar cls))
                 `(begin ,@(make-syntactic-closure-list env '() (cdar cls))))
                (else (expand (cdr cls))))))))))
(check t19-feature-literals '(yes no a)
  (list (my-feature-case-19 ((and foo (not baz)) 'yes) (else 'no))
        (my-feature-case-19 ((or baz qux) 'yes) (else 'no))
        (my-feature-case-19 ((not baz) 'a) (else 'b))))
(check t20-feature-literal-shadowed 'b
  (let ((not (lambda (x) x)))
    (my-feature-case-19 ((not baz) 'a) (else 'b))))

;; T21 identifier? / identifier->symbol / predicates, probed at expansion time
(define-syntax probe-21
  (sc-macro-transformer
   (lambda (f env)
     (let ((c (close-syntax 'a env)))
       `(quote ,(list (identifier? 'a)
                      (identifier? c)
                      (identifier? (close-syntax c env))
                      (identifier? (close-syntax '(a) env))
                      (identifier? 5)
                      (identifier? "a")
                      (identifier->symbol c)
                      (identifier->symbol (close-syntax c env))
                      (syntactic-closure? c)
                      (syntactic-closure? 'a)
                      (syntactic-environment? env)
                      (syntactic-environment? 'a)))))))
(check t21-identifier-predicates '(#t #t #t #f #f #f a a #t #f #t #f) (probe-21))

;; T22 identifier=? on plain and closed identifiers, shadowing respected
(define-syntax same-22
  (sc-macro-transformer
   (lambda (f env)
     (capture-syntactic-environment
      (lambda (menv)
        `(quote ,(list (identifier=? env (close-syntax 'x env) env 'x)
                       (identifier=? env (cadr f) menv 'car)
                       (identifier=? env 'a env 'b)
                       (identifier=? menv 'if env (close-syntax 'if menv)))))))))
(check t22a-identifier=?-toplevel '(#t #t #f #t) (same-22 car))
(check t22b-identifier=?-shadowed '(#t #f #f #t) (let ((car cdr)) (same-22 car)))

;; T23 identifier->symbol of an identifier renamed by syntax-rules
(define-syntax sym-of-23
  (sc-macro-transformer
   (lambda (f env) `(quote ,(identifier->symbol (cadr f))))))
(define-syntax via-sr-23 (syntax-rules () ((_) (sym-of-23 foo))))
(check t23-identifier->symbol-of-alias #t (eq? (via-sr-23) 'foo))

;;; ------------------------------------------------------------------
;;; Definitions

;; T24 define-record as in the egg: generated names are interpreted in the
;; macro environment, which at top level is the global environment
(define-syntax define-record-24
  (sc-macro-transformer
   (lambda (form env)
     (define (id->string x) (symbol->string (identifier->symbol x)))
     (define (mk . parts)
       (string->symbol
        (apply string-append
               (map (lambda (p) (if (string? p) p (id->string p))) parts))))
     (let* ((name (cadr form)) (slots (cddr form)) (tag (identifier->symbol name)))
       (capture-syntactic-environment
        (lambda (xenv)
          `(begin
             (define ,(mk "make-" name)
               (lambda ,slots (,(close-syntax 'vector xenv) ',tag ,@slots)))
             (define ,(mk name "?")
               (lambda (x) (and (vector? x) (eq? (vector-ref x 0) ',tag))))
             ,@(let loop ((slots slots) (i 1))
                 (if (null? slots)
                     '()
                     (cons `(begin
                              (define ,(mk name "-" (car slots))
                                (lambda (x) (vector-ref x ,i)))
                              (define ,(mk name "-" (car slots) "-set!")
                                (lambda (x v) (vector-set! x ,i v))))
                           (loop (cdr slots) (+ i 1))))))))))))
(define-record-24 point24 x y)
(check t24-define-record-toplevel '(#t 10 2 #f)
  (let ((p (make-point24 1 2)) (vector list))
    (point24-x-set! p 10)
    (list (point24? p) (point24-x p) (point24-y p) (point24? 'nope))))

;; T25 same, but generated names closed in the usage env so it also works
;; as an internal definition
(define-syntax define-record-25
  (sc-macro-transformer
   (lambda (form env)
     (define (mk . parts)
       (close-syntax
        (string->symbol
         (apply string-append
                (map (lambda (p) (if (string? p) p (symbol->string (identifier->symbol p))))
                     parts)))
        env))
     (let* ((name (cadr form)) (slots (cddr form)) (tag (identifier->symbol name)))
       `(begin
          (define ,(mk "make-" name) (lambda ,slots (vector ',tag ,@slots)))
          (define ,(mk name "?")
            (lambda (x) (and (vector? x) (eq? (vector-ref x 0) ',tag))))
          ,@(let loop ((slots slots) (i 1))
              (if (null? slots)
                  '()
                  (cons `(define ,(mk name "-" (car slots))
                           (lambda (x) (vector-ref x ,i)))
                        (loop (cdr slots) (+ i 1))))))))))
(check t25-define-record-internal '(#t 1 2)
  (let ()
    (define-record-25 pt x y)
    (define p (make-pt 1 2))
    (list (pt? p) (pt-x p) (pt-y p))))

;; T26 macro expanding into several internal defines (names from the user)
(define-syntax def-two-26
  (sc-macro-transformer
   (lambda (f env)
     `(begin (define ,(close-syntax (cadr f) env) 1)
             (define ,(close-syntax (caddr f) env) 2)))))
(check t26-internal-defines 3 (let () (def-two-26 a b) (+ a b)))

;; T27 an internal define of a macro-environment name is invisible to the user
(define foo27 'global)
(define-syntax def-foo-27
  (sc-macro-transformer (lambda (f env) '(define foo27 'macro))))
(check t27-hygienic-internal-define 'global (let () (def-foo-27) foo27))

;; T28 at top level a macro-environment name defines the global of that name
(define-syntax def-foo-28
  (sc-macro-transformer (lambda (f env) '(define foo28 42))))
(def-foo-28)
(check t28-toplevel-define-from-macro-env 42 foo28)

;; T29 closed identifier as the name of a procedure define, in a body
(define-syntax defn-double-29
  (sc-macro-transformer
   (lambda (f env)
     `(define (,(close-syntax (cadr f) env) x) (* 2 x)))))
(check t29-closed-define-name 42 (let ((x 100)) (defn-double-29 dbl) (dbl 21)))

;;; ------------------------------------------------------------------
;;; Composition of macros

;; T30 sc macro expanding into another sc macro
(define-syntax my-if-not-30
  (sc-macro-transformer
   (lambda (f env)
     `(if ,(close-syntax (cadr f) env) #f ,(close-syntax (caddr f) env)))))
(define-syntax my-unless-30
  (sc-macro-transformer
   (lambda (f env)
     `(my-if-not-30 ,(close-syntax (cadr f) env)
                    (begin ,@(make-syntactic-closure-list env '() (cddr f)))))))
(check t30-sc-into-sc '(1 #f)
  (let ((if list) (begin vector) (my-if-not-30 'shadow))
    (list (my-unless-30 #f 1) (my-unless-30 #t 1))))

;; T31 closures passed to another sc macro are still identifiers there and
;; compare correctly with identifier=?
(define-syntax inner-31
  (sc-macro-transformer
   (lambda (f env)
     (capture-syntactic-environment
      (lambda (menv)
        `(quote ,(list (identifier? (cadr f))
                       (identifier->symbol (cadr f))
                       (identifier=? env (caddr f) menv 'else))))))))
(define-syntax outer-31
  (sc-macro-transformer
   (lambda (f env)
     `(inner-31 ,(close-syntax (cadr f) env) ,(close-syntax (caddr f) env)))))
(check t31-closures-to-nested-macro '(#t x #t) (outer-31 x else))
(check t31b-closures-to-nested-macro-shadowed '(#t x #f)
  (let ((else 1)) (outer-31 x else)))

;; T32 macro-defining macro (definition at top level)
(define-syntax def-const-macro-32
  (sc-macro-transformer
   (lambda (form env)
     `(define-syntax ,(close-syntax (cadr form) env)
        (sc-macro-transformer (lambda (f e) ,(caddr form)))))))
(def-const-macro-32 five-32 5)
(check t32-macro-defining-macro 5 (five-32))

;; T33 macro-defining macro: inner macro refers to the variable named at the
;; definition site, regardless of shadowing at the use site
(define x33 10)
(define-syntax define-getter-33
  (sc-macro-transformer
   (lambda (form env)
     `(define-syntax ,(close-syntax (cadr form) env)
        (sc-macro-transformer (lambda (f e) ',(caddr form)))))))
(define-getter-33 get-x33 x33)
(check t33-macro-defining-macro 10 (get-x33))
(check t33b-macro-defining-macro-internal 1
  (let ((y 1))
    (define-getter-33 get-y y)
    (let ((y 2)) (get-y))))

;; T34 sc macro used from a syntax-rules template (alias input) with a user
;; variable that has the macro's internal temp name
(define-syntax or2-34
  (sc-macro-transformer
   (lambda (f env)
     `(let ((temp ,(close-syntax (cadr f) env)))
        (if temp temp ,(close-syntax (caddr f) env))))))
(define-syntax sr-or-34 (syntax-rules () ((_ a b) (or2-34 a b))))
(check t34-sc-under-syntax-rules 'user (let ((temp 'user)) (sr-or-34 #f temp)))

;; T35 sc and er macros interoperate in both directions
(define-syntax er-swap-35
  (er-macro-transformer
   (lambda (f r c)
     (let ((a (cadr f)) (b (caddr f)) (t (r 'tmp)))
       `(,(r 'let) ((,t ,a)) (,(r 'set!) ,a ,b) (,(r 'set!) ,b ,t))))))
(define-syntax sc-rotate-35
  (sc-macro-transformer
   (lambda (f env)
     (let ((a (close-syntax (cadr f) env))
           (b (close-syntax (caddr f) env))
           (c (close-syntax (cadddr f) env)))
       `(begin (er-swap-35 ,a ,b) (er-swap-35 ,b ,c))))))
(check t35-sc-calls-er '(2 3 1)
  (let ((tmp 1) (t 2) (let 3))
    (sc-rotate-35 tmp t let)
    (list tmp t let)))

;; T36 recursive top-level sc macro (n-ary and)
(define-syntax my-and-36
  (sc-macro-transformer
   (lambda (f env)
     (cond ((null? (cdr f)) #t)
           ((null? (cddr f)) (close-syntax (cadr f) env))
           (else `(if ,(close-syntax (cadr f) env)
                      (my-and-36 ,@(make-syntactic-closure-list env '() (cddr f)))
                      #f))))))
(check t36-recursive-toplevel '(3 #f #t)
  (let ((if 'shadow)) (list (my-and-36 1 2 3) (my-and-36 1 #f 3) (my-and-36))))

;;; ------------------------------------------------------------------
;;; set!, quote, vectors

;; T37 closed identifier as set! target; macro's + is the global one
(define-syntax inc!-37
  (sc-macro-transformer
   (lambda (f env)
     (let ((v (close-syntax (cadr f) env)))
       `(set! ,v (+ ,v 1))))))
(check t37-set!-closed-target 2 (let ((+ -) (n 1)) (inc!-37 n) n))

;; T38 set! of a macro-environment variable, not the user's
(define counter38 0)
(define (global-counter38) counter38)
(define-syntax bump!-38
  (sc-macro-transformer (lambda (f env) '(set! counter38 (+ counter38 1)))))
(check t38-set!-macro-env-target 1 (begin (bump!-38) counter38))

;; T39 quote strips syntactic closures, also inside nested lists and vectors
(define-syntax q-39
  (sc-macro-transformer
   (lambda (f env)
     `(quote (a ,(close-syntax (cadr f) env)
                #(b ,(close-syntax 'c env) ,(close-syntax '(d e) env)))))))
(check t39-closures-in-quote '(a x #(b c (d e))) (q-39 x))
(check t39b-quoted-symbols-are-plain #t
  (let ((v (q-39 x))) (and (eq? (car v) 'a) (eq? (cadr v) 'x))))

;; T40 rsc: quote of a closed identifier yields the plain symbol
(define-syntax q-40
  (rsc-macro-transformer
   (lambda (f env) `(,(close-syntax 'quote env) ,(close-syntax 'foo env)))))
(check t40-quote-closed-identifier #t (eq? (q-40) 'foo))

;; T41 a self-evaluating vector constant produced by an sc macro
(define-syntax vec-41
  (sc-macro-transformer (lambda (f env) '#(a b 1))))
(check t41-vector-literal #(a b 1) (vec-41))

;; T42 closing a vector form of the user
(define-syntax id-42
  (sc-macro-transformer (lambda (f env) (close-syntax (cadr f) env))))
(check t42-closed-vector-input #(1 x) (id-42 #(1 x)))
(check t42b-closed-whole-form 6 (let ((+ *)) (id-42 (+ 2 3 1))))

;;; ------------------------------------------------------------------
;;; Closing closures, free names, capture-syntactic-environment

;; T43 free name inside a closure resolves where the closure is placed
(define-syntax m-43
  (sc-macro-transformer
   (lambda (f env)
     `(let ((x 'macro)) ,(make-syntactic-closure env '(x) (cadr f))))))
(check t43-free-name-captured '(macro user)
  (let ((x 'user)) (m-43 (list x (let ((x 'user)) x)))))

;; T44 closing an already-closed form: the inner closure's free name x is
;; resolved by the environment of the OUTER closure (usage), not by the
;; macro's let
(define-syntax m-44
  (sc-macro-transformer
   (lambda (f env)
     (let* ((inner (make-syntactic-closure env '(x) (cadr f)))
            (outer (make-syntactic-closure env '() inner)))
       `(let ((x 'macro)) ,outer)))))
(check t44-reclose-closes-free-names 'user (let ((x 'user)) (m-44 x)))

;; T45 re-closing in a different environment has no effect on an already
;; context-insensitive closure
(define-syntax m-45
  (sc-macro-transformer
   (lambda (f env)
     (capture-syntactic-environment
      (lambda (menv)
        `(let ((x 'macro)) ,(close-syntax (close-syntax 'x env) menv)))))))
(check t45-reclose-in-other-env 'user (let ((x 'user)) (m-45)))

;; T46 free names that do not occur are harmless; closing a constant returns
;; the constant; closing a name that is in its own free list returns the name
(define-syntax m-46
  (sc-macro-transformer
   (lambda (f env)
     `(list ,(make-syntactic-closure env '(zz qq) (cadr f))
            ,(make-syntactic-closure env '() 5)
            ,(if (eq? (make-syntactic-closure env '(y) 'y) 'y) ''same ''different)))))
(check t46-free-names-misc '(4 5 same) (let ((y 4)) (m-46 y)))

;; T47 capture-syntactic-environment gives the env where the form is
;; interpreted: usage env in rsc output, macro env in sc output
(define-syntax rsc-car-47
  (rsc-macro-transformer
   (lambda (f env)
     `(,(capture-syntactic-environment (lambda (e) (close-syntax 'car e))) ,(cadr f)))))
(define-syntax sc-car-47
  (sc-macro-transformer
   (lambda (f env)
     `(,(capture-syntactic-environment (lambda (e) (close-syntax 'car e)))
       ,(close-syntax (cadr f) env)))))
(check t47-capture-env-sc-vs-rsc '((2) 1)
  (let ((car cdr))
    (list (rsc-car-47 '(1 2)) (sc-car-47 '(1 2)))))

;; T48 capture inside a closure closed in the usage env yields the usage env
(define-syntax m-48
  (sc-macro-transformer
   (lambda (f env)
     `(list ,(close-syntax (capture-syntactic-environment
                            (lambda (e) `(,(close-syntax 'car e) '(1 2))))
                           env)
            (car '(1 2))))))
(check t48-capture-in-closure '((2) 1) (let ((car cdr)) (m-48)))

;; T49 closures as lambda binders (rsc), and closed-identifier binders that
;; are the same identifier as their references
(define-syntax with-temp-49
  (rsc-macro-transformer
   (lambda (f env)
     (let ((t (close-syntax 'temp env)))
       `((,(close-syntax 'lambda env) (,t) (,(close-syntax 'list env) ,t ,(cadr f))) 1)))))
(check t49-closed-binder '(1 2) (let ((temp 2)) (with-temp-49 temp)))

;; T50 operator position: a closed keyword or macro name from the user
(define-syntax apply-1-2-50
  (sc-macro-transformer
   (lambda (f env) `(,(close-syntax (cadr f) env) 1 2))))
(check t50-closed-operator '(2 3 (2 1))
  (let-syntax ((rev (syntax-rules () ((_ a b) (list b a)))))
    (list (apply-1-2-50 and) (apply-1-2-50 +) (apply-1-2-50 rev))))

;; T51 quasiquote produced by an sc macro (keywords quasiquote/unquote are
;; macro-environment identifiers)
(define-syntax qq-51
  (sc-macro-transformer
   (lambda (f env)
     (list 'quasiquote (list 1 (list 'unquote (close-syntax (cadr f) env)) 'z)))))
(check t51-quasiquote-output '(1 5 z) (let ((x 5) (unquote 0)) (qq-51 x)))

;; T52 strip-syntactic-closures
(define-syntax strip-52
  (sc-macro-transformer
   (lambda (f env)
     `(quote ,(list (strip-syntactic-closures
                     (list (close-syntax 'a env)
                           (vector (close-syntax 'b env))
                           (close-syntax (list 'c (close-syntax 'd env)) env)))
                    (syntactic-closure?
                     (strip-syntactic-closures (close-syntax 'a env))))))))
(check t52-strip-syntactic-closures '((a #(b) (c d)) #f) (strip-52))

;; T53 errors are signalled at expansion time for bad arguments
(define (expansion-error? form)
  (handle-exceptions e #t (eval form) #f))
(check t53a-bad-env #t
  (expansion-error?
   '(let-syntax ((bad (sc-macro-transformer (lambda (f e) (close-syntax 'x 42)))))
      (bad))))
(check t53b-identifier->symbol-non-identifier #t
  (expansion-error?
   '(let-syntax ((bad (sc-macro-transformer
                       (lambda (f e) (identifier->symbol '(a b))))))
      (bad))))

;;; ------------------------------------------------------------------
;;; Modules

;; T54 exported sc macro referencing a module-private binding
(module sc-mod-54 ((scale-54 secret))   ; CHICKEN: indirect export required
  (import scheme (chicken syntax))
  (define (secret x) (* x 100))
  (define-syntax scale-54
    (sc-macro-transformer
     (lambda (f e) `(secret ,(close-syntax (cadr f) e))))))
(import sc-mod-54)
(check t54-module-private-reference 200 (let ((secret 2)) (scale-54 secret)))

;;; ------------------------------------------------------------------
;;; [CHICKEN] capture-syntactic-environment is eager: its procedure runs
;;; when the output is lowered, before the output's own bindings are
;;; expanded, so identifier=? in the captured environment does not see
;;; them (closures made in it do, see T86).  MIT and chibi would yield
;;; #f here.
(define-syntax lazy-capture-55
  (sc-macro-transformer
   (lambda (f env)
     (capture-syntactic-environment
      (lambda (menv)
        `(let ((x 1))
           ,(capture-syntactic-environment
             (lambda (inner) `(quote ,(identifier=? inner 'x menv 'x))))))))))
(check t55-eager-capture #t (lazy-capture-55))

;;; ------------------------------------------------------------------
;;; [CHICKEN] interaction with the renaming expander

;; T56 identifier=? consults the usage environment before alias
;; properties: an `else' bound by a syntax-rules expansion is not `else'
(define-syntax is-else-56
  (sc-macro-transformer
   (lambda (f env)
     (capture-syntactic-environment
      (lambda (menv) `(quote ,(identifier=? env (cadr f) menv 'else)))))))
(define-syntax bind-else-56 (syntax-rules () ((_ m) (let ((else 1)) (m else)))))
(define-syntax pass-else-56 (syntax-rules () ((_ m) (m else))))
(check t56-identifier=?-alias-bound '(#f #t #t)
  (list (bind-else-56 is-else-56) (pass-else-56 is-else-56) (is-else-56 else)))

;; T57 identifier=? is #f for non-identifiers
(define-syntax nonid-57
  (sc-macro-transformer
   (lambda (f env) `(quote ,(identifier=? env 1 env 1)))))
(check t57-identifier=?-non-identifier #f (nonid-57))

;; T58 compiler syntax: returning the form (rsc) or closing it in the
;; usage environment (sc) declines
(define (dbl-58 x) (list 'runtime x))
(define-compiler-syntax dbl-58
  (rsc-macro-transformer
   (lambda (form env)
     (if (number? (cadr form)) (list 'quote (* 2 (cadr form))) form))))
(define (dbl2-58 x) (list 'runtime x))
(define-compiler-syntax dbl2-58
  (sc-macro-transformer
   (lambda (form env)
     (if (number? (cadr form)) (* 2 (cadr form)) (close-syntax form env)))))
(check t58-compiler-syntax-decline '(runtime 4)
  (let ((y 4)) (dbl-58 y)))
(check t58b-compiler-syntax-decline-sc '(runtime 4)
  (let ((y 4)) (dbl2-58 y)))

;; T59 an sc macro returning its input still reports endless expansion
(check t59-endless-expansion #t
  (expansion-error?
   '(let-syntax ((m (sc-macro-transformer (lambda (f e) f)))) (m))))

;; T60 an environment used after its expansion has returned is an error
;; (closures made while it was alive stay usable, see T86)
(define saved-env-60 (list #f))
(check t60-dead-environment #t
  (begin
    (eval '(let-syntax ((keep (sc-macro-transformer
                               (lambda (f e) (set-car! saved-env-60 e) #t))))
             (keep)))
    (handle-exceptions e #t (close-syntax 'x (car saved-env-60)) #f)))
(check t60b-dead-environment-identifier=? #t
  (handle-exceptions e #t
    (identifier=? (car saved-env-60) 'x (car saved-env-60) 'x)
    #f))

;; T61 keywords and DSSSL markers pass through
(define-syntax kw-61
  (sc-macro-transformer
   (lambda (f env)
     '(list foo: #:bar ((lambda (a #!optional (b 2)) (list a b)) 1)))))
(check t61-keywords-and-optionals '(foo: bar: (1 2)) (kw-61))

;; T62 sc macros exported from a module and used in another one
(module sc-m1-62 (twice-62)
  (import scheme (chicken syntax))
  (define-syntax twice-62
    (sc-macro-transformer
     (lambda (f env)
       (let ((e (close-syntax (cadr f) env)))
         `(begin ,e ,e))))))
(module sc-m2-62 (run-62)
  (import scheme sc-m1-62)
  (define (run-62) (let ((n 0) (begin list)) (twice-62 (set! n (+ n 1))) n)))
(import sc-m2-62)
(check t62-modules 2 (run-62))

;; T63 a raw input identifier in sc output means the macro environment,
;; also when it was renamed by syntax-rules (an alias): like chibi-scheme,
;; the let made by the syntax-rules template does not bind it.  rsc and
;; usage-closed identifiers keep their usage meaning.
(define tmp-63 'global)
(define-syntax sc-raw-63 (sc-macro-transformer (lambda (f env) `(list ,(cadr f)))))
(define-syntax sc-closed-63
  (sc-macro-transformer (lambda (f env) `(list ,(close-syntax (cadr f) env)))))
(define-syntax rsc-raw-63 (rsc-macro-transformer (lambda (f env) `(list ,(cadr f)))))
(define-syntax via-sr-63
  (syntax-rules ()
    ((_) (let ((tmp-63 'local))
           (list (sc-raw-63 tmp-63) (sc-closed-63 tmp-63) (rsc-raw-63 tmp-63))))))
(check t63-raw-alias-in-sc-output '((global) (local) (local)) (via-sr-63))

;; T64 nested closures: the free name of the inner closure is resolved by
;; the outer closure, whose own free name is resolved where it is placed
;; (the paper's filter-syntactic-env composition)
(define-syntax m-64
  (sc-macro-transformer
   (lambda (f env)
     (let* ((inner (make-syntactic-closure env '(y) (cadr f)))
            (outer (make-syntactic-closure env '(y) inner)))
       `(let ((y 'macro-y)) ,outer)))))
(check t64-nested-free-names 'macro-y (let ((y 'user-y)) (m-64 y)))

;; T65 captures (eager) work in any position of the output
(define-syntax cap-quote-65
  (sc-macro-transformer
   (lambda (f e) `(quote (a ,(capture-syntactic-environment (lambda (env) 'b)))))))
(define-syntax cap-let-65
  (sc-macro-transformer
   (lambda (f e)
     `(let ((,(capture-syntactic-environment (lambda (env) 'q)) 1)) q))))
(define-syntax cap-clause-65
  (sc-macro-transformer
   (lambda (f e)
     `(cond ((= 1 2) 'no) ,(capture-syntactic-environment (lambda (env) '(else 'yes)))))))
(define-syntax cap-formal-65
  (rsc-macro-transformer
   (lambda (f e)
     `((lambda (a ,(capture-syntactic-environment (lambda (env) 'b))) (list a b)) 1 2))))
(define-syntax cap-set!-65
  (sc-macro-transformer
   (lambda (f e)
     `(begin
        (set! ,(capture-syntactic-environment (lambda (env) (close-syntax (cadr f) e))) 9)
        ,(close-syntax (cadr f) e)))))
(define-syntax cap-define-65
  (sc-macro-transformer
   (lambda (f e)
     `(define ,(capture-syntactic-environment (lambda (env) (close-syntax (cadr f) e)))
        42))))
(define-syntax cap-body-65
  (rsc-macro-transformer
   (lambda (f e)
     `(let () ,(capture-syntactic-environment (lambda (env) '(define w 3))) (+ w 1)))))
(cap-define-65 zz-65)
(check t65-capture-positions '((a b) 1 yes (1 2) 9 42 4)
  (list (cap-quote-65) (cap-let-65) (cap-clause-65) (cap-formal-65)
        (let ((w 0)) (cap-set!-65 w)) zz-65 (cap-body-65)))

;; T66 compiler syntax whose whole output is a capture that declines
(define (cs-66 a b) (list 'proc a b))
(define-compiler-syntax cs-66
  (sc-macro-transformer
   (lambda (form env)
     (capture-syntactic-environment
      (lambda (menv)
        (if (number? (cadr form))
            `(list 'cs ,(cadr form))
            (close-syntax form env)))))))
(check t66-compiler-syntax-capture-decline '(proc 1 2) (let ((v 1)) (cs-66 v 2)))
(check t66b-compiler-syntax-capture #t
  (and (member (cs-66 1 2) '((cs 1) (proc 1 2))) #t))

;; T67 printed representation of closures and environments
(import-for-syntax (only (scheme base) open-output-string get-output-string))
(define-syntax show-67
  (sc-macro-transformer
   (lambda (f env)
     (let ((port (open-output-string)))
       (write (list (close-syntax '(a b) env) env) port)
       (get-output-string port)))))
(check t67-printers "(#<syntactic-closure (a b)> #<syntactic-environment>)" (show-67))

;; T68 every closure object is a distinct identifier (the paper's
;; appendix, MIT and chibi): a closure used as a binder binds only
;; itself, not another closure of the same name, nor the user's name
(define-syntax bind-68
  (sc-macro-transformer
   (lambda (f env)
     `(let ((,(close-syntax (cadr f) env) 10)) ,(close-syntax (caddr f) env)))))
(check t68-distinct-closed-identifiers 'outer (let ((y 'outer)) (bind-68 y y)))
(define-syntax bind-same-68
  (sc-macro-transformer
   (lambda (f env)
     (let ((c (close-syntax (cadr f) env)))
       `(let ((,c 10)) (list ,c ,(close-syntax (cadr f) env)))))))
(check t68b-same-closure-object '(10 outer)
  (let ((y 'outer)) (bind-same-68 y)))

;; T69 (D1) a raw binder of the output does not capture a closure of
;; the same name: rsc output and the usage environment
(define-syntax d1-rsc-69
  (rsc-macro-transformer
   (lambda (f menv)
     (capture-syntactic-environment
      (lambda (uenv)
        `((lambda (x) (list x ,(close-syntax 'x uenv))) 'inner))))))
(check t69-raw-binder-vs-usage-closure '(inner outer)
  (let ((x 'outer)) (d1-rsc-69)))
;; ... and sc output and the macro environment
(define x-69 'global)
(define-syntax d1-sc-69
  (sc-macro-transformer
   (lambda (f env)
     (capture-syntactic-environment
      (lambda (menv)
        `((lambda (x-69) (list x-69 ,(close-syntax 'x-69 menv))) 'inner))))))
(check t69b-raw-binder-vs-macro-closure '(inner global) (d1-sc-69))

;; T70 the egg idiom: definition and assignment of a name through two
;; different closures, in a body, also by two macro uses
(define-syntax def-counter-70
  (sc-macro-transformer
   (lambda (f env)
     `(begin (define ,(close-syntax (cadr f) env) 0)
             (define (,(close-syntax (caddr f) env))
               (set! ,(close-syntax (cadr f) env)
                     (+ ,(close-syntax (cadr f) env) 1))
               ,(close-syntax (cadr f) env))))))
(define-syntax reset-70
  (sc-macro-transformer
   (lambda (f env)
     `(define (,(close-syntax (caddr f) env))
        (set! ,(close-syntax (cadr f) env) 100)
        ,(close-syntax (cadr f) env)))))
(check t70-definition-through-closures '(1 2 2 100 101 101)
  (let ((n 'outer-n))
    (def-counter-70 n bump!)
    (reset-70 n reset!)
    (let* ((a (bump!)) (b (bump!)) (c n) (d (reset!)) (e (bump!)))
      (list a b c d e n))))
(def-counter-70 n-70 bump-70!)
(check t70b-toplevel-definition-through-closures '(1 2 2)
  (let* ((a (bump-70!)) (b (bump-70!))) (list a b n-70)))

;; T71 a nested non-hygienic macro sees a binder of a usage closure
;; when that is the only identifier for the name (un-renamed)
(define-syntax anaphoric-71 (rsc-macro-transformer (lambda (f e) 'it)))
(define-syntax with-it-71
  (sc-macro-transformer
   (lambda (f env)
     (close-syntax `(let ((it ,(cadr f))) ,(caddr f)) env))))
(check t71-nested-rsc-in-usage-closure 5 (with-it-71 5 (anaphoric-71)))

;; T72 nested anaphoric macros: the inner macro's free name captures the
;; name written in its own call, even though the enclosing expansion
;; has already resolved it (the paper's filter-syntactic-env)
(check t72-nested-anaphora '(2 (1 2) (1 (2 3)))
  (list (aif-15 1 (aif-15 2 it 'no) 'no)
        (aif-15 1 (list it (aif-15 2 it 'no)) 'no)
        (aif-15 1 (list it (aif-15 2 (list it (aif-15 3 it 'no)) 'no)) 'no)))
(check t72b-nested-loop-exit '(o i)
  (loop-09 (exit (list 'o (loop-09 (exit 'i))))))

;; T73 a macro called inside a closure of another environment sees the
;; names of that environment: here a raw `it' written by an rsc macro
;; refers to the binding made in the closure that calls it
(define-syntax rsc-it-73 (rsc-macro-transformer (lambda (f e) 'it)))
(define-syntax bind-it-73
  (sc-macro-transformer
   (lambda (f env)
     (capture-syntactic-environment
      (lambda (menv)
        (close-syntax `(let ((it 'macro-it)) (rsc-it-73)) menv))))))
(check t73-macro-in-closure '(macro-it user-it)
  (let ((it 'user-it)) (list (bind-it-73) (rsc-it-73))))

;; T74 rsc: a raw binder x does not capture the user's x closed in the
;; usage environment (obtained by a capture at the top of the output)
(define-syntax m-74
  (rsc-macro-transformer
   (lambda (f menv)
     (capture-syntactic-environment
      (lambda (uenv)
        `(let ((x 1)) ,(close-syntax (cadr f) uenv)))))))
(check t74-raw-binder-vs-usage-closure-rsc 'user (let ((x 'user)) (m-74 x)))

;; T75 sc: output closed in the usage environment binds a raw x around
;; a closure of x in that same environment
(define-syntax m-75
  (sc-macro-transformer
   (lambda (f env)
     (make-syntactic-closure
      env '()
      `((lambda (x) ,(make-syntactic-closure env '() 'x)) 'inner)))))
(check t75-raw-binder-vs-usage-closure-sc 'outer (let ((x 'outer)) (m-75)))

;; T76 the same in the macro environment: the closure means the global
(define gv-76 'global)
(define-syntax m-76
  (sc-macro-transformer
   (lambda (f env)
     (capture-syntactic-environment
      (lambda (menv)
        `((lambda (gv-76) ,(close-syntax 'gv-76 menv)) 'inner))))))
(check t76-raw-binder-vs-macro-closure 'global (m-76))

;; T77 ... unless the name is left free
(define-syntax m-77
  (sc-macro-transformer
   (lambda (f env)
     (make-syntactic-closure
      env '()
      `((lambda (x) ,(make-syntactic-closure env '(x) 'x)) 'inner)))))
(check t77-free-name-captured 'inner (let ((x 'outer)) (m-77)))

;; T78 nested catch: the inner catch's throw is the inner one, as the
;; inner catch is called in the outer one's closure, where `throw' is
;; free (the paper's filter-syntactic-env)
(define-syntax catch-78
  (sc-macro-transformer
   (lambda (exp env)
     (let ((body (make-syntactic-closure env '(throw) (cadr exp))))
       `(call-with-current-continuation (lambda (throw) ,body))))))
(check t78-nested-catch '(outer inner)
  (catch-78 (list 'outer (catch-78 (throw 'inner)))))

;; T79 raw output text of an sc macro passed to an anaphoric macro is
;; captured through its free-names list, as in the paper and MIT
(define-syntax with-it-79
  (sc-macro-transformer
   (lambda (f env)
     `(let ((it ,(close-syntax (cadr f) env)))
        ,(make-syntactic-closure env '(it) (caddr f))))))
(define-syntax m-79
  (sc-macro-transformer (lambda (f env) '(let ((it 5)) (with-it-79 7 it)))))
(check t79-raw-text-free-name 7 (m-79))

;;; ------------------------------------------------------------------
;;; Paper, section 4: advertised environments, extend-syntactic-environment,
;;; expanders in the paper's protocol

;; T80 the paper's push expander, verbatim
(define-for-syntax (push-expander-80 syntactic-env exp)
  (let ((obj-exp (make-syntactic-closure
                  syntactic-env '()
                  (cadr exp)))
        (list-var (make-syntactic-closure
                   syntactic-env '()
                   (caddr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(set! ,list-var
            (cons ,obj-exp ,list-var)))))
(define-syntax push-80 (expander-macro-transformer push-expander-80))
(check t80-paper-push-expander '((foo) (bar))
  (let ((s1 '()) (s2 '()))
    (let ((cons 6)) (push-80 'foo s1))
    (let-syntax ((set! (syntax-rules () ((_ . r) 'hijacked))))
      (push-80 'bar s2))
    (list s1 s2)))

;; T81 scheme-syntactic-environment: variables are absolute references,
;; keywords the standard ones, other names consistent per expansion
(define-syntax or-81
  (expander-macro-transformer
   (lambda (syntactic-env exp)
     (let ((exp-1 (make-syntactic-closure syntactic-env '() (cadr exp)))
           (exp-2 (make-syntactic-closure syntactic-env '() (caddr exp))))
       (make-syntactic-closure
        scheme-syntactic-environment '()
        `((lambda (temp) (if temp temp ,exp-2)) ,exp-1))))))
(check t81-advertised-environment '(tv 5 5)
  (list (let ((temp 'tv)) (or-81 #f temp))
        (let ((if list) (lambda vector)) (or-81 #f 5))
        (let ((list 1) (cons 2)) (or-81 (memq 'x '(a)) 5))))

;; T82 extend-syntactic-environment: the paper's `contorted' (sec. 1),
;; whose auxiliary keyword `use' exists only in closures it makes
(define-for-syntax (contorted-expander-82 syntactic-env exp)
  (let* ((test (make-syntactic-closure syntactic-env '() (cadr exp)))
         (x (make-syntactic-closure syntactic-env '() (caddr exp)))
         (y (make-syntactic-closure syntactic-env '() (cadddr exp)))
         (use-env
          (extend-syntactic-environment
           scheme-syntactic-environment 'use
           (lambda (use-syntactic-env use-exp)
             (make-syntactic-closure
              scheme-syntactic-environment '()
              `(,(cadr use-exp) ,x ,y))))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(if ,test
          ,(make-syntactic-closure use-env '() '(use and))
          ,(make-syntactic-closure use-env '() '(use or))))))
(define-syntax contorted-82 (expander-macro-transformer contorted-expander-82))
(check t82-extend-syntactic-environment '(2 1 user-use)
  (let ((use (lambda (a b) 'user-use)))
    (list (contorted-82 #t 1 2) (contorted-82 #f 1 2)
          (contorted-82 #f (use 1 2) 3))))

;; T83 extending the usage environment; the keyword is scoped
(define-syntax with-swap-83
  (expander-macro-transformer
   (lambda (env exp)
     (make-syntactic-closure
      (extend-syntactic-environment
       env 'swap
       (sc-macro-transformer
        (lambda (x e)
          (let ((a (close-syntax (cadr x) e)) (b (close-syntax (caddr x) e)))
            `(let ((tmp ,a)) (set! ,a ,b) (set! ,b tmp))))))
      '()
      `(begin ,@(cdr exp))))))
(check t83-extend-usage-environment '((2 1) unbound)
  (let ((tmp 1) (y 2))
    (with-swap-83 (swap tmp y))
    (list (list tmp y)
          (handle-exceptions e 'unbound (swap tmp y)))))

;; T84 core-syntactic-environment has only the primitive keywords; any
;; other keyword is a syntax error (signalled when the use is expanded,
;; hence the eval)
(define-syntax in-core-84
  (expander-macro-transformer
   (lambda (env exp) (make-syntactic-closure core-syntactic-environment '() (cadr exp)))))
(check t84-core-environment '(1 error)
  (list (in-core-84 (if #t 1 2))
        (handle-exceptions e 'error
          (eval '(let-syntax ((in-core
                               (expander-macro-transformer
                                (lambda (env exp)
                                  (make-syntactic-closure
                                   core-syntactic-environment '() (cadr exp))))))
                   (in-core (let ((a 1)) a)))))))

;; T85 identifier=? against the advertised environment
(define-syntax is-if-85
  (sc-macro-transformer
   (lambda (f env)
     `(quote ,(identifier=? env (cadr f) scheme-syntactic-environment 'if)))))
(check t85-identifier=?-advertised '(#t #f) (list (is-if-85 if) (let ((if 1)) (is-if-85 if))))

;;; ------------------------------------------------------------------
;;; Captures inside the output, hygiene through nested macros, lifetime

;; T86 [MIT] a capture placed inside the output gets the environment at
;; that place: its closures see the bindings the output makes around it
;; (a capture that is the whole output gets the macro environment, T69b)
(define-syntax here-86
  (sc-macro-transformer
   (lambda (f env)
     `(let ((x 'inner))
        ,(capture-syntactic-environment (lambda (e) (close-syntax 'x e)))))))
(check t86-capture-inside-output 'inner (let ((x 'outer)) (here-86)))
;; MIT Scheme reference manual, "SC Transformer Definition": loop-until
(define-syntax loop-until-86
  (sc-macro-transformer
   (lambda (exp env)
     (let ((id (cadr exp))
           (init (caddr exp))
           (test (cadddr exp))
           (return (cadddr (cdr exp)))
           (step (cadddr (cddr exp)))
           (close
            (lambda (exp free)
              (make-syntactic-closure env free exp))))
       `(letrec ((loop
                  ,(capture-syntactic-environment
                    (lambda (env)
                      `(lambda (,id)
                         (,(make-syntactic-closure env '() `if)
                          ,(close test (list id))
                          ,(close return (list id))
                          (,(make-syntactic-closure env '() `loop)
                           ,(close step (list id)))))))))
          (loop ,(close init '())))))))
(check t86b-mit-loop-until '(60 (6 7))
  (list (loop-until-86 i 0 (> i 5) (* i 10) (+ i 1))
        (let ((loop 7) (if 3))
          (loop-until-86 i 0 (> i 5) (list i loop) (+ i 1)))))

;; T87 a closure handed to an anaphoric macro is not captured by the
;; anaphoric macro's free names, even when CHICKEN has turned it back
;; into the user's name; a whole form closed and handed over is
(define-syntax aif-87
  (sc-macro-transformer
   (lambda (f env)
     `(let ((it ,(close-syntax (cadr f) env)))
        (if it
            ,(make-syntactic-closure env '(it) (caddr f))
            ,(close-syntax (cadddr f) env))))))
(define-syntax pass-87
  (sc-macro-transformer
   (lambda (f env)
     `(aif-87 ,(close-syntax (cadr f) env) ,(close-syntax (caddr f) env) #f))))
(define-syntax pass-pass-87
  (sc-macro-transformer
   (lambda (f env)
     `(pass-87 ,(close-syntax (cadr f) env) ,(close-syntax (caddr f) env)))))
(define-syntax pass-form-87
  (sc-macro-transformer
   (lambda (f env) (close-syntax (cadr f) env))))
(check t87-closure-not-captured-by-free-name '(user user 1 user (1 1))
  (let ((it 'user))
    (list (pass-87 1 it)
          (pass-pass-87 1 it)
          (pass-form-87 (aif-87 1 it #f))
          (pass-form-87 (pass-87 1 it))
          (pass-form-87 (aif-87 1 (list it (pass-87 2 it)) #f)))))

;; T88 extend-syntactic-environment with transformers: syntax-rules and
;; er-macro-transformer.  Their macro environment is that of the
;; expansion defining them (so their `list' is the standard one), while
;; the closure's `list' is the user's
(define-syntax with-kw-88
  (expander-macro-transformer
   (lambda (env exp)
     (make-syntactic-closure
      (extend-syntactic-environment
       (extend-syntactic-environment
        env 'twice (syntax-rules () ((_ e) (list e e))))
       'thrice
       (er-macro-transformer
        (lambda (x r c) `(,(r 'list) ,(cadr x) ,(cadr x) ,(cadr x)))))
      '()
      `(list ,@(cdr exp))))))
(check t88-extend-with-transformers '#((1 1) (2 2 2))
  (let ((list vector)) (with-kw-88 (twice 1) (thrice 2))))

;; T89 a closure made while its environment was alive may be placed in
;; the output of a later expansion; it keeps its meaning
(define-for-syntax saved-89 #f)
(define-syntax later-89
  (sc-macro-transformer
   (lambda (f env)
     (set! saved-89 (close-syntax (cadr f) env))
     '(let ((x 'inner)) (use-89)))))
(define-syntax use-89 (sc-macro-transformer (lambda (f env) saved-89)))
(check t89-closure-used-in-later-expansion 'outer
  (let ((x 'outer)) (later-89 x)))

;; T90 scheme-syntactic-environment refers to standard bindings by their
;; absolute names (e.g. scheme#cons), not through aliases
(check t90-advertised-absolute-names #t
  (let ((e (eval '(begin
                    (define-syntax push-90
                      (expander-macro-transformer
                       (lambda (env exp)
                         (make-syntactic-closure
                          scheme-syntactic-environment '()
                          `(set! ,(make-syntactic-closure env '() (caddr exp))
                                 (cons ,(make-syntactic-closure env '() (cadr exp))
                                       ,(make-syntactic-closure env '() (caddr exp))))))))
                    (expand '(push-90 1 s))))))
    (let walk ((x e))
      (cond ((eq? x 'scheme#cons) #t)
            ((pair? x) (or (walk (car x)) (walk (cdr x))))
            (else #f)))))

;; T91 large outputs: more distinct names than fit in a small table
(define-syntax big-let-91
  (sc-macro-transformer
   (lambda (f env)
     (let* ((n (cadr f))
            (names (let loop ((i 0) (r '()))
                     (if (= i n) r
                         (loop (+ i 1)
                               (cons (string->symbol
                                      (string-append "v" (number->string i)))
                                     r))))))
       `(let ,(map (lambda (s) `(,s 1)) names)
          (+ ,@names ,(close-syntax (caddr f) env)))))))
(check t91-many-names '(201 1200)
  (let ((v3 1000))
    (list (big-let-91 200 1) (big-let-91 200 v3))))
(check t91b-many-names-closed 5000
  (eval `(let-syntax ((qlen (sc-macro-transformer
                             (lambda (f env)
                               `(length (quote ,(close-syntax (cadr f) env)))))))
           (qlen ,(let loop ((i 0) (r '()))
                    (if (= i 5000) r
                        (loop (+ i 1)
                              (cons (string->symbol
                                     (string-append "s" (number->string i)))
                                    r))))))))

;; T92 expansions keep nothing alive: repeated evaluation of macro uses
;; does not grow the heap
(import (only (chicken gc) gc memory-statistics))
(eval '(define-syntax m-92
         (sc-macro-transformer
          (lambda (e env)
            `(let ((temp 1))
               (list temp ,(close-syntax (cadr e) env)
                     ,(make-syntactic-closure env '(it) '(+ 1 2))))))))
(define (heap-in-use-92)
  (gc #t)
  (vector-ref (memory-statistics) 1))
(check t92-no-leak #t
  (let ((run (lambda (n)
               (do ((i 0 (+ i 1))) ((= i n))
                 (eval `(let ((x ,i)) (m-92 (list x x x x x x x x x x))))))))
    (run 1000)
    (let ((h1 (heap-in-use-92)))
      (do ((k 0 (+ k 1))) ((= k 8)) (run 1000) (heap-in-use-92))
      ;; 10MB or more when the contexts of the expansions are kept; the
      ;; dead ones are swept only now and then
      (< (- (heap-in-use-92) h1) 4000000))))

;;; ------------------------------------------------------------------
;;; Review round 1 regressions.  Expected values of T93 and T94 were
;;; computed by the paper-appendix oracle.

;; T93 an anaphoric macro nested in itself through another macro that
;; closes its operand in its usage environment: the inner free name is
;; the inner macro's binder
(define-syntax catch-93
  (sc-macro-transformer
   (lambda (form env)
     `(call-with-current-continuation
       (lambda (throw) ,(make-syntactic-closure env '(throw) (cadr form)))))))
(define-syntax aif-93
  (sc-macro-transformer
   (lambda (f env)
     `(let ((it ,(close-syntax (cadr f) env)))
        (if it
            ,(make-syntactic-closure env '(it) (caddr f))
            ,(close-syntax (cadddr f) env))))))
(define-syntax id-93
  (sc-macro-transformer (lambda (form env) (close-syntax (cadr form) env))))
(define-syntax rid-93 (rsc-macro-transformer (lambda (f e) (cadr f))))
(define-syntax or2-93
  (sc-macro-transformer
   (lambda (form env)
     `(let ((temp ,(close-syntax (cadr form) env)))
        (if temp temp ,(close-syntax (caddr form) env))))))
;; the inner form gets a closure of `it' made by the macro: not the
;; user's text, so it is not captured
(define-syntax mk-93
  (sc-macro-transformer
   (lambda (f env)
     (close-syntax `(aif-93 2 ,(close-syntax 'it env) 0) env))))
(check t93-catch-through-id '(outer inner)
  (catch-93 (list 'outer (id-93 (catch-93 (throw 'inner))))))
(check t93-catch-through-rsc-id '(outer inner)
  (catch-93 (list 'outer (rid-93 (catch-93 (throw 'inner))))))
(check t93-catch-through-or2 '(outer inner)
  (catch-93 (list 'outer (or2-93 #f (catch-93 (throw 'inner))))))
(check t93-aif-through-id 2 (aif-93 1 (id-93 (aif-93 2 it 0)) 0))
(check t93-aif-through-id-twice 2 (aif-93 1 (id-93 (id-93 (aif-93 2 it 0))) 0))
(check t93-aif-through-rsc-and-id 2 (aif-93 1 (rid-93 (id-93 (aif-93 2 it 0))) 0))
(check t93-aif-outer-and-inner '(1 2)
  (aif-93 1 (list it (id-93 (aif-93 2 it 0))) 0))
(check t93-aif-two-closures '(1 2)
  (aif-93 1 (list it (or2-93 (not it) (aif-93 2 it 0))) 0))
(check t93-aif-three-levels '(1 (2 3))
  (aif-93 1 (list it (or2-93 #f (aif-93 2 (list it (id-93 (aif-93 3 it 0))) 0))) 0))
(check t93-macro-closure-not-captured 1 (aif-93 1 (mk-93) 0))
(check t93-macro-closure-not-captured-2 1 (aif-93 1 (id-93 (mk-93)) 0))

;; T94 extend-syntactic-environment: an inner extension of the same
;; keyword shadows the outer one, also through an intermediate macro
(define-syntax with-k-94
  (sc-macro-transformer
   (lambda (f env)
     (make-syntactic-closure
      (extend-syntactic-environment
       env 'k
       (lambda (e x)
         (make-syntactic-closure scheme-syntactic-environment '()
                                 (list 'quote (cadr f)))))
      '() `(begin ,@(cddr f))))))
(define-syntax with-k2-94
  (sc-macro-transformer
   (lambda (f env)
     (make-syntactic-closure
      (extend-syntactic-environment
       env 'k (sc-macro-transformer (lambda (x e) ''two)))
      '() `(begin ,@(cdr f))))))
(check t94-shadow 'b (with-k-94 a (with-k-94 b (k))))
(check t94-shadow-scope '(a b a) (with-k-94 a (list (k) (with-k-94 b (k)) (k))))
(check t94-shadow-under-let 'b (with-k-94 a (let ((z 1)) (with-k-94 b (k)))))
(check t94-shadow-through-id 'b (with-k-94 a (id-93 (with-k-94 b (k)))))
(check t94-three-levels '(b c)
  (with-k-94 a (or2-93 #f (with-k-94 b (list (k) (with-k-94 c (k)))))))
(check t94-other-macro 'two (with-k-94 a (with-k2-94 (k))))
(check t94-other-macro-outer 'a (with-k2-94 (with-k-94 a (k))))
(check t94-inside-aif 'b (with-k-94 a (aif-93 1 (with-k-94 b (k)) 0)))
(check t94-let-syntax-control 'c
  (with-k-94 a (let-syntax ((k (syntax-rules () ((_) 'c)))) (k))))

;; T95 an sc macro bound by let-syntax, letrec-syntax or an internal
;; define-syntax in the output of an sc macro gets the context of its
;; calls there (sc-note-syntax-binders!)
(define-syntax with-it-95a
  (sc-macro-transformer
   (lambda (f env)
     '(let-syntax ((my-aif
                    (sc-macro-transformer
                     (lambda (form env)
                       (list 'let (list (list 'it (close-syntax (cadr form) env)))
                             (make-syntactic-closure env '(it) (caddr form)))))))
        (let ((it 'outer-it))
          (my-aif 1 it))))))
(define-syntax with-it-95b
  (sc-macro-transformer
   (lambda (f env)
     '(letrec-syntax ((my-aif
                       (sc-macro-transformer
                        (lambda (form env)
                          (list 'let (list (list 'it (close-syntax (cadr form) env)))
                                (make-syntactic-closure env '(it) (caddr form)))))))
        (let ((it 'outer-it))
          (my-aif 1 it))))))
(define-syntax with-it-95c
  (sc-macro-transformer
   (lambda (f env)
     '(let ()
        (define-syntax my-aif
          (sc-macro-transformer
           (lambda (form env)
             (list 'let (list (list 'it (close-syntax (cadr form) env)))
                   (make-syntactic-closure env '(it) (caddr form))))))
        (let ((it 'outer-it))
          (my-aif 1 it))))))
(check t95-let-syntax-in-output 1 (with-it-95a))
(check t95-letrec-syntax-in-output 1 (with-it-95b))
(check t95-define-syntax-in-output 1 (with-it-95c))

;; T96 a body's define-syntax of a name closed twice in the usage
;; environment defines the user's keyword (define-syntax-names)
(define-syntax def-kw-96
  (sc-macro-transformer
   (lambda (f env)
     (let ((n1 (close-syntax (cadr f) env)) (n2 (close-syntax (cadr f) env)))
       `(begin (define-syntax ,n1 (syntax-rules () ((_) 'kw)))
               (define ,(close-syntax 'probe-96 env) (list ',n2)))))))
(define (f-96) (def-kw-96 foo) (list (foo) probe-96))
(check t96-define-syntax-two-closures '(kw (foo)) (f-96))
(check t96-define-syntax-two-closures-let '(kw (bar))
  (let () (def-kw-96 bar) (list (bar) probe-96)))

;; T97 of several usage aliases of a name, the raw rsc one is written
;; as the name, so a non-hygienic er macro there sees the rsc binding
(define-syntax unhyg-97 (er-macro-transformer (lambda (f r c) 'x)))
(define-syntax rsc-two-97
  (rsc-macro-transformer
   (lambda (f menv)
     (capture-syntactic-environment
      (lambda (uenv)
        `(let ((x 5)) (list ,(close-syntax 'x uenv) (unhyg-97))))))))
(check t97-raw-rsc-alias-unrenamed '(outer 5) (let ((x 'outer)) (rsc-two-97)))

;; T98 a result eq? to the form: compiler syntax declines, and a macro
;; returning its form is an error rather than a loop
(define (foo-98 x) (list 'proc x))
(define-compiler-syntax foo-98
  (sc-macro-transformer
   (lambda (form env)
     (if (number? (cadr form)) `(list 'cs ,(cadr form)) form))))
(check t98-compiler-syntax-declines
  (list (cond-expand (compiling '(cs 1)) (else '(proc 1))) '(proc a))
  (list (foo-98 1) (foo-98 'a)))
(eval '(define-syntax same-98 (sc-macro-transformer (lambda (form env) form))))
(eval '(define-syntax rsame-98 (rsc-macro-transformer (lambda (form env) form))))
(check t98-endless-expansion '(error error)
  (list (handle-exceptions e 'error (eval '(same-98)))
        (handle-exceptions e 'error (eval '(rsame-98)))))

;; T99 vector literals: renamed symbols are stripped, other vectors
;; keep their identity
(define-syntax vec-99 (syntax-rules () ((_ x) #(x y))))
(define-syntax vec-er-99
  (er-macro-transformer (lambda (f r c) (vector (r 'a) 'b))))
(define-syntax same-vec-99
  (er-macro-transformer
   (lambda (f r c) (let ((v (vector 1 2))) `(,(r 'eq?) ,v ,v)))))
(check t99-vector-literal-stripped '(#(1 y) #(a b)) (list (vec-99 1) (vec-er-99)))
(check t99-vector-literal-identity '(#t #t #t #(x 2))
  (let ((v (vector 1 2)))
    (let ((r (list (same-vec-99) (eval (list 'eq? v v)) (eq? v (eval v)))))
      (eval (list 'vector-set! v 0 ''x))
      (append r (list v)))))

;; T100 make-syntactic-closure-list checks its arguments, also when
;; FORMS is empty
(import-for-syntax (chicken condition))
(define-syntax mscl-100
  (sc-macro-transformer
   (lambda (f env)
     (let ((try (lambda (thunk) (handle-exceptions e 'error (thunk) 'ok))))
       `(quote ,(list (try (lambda () (make-syntactic-closure-list 42 '() '())))
                      (try (lambda () (make-syntactic-closure-list env 7 '())))
                      (try (lambda () (make-syntactic-closure-list env '(1) '())))
                      (try (lambda () (make-syntactic-closure-list env '() '(a . b))))
                      (try (lambda () (make-syntactic-closure-list env '() '(a b))))))))))
(check t100-msc-list-checks '(error error error error ok) (mscl-100))

;; T101 constants other than vectors are returned unchanged
(define-syntax closed-101
  (sc-macro-transformer
   (lambda (form env)
     (let* ((v (cadr form)) (c (make-syntactic-closure env '() v)))
       `(quote ,(list (eq? c v) (syntactic-closure? c)))))))
(check t101-vector-is-closed '(#f #t) (closed-101 #(1 2)))
(check t101-string-unchanged '(#t #f) (closed-101 "s"))

;; T102 the environment of an expansion that raised an exception can
;; no longer make closures
(eval '(define saved-102 #f))
(check t102-env-dead-after-exception '(error error)
  (begin
    (handle-exceptions e #f
      (eval '(let-syntax ((m (sc-macro-transformer
                              (lambda (f env) (set! saved-102 env) (error "boom")))))
               (m))))
    (list (handle-exceptions e 'error (eval '(make-syntactic-closure saved-102 '() 'x)))
          (handle-exceptions e 'error (eval '(close-syntax 'x saved-102))))))

;; T103 a body defining a name that an earlier expansion left a usage
;; alias of does not walk its quoted data (which may be circular)
(eval '(define-syntax two-103
         (sc-macro-transformer
          (lambda (f env)
            `(list ,(close-syntax 'x-103 env) ,(close-syntax 'x-103 env))))))
(check t103-circular-constant '((5 5) 1)
  (let ((c (list 1 2 3)))
    (set-cdr! (cddr c) c)
    (list (eval '(let ((x-103 5)) (two-103)))
          ((eval `(lambda () (define x-103 1) (car ',c)))))))

;; T104 a macro called inside a closure that leaves a name free: what
;; its output binds of that name in its usage environment captures the
;; user's occurrence of the name in the macro form (as in the paper,
;; where the macro's usage environment is the closure's environment)
(define-syntax with-x-104
  (sc-macro-transformer
   (lambda (f e)
     `(let ((x 'outer)) ,(make-syntactic-closure e '(x) (cadr f))))))
(define-syntax rbind-x-104
  (rsc-macro-transformer
   (lambda (f m) `((lambda (x) ,(cadr f)) 'rsc))))
(define-syntax scbind-x-104
  (sc-macro-transformer
   (lambda (f e)
     (make-syntactic-closure e '() `((lambda (x) ,(cadr f)) 'sc)))))
(define-syntax catch-104
  (sc-macro-transformer
   (lambda (f env)
     `(call-with-current-continuation
       (lambda (throw) ,(make-syntactic-closure env '(throw) (cadr f)))))))
(define-syntax rcatch-104
  (rsc-macro-transformer
   (lambda (f m)
     `(call-with-current-continuation (lambda (throw) ,(cadr f))))))
(define-syntax with-it-104
  (sc-macro-transformer
   (lambda (f e)
     `(let ((it 'outer-it)) ,(make-syntactic-closure e '(it) (cadr f))))))
(define-syntax aif-u-104
  (sc-macro-transformer
   (lambda (f e)
     (make-syntactic-closure
      e '() `(let ((it ,(cadr f))) (if it ,(caddr f) #f))))))
(check t104-rsc-binder-in-free-closure 'rsc (with-x-104 (rbind-x-104 x)))
(check t104-rsc-binder-and-outer '(outer rsc)
  (with-x-104 (list x (rbind-x-104 x))))
(check t104-rsc-catch-in-catch '(o inner)
  (catch-104 (list 'o (rcatch-104 (throw 'inner)))))
(check t104-sc-binder-in-free-closure 'sc (with-x-104 (scbind-x-104 x)))
(check t104-aif-in-with-it 5 (with-it-104 (aif-u-104 5 it)))
(check t104-outside '(rsc sc 5)
  (list (rbind-x-104 x) (scbind-x-104 x) (aif-u-104 5 it)))

;; T105 [MIT] a closure in the environment a capture gets is not
;; captured by binders in the capture's own result: it denotes what
;; the name means at the capture place
(define x-105 'global)
(define-syntax h1-105
  (sc-macro-transformer
   (lambda (f e)
     `(let ((x-105 'a))
        ,(capture-syntactic-environment
          (lambda (env)
            `(list x-105 (let ((x-105 'b)) (list x-105 ,(close-syntax 'x-105 env))))))))))
(define-syntax h2-105
  (sc-macro-transformer
   (lambda (f e)
     `(let ((x-105 'a))
        ,(capture-syntactic-environment
          (lambda (env)
            `(list (let* ((y 1) (x-105 'b) (z (list x-105 ,(close-syntax 'x-105 env)))) z)
                   (do ((x-105 0 (+ x-105 1))) ((= x-105 2) (list x-105 ,(close-syntax 'x-105 env))))
                   (let x-105 ((n 0)) (if (= n 1) ,(close-syntax 'x-105 env) (x-105 (+ n 1))))
                   ((lambda () (define x-105 'b) (list x-105 ,(close-syntax 'x-105 env))))
                   (letrec ((x-105 (lambda () ,(close-syntax 'x-105 env)))) (x-105))
                   (let () (define (f x-105) (list x-105 ,(close-syntax 'x-105 env))) (f 'b)))))))))
;; the same for a capture at the top of a closure with free names
(define-syntax h3-105
  (sc-macro-transformer
   (lambda (f e)
     `(let ((x-105 'a))
        ,(make-syntactic-closure
          e '(x-105)
          (capture-syntactic-environment
           (lambda (env)
             `(let ((x-105 'b)) (list x-105 ,(close-syntax 'x-105 env))))))))))
;; a closure kept from one capture and placed by another
(define-syntax h4-105
  (sc-macro-transformer
   (lambda (f e)
     (let ((saved #f))
       `(let ((x-105 'a))
          (list ,(capture-syntactic-environment
                  (lambda (env) (set! saved (close-syntax 'x-105 env)) ''c))
                ,(capture-syntactic-environment
                  (lambda (env) `(let ((x-105 'b)) ,saved)))))))))
(check t105-here-closure-not-captured '(a (b a)) (h1-105))
(check t105-binding-forms '((b a) (2 a) a (b a) a (b a)) (h2-105))
(check t105-derived-closure-not-captured '(b a) (let ((x-105 'user)) (h3-105)))
(check t105-kept-closure '(c a) (h4-105))
;; MIT's loop-until (T86) with the loop variable named `loop' or `if'
(check t105-loop-until-id-loop-if '(60 60)
  (list (loop-until-86 loop 0 (> loop 5) (* loop 10) (+ loop 1))
        (loop-until-86 if 0 (> if 5) (* if 10) (+ if 1))))

;; T106 with-macro: two identifiers of the same name in the template
;; (the macrology's own `temp' and a closure of the caller's `temp'
;; quoted into it) stay distinct, as in the paper
(define-for-syntax menv-106 (scheme-macrology core-syntactic-environment))
(define-syntax wm-show-106
  (expander-macro-transformer
   (lambda (env exp)
     (make-syntactic-closure
      menv-106 '()
      `(let ((temp 'macro))
         (with-macro (m) (list 'list 'temp ',(make-syntactic-closure env '() (cadr exp)))
           (m)))))))
(check t106-with-macro-same-name '((macro user) (macro user))
  (list (let ((temp 'user)) (wm-show-106 temp))
        (let ((x 'user)) (wm-show-106 x))))

;; T107 a body that defines a name through a closure in the usage
;; environment: a binder of that name made by another closure in the
;; body does not capture a third closure of the name (as at toplevel)
(define-syntax defx-107
  (sc-macro-transformer
   (lambda (form env)
     (let ((name (cadr form)) (getter (close-syntax (caddr form) env)))
       `(begin (define ,(close-syntax name env) 'defined)
               (define (,getter)
                 (,(close-syntax `(lambda (x) ,(close-syntax name env)) env)
                  'lambda-param)))))))
(define-syntax defx-rsc-107
  (rsc-macro-transformer
   (lambda (form menv)
     (capture-syntactic-environment
      (lambda (uenv)
        (let ((n (close-syntax 'x uenv)))
          `(begin (define ,n 'defined)
                  (define (get-107) ((lambda (x) ,n) 'lambda-param)))))))))
(check t107-body-define-not-captured '(defined defined defined)
  (list (let () (defx-107 x get) (get))
        (let () (defx-107 y get) (get))
        (let () (defx-rsc-107) (get-107))))
;; a user binder of the defined name does not capture the closure either
(define-syntax defx2-107
  (sc-macro-transformer
   (lambda (form env)
     (let ((name (cadr form)))
       `(begin (define ,(close-syntax name env) 'defined)
               (define (,(close-syntax (cadddr form) env))
                 ,(close-syntax `(,(caddr form) ,(close-syntax name env)) env)))))))
(check t107-user-binder '(defined user)
  (let () (defx2-107 x (lambda (x) (list x 'user)) get) (get)))

;; T108 circular data: a circular vector literal is evaluated without a
;; deep walk, and circular quoted data passes through sc and rsc macros
(eval '(define-syntax id-sc-108
         (sc-macro-transformer (lambda (f env) (close-syntax (cadr f) env)))))
(eval '(define-syntax id-rsc-108 (rsc-macro-transformer (lambda (f env) (cadr f)))))
(check t108-circular-data '(#t a a)
  (let ((l (list 'a 'b))
        (v (vector 1 #f)))
    (set-cdr! (cdr l) l)
    (vector-set! v 1 v)
    ;; V is a self-evaluating vector literal of the evaluated code
    (list (eval `(let ((w ,v)) (eq? w (vector-ref w 1))))
          (car (eval `(id-sc-108 (quote ,l))))
          (car (eval `(id-rsc-108 (quote ,l)))))))

;; T109 the environment a capture gets inside the output stands for
;; bindings of that output: it cannot be used after the expansion
(eval '(define-syntax keep-109
         (sc-macro-transformer
          (lambda (f env)
            `(let ((zz 'inner))
               (list zz ,(capture-syntactic-environment
                          (lambda (e) (set! saved-109 e) ''kept))))))))
(eval '(define saved-109 #f))
(check t109-capture-env-dead '((inner kept) error)
  (list (eval '(keep-109))
        (handle-exceptions e 'error (eval '(close-syntax 'zz saved-109)))))

;; T110 the values of finished expansions are not kept alive (nothing
;; registers contexts after them here, so only a collection drops them)
(check t110-dead-contexts-freed #t
  (let ((h0 (heap-in-use-92)))
    (do ((i 0 (+ i 1))) ((= i 20))
      (eval `(letrec-syntax ((m (sc-macro-transformer
                                 (lambda (f e) (vector-ref ',(make-vector 200000 i) 0)
                                    (close-syntax (cadr f) e))))
                             (m2 (sc-macro-transformer
                                  (lambda (f e) `(m ,(close-syntax (cadr f) e))))))
               (let ((x ,i)) (m2 x)))))
    ;; 20 vectors of 200000 elements: 16MB (32-bit) or 32MB (64-bit)
    (< (- (heap-in-use-92) h0) 8000000)))

;; T111 an internal definition does not capture a closure of the name
;; made in an environment outside the body (as letrec* does not): one
;; that a macro around the body made, one kept from an earlier
;; expansion, and one in a with-macro template
(define-syntax with-get-111
  (sc-macro-transformer
   (lambda (f e)
     (let ((c (close-syntax 'x e)))
       (make-syntactic-closure
        (extend-syntactic-environment e 'get (lambda (e2 form) c))
        '() `(begin ,@(cdr f)))))))
(check t111-extended-env-closure '(outer outer outer outer outer)
  (list (let ((x 'outer)) (with-get-111 (let () (define x 'inner) (get))))
        (let ((x 'outer)) (with-get-111 (let ((x 'inner)) (get))))
        (let ((x 'outer)) (with-get-111 ((lambda () (define x 'inner) (get)))))
        (let ((x 'outer)) (with-get-111 (letrec ((x 'inner)) (get))))
        (let ((x 'outer)) (with-get-111 (letrec* ((x 'inner)) (get))))))
(define-for-syntax saved-111 #f)
(define-syntax save-x-111
  (sc-macro-transformer
   (lambda (f e) (set! saved-111 (close-syntax 'x e)) ''saved)))
(define-syntax use-saved-111 (sc-macro-transformer (lambda (f e) saved-111)))
(define-syntax defx-111
  (sc-macro-transformer
   (lambda (f e) `(define ,(close-syntax 'x e) 'inner-def))))
(check t111-saved-closure '(outer outer)
  (list (let ((x 'outer))
          (save-x-111)
          (let () (defx-111) (use-saved-111)))
        (let ((x 'outer))
          (save-x-111)
          (let () (define x 'inner-def) (use-saved-111)))))
(define-for-syntax menv-111 (scheme-macrology scheme-syntactic-environment))
(define-syntax paper-111
  (expander-macro-transformer
   (lambda (env exp) (make-syntactic-closure menv-111 '() (cadr exp)))))
(check t111-with-macro-template '(outer outer)
  (list (paper-111
         (let ((x 'outer))
           (with-macro (get) 'x ((lambda () (define x 'inner) (get))))))
        (paper-111
         (let ((x 'outer))
           (with-macro (get) 'x ((lambda (x) (get)) 'inner))))))
;; ... while closures made for a macro used in the body still refer to
;; the definition
(check t111-body-macro-closure 'inner-def
  (let ((x 'outer)) (let () (defx-111) x)))

;; T112 a nested sc macro called through a syntax-rules, er or ir macro
;; that builds its call sees the code that calls it as when called
;; directly (the paper's semantics)
(define-syntax aif-112
  (sc-macro-transformer
   (lambda (form env)
     `(let ((it ,(close-syntax (cadr form) env)))
        (if it
            ,(make-syntactic-closure env '(it) (caddr form))
            ,(close-syntax (cadddr form) env))))))
(define-syntax aif*-112 (syntax-rules () ((_ c t) (aif-112 c t #f))))
(define-syntax aif-er-112
  (er-macro-transformer (lambda (f r c) `(,(r 'aif-112) ,(cadr f) ,(caddr f) #f))))
(define-syntax aif-ir-112
  (ir-macro-transformer (lambda (f i c) `(aif-112 ,(cadr f) ,(caddr f) #f))))
(define-syntax aif-begin-112
  (syntax-rules () ((_ c t) (begin (aif-112 c t #f)))))
(check t112-wrappers '(b b b b b b (a b) b)
  (list (aif*-112 'a (aif-112 'b it 'no))
        (aif-112 'a (aif*-112 'b it) #f)
        (aif*-112 'a (aif*-112 'b it))
        (aif-112 'a (aif-er-112 'b it) #f)
        (aif-112 'a (aif-ir-112 'b it) #f)
        (aif-112 'a (aif-begin-112 'b it) #f)
        (aif-112 'a (list it (aif*-112 'b it)) #f)
        (let ((it 'user)) (aif*-112 'b it))))
(define-syntax catch-112
  (sc-macro-transformer
   (lambda (exp env)
     `(call-with-current-continuation
       (lambda (throw) ,(make-syntactic-closure env '(throw) (cadr exp)))))))
(define-syntax my-catch-112 (syntax-rules () ((_ e) (catch-112 e))))
(check t112-wrapped-catch '((outer inner) (outer inner))
  (list (catch-112 (list 'outer (my-catch-112 (throw 'inner))))
        (my-catch-112 (list 'outer (my-catch-112 (throw 'inner))))))
;; names a macro writes in its usage environment
(define x-112 'global-x)
(define-syntax get-x-112 (sc-macro-transformer (lambda (f e) (close-syntax 'x-112 e))))
(define-syntax sr-get-x-112 (syntax-rules () ((_) (get-x-112))))
(define-syntax er-bind-112
  (er-macro-transformer
   (lambda (f r c) `(,(r 'let) ((x-112 5)) (,(r 'get-x-112))))))
(define-syntax outer-112
  (sc-macro-transformer
   (lambda (f e)
     `(let ((x-112 'outer-mac)) (list (get-x-112) (sr-get-x-112) (er-bind-112))))))
(check t112-usage-names '(outer-mac outer-mac 5) (outer-112))

;; T113 a call of an sc macro whose operator is a closed keyword is in
;; the output where it is placed: the macro's usage environment is
;; there, not where the keyword was closed
(define-syntax get-x-113 (sc-macro-transformer (lambda (f e) (close-syntax 'x e))))
(define-syntax via-raw-113
  (sc-macro-transformer (lambda (f e) `(let ((x 'mac)) (get-x-113)))))
(define-syntax via-closure-113
  (sc-macro-transformer
   (lambda (f e) `(let ((x 'mac)) (,(close-syntax 'get-x-113 e))))))
(define-syntax via-scheme-env-113
  (sc-macro-transformer
   (lambda (f e)
     `(let ((x 'mac)) (,(close-syntax 'get-x-113 scheme-syntactic-environment))))))
(define-syntax call-it-113
  (sc-macro-transformer
   (lambda (f e) `(let ((x 'mac)) (,(close-syntax (cadr f) e) x)))))
(check t113-closed-operator '(mac mac mac mac mac)
  (let ((x 'user))
    (list (via-raw-113) (via-closure-113) (via-scheme-env-113)
          (let-syntax ((foo (sc-macro-transformer (lambda (f e) (close-syntax 'x e)))))
            (call-it-113 foo))
          (let-syntax ((foo (rsc-macro-transformer (lambda (f e) 'x))))
            (call-it-113 foo)))))

;; T114 [MIT] a capture nested in the result of another capture gets the
;; environment at its place, also when a closure in the outer
;; capture's environment makes the binder there be renamed apart
(define x-114 'global)
(define-syntax c3c-114
  (sc-macro-transformer
   (lambda (form env)
     `(let ((x-114 'out1))
        ,(capture-syntactic-environment
          (lambda (e1)
            `(let ((x-114 'out2))
               ,(capture-syntactic-environment
                 (lambda (e2) (make-syntactic-closure e2 '() 'x-114))))))))))
(define-syntax c3d-114
  (sc-macro-transformer
   (lambda (form env)
     `(let ((x-114 'out1))
        ,(capture-syntactic-environment
          (lambda (e1)
            `(let ((x-114 'out2))
               (list ,(make-syntactic-closure e1 '() 'x-114)
                     ,(capture-syntactic-environment
                       (lambda (e2) (make-syntactic-closure e2 '() 'x-114)))))))))))
(check t114-nested-capture-renamed-apart '(out2 (out1 out2)) (list (c3c-114) (c3d-114)))

;; T115 a closed `quote' heading data too large to walk: the captures in
;; the data are not called, and those after it get their own results
(eval '(define-syntax big-quote-115
         (sc-macro-transformer
          (lambda (f e)
            (let ((deep (let loop ((i 0) (r (capture-syntactic-environment
                                             (lambda (e) ''first))))
                          (if (= i 1100) r (loop (+ i 1) (list r))))))
              `(list (car (,(close-syntax 'quote e) (a)))
                     (,(close-syntax 'quote e) ,deep)
                     ,(capture-syntactic-environment (lambda (e) ''second))))))))
(check t115-closed-quote-big-datum '(a second)
  (let ((r (eval '(big-quote-115)))) (list (car r) (caddr r))))

;; T116 a local variable named `quote' is no quotation, also in a body
;; that defines a name through closures
(define x-116 1)
(define-syntax def-bind-call-116
  (sc-macro-transformer
   (lambda (form env)
     (let ((f (cadr form)) (n (caddr form)))
       `(begin (define ,(close-syntax n env) 2)
               ((lambda (,(close-syntax n env)) (,(close-syntax f env) ,(close-syntax n env)))
                5))))))
(define-syntax def-and-call-116
  (sc-macro-transformer
   (lambda (form env)
     (let ((f (cadr form)) (n (caddr form)))
       `(begin (define ,(close-syntax n env) 2)
               (,(close-syntax f env) ,(close-syntax n env)))))))
(check t116-local-quote '((2) (2) (2) (2))
  (list (let ((g list)) (def-bind-call-116 g x-116))
        (let ((quote list)) (def-bind-call-116 quote x-116))
        (let ((quote list)) (def-and-call-116 quote x-116))
        ((lambda () (define quote list) (def-and-call-116 quote x-116)))))

;; T117 circular quoted data in the form of an sc or rsc macro called in
;; the output of another sc macro
(eval '(define-syntax id-sc-117 (sc-macro-transformer (lambda (f env) (close-syntax (cadr f) env)))))
(eval '(define-syntax inner-sc-117 (sc-macro-transformer (lambda (f env) (close-syntax (cadr f) env)))))
(eval '(define-syntax inner-rsc-117 (rsc-macro-transformer (lambda (f env) ''const))))
(eval '(define-syntax outer-117
         (sc-macro-transformer
          (lambda (form env)
            (let ((c (list 'a 'b))) (set-cdr! (cdr c) c) `(inner-sc-117 (quote ,c)))))))
(check t117-nested-circular-data '(a const a)
  (let ((l (list 'a 'b)))
    (set-cdr! (cdr l) l)
    (list (car (eval `(id-sc-117 (inner-sc-117 (quote ,l)))))
          (eval `(id-sc-117 (inner-rsc-117 (quote ,l))))
          (car (eval '(outer-117))))))

;; T118 a continuation of an sc handler called after the expansion has
;; returned lowers the new result; one of a capture procedure is an error
;; (the state is in a vector set by evaluated code)
(define st-118 (vector #f 0 #f))
(eval '(define-syntax m-118
         (sc-macro-transformer
          (lambda (f e)
            (call-with-current-continuation (lambda (k) (vector-set! st-118 0 k)))
            (vector-set! st-118 1 (+ (vector-ref st-118 1) 1))
            `(list ,(close-syntax '(vector-ref st-118 1) e) ,(vector-ref st-118 1))))))
(check t118-reentered-handler '((1 1) (2 2))
  (let* ((rs '())
         (r (eval '(m-118))))
    (set! rs (cons r rs))
    (when (< (vector-ref st-118 1) 2) ((vector-ref st-118 0) #f))
    (reverse rs)))
(eval '(define-syntax m2-118
         (sc-macro-transformer
          (lambda (f e)
            (capture-syntactic-environment
             (lambda (e)
               (call-with-current-continuation (lambda (k) (vector-set! st-118 2 k)))
               ''x))))))
(check t118-reentered-capture '(x error)
  (let* ((n 0)
         (r (handle-exceptions e 'error (eval '(m2-118)))))
    (set! n (+ n 1))
    (if (= n 1) ((vector-ref st-118 2) #f) (list 'x r))))

;; T119 many identical sc macro calls in one output (they hash alike)
(define-syntax inner-119 (sc-macro-transformer (lambda (f e) (close-syntax (cadr f) e))))
(define-syntax many-119
  (sc-macro-transformer
   (lambda (f e)
     `(length (list ,@(let loop ((i 0) (r '()))
                        (if (= i 5000) r (loop (+ i 1) (cons '(inner-119 1) r)))))))))
(check t119-identical-calls 5000 (many-119))

;; T120 a body whose expansion fails and is caught by a transformer
;; does not leave a stale current body behind for the enclosing body
(define-syntax def-and-set-120
  (sc-macro-transformer
   (lambda (f env)
     `(begin (define ,(close-syntax (cadr f) env) 1)
             (set! ,(close-syntax (cadr f) env)
                   (+ 1 ,(close-syntax (cadr f) env)))))))
(define-syntax probe-eval-120
  (er-macro-transformer
   (lambda (f r c)
     (handle-exceptions e (list (r 'quote) 'caught)
       (eval '(let ()
                (define-syntax bad
                  (er-macro-transformer (lambda (f r c) (error "boom"))))
                (bad)
                1))))))
(define (f-120)
  (probe-eval-120)
  (def-and-set-120 zz)
  zz)
(check t120-body-restored-after-error 2 (f-120))

(print *pass* " passed, " *fail* " failed")
(unless (zero? *fail*) (exit 1))
