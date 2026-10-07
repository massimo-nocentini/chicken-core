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
;;; [CHICKEN] capture-syntactic-environment is eager: the environment is
;;; the one of the place where the capture occurs in the transformer's
;;; output, minus the bindings made by that same output.  MIT and chibi
;;; would yield #f here.
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
(define saved-env-60 (list #f))
(check t60-dead-environment #t
  (begin
    (eval '(let-syntax ((keep (sc-macro-transformer
                               (lambda (f e) (set-car! saved-env-60 e) #t))))
             (keep)))
    (handle-exceptions e #t (close-syntax 'x (car saved-env-60)) #f)))

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

;; T68 [CHICKEN] two closures of the same name in the same environment
;; are the same identifier, so a usage-closed binder binds the user's
;; name (MIT 9.2 and chibi treat each closure object as a new identifier
;; here and would yield outer)
(define-syntax bind-68
  (sc-macro-transformer
   (lambda (f env)
     `(let ((,(close-syntax (cadr f) env) 10)) ,(close-syntax (caddr f) env)))))
(check t68-same-closed-identifier 10 (let ((y 'outer)) (bind-68 y y)))

;;; ------------------------------------------------------------------
;;; A closure carries its own context (paper sec. 3.1): binders that the
;;; surrounding output introduces do not capture its names, only its
;;; free names.

;; T69 output closed in the usage environment binds a raw x around a
;; closure of x in that same environment
(define-syntax d1u-69
  (sc-macro-transformer
   (lambda (f env)
     (make-syntactic-closure env '()
       `(list ((lambda (x) ,(make-syntactic-closure env '() 'x)) 'inner)
              ((lambda (x) ,(make-syntactic-closure env '(x) 'x)) 'inner))))))
(check t69-closure-not-captured-usage '(outer inner)
  (let ((x 'outer)) (d1u-69)))

;; T70 the same in rsc, the usage environment obtained by a capture
(define-syntax d1r-70
  (rsc-macro-transformer
   (lambda (f menv)
     (capture-syntactic-environment
      (lambda (uenv) `(let ((x 'inner)) ,(close-syntax (cadr f) uenv)))))))
(check t70-closure-not-captured-rsc 'outer (let ((x 'outer)) (d1r-70 x)))

;; T71 and in sc, for a closure in the macro environment: the raw
;; binder temp-71 does not capture the closure of temp-71
(define temp-71 'global)
(define-syntax d1m-71
  (sc-macro-transformer
   (lambda (f env)
     (capture-syntactic-environment
      (lambda (menv)
        `(let ((temp-71 'inner)) (list ,(close-syntax 'temp-71 menv) temp-71)))))))
(check t71-closure-not-captured-macro-env '(global inner) (d1m-71))

;; T72 [CHICKEN] a capture inside the output gives the environment of
;; its place, binders of the output included (as in MIT Scheme); a
;; definition made by the output is seen by closures of the same
;; environment
(define-syntax d1-72
  (sc-macro-transformer
   (lambda (f env)
     `(let ((x 'inner)) ,(capture-syntactic-environment (lambda (e) (close-syntax 'x e)))))))
(define-syntax define-rec-72
  (sc-macro-transformer
   (lambda (f env)
     (make-syntactic-closure env '()
       `(define ,(cadr f) ,(make-syntactic-closure env '() (caddr f)))))))
(define-rec-72 fact-72 (lambda (n) (if (= n 0) 1 (* n (fact-72 (- n 1))))))
(check t72-nested-capture-and-definitions '(inner 120 24)
  (list (d1-72) (fact-72 5)
        (let () (define-rec-72 f (lambda (n) (if (= n 0) 1 (* n (f (- n 1)))))) (f 4))))

;;; ------------------------------------------------------------------
;;; Section 4 of the paper: advertised environments, extending
;;; environments, macrologies, expanders

;; T73 the expanders of section 3.2, verbatim, run as transformers
(begin-for-syntax
 (define (push-expander-73 syntactic-env exp)
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
 (define (or-expander-73 syntactic-env exp)
   (let ((exp-1 (make-syntactic-closure
                 syntactic-env '()
                 (cadr exp)))
         (exp-2 (make-syntactic-closure
                 syntactic-env '()
                 (caddr exp))))
     (make-syntactic-closure
      scheme-syntactic-environment '()
      `((lambda (temp)
          (if temp temp ,exp-2))
        ,exp-1))))
 (define (catch-expander-73 syntactic-env exp)
   (let ((body-exp (make-syntactic-closure
                    syntactic-env '(throw)
                    (cadr exp))))
     (make-syntactic-closure
      scheme-syntactic-environment '()
      `(call-with-current-continuation
        (lambda (throw) ,body-exp))))))
(define-syntax push-73 (expander-macro-transformer push-expander-73))
(define-syntax or-73 (expander-macro-transformer or-expander-73))
(define-syntax catch-73 (expander-macro-transformer catch-expander-73))
(check t73-paper-expanders '((foo) tv x (outer inner) 5)
  (list (let ((stack '())) (let ((cons 6)) (push-73 'foo stack)) stack)
        (let ((temp 'tv)) (or-73 #f temp))
        (catch-73 (+ 5 (throw 'x)))
        (catch-73 (list 'outer (catch-73 (throw 'inner))))
        (let-syntax ((if (syntax-rules () ((_ . r) 'hijacked))))
          (let ((lambda 1)) (or-73 #f 5)))))

;; T74 extend-syntactic-environment and a macrology: the keywords of
;; scheme-syntactic-environment are the standard ones, its variables
;; are absolute, other names are global
(begin-for-syntax
 (define (pop-expander-74 syntactic-env exp)
   (let ((var (make-syntactic-closure syntactic-env '() (cadr exp))))
     (make-syntactic-closure scheme-syntactic-environment '()
       `(let ((top (car ,var))) (set! ,var (cdr ,var)) top))))
 (define (stack-macrology-74 env)
   (extend-syntactic-environment
    (extend-syntactic-environment env 'push push-expander-73)
    'pop pop-expander-74)))
(define-syntax with-stack-74
  (expander-macro-transformer
   (lambda (env exp)
     (make-syntactic-closure (stack-macrology-74 env) '() (cadr exp)))))
(define-syntax push-pop-74
  (expander-macro-transformer
   (lambda (env exp)
     (make-syntactic-closure (stack-macrology-74 scheme-syntactic-environment) '()
       `(begin (push 1 ,(make-syntactic-closure env '() (cadr exp)))
               (pop ,(make-syntactic-closure env '() (cadr exp))))))))
(define push 'global-push)
(check t74-extend-and-macrology '((2 (1)) 1 global-push)
  (list (let ((s '()) (car cdr) (top 0))
          (with-stack-74 (begin (push 1 s) (push 2 s) (list (pop s) s))))
        (let ((s '(0)) (let 3) (set! 4)) (push-pop-74 s))
        push))

;; T75 problem 4 of the paper: CONTORTED's helper keyword `use' is known
;; only to the code CONTORTED writes
(begin-for-syntax
 (define (contorted-expander-75 syntactic-env exp)
   (let* ((test (make-syntactic-closure syntactic-env '() (cadr exp)))
          (x (make-syntactic-closure syntactic-env '() (caddr exp)))
          (y (make-syntactic-closure syntactic-env '() (cadddr exp)))
          (use-env
           (extend-syntactic-environment
            scheme-syntactic-environment 'use
            (lambda (use-syntactic-env use-exp)
              (make-syntactic-closure scheme-syntactic-environment '()
                `(,(cadr use-exp) ,x ,y))))))
     (make-syntactic-closure scheme-syntactic-environment '()
       `(if ,test
            ,(make-syntactic-closure use-env '() '(use and))
            ,(make-syntactic-closure use-env '() '(use or)))))))
(define-syntax contorted-75 (expander-macro-transformer contorted-expander-75))
(check t75-contorted '(2 1 client-use)
  (list (contorted-75 #t 1 2)
        (contorted-75 #f 1 2)
        (let-syntax ((use (syntax-rules () ((_) 'client-use))))
          (contorted-75 #t (use) (use)))))

;; T76 core-syntactic-environment knows only the primitive keywords
(define-syntax in-core-76
  (expander-macro-transformer
   (lambda (env exp)
     (make-syntactic-closure core-syntactic-environment '() (cadr exp)))))
(check t76-core-environment '(1 #t)
  (list (in-core-76 ((lambda (a) (if a 1 2)) #t))
        (handle-exceptions e #t (in-core-76 (let ((a 1)) a)) #f)))

(print *pass* " passed, " *fail* " failed")
(unless (zero? *fail*) (exit 1))
