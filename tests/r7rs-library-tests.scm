;; by Anton Idukov (included code was expanded too early)

(define-library (mod)
  (export fx mx)
  (import (scheme base))

  (include "r7rs-library-tests-code.scm")

  )

;; reported by Peter McGoron, hack to handle arbitrary indirect exports was
;; simply incomplete

(define-library with-indirect-export
  (import (scheme base))
  (export bar)
  (begin
    (define baz 99) 
    (define-syntax bar
      (syntax-rules ()
        ((_) baz)))))

(import with-indirect-export)
(assert (= 99 (bar)))
