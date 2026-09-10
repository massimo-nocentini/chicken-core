;;;; bytevector-guard-tests.scm
;
; Type predicates and accessors must reject immediates instead of dereferencing
; them.  Every call site here is deliberately POLYMORPHIC: a monomorphic one is
; folded by the scrutinizer and proves nothing, because the guard under test is
; exactly what the scrutinizer discharges.
;
; Covers the bytevector family, the pointer and generic-structure predicates,
; and the range checks used by the lolevel accessors.

(import (chicken number-vector) (chicken bytevector) (chicken condition))

(define immediates (list 42 -1 '() #t #f #\a (void)))
(define non-bytevector-blocks (list "str" 3.5 '(1 2) (vector 1 2) (s8vector 1 2)))
(define bytevectors (list (u8vector 1 2 3) (make-bytevector 4 0) (make-u8vector 2 1)))

(define (p-u8vector? x) (u8vector? x))
(define (p-bytevector? x) (bytevector? x))
(define (p-sys-bytevector? x) (##sys#bytevector? x))
(define (p-u8-ref x) (u8vector-ref x 0))
(define (p-u8-set! x) (u8vector-set! x 0 1))
(define (p-u8-length x) (u8vector-length x))
(define (p-bv-u8-ref x) (bytevector-u8-ref x 0))
(define (p-bv-u8-set! x) (bytevector-u8-set! x 0 1))
(define (p-bv-length x) (bytevector-length x))

(define (raises? thunk)
  (handle-exceptions e 'error (begin (thunk) #f)))

;; predicates: false for everything that is not a bytevector, no crash
(for-each (lambda (x)
	    (assert (not (p-u8vector? x)) "u8vector? on non-bytevector" x)
	    (assert (not (p-bytevector? x)) "bytevector? on non-bytevector" x)
	    (assert (not (p-sys-bytevector? x)) "##sys#bytevector? on non-bytevector" x))
	  (append immediates non-bytevector-blocks))

(for-each (lambda (x)
	    (assert (p-u8vector? x) "u8vector? on bytevector" x)
	    (assert (p-bytevector? x) "bytevector? on bytevector" x)
	    (assert (p-sys-bytevector? x) "##sys#bytevector? on bytevector" x))
	  bytevectors)

;; accessors: a type error, never a segfault
(for-each (lambda (x)
	    (for-each (lambda (op)
			(assert (eq? 'error (raises? (lambda () (op x))))
				"accessor accepted a non-bytevector" x))
		      (list p-u8-ref p-u8-set! p-u8-length
			    p-bv-u8-ref p-bv-u8-set! p-bv-length)))
	  (append immediates non-bytevector-blocks))

;; and they still work on real bytevectors
(let ((bv (u8vector 7 8 9)))
  (assert (= 3 (p-u8-length bv)))
  (assert (= 3 (p-bv-length bv)))
  (assert (= 7 (p-u8-ref bv)))
  (p-u8-set! bv)
  (assert (= 1 (p-bv-u8-ref bv)))
  (p-bv-u8-set! bv)
  (assert (= 1 (p-u8-ref bv))))

;;; Pointer and generic-structure predicates.
;
; ##sys#pointer? and ##sys#generic-structure? used to rewrite to the raw
; C_anypointerp / C_structurep macros, which dereference their argument with no
; C_immediatep check, and both carried the safe-mode flag -- so these calls
; segfaulted in DEFAULT SAFE MODE.

(define (p-sys-pointer? x) (##sys#pointer? x))
(define (p-generic-structure? x) (##sys#generic-structure? x))

(for-each
 (lambda (x)
   (assert (eq? #f (p-sys-pointer? x)))
   (assert (eq? #f (p-generic-structure? x))))
 immediates)

(for-each
 (lambda (x)
   (assert (eq? #f (p-sys-pointer? x))))
 non-bytevector-blocks)

;; ... and they still say yes to the real thing
(assert (eq? #t (p-generic-structure? (##sys#make-structure 'thing 1 2))))
(assert (eq? #f (p-generic-structure? (vector 1 2))))

(print "bytevector guard tests passed")
