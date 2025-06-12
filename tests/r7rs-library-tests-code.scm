(define (fx x)
  (+ x x))

(define-syntax mx
  (syntax-rules ()
    ((_ x) (+ x x))))
