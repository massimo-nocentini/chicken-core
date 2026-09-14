;;;; srfi-4-tests.scm


(import (chicken number-vector) (chicken port))
(import-for-syntax (chicken base))

(define-syntax test1
  (er-macro-transformer
   (lambda (x r c)
     (let* ((t (strip-syntax (cadr x)))
	    (name (symbol->string (strip-syntax t)))
	    (min (caddr x))
	    (max (cadddr x)))
       (define (conc op)
	 (string->symbol (string-append name op)))
       `(let ((x (,(conc "vector") 100 101)))
	  (assert (eqv? 100 (,(conc "vector-ref") x 0)))
	  (assert (,(conc "vector?") x))
	  (assert (number-vector? x))
	  ;; Test direct setter and ref
	  (,(conc "vector-set!") x 1 99)
	  (assert (eqv? 99 (,(conc "vector-ref") x 1)))
	  ;; Test SRFI-17 generalised set! and ref
	  (set! (,(conc "vector-ref") x 0) 127)
	  (assert (eqv? 127 (,(conc "vector-ref") x 0)))
	  ;; Ensure length is okay
	  (assert (= 2 (,(conc "vector-length") x)))
	  (assert
	   (let ((result (,(conc "vector->list") x)))
	     (and (eqv? 127 (car result))
		  (eqv? 99 (cadr result))))))))))

(define-syntax test-subv
  (er-macro-transformer
    (lambda (x r c)
      (let* ((t (strip-syntax (cadr x)))
	     (make (symbol-append 'make- t 'vector))
	     (subv (symbol-append 'sub   t 'vector))
	     (len  (symbol-append t 'vector-length)))
	`(let ((x (,make 10)))
	   (assert (eq? (,len (,subv x 0 5)) 5)))))))

(test-subv u8)
(test-subv s8)
(test-subv u16)
(test-subv s16)
(test-subv u32)
(test-subv s32)
(test-subv u64)
(test-subv s64)

(test1 u8 0 255)
(test1 u16 0 65535)
(test1 u32 0 4294967295)
(test1 u64 0 18446744073709551615)
(test1 s8 -128 127)
(test1 s16 -32768 32767)
(test1 s32 -2147483648 2147483647)
(test1 s64 -9223372036854775808 9223372036854775807)

