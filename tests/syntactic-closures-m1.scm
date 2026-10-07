;;;; syntactic-closures-m1.scm - sc/rsc macros exported through an import library

(module syntactic-closures-m1 (my-or (scale secret) my-cond swap!
                               push (double twice-it) with-swap
                               loop-until aif pass with-kw)
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

  ;; Paper-protocol expanders (sec. 3.2 and 4)
  (define (twice-it x) (* 2 x))
  (define-syntax push
    (expander-macro-transformer
     (lambda (syntactic-env exp)
       (let ((obj-exp (make-syntactic-closure syntactic-env '() (cadr exp)))
             (list-var (make-syntactic-closure syntactic-env '() (caddr exp))))
         (make-syntactic-closure
          scheme-syntactic-environment '()
          `(set! ,list-var (cons ,obj-exp ,list-var)))))))
  (define-syntax double
    (expander-macro-transformer
     (lambda (syntactic-env exp)
       (make-syntactic-closure
        scheme-syntactic-environment '()
        `(twice-it ,(make-syntactic-closure syntactic-env '() (cadr exp)))))))
  (define-syntax with-swap
    (expander-macro-transformer
     (lambda (syntactic-env exp)
       (make-syntactic-closure
        (extend-syntactic-environment
         syntactic-env 'swap2!
         (lambda (env x)
           (let ((a (make-syntactic-closure env '() (cadr x)))
                 (b (make-syntactic-closure env '() (caddr x))))
             (make-syntactic-closure
              scheme-syntactic-environment '()
              `(let ((tmp ,a)) (set! ,a ,b) (set! ,b tmp))))))
        '()
        `(begin ,@(cdr exp))))))

  ;; A capture inside the output (MIT's loop-until), a closure handed to
  ;; an anaphoric macro, keywords bound to transformers
  (define-syntax loop-until
    (sc-macro-transformer
     (lambda (exp env)
       (let ((id (cadr exp))
             (init (caddr exp))
             (test (cadddr exp))
             (return (cadddr (cdr exp)))
             (step (cadddr (cddr exp)))
             (close (lambda (exp free) (make-syntactic-closure env free exp))))
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
  (define-syntax aif
    (sc-macro-transformer
     (lambda (f env)
       `(let ((it ,(close-syntax (cadr f) env)))
          (if it
              ,(make-syntactic-closure env '(it) (caddr f))
              ,(close-syntax (cadddr f) env))))))
  (define-syntax pass
    (sc-macro-transformer
     (lambda (f env)
       `(aif ,(close-syntax (cadr f) env) ,(close-syntax (caddr f) env) #f))))
  (define-syntax with-kw
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
        `(list ,@(cdr exp)))))))
