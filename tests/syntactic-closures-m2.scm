;;;; syntactic-closures-m2.scm - uses the macros of syntactic-closures-m1

(import scheme (chicken base) syntactic-closures-m1)

(define temp 'user-temp)

(assert (equal? '(200 9 2 3 (2 1) (1) (outer inner))
                (list (scale 2)
                      (let ((secret 3) (temp 9)) (my-or #f temp))
                      (let ((else #f) (if list)) (my-cond (else 1) (#t 2)))
                      (my-cond (#f 1) (else 3))
                      (let ((tmp 1) (let 2)) (swap! tmp let) (list tmp let))
                      (let ((s '()) (cons 6) (set! 7)) (paper-push 1 s) s)
                      (paper-catch (list 'outer (paper-catch (throw 'inner)))))))
