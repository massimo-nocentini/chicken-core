;;;; paper-oracle-tests.scm - the differential cases of the paper oracle
;;;; (a port of the appendix of Bawden & Rees, "Syntactic Closures", LFP
;;;; 1988), translated to CHICKEN.
;;;;
;;;; Every expected value was computed by the oracle.  The expanders are
;;;; the oracle's, written in the paper's protocol (lambda (syntactic-env
;;;; exp) ...) and run with `expander-macro-transformer'; `with-macro' and
;;;; `with-macro-rec' are the syntax-rules wrappers of the oracle's README.
;;;; Where CHICKEN gives another value, the case is a `differs' check: it
;;;; asserts CHICKEN's value and names the oracle's.

(import (chicken base) (chicken syntax) (chicken condition))

(define *pass* 0)
(define *fail* 0)
(define *differ* '())
(define-syntax value-of
  (syntax-rules ()
    ((_ expr)
     (handle-exceptions e
         (list 'error ((condition-property-accessor 'exn 'message #f) e))
       (call-with-values (lambda () expr) (lambda (x . _) x))))))
(define (report name v expected)
  (if (equal? v expected)
      (begin (set! *pass* (+ *pass* 1)) (print "ok   " name))
      (begin (set! *fail* (+ *fail* 1))
             (print "FAIL " name " got: " v " expected: " expected))))
(define-syntax check
  (syntax-rules ()
    ((_ name expected expr) (report 'name (value-of expr) expected))))
;; The oracle signals an error: so must CHICKEN (at run time).
(define-syntax check-error
  (syntax-rules ()
    ((_ name expr)
     (report 'name (let ((v (value-of expr))) (and (pair? v) (eq? (car v) 'error))) #t))))
;; CHICKEN disagrees with the oracle: assert CHICKEN's value (one of
;; CHICKEN-VALUES, which differ between csi and csc for the cases that
;; hit the alias resolution bug described in section 5).
(define-syntax differs
  (syntax-rules ()
    ((_ name oracle chicken-values expr)
     (let ((v (value-of expr)))
       (set! *differ* (cons 'name *differ*))
       (report 'name (if (member v chicken-values) v (list v 'not-in chicken-values))
               v)))))

;;; ------------------------------------------------------------------
;;; 1. Host globals

(define gv 'global-gv)
(define it 'global-it)

;;; ------------------------------------------------------------------
;;; 2. Expanders, as in the oracle (paper protocol)

(begin-for-syntax

;; Section 3.2, verbatim.
(define (push-expander syntactic-env exp)
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

;; Section 3.2 OR, verbatim (bound to OR2).
(define (or2-expander syntactic-env exp)
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

;; Section 3.2, verbatim.
(define (catch-expander syntactic-env exp)
  (let ((body-exp (make-syntactic-closure
                   syntactic-env '(throw)
                   (cadr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(call-with-current-continuation
       (lambda (throw) ,body-exp)))))

(define (pop-expander syntactic-env exp)
  (let ((var (make-syntactic-closure syntactic-env '() (cadr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(let ((top (car ,var)))
        (set! ,var (cdr ,var))
        top))))

;; Section 4.3: a macrology is a procedure from environments to
;; environments.
(define (stack-macrology syntactic-env)
  (extend-syntactic-environment
   (extend-syntactic-environment syntactic-env 'push push-expander)
   'pop pop-expander))

(define (contorted-expander syntactic-env exp)
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

(define (contorted2-expander syntactic-env exp)
  (let ((test (make-syntactic-closure syntactic-env '() (cadr exp)))
        (x (make-syntactic-closure syntactic-env '() (caddr exp)))
        (y (make-syntactic-closure syntactic-env '() (cadddr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(with-macro (use) '(list 'contorted-use)
        (if ,test (list (use) ,x) (list (use) ,y))))))

(define (d1u-expander syntactic-env exp)
  (make-syntactic-closure
   syntactic-env '()
   `((lambda (x) ,(make-syntactic-closure syntactic-env '() 'x))
     'inner)))

(define (d1u-free-expander syntactic-env exp)
  (make-syntactic-closure
   syntactic-env '()
   `((lambda (x) ,(make-syntactic-closure syntactic-env '(x) 'x))
     'inner)))

(define (d1m-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `((lambda (gv) ,(make-syntactic-closure
                    scheme-syntactic-environment '() 'gv))
     'inner)))

(define (d1m-free-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `((lambda (gv) ,(make-syntactic-closure
                    scheme-syntactic-environment '(gv) 'gv))
     'inner)))

(define (d1-arg-expander syntactic-env exp)
  (make-syntactic-closure
   syntactic-env '()
   `((lambda (x) ,(make-syntactic-closure syntactic-env '() (cadr exp)))
     'inner)))

(define (bind2-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `(let ((,(make-syntactic-closure syntactic-env '() (cadr exp)) 10))
      ,(make-syntactic-closure syntactic-env '() (caddr exp)))))

(define (bind-same-expander syntactic-env exp)
  (let ((c (make-syntactic-closure syntactic-env '() (cadr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(let ((,c 10)) ,c))))

(define (bind-lambda-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `((lambda (,(make-syntactic-closure syntactic-env '() (cadr exp)))
       ,(make-syntactic-closure syntactic-env (list (cadr exp))
                                (caddr exp)))
     10)))

(define (bind-raw-expander syntactic-env exp)
  (let ((name (cadr exp)))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `((lambda (,name)
         ,(make-syntactic-closure syntactic-env (list name) (cadddr exp)))
       ,(make-syntactic-closure syntactic-env '() (caddr exp))))))

(define (nest-free-expander syntactic-env exp)
  (let* ((b (make-syntactic-closure syntactic-env '(it) (cadr exp)))
         (m (make-syntactic-closure syntactic-env '(it) `(list ,b))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `((lambda (it) ,m) 'bound))))

(define (nest-stop-expander syntactic-env exp)
  (let* ((b (make-syntactic-closure syntactic-env '(it) (cadr exp)))
         (m (make-syntactic-closure syntactic-env '() `(list ,b))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `((lambda (it) ,m) 'bound))))

(define (nest-stop-global-expander syntactic-env exp)
  (let* ((b (make-syntactic-closure syntactic-env '(it) (cadr exp)))
         (m (make-syntactic-closure scheme-syntactic-environment '()
                                    `(list ,b))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `((lambda (it) ,m) 'bound))))

(define (with-it-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `((lambda (it)
       ,(make-syntactic-closure syntactic-env '(it) (caddr exp)))
     ,(make-syntactic-closure syntactic-env '() (cadr exp)))))

(define (pass-it-expander syntactic-env exp)
  (make-syntactic-closure
   case-syntactic-environment '()
   `(with-it 'from-pass-it
      ,(make-syntactic-closure syntactic-env '(it) (cadr exp)))))

(define (with-local-push-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `(with-macro (push a b) ''local-push
      ,(make-syntactic-closure syntactic-env '(push) (cadr exp)))))

(define (with-hidden-push-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `(with-macro (push a b) ''local-push
      ,(make-syntactic-closure syntactic-env '() (cadr exp)))))

(define (swap-expander syntactic-env exp)
  (let ((a (make-syntactic-closure syntactic-env '() (cadr exp)))
        (b (make-syntactic-closure syntactic-env '() (caddr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(let ((tmp ,a)) (set! ,a ,b) (set! ,b tmp)))))

(define (with-swap-expander syntactic-env exp)
  (make-syntactic-closure
   (extend-syntactic-environment syntactic-env 'swap! swap-expander)
   '()
   (cadr exp)))

(define (push-or-expander syntactic-env exp)
  (let ((args (make-syntactic-closure-list syntactic-env '() (cdr exp))))
    (make-syntactic-closure
     (stack-macrology scheme-syntactic-environment) '()
     `(push (or ,(car args) ,(cadr args)) ,(caddr args)))))

(define (twice-expander syntactic-env exp)
  (let ((e (make-syntactic-closure syntactic-env '() (cadr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(begin ,e ,e))))

;; The paper's scheme-macrology (appendix), verbatim but for DELAY and
;; WITH-MACRO(-REC), which the cases do not need here: they are
;; CHICKEN's own and the README's wrappers.
(define (scheme-macrology base-syntactic-env)
  (define (and-expander syntactic-env exp)
    (let ((operands (make-syntactic-closure-list
                     syntactic-env '()
                     (cdr exp))))
      (cond ((null? operands)
             (make-syntactic-closure final-syntactic-env '() '#t))
            ((null? (cdr operands)) (car operands))
            (else
             (make-syntactic-closure
              final-syntactic-env '()
              `(let ((temp ,(car operands)))
                 (if temp
                     (and ,@(cdr operands))
                     temp)))))))
  (define (or-expander syntactic-env exp)
    (let ((operands (make-syntactic-closure-list
                     syntactic-env '()
                     (cdr exp))))
      (cond ((null? operands)
             (make-syntactic-closure final-syntactic-env '() '#f))
            ((null? (cdr operands)) (car operands))
            (else
             (make-syntactic-closure
              final-syntactic-env '()
              `(let ((temp ,(car operands)))
                 (if temp
                     temp
                     (or ,@(cdr operands)))))))))
  (define (let-expander syntactic-env exp)
    (let ((identifiers (map car (cadr exp))))
      (make-syntactic-closure final-syntactic-env '()
        `((lambda ,identifiers
            ,@(make-syntactic-closure-list
               syntactic-env identifiers
               (cddr exp)))
          ,@(make-syntactic-closure-list
             syntactic-env '()
             (map cadr (cadr exp)))))))
  (define (cond-expander syntactic-env exp)
    (make-syntactic-closure final-syntactic-env '()
      (process-cond-clauses syntactic-env (cdr exp))))
  (define (process-cond-clauses syntactic-env clauses)
    (let ((body (make-syntactic-closure-list
                 syntactic-env '()
                 (cdar clauses))))
      (cond ((not (null? (cdr clauses)))
             (let ((test (make-syntactic-closure
                          syntactic-env '()
                          (caar clauses)))
                   (rest (process-cond-clauses
                          syntactic-env
                          (cdr clauses))))
               (if (null? body)
                   `(or ,test ,rest)
                   `(if ,test
                        (begin ,@body)
                        ,rest))))
            ((eq? (caar clauses) 'else)
             `(begin ,@body))
            (else
             (let ((test (make-syntactic-closure
                          syntactic-env '()
                          (caar clauses))))
               (if (null? body)
                   test
                   `(if ,test (begin ,@body))))))))
  (define (case-expander syntactic-env exp)
    (make-syntactic-closure final-syntactic-env '()
      `(let ((temp ,(make-syntactic-closure
                     syntactic-env '()
                     (cadr exp))))
         ,(process-case-clauses syntactic-env (cddr exp)))))
  (define (process-case-clauses syntactic-env clauses)
    (let ((data (caar clauses))
          (body (make-syntactic-closure-list
                 syntactic-env '()
                 (cdar clauses))))
      (cond ((not (null? (cdr clauses)))
             (let ((rest (process-case-clauses
                          syntactic-env
                          (cdr clauses))))
               `(if (memv temp ',data)
                    (begin ,@body)
                    ,rest)))
            ((eq? data 'else) `(begin ,@body))
            (else `(if (memv temp ',data)
                       (begin ,@body))))))
  (define final-syntactic-env #f)
  (do ((syntactic-env base-syntactic-env
                      (extend-syntactic-environment
                       syntactic-env
                       (caar pairs)
                       (cadar pairs)))
       (pairs (list (list 'or or-expander)
                    (list 'and and-expander)
                    (list 'let let-expander)
                    (list 'cond cond-expander)
                    (list 'case case-expander))
              (cdr pairs)))
      ((null? pairs)
       (set! final-syntactic-env syntactic-env)))
  final-syntactic-env)

(define (new-if-expander syntactic-env exp)
  (let ((parts (make-syntactic-closure-list syntactic-env '() (cdr exp))))
    (make-syntactic-closure
     core-syntactic-environment '()
     `(if (not ,(car parts)) ,@(cdr parts)))))

(define new-if-syntactic-environment
  (scheme-macrology
   (extend-syntactic-environment
    core-syntactic-environment
    'if
    new-if-expander)))

(define (with-new-if-expander syntactic-env exp)
  (make-syntactic-closure new-if-syntactic-environment '() (cadr exp)))

(define (in-core-expander syntactic-env exp)
  (make-syntactic-closure core-syntactic-environment '() (cadr exp)))

(define (set-both-expander syntactic-env exp)
  (let ((a (make-syntactic-closure syntactic-env '() (cadr exp)))
        (b (make-syntactic-closure syntactic-env '() (caddr exp)))
        (v (make-syntactic-closure syntactic-env '() (cadddr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(let ((val ,v)) (set! ,a val) (set! ,b val)))))

(define (inc-shadow-expander syntactic-env exp)
  (let ((v (make-syntactic-closure syntactic-env '() (cadr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `((lambda (,(cadr exp)) (set! ,v (+ ,v 1))) 'junk))))

(define (cons-it-expander syntactic-env exp)
  (make-syntactic-closure
   syntactic-env '()
   (make-syntactic-closure
    scheme-syntactic-environment '(it)
    `(cons it ,(make-syntactic-closure syntactic-env '() (cadr exp))))))

(define (reclose-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   (make-syntactic-closure
    syntactic-env '()
    (make-syntactic-closure syntactic-env '() (cadr exp)))))

(define (quote-it-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `(quote ,(make-syntactic-closure syntactic-env '() (cadr exp)))))

(define (quote-raw-expander syntactic-env exp)
  (make-syntactic-closure scheme-syntactic-environment '() ''temp))

(define (unclosed-expander syntactic-env exp)
  '(+ 1 2))

;; The oracle's case-macrology, used here for PASS-IT's environment.
(define (case-macrology syntactic-env)
  (extend-syntactic-environment (stack-macrology syntactic-env)
                                'with-it with-it-expander))

(define case-syntactic-environment
  (case-macrology scheme-syntactic-environment))

) ; begin-for-syntax

;;; ------------------------------------------------------------------
;;; 3. The keywords of the cases, at toplevel

(define-syntax with-macro
  (syntax-rules ()
    ((_ (kw . params) template body ...)
     (let-syntax ((kw (sc-macro-transformer
                       (lambda (exp env)
                         (apply (lambda params template)
                                (make-syntactic-closure-list env '() (cdr exp)))))))
       body ...))))
(define-syntax with-macro-rec
  (syntax-rules ()
    ((_ (kw . params) template body ...)
     (letrec-syntax ((kw (sc-macro-transformer
                          (lambda (exp env)
                            (apply (lambda params template)
                                   (make-syntactic-closure-list env '() (cdr exp)))))))
       body ...))))

(define-syntax push (expander-macro-transformer push-expander))
(define-syntax pop (expander-macro-transformer pop-expander))
(define-syntax or2 (expander-macro-transformer or2-expander))
(define-syntax catch (expander-macro-transformer catch-expander))
(define-syntax contorted (expander-macro-transformer contorted-expander))
(define-syntax contorted2 (expander-macro-transformer contorted2-expander))
(define-syntax d1u (expander-macro-transformer d1u-expander))
(define-syntax d1u-free (expander-macro-transformer d1u-free-expander))
(define-syntax d1m (expander-macro-transformer d1m-expander))
(define-syntax d1m-free (expander-macro-transformer d1m-free-expander))
(define-syntax d1-arg (expander-macro-transformer d1-arg-expander))
(define-syntax bind2 (expander-macro-transformer bind2-expander))
(define-syntax bind-same (expander-macro-transformer bind-same-expander))
(define-syntax bind-lambda (expander-macro-transformer bind-lambda-expander))
(define-syntax bind-raw (expander-macro-transformer bind-raw-expander))
(define-syntax nest-free (expander-macro-transformer nest-free-expander))
(define-syntax nest-stop (expander-macro-transformer nest-stop-expander))
(define-syntax nest-stop-global (expander-macro-transformer nest-stop-global-expander))
(define-syntax with-it (expander-macro-transformer with-it-expander))
(define-syntax pass-it (expander-macro-transformer pass-it-expander))
(define-syntax with-local-push (expander-macro-transformer with-local-push-expander))
(define-syntax with-hidden-push (expander-macro-transformer with-hidden-push-expander))
(define-syntax with-swap (expander-macro-transformer with-swap-expander))
(define-syntax push-or (expander-macro-transformer push-or-expander))
(define-syntax twice (expander-macro-transformer twice-expander))
(define-syntax with-new-if (expander-macro-transformer with-new-if-expander))
(define-syntax in-core (expander-macro-transformer in-core-expander))
(define-syntax set-both! (expander-macro-transformer set-both-expander))
(define-syntax inc-shadow! (expander-macro-transformer inc-shadow-expander))
(define-syntax cons-it (expander-macro-transformer cons-it-expander))
(define-syntax reclose (expander-macro-transformer reclose-expander))
(define-syntax quote-it (expander-macro-transformer quote-it-expander))
(define-syntax quote-raw (expander-macro-transformer quote-raw-expander))
(define-syntax unclosed (expander-macro-transformer unclosed-expander))

;;; ------------------------------------------------------------------
;;; 4. The cases

(check p1-push-local-cons
       '(foo)
       ((lambda (stack) (let ((cons 6)) (push 'foo stack)) stack) '()))
(check p1-push-local-cons-set!-keyword-local
       '(foo bar)
       ((lambda (stack)
          (with-macro
            (set! flag)
            ''hijacked
            (let ((cons 6)) (push 'foo stack)))
          stack)
        '(bar)))
(check p2-or2-temp 'tv ((lambda (temp x y) (or2 (memq x y) temp)) 'tv 'a '(b)))
(check p2-macrology-or-temp
       'tv
       ((lambda (temp x y) (or (memq x y) temp)) 'tv 'a '(b)))
(check p2-macrology-and-temp 'tv ((lambda (temp) (and 1 temp)) 'tv))
(check p2-case-temp 'tv ((lambda (temp) (case 2 ((1) 'one) ((2) temp))) 'tv))
(check p3-with-macro-set!
       '(foo)
       ((lambda (stack)
          (with-macro (set! flag) '(list 'set-flag! ',flag) (push 'foo stack))
          stack)
        '()))
(check p3-local-set!-still-usable
       'local-set!-used
       (with-macro (set! flag) ''local-set!-used (set! 1)))
(check p4-contorted-and '2 (contorted #t 1 2))
(check p4-contorted-or '1 (contorted #f 1 2))
(check p4-contorted-client-use
       'client-use
       (with-macro (use) ''client-use (contorted #t (use) (use))))
(check p4-contorted2-client-use
       '((contorted-use) client-use)
       (with-macro (use) ''client-use (contorted2 #t (use) 'unused)))
(check catch-throw 'x (catch (+ 5 (throw 'x))))
(check catch-no-throw '6 (catch (+ 5 1)))
(check catch-nested-inner
       '(outer inner)
       (catch (list 'outer (catch (throw 'inner)))))
(check catch-client-binds-throw
       '(client mine)
       (catch ((lambda (throw) (throw 'mine)) (lambda (v) (list 'client v)))))
(check s44-adjoin
       '(3 0)
       ((lambda (n m sum-stack)
          (let ((adjoin cons))
            (with-macro
              (push frob stack)
              `(set! ,stack (adjoin ,frob ,stack))
              (let ((adjoin +)) (push (adjoin n m) sum-stack))))
          sum-stack)
        1
        2
        '(0)))
(check s44-with-macro-template-temp
       '5
       (with-macro
         (my-or a b)
         `(let ((temp ,a)) (if temp temp ,b))
         (let ((temp 5)) (my-or #f temp))))
(check s44-with-macro-not-recursive
       'outer-m
       (with-macro (m) ''outer-m (with-macro (m) '(m) (m))))
(check s44-with-macro-rec-or
       '7
       (with-macro-rec
         (or exp . other-exps)
         (if (null? other-exps)
           exp
           `(let ((temp ,exp)) (if temp temp (or ,@other-exps))))
         (let ((temp 7)) (or #f #f temp))))
(check s44-with-macro-rec-or-shadows-global
       '(last #f)
       (with-macro-rec
         (or exp . other-exps)
         (if (null? other-exps)
           `(list 'last ,exp)
           `(let ((temp ,exp)) (if temp temp (or ,@other-exps))))
         (or #f #f)))
(check s44-with-macro-param-named-list
       '(1 2)
       (with-macro (two list cons) `(list ,list ,cons) (two 1 2)))
(check d1-usage-env 'outer ((lambda (x) (d1u)) 'outer))
(check d1-usage-env-free-name 'inner ((lambda (x) (d1u-free)) 'outer))
(check d1-macro-env 'global-gv (d1m))
;; [DIFFERS: alias bug] A global name of an advertised environment is
;; an alias of the global name; placed under a local binding of the
;; same name it is captured by CHICKEN's alias resolution (csc) or
;; becomes an unbound gensym (csi).  Pre-existing, see section 5.
(differs d1-macro-env-under-local-gv 'global-gv '(local (error "unbound variable")) ((lambda (gv) (d1m)) 'local))
(check d1-macro-env-free-name 'inner (d1m-free))
(check d1-user-arg 'outer ((lambda (x) (d1-arg x)) 'outer))
(check d1-with-macro-env
       'outer
       ((lambda (temp)
          (with-macro (m e) `((lambda (temp) ,e) 'inner) (m temp)))
        'outer))
(check d1-inc-shadow '2 ((lambda (v) (inc-shadow! v) v) 1))
;; [DIFFERS: D2] two closures of the same name in the same environment
;; are one identifier in CHICKEN (binding a closure is an extension of
;; the oracle; the paper's appendix rejects it).  See section 5.
(differs d2-bind2-t68 'outer '(10) ((lambda (y) (bind2 y y)) 'outer))
(check d2-bind-same '10 ((lambda (y) (bind-same y)) 'outer))
;; [DIFFERS: alias bug] A global name of an advertised environment is
;; an alias of the global name; placed under a local binding of the
;; same name it is captured by CHICKEN's alias resolution (csc) or
;; becomes an unbound gensym (csi).  Pre-existing, see section 5.
(differs d2-bind-lambda-free-raw-name 'global-it '(10 (error "unbound variable"))
       ((lambda (it) (bind-lambda it it)) 'outer))
(check d2-paper-idiom-bind-raw '10 ((lambda (y) (bind-raw y 10 y)) 'outer))
(check d2-paper-idiom-bind-raw-init-outer
       '(outer)
       ((lambda (y) (bind-raw y (list y) y)) 'outer))
(check free-with-it '6 (with-it 5 (+ it 1)))
(check free-with-it-val-not-captured
       '(u)
       ((lambda (it) (with-it (list it) it)) 'u))
(check free-nest-flows-outward '(bound) ((lambda (it) (nest-free it)) 'user))
(check free-nest-stops-at-usage-env
       '(user)
       ((lambda (it) (nest-stop it)) 'user))
;; [DIFFERS: alias bug] A global name of an advertised environment is
;; an alias of the global name; placed under a local binding of the
;; same name it is captured by CHICKEN's alias resolution (csc) or
;; becomes an unbound gensym (csi).  Pre-existing, see section 5.
(differs free-nest-stops-at-advertised-env '(global-it) '((user) (error "unbound variable"))
       ((lambda (it) (nest-stop-global it)) 'user))
(check free-through-macro-output
       'from-pass-it
       ((lambda (it) (pass-it it)) 'user))
;; [DIFFERS: L4] a free name of a closure placed in a closure of the
;; usage environment is resolved in the usage environment as CHICKEN
;; knows it, which does not know that WITH-IT captured the name `it'
;; (the paper's filtered environment).  See section 5.
(differs free-advertised-closure-inside-usage '(w . w) '((user . w))
       ((lambda (it) (with-it 'w (cons-it it))) 'user))
(check closure-of-closure 'user ((lambda (gv) (reclose gv)) 'user))
(check closure-of-closure-in-binder
       'inner
       ((lambda (gv) ((lambda (gv) (reclose gv)) 'inner)) 'outer))
(check free-keyword-captured
       'local-push
       ((lambda (s) (with-local-push (push 1 s))) '()))
(check free-keyword-not-captured
       '(1)
       ((lambda (s) (with-hidden-push (push 1 s)) s) '()))
(check set!-target-push-pop
       '(2 (1))
       ((lambda (s) (push 1 s) (push 2 s) (list (pop s) s)) '()))
(check set!-target-two
       '(v v)
       ((lambda (a b) (set-both! a b 'v) (list a b)) 1 2))
(check set!-target-swap
       '(2 1)
       ((lambda (tmp other) (with-swap (swap! tmp other)) (list tmp other))
        1
        2))
(check mm-push-or '(x) ((lambda (s) (push-or #f 'x s) s) '()))
(check mm-push-or-local-or
       '(x)
       ((lambda (s) (with-macro (or a b) ''hijacked (push-or #f 'x s)) s) '()))
(check mm-twice-user-macro '(a a) ((lambda (s) (twice (push 'a s)) s) '()))
(check mm-twice-with-macro
       '(a a)
       ((lambda (s) (with-macro (add x) `(push ,x s) (twice (add 'a))) s) '()))
(check mm-with-macro-expands-to-with-macro
       'zz
       ((lambda (z)
          (with-macro (outer v) `(with-macro (inner) ',v (inner)) (outer z)))
        'zz))
(check mm-cond-or-and
       '(b)
       ((lambda (x) (cond ((and x (memq x '(a b)))) (else 'no))) 'b))
(check macrology-delay '3 (force (delay (+ 1 2))))
(check macrology-let-cond-case
       'medium
       (let ((x 3))
         (cond ((< x 2) 'small)
               ((case x ((3 4) #t) (else #f)) 'medium)
               (else 'large))))
(check macrology-new-if-or '#f (with-new-if (or #f 5)))
(check macrology-new-if-and '1 (with-new-if (and 1 2)))
(check macrology-new-if-cond 'a (with-new-if (cond (#f 'a) (else 'b))))
;; [DIFFERS: alias bug] A global name of an advertised environment is
;; an alias of the global name; placed under a local binding of the
;; same name it is captured by CHICKEN's alias resolution (csc) or
;; becomes an unbound gensym (csi).  Pre-existing, see section 5.
(differs macrology-new-if-closes-in-new-env 'global-gv '(user (error "unbound variable"))
       ((lambda (gv) (with-new-if gv)) 'user))
(check-error macrology-in-core-no-derived (in-core (let ((a 1)) a)))
(check-error
  extend-usage-env-swap-scoped
  ((lambda (a b) (with-swap (swap! a b)) (swap! a b)) 1 2))
(check adv-local-if-keyword '5 (with-macro (if a b c) ''hijacked (or #f 5)))
(check adv-local-lambda-keyword
       '5
       (with-macro (lambda a b) ''hijacked (or2 #f 5)))
(check adv-local-let-keyword
       '1
       ((lambda (s) (with-macro (let a b) ''hijacked (pop s))) '(1 2)))
(check adv-local-cons-memv
       '(hit)
       ((lambda (cons memv) (case 'b ((a b) (list 'hit)))) 1 2))
(check adv-local-call/cc
       'ok
       ((lambda (call-with-current-continuation) (catch (throw 'ok))) #f))
(check adv-local-make-promise
       'ok
       ((lambda (make-promise) (force (delay 'ok))) #f))

;;; ------------------------------------------------------------------
;;; 5. Disagreements with the oracle
;;;
;;; - [D2] d2-bind2-t68.  Lowering keeps one identifier per name and
;;;   environment within an expansion, so two closures of `y' in the
;;;   usage environment are the same identifier, and a closure used as a
;;;   binder binds the user's name.  The oracle's value depends on its
;;;   closure-binder extension: the paper never binds a closure, and its
;;;   appendix taken literally rejects d2-bind2-t68, d2-bind-same and
;;;   d2-bind-lambda-free-raw-name ("not a symbol").  Without closure
;;;   binders the difference is not observable: a closure used as an
;;;   expression or a set! target means the same in both (all the
;;;   set!-target-* and d1-* cases agree).  It is what makes the idiom
;;;   (define ,(close-syntax name env) ...) define the user's NAME in a
;;;   body.  d2-bind-same and the paper's own binding idiom
;;;   (d2-paper-idiom-*) agree.
;;; - [L4] free-advertised-closure-inside-usage.  A free name is resolved
;;;   when the expansion that places the closure returns; the usage
;;;   environment of a later expansion is the renaming expander's, which
;;;   does not know that an earlier `with-it' captured the name `it'.
;;; - [alias bug] d1-macro-env-under-local-gv,
;;;   d2-bind-lambda-free-raw-name, free-nest-stops-at-advertised-env,
;;;   macrology-new-if-closes-in-new-env.  The lowering gives the right
;;;   identifier (an alias of the global name), but CHICKEN resolves an
;;;   alias of a global name against the local bindings of the use site
;;;   (##sys#alias-global-hook): syntax-rules has the same problem,
;;;   (define gv 'global) (define-syntax g (syntax-rules () ((_) gv)))
;;;   ((lambda (gv) (g)) 'local) gives `local' in csc and an unbound
;;;   variable error in csi.

;;; ------------------------------------------------------------------
;;; 6. The oracle's appendix-artifact cases, with CHICKEN's own values
;;;    (the oracle's values are expository simplifications of the
;;;    appendix, see its README).

;; oracle: 2 (variables never shadow keywords in the appendix)
(check artifact-variable-named-if '(1 2 3) ((lambda (if) (if 1 2 3)) list))
;; oracle: (1)
(check artifact-variable-named-push '() ((lambda (push s) (push 1 s) s) list '()))
;; oracle: a closure object; CHICKEN strips closures in quoted data
(check artifact-closure-in-quote 'hello (quote-it hello))
(check artifact-closure-in-quote-eq #t ((lambda (q) (eq? q 'hello)) (quote-it hello)))
(check artifact-raw-symbol-in-quote 'temp (quote-raw))
;; oracle: "Unclosed expression"; sc-style transformers close the output
;; in the macro environment
(check artifact-unclosed-expansion 3 (unclosed))
(check artifact-with-macro-arg-as-keyword '(1 2) (with-macro (use k) `(,k 1 2) (use list)))
;; oracle: unbound variable `and'; a closed keyword works in CHICKEN
(check artifact-with-macro-arg-keyword-and 2 (with-macro (use k) `(,k 1 2) (use and)))

(print *pass* " passed, " *fail* " failed, "
       (length *differ*) " differ from the oracle: " (reverse *differ*))
(unless (zero? *fail*) (exit 1))
