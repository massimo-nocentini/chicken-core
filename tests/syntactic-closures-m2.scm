;;;; syntactic-closures-m2.scm - uses the macros of syntactic-closures-m1

(import scheme (chicken base) syntactic-closures-m1)

(define temp 'user-temp)

(assert (equal? '(200 9 2 3 (2 1))
                (list (scale 2)
                      (let ((secret 3) (temp 9)) (my-or #f temp))
                      (let ((else #f) (if list)) (my-cond (else 1) (#t 2)))
                      (my-cond (#f 1) (else 3))
                      (let ((tmp 1) (let 2)) (swap! tmp let) (list tmp let)))))

(assert (equal? '((2 1) 42 (2 3 1))
                (list (let ((s '()) (cons vector)) (push 1 s) (push 2 s) s)
                      (let ((twice-it 0)) (double 21))
                      (let ((a 1) (b 2) (tmp 3))
                        (with-swap (swap2! a b) (swap2! b tmp))
                        (list a b tmp)))))

(assert (equal? '(60 (6 7) user (1 2) #((1 1) (2 2 2)))
                (list (loop-until i 0 (> i 5) (* i 10) (+ i 1))
                      (let ((loop 7) (if 3))
                        (loop-until i 0 (> i 5) (list i loop) (+ i 1)))
                      (let ((it 'user)) (pass 1 it))
                      (aif 1 (list it (aif 2 it #f)) #f)
                      (let ((list vector)) (with-kw (twice 1) (thrice 2))))))
