;;;; syntactic-closures-m1.scm - sc/rsc macros exported through an import library

(module syntactic-closures-m1 (my-or (scale secret) my-cond swap! paper-push paper-catch)
  (import scheme (chicken base) (chicken syntax))
  (define (secret x) (* x 100))
  (define-syntax scale
    (sc-macro-transformer
     (lambda (f e) `(secret ,(close-syntax (cadr f) e)))))
  (define-syntax my-or
    (sc-macro-transformer
     (lambda (f env)
       (cond ((null? (cdr f)) #f)
             (else `(let ((temp ,(close-syntax (cadr f) env)))
                      (if temp temp (my-or ,@(make-syntactic-closure-list env '() (cddr f))))))))))
  (define-syntax my-cond
    (sc-macro-transformer
     (lambda (form env)
       (capture-syntactic-environment
        (lambda (menv)
          (let loop ((cs (cdr form)))
            (cond ((null? cs) '(if #f #f))
                  ((identifier=? env (caar cs) menv 'else)
                   `(begin ,@(make-syntactic-closure-list env '() (cdar cs))))
                  (else `(if ,(close-syntax (caar cs) env)
                             (begin ,@(make-syntactic-closure-list env '() (cdar cs)))
                             ,(loop (cdr cs)))))))))))
  (define-syntax swap!
    (rsc-macro-transformer
     (lambda (form env)
       (let ((a (cadr form)) (b (caddr form)) (tmp (close-syntax 'tmp env)))
         `(,(close-syntax 'let env) ((,tmp ,a))
           (,(close-syntax 'set! env) ,a ,b)
           (,(close-syntax 'set! env) ,b ,tmp))))))
  ;; the expanders of section 3.2 of the paper
  (define-syntax paper-push
    (expander-macro-transformer
     (lambda (syntactic-env exp)
       (let ((obj-exp (make-syntactic-closure syntactic-env '() (cadr exp)))
             (list-var (make-syntactic-closure syntactic-env '() (caddr exp))))
         (make-syntactic-closure scheme-syntactic-environment '()
           `(set! ,list-var (cons ,obj-exp ,list-var)))))))
  (define-syntax paper-catch
    (expander-macro-transformer
     (lambda (syntactic-env exp)
       (let ((body-exp (make-syntactic-closure syntactic-env '(throw) (cadr exp))))
         (make-syntactic-closure scheme-syntactic-environment '()
           `(call-with-current-continuation
             (lambda (throw) ,body-exp))))))))
