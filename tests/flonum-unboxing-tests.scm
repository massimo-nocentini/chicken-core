;;;; flonum-unboxing-tests.scm
;
; Every flonum operation lfa2 knows how to unbox must still compute the right
; value once it has been unboxed.  runtests.sh compiles this file at -O3 and
; also checks the generated C: a misspelt name in lfa2's +unboxed-map+ does not
; break anything, it only leaves the operation boxed, so the values below would
; pass either way.  The C check is what catches that.
;
; Each chain starts from an fp operation on the argument, which proves the
; argument and every intermediate a flonum and so lets lfa2 unbox the lot.

(import (chicken flonum))

(define (expt-chain x)
  (let* ((a (fp* x 2.0))
	 (b (fpexp a))
	 (c (fpexpt b 1.5)))
    c))

(define (finite-chain x)
  (let ((a (fp* x 2.0)))
    (if (finite? a) (fp+ a 1.0) -1.0)))

(define (infinite-chain x)
  (let ((a (fp* x 2.0)))
    (if (infinite? a) 1.0 0.0)))

(define (nan-chain x)
  (let ((a (fp* x 2.0)))
    (if (nan? a) 1.0 0.0)))

(define (inexact= a b)
  (fp< (fpabs (fp- a b)) (fp* 1e-12 (fpmax 1.0 (fpabs b)))))

;; exp(2x)^1.5 = exp(3x)
(assert (inexact= (expt-chain 0.25) (exp 0.75)))
(assert (inexact= (expt-chain -1.0) (exp -3.0)))
(assert (fp= (expt-chain 0.0) 1.0))

(assert (fp= (finite-chain 1.0) 3.0))
(assert (fp= (finite-chain +inf.0) -1.0))
(assert (fp= (finite-chain +nan.0) -1.0))

(assert (fp= (infinite-chain 1.0) 0.0))
(assert (fp= (infinite-chain -inf.0) 1.0))
(assert (fp= (infinite-chain +nan.0) 0.0))

(assert (fp= (nan-chain 1.0) 0.0))
(assert (fp= (nan-chain +nan.0) 1.0))
