;;;; syntactic-closures-redefine.scm - a program may define its own
;;;; identifier?, syntactic-closure? and syntactic-environment?, which
;;;; (chicken syntax) makes visible in every toplevel: compiled, its
;;;; definitions are called and not folded (the compiler warns about
;;;; the assignments to the imported bindings).

(define count 0)
(define (identifier? x) (set! count (+ count 1)) (symbol? x))
(define (syntactic-closure? x) (and (pair? x) (eq? (car x) 'closure)))
(define (syntactic-environment? x) (and (pair? x) (eq? (car x) 'env)))

(identifier? 'a)			; result unused
(assert (= count 1))
(assert (syntactic-closure? (list 'closure 1)))
(assert (syntactic-environment? (list 'env)))
;; Redefining procedures that scheme-macrology and
;; extend-syntactic-environment are written with does not change them:
;; they use the procedures of the expander
(define (identifier=? . args) (error "user identifier=? called"))
(define (make-syntactic-closure-list . args) '())
(define (expander-macro-transformer f) (error "user expander-macro-transformer called"))
(assert
 (equal? '((2 2 (macro user)) kk)
         (eval '(let-syntax
                    ((in-macrology
                      (sc-macro-transformer
                       (lambda (f e)
                         (make-syntactic-closure
                          (scheme-macrology core-syntactic-environment) '()
                          '(list (cond (#f 1) (else 2))
                                 (or #f 2)
                                 (let ((temp 'macro))
                                   (with-macro (m) (list 'list 'temp ''user) (m))))))))
                     (with-k
                      (sc-macro-transformer
                       (lambda (form env)
                         (make-syntactic-closure
                          (extend-syntactic-environment
                           env 'k
                           (lambda (e x)
                             (make-syntactic-closure scheme-syntactic-environment '() ''kk)))
                          '() (cadr form))))))
                  (list (in-macrology) (with-k (k)))))))
(print "syntactic-closures-redefine: ok")