(define-syntax test2
  (er-macro-transformer
   (lambda (x r c)
     (let* ((t (strip-syntax (cadr x)))
	    (name (symbol->string (strip-syntax t))))
       (define (conc op)
	 (string->symbol (string-append name op)))
       `(let ((x (,(conc "vector") 100 101.0)))
	  (assert (eqv? 100.0 (,(conc "vector-ref") x 0)))
	  (assert (eqv? 101.0 (,(conc "vector-ref") x 1)))
	  (assert (,(conc "vector?") x))
	  (assert (number-vector? x))
	  (,(conc "vector-set!") x 1 99)
	  (assert (eqv? 99.0 (,(conc "vector-ref") x 1)))
	  (assert (= 2 (,(conc "vector-length") x)))
          (assert
	   (let ((result (,(conc "vector->list") x)))
	     (and (eqv? 100.0 (car result))
		  (eqv? 99.0 (cadr result))))))))))

(test2 f32)
(test2 f64)

;; Test implicit quoting/self evaluation
(assert (equal? #u8(1 2 3) '#u8(1 2 3)))
(assert (equal? #s8(-1 2 3) '#s8(-1 2 3)))
(assert (equal? #u16(1 2 3) '#u16(1 2 3)))
(assert (equal? #s16(-1 2 3) '#s16(-1 2 3)))
(assert (equal? #u32(1 2 3) '#u32(1 2 3)))
(assert (equal? #u64(1 2 3) '#u64(1 2 3)))
(assert (equal? #s32(-1 2 3) '#s32(-1 2 3)))
(assert (equal? #s64(-1 2 3) '#s64(-1 2 3)))
(assert (equal? #f32(1 2 3) '#f32(1 2 3)))
(assert (equal? #f64(-1 2 3) '#f64(-1 2 3)))

; make sure the N parameter is a fixnum
(assert
  (handle-exceptions exn #t
    (make-f64vector 4.0) #f))
; catch the overflow
(assert
  (handle-exceptions exn #t
    (make-f64vector most-positive-fixnum) #f))

;; test special read-syntax

(let ((cases '(("#u8(1 2 #\\A)" #u8(1 2 65))
               ("#u8(\"abc\")" #u8(97 98 99))
               ("#u8\"abc\"" #u8(97 98 99))
               ("#u8(\"abc\")" #u8(97 98 99))
               ("#u8(\"ab\" \"c\")" #u8(97 98 99))
               ("#u8(\"a\" \"b\" \"c\")" #u8(97 98 99))
               ("#u8\"🐔\""               #u8(#xf0 #x9f #x90 #x94))
               ("#u8(#\\🐔)"              #u8(#xf0 #x9f #x90 #x94))
               ("#u8(\"🐔\"      \"🏫\")" #u8(#xf0 #x9f #x90 #x94   #xf0 #x9f #x8f #xab))
               ("#u8(\"🐔\" \"\" \"🏫\")" #u8(#xf0 #x9f #x90 #x94   #xf0 #x9f #x8f #xab))
               ("#u8(#\\🐔       \"🏫\")" #u8(#xf0 #x9f #x90 #x94   #xf0 #x9f #x8f #xab))
               ("#u8(\"🐔\"       #\\🏫)" #u8(#xf0 #x9f #x90 #x94   #xf0 #x9f #x8f #xab))
               ("#u8(\"🐔\"   0   #\\🏫)" #u8(#xf0 #x9f #x90 #x94 0 #xf0 #x9f #x8f #xab))
               ("#u8(\"\")" #u8())
               ("#u8(\"\" \"a\")" #u8(97))
               ("#u8(\"a\" \"\")" #u8(97))
               ("#u8\"\"" #u8())
               ("#s8\"\"" #s8())
               ("#u64(\" \" #\\! 1 \"A\")" #u64(32 33 1 65))
               ("#u64(\" \" #\\! \"A\" 1)" #u64(32 33 65 1))
               ("#u64(\"🐔\"      \"🏫\")" #u64(#xf0 #x9f #x90 #x94   #xf0 #x9f #x8f #xab)))))
  (do ((cs cases (cdr cs)))
      ((null? cs))
      (let ((x (with-input-from-string (caar cs) read)))
        (unless (equal? x (cadar cs))
          (error "failed" x (caar cs))))))

;; complex vectors

(define (dot v1 v2 n ref)
  (do ((i 0 (add1 i))
  	   (sum 0 (+ sum (* (ref v1 i) (ref v2 i)))))
  	  ((>= i n) sum)))

(assert
  (= 1-i
     (dot '#c64(1+i 1-i 0) '#c64(-i 0 2-i) 3 c64vector-ref)))
(assert
  (= 1-i
     (dot '#c128(1+i 1-i 0) '#c128(-i 0 2-i) 3 c128vector-ref)))

(assert
  (= -1-i
     (dot (c64vector 1+i 1-i 0) (c64vector 2+i 1-3i 0+2i) 3 c64vector-ref)))
(assert
  (= -1-i
     (dot (c128vector 1+i 1-i 0) (c128vector 2+i 1-3i 0+2i) 3 c128vector-ref)))

;; bulk arithmetic on float vectors

(import (chicken condition))

(define (bulk-error? thunk)
  (condition-case (begin (thunk) #f) ((exn) #t)))

(define (bulk-tests make vec ->list fill! copy! scale! axpy! sum dot)
  ;; fill!, with and without a range
  (let ((v (make 5 1.0)))
    (fill! v 2.5)
    (assert (equal? '(2.5 2.5 2.5 2.5 2.5) (->list v)))
    (fill! v -1.0 1 3)
    (assert (equal? '(2.5 -1.0 -1.0 2.5 2.5) (->list v)))
    (fill! v 9.0 2 2)                                  ; empty range
    (assert (equal? '(2.5 -1.0 -1.0 2.5 2.5) (->list v)))
    (fill! v 3 0 1)                                    ; exact integer argument
    (assert (equal? '(3.0 -1.0 -1.0 2.5 2.5) (->list v))))
  ;; copy!
  (let ((a (vec 1.0 2.0 3.0 4.0 5.0))
        (b (make 5 0.0)))
    (copy! b 0 a)
    (assert (equal? (->list a) (->list b)))
    (copy! b 1 a 0 3)
    (assert (equal? '(1.0 1.0 2.0 3.0 5.0) (->list b)))
    (copy! b 0 b 2 5)                                  ; overlapping, downwards
    (assert (equal? '(2.0 3.0 5.0 3.0 5.0) (->list b)))
    (copy! b 2 b 0 3)                                  ; overlapping, upwards
    (assert (equal? '(2.0 3.0 2.0 3.0 5.0) (->list b))))
  ;; scale!
  (let ((v (vec 1.0 2.0 3.0 4.0)))
    (scale! v 2.0 1 3)
    (assert (equal? '(1.0 4.0 6.0 4.0) (->list v)))
    (scale! v 0.5)
    (assert (equal? '(0.5 2.0 3.0 2.0) (->list v))))
  ;; axpy!
  (let ((y (vec 1.0 2.0 3.0 4.0))
        (x (vec 10.0 20.0 30.0 40.0)))
    (axpy! y 2.0 x 1 3)
    (assert (equal? '(1.0 42.0 63.0 4.0) (->list y)))
    (axpy! y -1.0 y)                                   ; aliasing itself
    (assert (equal? '(0.0 0.0 0.0 0.0) (->list y))))
  ;; sum and dot
  (let ((a (vec 1.0 2.0 3.0 4.0))
        (b (vec 4.0 3.0 2.0 1.0)))
    (assert (= 10.0 (sum a)))
    (assert (= 5.0 (sum a 1 3)))
    (assert (= 0.0 (sum a 2 2)))
    (assert (= 20.0 (dot a b)))
    (assert (= 12.0 (dot a b 1 3)))
    (assert (= 0.0 (dot a b 2 2)))
    ;; long enough to exercise the unrolled body and its tail
    (let* ((n 1000) (u (make n 0.0)))
      (fill! u 0.5)
      (assert (= 500.0 (sum u)))
      (assert (= 250.0 (dot u u)))
      (assert (= 499.5 (sum u 1 n)))))
  ;; argument checking, which -unsafe does not remove
  (let ((v (make 4 1.0))
        (w (make 8 1.0)))
    (assert (bulk-error? (lambda () (sum 42))))
    (assert (bulk-error? (lambda () (sum v 5))))
    (assert (bulk-error? (lambda () (sum v 0 5))))
    (assert (bulk-error? (lambda () (sum v 3 1))))
    (assert (bulk-error? (lambda () (sum v -1))))
    (assert (bulk-error? (lambda () (sum v 'x))))
    (assert (bulk-error? (lambda () (dot w v))))
    (assert (= 4.0 (dot w v 0 4)))
    (assert (bulk-error? (lambda () (axpy! w 1.0 v))))
    (assert (bulk-error? (lambda () (copy! v 0 w))))
    (assert (bulk-error? (lambda () (copy! v 2 w 0 4))))
    (assert (bulk-error? (lambda () (fill! v "x"))))))

(bulk-tests make-f64vector f64vector f64vector->list
            f64vector-fill! f64vector-copy! f64vector-scale!
            f64vector-axpy! f64vector-sum f64vector-dot)
(bulk-tests make-f32vector f32vector f32vector->list
            f32vector-fill! f32vector-copy! f32vector-scale!
            f32vector-axpy! f32vector-sum f32vector-dot)

;; the reductions reassociate, so they need not agree with a left-to-right
;; loop; they must agree when every partial sum is exact
(let ((v (make-f64vector 257 0.0)))
  (do ((i 0 (add1 i))) ((>= i 257))
    (f64vector-set! v i (exact->inexact i)))
  (assert (= (f64vector-sum v)
             (do ((i 0 (add1 i)) (s 0.0 (+ s (f64vector-ref v i))))
                 ((>= i 257) s))))
  (assert (= (f64vector-dot v v)
             (do ((i 0 (add1 i))
                  (s 0.0 (+ s (* (f64vector-ref v i) (f64vector-ref v i)))))
                 ((>= i 257) s)))))

;; A ratnum reaching `->f' used to be read as a bignum and segfault; every
;; complex store path must reject it cleanly, and must still accept the
;; complex, flonum and fixnum values it exists for.
(assert (bulk-error? (lambda () (c64vector 1/2))))
(assert (bulk-error? (lambda () (c128vector 1/2))))
(assert (bulk-error? (lambda () (make-c64vector 2 1/2))))
(assert (bulk-error? (lambda () (make-c128vector 2 1/2))))
(assert (bulk-error? (lambda () (c64vector-set! (make-c64vector 1 0) 0 1/2))))
(assert (bulk-error? (lambda () (c128vector-set! (make-c128vector 1 0) 0 1/2))))
(assert (bulk-error? (lambda () (list->c64vector (list 1/2)))))
(assert (bulk-error? (lambda () (list->c128vector (list 1/2)))))
(assert (bulk-error? (lambda () (with-input-from-string "#c64(1/2)" read))))

(assert (= 1+2i (c64vector-ref (c64vector 1+2i) 0)))
(assert (= 1+2i (c128vector-ref (c128vector 1+2i) 0)))
(assert (= 1.5+0.0i (c64vector-ref (c64vector 1.5) 0)))
(assert (= 2.0+0.0i (c128vector-ref (c128vector 2) 0)))
;; a complex fill is the one initializer these constructors exist for
(assert (= 1+2i (c64vector-ref (make-c64vector 2 1+2i) 1)))
(assert (= 1+2i (c128vector-ref (make-c128vector 2 1+2i) 1)))
(assert (= 3.0+0.0i (c64vector-ref (make-c64vector 2 3) 1)))
