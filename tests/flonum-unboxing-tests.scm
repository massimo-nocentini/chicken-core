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

(define (special-chain x)
  (let* ((a (fp* x 0.5))
	 (b (fplog1p a))
	 (c (fpexpm1 b))
	 (d (fplgamma (fp+ c 4.0)))
	 (e (fptgamma (fp+ c 4.0)))
	 (f (fperf c))
	 (g (fperfc c)))
    (fp+ (fp+ d (fplog e)) (fp+ f g))))

;; Unlike the chains above, this one takes its argument untouched, so at
;; -O2 -unsafe, where nothing is specialized, only the rewrites in
;; c-platform.scm open-code it (runtests.sh compiles this file that way too).
(define (hyperbolic-chain x)
  (let ((s (fpsinh x))
	(c (fpcosh x))
	(t (fptanh x)))
    (fp+ (fp- (fp* c c) (fp* s s))
	 (fp+ (fp- t (fp/ s c))
	      (fp+ (fp- (fpasinh s) x)
		   (fp+ (fp- (fpacosh c) (fpabs x))
			(fp- (fpatanh t) x)))))))

(define (inexact= a b)
  (fp< (fpabs (fp- a b)) (fp* 1e-12 (fpmax 1.0 (fpabs b)))))

;; log1p and expm1 cancel; lgamma(5) = log(24) = log(tgamma(5));
;; erf + erfc = 1
(assert (inexact= (special-chain 2.0) (fp+ (fp* 2.0 (log 24.0)) 1.0)))

;; cosh^2 - sinh^2 = 1, tanh = sinh/cosh, and each inverse undoes its function
(assert (inexact= (hyperbolic-chain 0.75) 1.0))
(assert (inexact= (hyperbolic-chain -0.5) 1.0))

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
