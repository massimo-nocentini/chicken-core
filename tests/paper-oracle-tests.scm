;;;; paper-oracle-tests.scm - the differential cases of the paper oracle
;;;;
;;;; The cases and their expected values come from a port of the
;;;; appendix of Bawden & Rees, "Syntactic Closures" (LFP 1988), run as
;;;; an oracle.  Expanders are the paper's: procedures
;;;; (lambda (syntactic-env exp) ...) returning a syntactic closure,
;;;; bound with `expander-macro-transformer' or
;;;; `extend-syntactic-environment' and closing their output in
;;;; `scheme-syntactic-environment'.  Section 2 and 3 below are copied
;;;; verbatim from the oracle's cases.scm, and so are the case programs
;;;; and expected values.  Only these are translated:
;;;;  - WITH-MACRO / WITH-MACRO-REC (paper sec. 4.4) are syntax-rules
;;;;    wrappers over let-syntax / letrec-syntax;
;;;;  - an expected (*oracle-error* ...) means that CHICKEN must signal
;;;;    an error; an expansion-time error is checked through `eval';

;;;;  - the globals GV and IT are defined in a module (see section 1);
;;;;    section 7 repeats the cases where that matters with plain
;;;;    toplevel globals, as documented deviations;
;;;;  - the oracle's appendix artifacts (sec. 5 of cases.scm) are
;;;;    checked with CHICKEN's values, see the end of this file.

(import (chicken base) (chicken syntax) (chicken condition))
(import-for-syntax (chicken base) (chicken syntax))

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
(define-syntax check-error
  (syntax-rules ()
    ((_ name expr)
     (check name 'error (handle-exceptions e 'error expr)))))
;; CHICKEN differs from the oracle: both values are given, CHICKEN's
;; is checked
(define *deviations* 0)
(define-syntax check-deviation
  (syntax-rules ()
    ((_ name oracle-value chicken-value expr)
     (begin
       (set! *deviations* (+ *deviations* 1))
       (check name chicken-value expr)))))

;;; ------------------------------------------------------------------
;;; Translation of WITH-MACRO and WITH-MACRO-REC (paper sec. 4.4): the
;;; replacement is computed from the closed arguments and interpreted
;;; where the with-macro form occurs (with-macro) or inside its body
;;; (with-macro-rec).

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

;;; ------------------------------------------------------------------
;;; 1. Host globals (cases.scm section 1)
;;; [translation] The paper's free variables are host globals.  They are
;;; defined in a module here: CHICKEN's renaming expander (er,
;;; syntax-rules and so sc) does not keep a macro's reference to a
;;; global that is not module-qualified apart from a local variable of
;;; the same name at the use site (csi reports an unbound variable,
;;; compiled code takes the local one).

(module oracle-globals (gv it)
  (import scheme)
  (define gv 'global-gv)
  (define it 'global-it))
(import oracle-globals)

(begin-for-syntax

;;; ------------------------------------------------------------------
;;; The paper's SCHEME-MACROLOGY (appendix), used by sec. 4.3's NEW-IF
;;; example.  Verbatim (renamed, as chicken.syntax exports its own
;;; `scheme-macrology'), except that DELAY (it needs MIT's
;;; thunk-taking MAKE-PROMISE) and WITH-MACRO/WITH-MACRO-REC (they call
;;; the appendix's own compiler) are left out: in CHICKEN these
;;; keywords come from scheme-syntactic-environment and the wrappers
;;; above.  Section 6 checks the library's scheme-macrology too.

(define (paper-scheme-macrology base-syntactic-env)

  (define (and-expander syntactic-env exp)
    (let ((operands (make-syntactic-closure-list
                     syntactic-env '()
                     (cdr exp))))
      (cond ((null? operands)
             (make-syntactic-closure
              final-syntactic-env '()
              '#t))
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
             (make-syntactic-closure
              final-syntactic-env '()
              '#f))
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
      (process-cond-clauses syntactic-env
                            (cdr exp))))

  (define (process-cond-clauses
           syntactic-env clauses)
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
         ,(process-case-clauses syntactic-env
                                (cddr exp)))))

  (define (process-case-clauses
           syntactic-env clauses)
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

  final-syntactic-env
  )

;;; ------------------------------------------------------------------
;;; 2. Expanders

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

;; Section 3.2 OR, verbatim (bound to OR2: OR is the macrology's).
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

;; (pop var): the second half of the section 4.3 stack-macrology.
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

;; Section 1, problem 4, written with syntactic closures.  USE is
;; bound only for the code CONTORTED writes, never for TEST, X, Y.
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

;; Problem 4 again, with CONTORTED's auxiliary keyword made by the
;; macrology's WITH-MACRO: (contorted2 test x y) ->
;;   (with-macro (use) '(list 'contorted-use x y) (if test (use) (use)))
(define (contorted2-expander syntactic-env exp)
  (let ((test (make-syntactic-closure syntactic-env '() (cadr exp)))
        (x (make-syntactic-closure syntactic-env '() (caddr exp)))
        (y (make-syntactic-closure syntactic-env '() (cadddr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(with-macro (use) '(list 'contorted-use)
        (if ,test (list (use) ,x) (list (use) ,y))))))

;; D1, usage environment ("rsc"): the output is closed in the usage
;; environment and binds a raw X around a closure of X in that same
;; environment.  (d1u) => the closure's X, never the raw binder.
(define (d1u-expander syntactic-env exp)
  (make-syntactic-closure
   syntactic-env '()
   `((lambda (x) ,(make-syntactic-closure syntactic-env '() 'x))
     'inner)))

;; The same, but the closure leaves X free: now it IS captured.
(define (d1u-free-expander syntactic-env exp)
  (make-syntactic-closure
   syntactic-env '()
   `((lambda (x) ,(make-syntactic-closure syntactic-env '(x) 'x))
     'inner)))

;; D1, macro environment ("sc"): output closed in the advertised
;; environment binds a raw GV around a closure of GV in that same
;; environment => the global GV.
(define (d1m-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `((lambda (gv) ,(make-syntactic-closure
                    scheme-syntactic-environment '() 'gv))
     'inner)))

;; D1, macro env, closure leaves GV free => captured by the raw binder.
(define (d1m-free-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `((lambda (gv) ,(make-syntactic-closure
                    scheme-syntactic-environment '(gv) 'gv))
     'inner)))

;; D1 with a user argument: (d1-arg e) binds a raw X around the user's
;; E closed in the usage environment.
(define (d1-arg-expander syntactic-env exp)
  (make-syntactic-closure
   syntactic-env '()
   `((lambda (x) ,(make-syntactic-closure syntactic-env '() (cadr exp)))
     'inner)))

;; D2 / CHICKEN t68 [EXT]: (bind2 a b) =
;;   (let ((<a closed in usage env> 10)) <b closed in usage env>)
;; two DIFFERENT closure objects.
(define (bind2-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `(let ((,(make-syntactic-closure syntactic-env '() (cadr exp)) 10))
      ,(make-syntactic-closure syntactic-env '() (caddr exp)))))

;; [EXT] (bind-same a): the SAME closure object as binder and reference.
(define (bind-same-expander syntactic-env exp)
  (let ((c (make-syntactic-closure syntactic-env '() (cadr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(let ((,c 10)) ,c))))

;; [EXT] (bind-lambda name body): closure as a LAMBDA binder, body
;; closed with NAME (the raw symbol) left free.
(define (bind-lambda-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `((lambda (,(make-syntactic-closure syntactic-env '() (cadr exp)))
       ,(make-syntactic-closure syntactic-env (list (cadr exp))
                                (caddr exp)))
     10)))

;; The paper's own idiom for binding forms (cf. the macrology's LET):
;; (bind-raw name init body) binds the raw NAME and leaves it free in BODY.
(define (bind-raw-expander syntactic-env exp)
  (let ((name (cadr exp)))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `((lambda (,name)
         ,(make-syntactic-closure syntactic-env (list name) (cadddr exp)))
       ,(make-syntactic-closure syntactic-env '() (caddr exp))))))

;; Nested closures with free names.  (nest-free body):
;;   ((lambda (it) <M>) 'bound)  where M = closure in the usage env
;;   leaving IT free of (list <B>), B = closure in the usage env
;;   leaving IT free of BODY.  IT flows outward through M to the binder.
(define (nest-free-expander syntactic-env exp)
  (let* ((b (make-syntactic-closure syntactic-env '(it) (cadr exp)))
         (m (make-syntactic-closure syntactic-env '(it) `(list ,b))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `((lambda (it) ,m) 'bound))))

;; As NEST-FREE but M does not leave IT free: B's IT stops at M, whose
;; environment is the usage environment.
(define (nest-stop-expander syntactic-env exp)
  (let* ((b (make-syntactic-closure syntactic-env '(it) (cadr exp)))
         (m (make-syntactic-closure syntactic-env '() `(list ,b))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `((lambda (it) ,m) 'bound))))

;; As NEST-STOP but M is closed in the advertised environment: B's IT
;; stops at M and resolves to the global IT.
(define (nest-stop-global-expander syntactic-env exp)
  (let* ((b (make-syntactic-closure syntactic-env '(it) (cadr exp)))
         (m (make-syntactic-closure scheme-syntactic-environment '()
                                    `(list ,b))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `((lambda (it) ,m) 'bound))))

;; (with-it val body): binds IT for BODY (an anaphoric macro).
(define (with-it-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `((lambda (it)
       ,(make-syntactic-closure syntactic-env '(it) (caddr exp)))
     ,(make-syntactic-closure syntactic-env '() (cadr exp)))))

;; (pass-it body): wraps BODY in a closure that leaves IT free and puts
;; it inside a (with-it 'from-pass-it ...) of its own.  The user's IT is
;; captured by pass-it's with-it.
(define (pass-it-expander syntactic-env exp)
  (make-syntactic-closure
   case-syntactic-environment '()   ; an advertised env that has WITH-IT
   `(with-it 'from-pass-it
      ,(make-syntactic-closure syntactic-env '(it) (cadr exp)))))

;; Keyword capture (the "analogous case for binding of syntactic
;; keywords", sec. 1): (with-local-push body) binds PUSH by WITH-MACRO
;; and leaves PUSH free in BODY, so BODY's push is the local one.
(define (with-local-push-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `(with-macro (push a b) ''local-push
      ,(make-syntactic-closure syntactic-env '(push) (cadr exp)))))

;; Same but PUSH not left free: BODY keeps the usage environment's PUSH.
(define (with-hidden-push-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `(with-macro (push a b) ''local-push
      ,(make-syntactic-closure syntactic-env '() (cadr exp)))))

;; Closing user code in an extended copy of ITS OWN environment
;; (extend-syntactic-environment on the usage env): (with-swap body)
;; makes (swap! a b) available inside BODY only.
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

;; Macro expanding into macros: (push-or a b var) =
;; (push (or2 a b) var), all closed in the advertised environment.
(define (push-or-expander syntactic-env exp)
  (let ((args (make-syntactic-closure-list syntactic-env '() (cdr exp))))
    (make-syntactic-closure
     (stack-macrology scheme-syntactic-environment) '()
     `(push (or ,(car args) ,(cadr args)) ,(caddr args)))))

;; Macro whose output uses a USER macro: (twice e) => (begin e e) with
;; E closed in the usage environment (E may itself be a macro call).
(define (twice-expander syntactic-env exp)
  (let ((e (make-syntactic-closure syntactic-env '() (cadr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(begin ,e ,e))))

;; Section 4.3: an alternative IF and the Scheme derived keywords
;; rebuilt on top of it.  NEW-IF negates the test.
(define (new-if-expander syntactic-env exp)
  (let ((parts (make-syntactic-closure-list syntactic-env '() (cdr exp))))
    (make-syntactic-closure
     core-syntactic-environment '()
     `(if (not ,(car parts)) ,@(cdr parts)))))

(define new-if-syntactic-environment
  (paper-scheme-macrology
   (extend-syntactic-environment
    core-syntactic-environment
    'if
    new-if-expander)))

;; (with-new-if e): compile the user's E in new-if-syntactic-environment
;; (an advertised environment), NOT in E's own environment.
(define (with-new-if-expander syntactic-env exp)
  (make-syntactic-closure new-if-syntactic-environment '() (cadr exp)))

;; (in-core e): E compiled in core-syntactic-environment: no derived
;; keywords at all.
(define (in-core-expander syntactic-env exp)
  (make-syntactic-closure core-syntactic-environment '() (cadr exp)))

;; Closures as SET! targets: (set-both! a b v) sets the user's A and B.
(define (set-both-expander syntactic-env exp)
  (let ((a (make-syntactic-closure syntactic-env '() (cadr exp)))
        (b (make-syntactic-closure syntactic-env '() (caddr exp)))
        (v (make-syntactic-closure syntactic-env '() (cadddr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `(let ((val ,v)) (set! ,a val) (set! ,b val)))))

;; (inc! v): (set! v (+ v 1)); with an output-introduced binder named
;; like the user's variable: ((lambda (v) (set! <v> (+ <v> 1))) 'junk).
(define (inc-shadow-expander syntactic-env exp)
  (let ((v (make-syntactic-closure syntactic-env '() (cadr exp))))
    (make-syntactic-closure
     scheme-syntactic-environment '()
     `((lambda (,(cadr exp)) (set! ,v (+ ,v 1))) 'junk))))

;; Closing an expression with a free name in an advertised environment:
;; (cons-it e) closes `(cons it ,e)` in the advertised env leaving IT
;; free; the closure is placed inside the user's code by the caller's
;; with-it, so IT is the user's.
(define (cons-it-expander syntactic-env exp)
  (make-syntactic-closure
   syntactic-env '()
   (make-syntactic-closure
    scheme-syntactic-environment '(it)
    `(cons it ,(make-syntactic-closure syntactic-env '() (cadr exp))))))

;; (reclose e): the user's closure closed again, in another env; a
;; closed expression is context insensitive (sec. 3.2).
(define (reclose-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   (make-syntactic-closure
    syntactic-env '()
    (make-syntactic-closure syntactic-env '() (cadr exp)))))

;; (quote-it e) => (quote <closure of e>): a closure inside QUOTE.
(define (quote-it-expander syntactic-env exp)
  (make-syntactic-closure
   scheme-syntactic-environment '()
   `(quote ,(make-syntactic-closure syntactic-env '() (cadr exp)))))

;; (quote-raw) => (quote temp): raw symbols in quoted output are data.
(define (quote-raw-expander syntactic-env exp)
  (make-syntactic-closure scheme-syntactic-environment '() ''temp))

;; An expander that violates the protocol: it returns an unclosed
;; expression.
(define (unclosed-expander syntactic-env exp)
  '(+ 1 2))

;;; ------------------------------------------------------------------
;;; 3. The environment of the cases

(define (case-macrology syntactic-env)
  (let loop ((env (stack-macrology syntactic-env))
             (pairs (list (list 'or2 or2-expander)
                          (list 'catch catch-expander)
                          (list 'contorted contorted-expander)
                          (list 'contorted2 contorted2-expander)
                          (list 'd1u d1u-expander)
                          (list 'd1u-free d1u-free-expander)
                          (list 'd1m d1m-expander)
                          (list 'd1m-free d1m-free-expander)
                          (list 'd1-arg d1-arg-expander)
                          (list 'bind2 bind2-expander)
                          (list 'bind-same bind-same-expander)
                          (list 'bind-lambda bind-lambda-expander)
                          (list 'bind-raw bind-raw-expander)
                          (list 'nest-free nest-free-expander)
                          (list 'nest-stop nest-stop-expander)
                          (list 'nest-stop-global nest-stop-global-expander)
                          (list 'with-it with-it-expander)
                          (list 'pass-it pass-it-expander)
                          (list 'with-local-push with-local-push-expander)
                          (list 'with-hidden-push with-hidden-push-expander)
                          (list 'with-swap with-swap-expander)
                          (list 'push-or push-or-expander)
                          (list 'twice twice-expander)
                          (list 'with-new-if with-new-if-expander)
                          (list 'in-core in-core-expander)
                          (list 'set-both! set-both-expander)
                          (list 'inc-shadow! inc-shadow-expander)
                          (list 'cons-it cons-it-expander)
                          (list 'reclose reclose-expander)
                          (list 'quote-it quote-it-expander)
                          (list 'quote-raw quote-raw-expander)
                          (list 'unclosed unclosed-expander))))
    (if (null? pairs)
        env
        (loop (extend-syntactic-environment env (caar pairs) (cadar pairs))
              (cdr pairs)))))

;; PUSH-OR's own output (closed in stack-macrology over the advertised
;; environment) refers to PUSH and OR, so they need no entry here.
(define case-syntactic-environment
  (case-macrology scheme-syntactic-environment))

) ; end begin-for-syntax

;;; ------------------------------------------------------------------
;;; The keywords of CASE-SYNTACTIC-ENVIRONMENT, bound at toplevel

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
;;; 4. The cases (verbatim from cases.scm)

(define-syntax run-cases
  (syntax-rules (*oracle-error*)
    ((_) (begin))
    ((_ (name program (*oracle-error* . _)) more ...)
     (begin (check-error name program) (run-cases more ...)))
    ((_ (name program expected) more ...)
     (begin (check name 'expected program) (run-cases more ...)))))

(run-cases
;;; Section 1, problem 1: PUSH under a local CONS
    (p1-push-local-cons
     ((lambda (stack) (let ((cons 6)) (push 'foo stack)) stack) '())
     (foo))
    (p1-push-local-cons-set!-keyword-local
     ((lambda (stack)
        (with-macro (set! flag) ''hijacked
          (let ((cons 6)) (push 'foo stack)))
        stack)
      '(bar))
     (foo bar))

;;; Section 1, problem 2: OR's TEMP vs the client's TEMP
    ;; the client's (or (memq x y) temp) where memq fails
    (p2-or2-temp ((lambda (temp x y) (or2 (memq x y) temp)) 'tv 'a '(b))
     tv)
    (p2-macrology-or-temp
     ((lambda (temp x y) (or (memq x y) temp)) 'tv 'a '(b)) tv)
    (p2-macrology-and-temp ((lambda (temp) (and 1 temp)) 'tv) tv)
    (p2-case-temp ((lambda (temp) (case 2 ((1) 'one) ((2) temp))) 'tv)
     tv)

;;; Section 1, problem 3: a local SET! keyword does not capture PUSH's
    (p3-with-macro-set!
     ((lambda (stack)
        (with-macro (set! flag) '(list 'set-flag! ',flag)
          (push 'foo stack))
        stack)
      '())
     (foo))
    (p3-local-set!-still-usable
     (with-macro (set! flag) ''local-set!-used (set! 1)) local-set!-used)

;;; Section 1, problem 4: CONTORTED's auxiliary keyword USE
    (p4-contorted-and (contorted #t 1 2) 2)
    (p4-contorted-or (contorted #f 1 2) 1)
    (p4-contorted-client-use
     (with-macro (use) ''client-use (contorted #t (use) (use)))
     client-use)
    (p4-contorted2-client-use
     (with-macro (use) ''client-use (contorted2 #t (use) 'unused))
     ((contorted-use) client-use))

;;; Section 1 / 3.2: CATCH captures THROW on purpose
    (catch-throw (catch (+ 5 (throw 'x))) x)
    (catch-no-throw (catch (+ 5 1)) 6)
    (catch-nested-inner (catch (list 'outer (catch (throw 'inner)))) (outer inner))
    (catch-client-binds-throw
     (catch ((lambda (throw) (throw 'mine)) (lambda (v) (list 'client v))))
     (client mine))

;;; Section 4.4: with-macro closes its replacement where it occurred
    (s44-adjoin
     ((lambda (n m sum-stack)
        (let ((adjoin cons))
          (with-macro (push frob stack)
                      `(set! ,stack (adjoin ,frob ,stack))
            (let ((adjoin +))
              (push (adjoin n m) sum-stack))))
        sum-stack)
      1 2 '(0))
     (3 0))
    (s44-with-macro-template-temp
     (with-macro (my-or a b) `(let ((temp ,a)) (if temp temp ,b))
       (let ((temp 5)) (my-or #f temp)))
     5)
    (s44-with-macro-not-recursive
     (with-macro (m) ''outer-m
       (with-macro (m) '(m) (m)))
     outer-m)
    (s44-with-macro-rec-or
     (with-macro-rec (or exp . other-exps)
                     (if (null? other-exps)
                         exp
                         `(let ((temp ,exp))
                            (if temp temp (or ,@other-exps))))
       (let ((temp 7)) (or #f #f temp)))
     7)
    (s44-with-macro-rec-or-shadows-global
     (with-macro-rec (or exp . other-exps)
                     (if (null? other-exps)
                         `(list 'last ,exp)
                         `(let ((temp ,exp))
                            (if temp temp (or ,@other-exps))))
       (or #f #f))
     (last #f))
    (s44-with-macro-param-named-list
     (with-macro (two list cons) `(list ,list ,cons) (two 1 2)) (1 2))

;;; D1: raw output binder vs closure of the same name in the same env
    (d1-usage-env ((lambda (x) (d1u)) 'outer) outer)
    (d1-usage-env-free-name ((lambda (x) (d1u-free)) 'outer) inner)
    (d1-macro-env (d1m) global-gv)
    (d1-macro-env-under-local-gv ((lambda (gv) (d1m)) 'local) global-gv)
    (d1-macro-env-free-name (d1m-free) inner)
    (d1-user-arg ((lambda (x) (d1-arg x)) 'outer) outer)
    (d1-with-macro-env
     ((lambda (temp)
        (with-macro (m e) `((lambda (temp) ,e) 'inner) (m temp)))
      'outer)
     outer)
    (d1-inc-shadow
     ((lambda (v) (inc-shadow! v) v) 1) 2)

;;; D2: two closures of the same name in the same env  [EXT]
    (d2-bind2-t68 ((lambda (y) (bind2 y y)) 'outer) outer)
    (d2-bind-same ((lambda (y) (bind-same y)) 'outer) 10)
    ;; the raw IT left free is resolved where the closure is inserted
    ;; (the advertised env => global IT); binding a closure binds only
    ;; that closure, not the raw name.
    (d2-bind-lambda-free-raw-name ((lambda (it) (bind-lambda it it)) 'outer)
     global-it)
    (d2-paper-idiom-bind-raw ((lambda (y) (bind-raw y 10 y)) 'outer)
     10)
    (d2-paper-idiom-bind-raw-init-outer
     ((lambda (y) (bind-raw y (list y) y)) 'outer) (outer))

;;; Free names, nested closures, free names flowing outward
    (free-with-it (with-it 5 (+ it 1)) 6)
    (free-with-it-val-not-captured ((lambda (it) (with-it (list it) it)) 'u)
     (u))
    (free-nest-flows-outward ((lambda (it) (nest-free it)) 'user) (bound))
    (free-nest-stops-at-usage-env ((lambda (it) (nest-stop it)) 'user)
     (user))
    (free-nest-stops-at-advertised-env
     ((lambda (it) (nest-stop-global it)) 'user) (global-it))
    (free-through-macro-output ((lambda (it) (pass-it it)) 'user) from-pass-it)
    (free-advertised-closure-inside-usage
     ((lambda (it) (with-it 'w (cons-it it))) 'user) (w . w))
    (closure-of-closure ((lambda (gv) (reclose gv)) 'user) user)
    (closure-of-closure-in-binder
     ((lambda (gv) ((lambda (gv) (reclose gv)) 'inner)) 'outer) inner)
    (free-keyword-captured
     ((lambda (s) (with-local-push (push 1 s))) '()) local-push)
    (free-keyword-not-captured
     ((lambda (s) (with-hidden-push (push 1 s)) s) '()) (1))

;;; Closures as SET! targets
    (set!-target-push-pop
     ((lambda (s) (push 1 s) (push 2 s) (list (pop s) s)) '()) (2 (1)))
    (set!-target-two
     ((lambda (a b) (set-both! a b 'v) (list a b)) 1 2) (v v))
    (set!-target-swap
     ((lambda (tmp other) (with-swap (swap! tmp other)) (list tmp other))
      1 2)
     (2 1))

;;; Macros expanding into macros
    (mm-push-or ((lambda (s) (push-or #f 'x s) s) '()) (x))
    (mm-push-or-local-or
     ((lambda (s) (with-macro (or a b) ''hijacked (push-or #f 'x s)) s) '())
     (x))
    (mm-twice-user-macro
     ((lambda (s) (twice (push 'a s)) s) '()) (a a))
    (mm-twice-with-macro
     ((lambda (s) (with-macro (add x) `(push ,x s) (twice (add 'a))) s) '())
     (a a))
    (mm-with-macro-expands-to-with-macro
     ((lambda (z)
        (with-macro (outer v) `(with-macro (inner) ',v (inner)) (outer z)))
      'zz)
     zz)
    (mm-cond-or-and
     ((lambda (x) (cond ((and x (memq x '(a b)))) (else 'no))) 'b) (b))

;;; Macrology / extend-syntactic-environment
    (macrology-delay (force (delay (+ 1 2))) 3)
    (macrology-let-cond-case
     (let ((x 3))
       (cond ((< x 2) 'small)
             ((case x ((3 4) #t) (else #f)) 'medium)
             (else 'large)))
     medium)
    (macrology-new-if-or (with-new-if (or #f 5)) #f)
    (macrology-new-if-and (with-new-if (and 1 2)) 1)
    (macrology-new-if-cond (with-new-if (cond (#f 'a) (else 'b))) a)
    (macrology-new-if-closes-in-new-env
     ((lambda (gv) (with-new-if gv)) 'user) global-gv)
    ;; [translation] an expansion-time error: checked through EVAL, with
    ;; IN-CORE defined inline (toplevel macros of a compiled program
    ;; are not visible to EVAL)
    (macrology-in-core-no-derived
     (eval '(let-syntax ((in-core
                          (expander-macro-transformer
                           (lambda (syntactic-env exp)
                             (make-syntactic-closure
                              core-syntactic-environment '() (cadr exp))))))
              (in-core (let ((a 1)) a))))
     (*oracle-error* "unbound variable" (let)))
    (extend-usage-env-swap-scoped
     ((lambda (a b) (with-swap (swap! a b)) (swap! a b)) 1 2) (*oracle-error* "unbound variable" (swap!)))

;;; Advertised environment immune to local rebinding
    (adv-local-if-keyword
     (with-macro (if a b c) ''hijacked (or #f 5)) 5)
    (adv-local-lambda-keyword
     (with-macro (lambda a b) ''hijacked (or2 #f 5)) 5)
    (adv-local-let-keyword
     ((lambda (s) (with-macro (let a b) ''hijacked (pop s))) '(1 2))
     1)
    (adv-local-cons-memv
     ((lambda (cons memv) (case 'b ((a b) (list 'hit)))) 1 2) (hit))
    (adv-local-call/cc
     ((lambda (call-with-current-continuation) (catch (throw 'ok))) #f)
     ok)
    (adv-local-make-promise
     ((lambda (make-promise) (force (delay 'ok))) #f) ok)
)

;;; ------------------------------------------------------------------
;;; 5. The oracle's appendix artifacts, with CHICKEN's values.  Where
;;; the appendix simplifies (variables never shadow keywords, closures
;;; survive in quoted data, unclosed expander output is an error),
;;; CHICKEN follows R7RS and its other macro systems instead.

;; oracle: 2 (the appendix dispatches on the raw keyword)
(check artifact-variable-named-if '(1 2 3) ((lambda (if) (if 1 2 3)) list))
;; oracle: (1)
(check artifact-variable-named-push '() ((lambda (push s) (push 1 s) s) list '()))
;; oracle: a closure object
(check artifact-closure-in-quote 'hello (quote-it hello))
;; oracle: #f
(check artifact-closure-in-quote-eq #t ((lambda (q) (eq? q 'hello)) (quote-it hello)))
;; oracle: temp
(check artifact-raw-symbol-in-quote 'temp (quote-raw))
;; oracle: error "Unclosed expression"; CHICKEN interprets unclosed
;; output in the macro environment, as sc-macro-transformer does
(check artifact-unclosed-expansion 3 (unclosed))
;; oracle: (1 2)
(check artifact-with-macro-arg-as-keyword '(1 2) (with-macro (use k) `(,k 1 2) (use list)))
;; oracle: error (a closed keyword symbol is a variable in the appendix)
(check artifact-with-macro-arg-keyword-and 2 (with-macro (use k) `(,k 1 2) (use and)))

;;; ------------------------------------------------------------------
;;; 6. The section 4 interface directly

;; scheme-syntactic-environment: standard names are absolute, so local
;; bindings cannot affect them; identifier=? agrees with the toplevel
(define-syntax probe-scheme-env
  (sc-macro-transformer
   (lambda (form env)
     `(quote ,(list (identifier=? env 'cons scheme-syntactic-environment 'cons)
                    (identifier=? env 'if scheme-syntactic-environment 'if)
                    (identifier=? env (cadr form) scheme-syntactic-environment 'car)
                    (syntactic-environment? scheme-syntactic-environment)
                    (syntactic-environment? core-syntactic-environment))))))
(check scheme-env-identifier=? '(#t #t #t #t #t) (probe-scheme-env car))
(check scheme-env-identifier=?-shadowed '(#t #t #f #t #t)
  (let ((car cdr)) (probe-scheme-env car)))

;; expander-macro-transformer and extend-syntactic-environment in
;; local macros; a macrology extending the usage environment
(check local-expander-macro '(2 1)
  (let ((stack '()) (cons list))
    (let-syntax ((push2 (expander-macro-transformer push-expander)))
      (push2 1 stack)
      (push2 2 stack)
      stack)))
(define-syntax with-stack-ops
  (expander-macro-transformer
   (lambda (syntactic-env exp)
     (make-syntactic-closure (stack-macrology syntactic-env) '()
                             `(begin ,@(cdr exp))))))
(check usage-env-macrology '(3 (2 1))
  (let ((s '(1)) (set! 'no) (car 'no))
    (with-stack-ops (push 2 s) (push 3 s) (list (pop s) s))))

;; a keyword bound by extend-syntactic-environment can be shadowed by a
;; variable inside the closure
(define-syntax shadow-ext
  (expander-macro-transformer
   (lambda (syntactic-env exp)
     (make-syntactic-closure
      (extend-syntactic-environment syntactic-env 'k
                                    (lambda (e x) (make-syntactic-closure scheme-syntactic-environment '() ''kw)))
      '()
      '(list (k) ((lambda (k) k) 'var))))))
(check extended-keyword-shadowed '(kw var) (shadow-ext))

;; errors are signalled for bad arguments
(check-error extend-bad-keyword
  (eval '(let-syntax ((m (expander-macro-transformer
                          (lambda (e x)
                            (extend-syntactic-environment e "k" (lambda (e x) 1))))))
           (m))))

;;; ------------------------------------------------------------------
;;; 7. [DEVIATION: pre-existing CHICKEN bug] the cases of section 4 that
;;; refer to a global from under a local variable of the same name,
;;; with plain toplevel globals.  Lowering gives the right identifier,
;;; an alias of the global, but `##sys#alias-global-hook' (compiled
;;; code) and eval.scm (csi) resolve an alias of a global that is not
;;; module-qualified by its name at the use site, where the local
;;; variable is bound.  syntax-rules and er macros behave the same:
;;; (define x 1) (define-syntax g (syntax-rules () ((_) x)))
;;; (let ((x 2)) (g)) gives 2 compiled and an error in csi.

(define tl-gv 'global-gv)
(define tl-it 'global-it)
(define-syntax tl-d1m
  (expander-macro-transformer
   (lambda (syntactic-env exp)
     (make-syntactic-closure
      scheme-syntactic-environment '()
      `((lambda (tl-gv) ,(make-syntactic-closure
                          scheme-syntactic-environment '() 'tl-gv))
        'inner)))))
(define-syntax tl-nest-stop-global
  (expander-macro-transformer
   (lambda (syntactic-env exp)
     (let* ((b (make-syntactic-closure syntactic-env '(tl-it) (cadr exp)))
            (m (make-syntactic-closure scheme-syntactic-environment '()
                                       `(list ,b))))
       (make-syntactic-closure
        scheme-syntactic-environment '()
        `((lambda (tl-it) ,m) 'bound))))))

(check-deviation tl-d1-macro-env-under-local-gv 'global-gv
  (cond-expand (compiling 'local) (else 'error))
  (handle-exceptions e 'error ((lambda (tl-gv) (tl-d1m)) 'local)))
(check-deviation tl-d2-bind-lambda-free-raw-name 'global-it
  (cond-expand (compiling 'outer) (else 'error))
  (handle-exceptions e 'error ((lambda (tl-it) (bind-lambda tl-it tl-it)) 'outer)))
(check-deviation tl-free-nest-stops-at-advertised-env '(global-it)
  (cond-expand (compiling '(user)) (else 'error))
  (handle-exceptions e 'error ((lambda (tl-it) (tl-nest-stop-global tl-it)) 'user)))
(check-deviation tl-macrology-new-if-closes-in-new-env 'global-gv
  (cond-expand (compiling 'user) (else 'error))
  (handle-exceptions e 'error ((lambda (tl-gv) (with-new-if tl-gv)) 'user)))

;; the library's scheme-macrology (paper sec. 4.3 and appendix),
;; including its with-macro and with-macro-rec
(define-for-syntax lib-new-if-env
  (scheme-macrology
   (extend-syntactic-environment core-syntactic-environment 'if new-if-expander)))
(define-syntax with-lib-new-if
  (expander-macro-transformer
   (lambda (syntactic-env exp)
     (make-syntactic-closure lib-new-if-env '() (cadr exp)))))
(check library-macrology-new-if '(#f 1 a b 3)
  (list (with-lib-new-if (or #f 5))
        (with-lib-new-if (and 1 2))
        (with-lib-new-if (cond (#f 'a) (else 'b)))
        (with-lib-new-if (case 1 ((1) 'a) (else 'b)))
        (force (with-lib-new-if (delay 3)))))
(define-for-syntax lib-scheme-env (scheme-macrology core-syntactic-environment))
(define-syntax in-lib-scheme
  (expander-macro-transformer
   (lambda (syntactic-env exp)
     (make-syntactic-closure lib-scheme-env '() (cadr exp)))))
(check library-macrology-with-macro '((3 0) 7 b)
  (in-lib-scheme
   (let ((adjoin cons) (n 1) (m 2) (sum-stack '(0)))
     (list
      (with-macro (push frob stack)
                  `(set! ,stack (adjoin ,frob ,stack))
        (let ((adjoin +))
          (push (adjoin n m) sum-stack)
          sum-stack))
      (with-macro-rec (or exp . other-exps)
                      (if (null? other-exps)
                          exp
                          `(let ((temp ,exp)) (if temp temp (or ,@other-exps))))
        (let ((temp 7)) (or #f #f temp)))
      (case 'x ((a) 'a) ((x y) 'b) (else 'c))))))
;; problem 3 of the paper with the library's with-macro: a local set!
;; does not capture the set! of push's replacement
(check library-macrology-problem-3 '(foo)
  (in-lib-scheme
   (let ((stack '()))
     (with-macro (push x s) `(set! ,s (cons ,x ,s))
       (with-macro (set! flag) `(set-flag! ',flag)
         (push 'foo stack)))
     stack)))

(print *pass* " passed, " *fail* " failed, " *deviations* " documented deviations")
(unless (zero? *fail*) (exit 1))
