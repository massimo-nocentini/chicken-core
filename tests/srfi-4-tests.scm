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
               ;; the string form used to reach list->NNNvector as a list of
               ;; characters, so it worked for u8 only
               ("#s8\"abc\"" #s8(97 98 99))
               ("#u16\"abc\"" #u16(97 98 99))
               ("#s64\"A\"" #s64(65))
               ("#u64\"A\"" #u64(65))
               ("#f32\"AB\"" #f32(65.0 66.0))
               ("#f64\"AB\"" #f64(65.0 66.0))
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

;; the complex constructors used to pre-scale the length with an unchecked
;; `fx*', which shifts and re-tags a non-fixnum into a plausible-looking
;; fixnum, so the length never reached `alloc''s validation
(assert (bulk-error? (lambda () (make-c64vector 'x))))
(assert (bulk-error? (lambda () (make-c128vector 'x))))
(assert (bulk-error? (lambda () (make-c64vector -1))))
(assert (bulk-error? (lambda () (make-c128vector -1))))
(assert (= 3 (c64vector-length (make-c64vector 3 1+2i))))
(assert (= 3 (c128vector-length (make-c128vector 3 1+2i))))
(assert (= 0 (c64vector-length (make-c64vector 0))))

;; NONGC allocation and explicit release.  ext-free used to free slot 1
;; unconditionally, which for a u8vector -- a bare bytevector, not a
;; (tag . bytevector) structure -- is a word of its own contents.
(let ((v (make-u8vector 32 170 #t #f)))
  (assert (eqv? 170 (u8vector-ref v 31)))
  (release-number-vector v))
(let ((v (make-f64vector 4 1.0 #t #f)))
  (assert (eqv? 1.0 (f64vector-ref v 3)))
  (release-number-vector v))
(let ((v (make-u16vector 8 65535 #t #f)))
  (assert (eqv? 65535 (u16vector-ref v 7)))
  (release-number-vector v))
(let ((v (make-c64vector 4 1+2i #t #f)))
  (assert (= 1+2i (c64vector-ref v 3)))
  (release-number-vector v))
(assert (bulk-error? (lambda () (release-number-vector 'x))))

;; ##sys#make-locative checked the index against the BYTE size of the
;; backing bytevector while C_a_i_make_locative scales it by the element
;; size, so the accepted range was elemsize times too large.
(import (chicken locative))

(define-syntax test-locative-range
  (er-macro-transformer
   (lambda (x r c)
     (let* ((name (symbol->string (strip-syntax (cadr x))))
            (len (caddr x)))
       (define (conc op) (string->symbol (string-append name op)))
       `(let ((v (,(conc "vector") ,@(cdddr x))))
          ;; the last element is addressable, one past the end is not
          (assert (,(conc "vector-ref") v (- ,len 1))
                  (locative-ref (make-locative v (- ,len 1))))
          (assert (bulk-error? (lambda () (make-locative v ,len))))
          ;; an index inside the byte count but outside the element count
          (assert (bulk-error? (lambda () (make-locative v (* ,len 8))))))))))

(test-locative-range u8 4 1 2 3 4)
(test-locative-range s8 4 1 2 3 4)
(test-locative-range u16 4 1 2 3 4)
(test-locative-range s16 4 1 2 3 4)
(test-locative-range u32 2 9 8)
(test-locative-range s32 2 9 -8)
(test-locative-range u64 2 9 8)
(test-locative-range s64 2 -1 -2)
(test-locative-range f32 2 1.0 2.0)
(test-locative-range f64 2 1.0 2.0)

;; complex vectors have no locative type of their own
(assert (bulk-error? (lambda () (make-locative (c64vector 1+2i) 0))))
(assert (bulk-error? (lambda () (make-locative (c128vector 1+2i) 0))))

(let* ((v (f64vector 1.0 2.0)) (l (make-locative v 1)))
  (locative-set! l 9.5)
  (assert (eqv? 9.5 (f64vector-ref v 1))))

;; the accessors held the index in an `int', so an index past 2**32 was
;; truncated and the bounds check passed on the wrapped value
(let ((big 4294967298))                 ; 2**32 + 2
  (assert (bulk-error? (lambda () (f64vector-ref (f64vector 1. 2. 3. 4. 5.) big))))
  (assert (bulk-error? (lambda () (f64vector-set! (f64vector 1. 2.) big 0.0))))
  (assert (bulk-error? (lambda () (u8vector-ref (u8vector 1 2 3) big))))
  (assert (bulk-error? (lambda () (u16vector-ref (u16vector 1 2 3) big))))
  (assert (bulk-error? (lambda () (s32vector-ref (s32vector 1 2 3) big))))
  (assert (bulk-error? (lambda () (vector-ref (vector 1 2 3) big))))
  (assert (bulk-error? (lambda () (string-ref "abc" big)))))

;; The setters tested integer-length <= N for signed N-bit types, where the
;; representable range needs <= N-1, and u8/u32/u64 never tested the sign at
;; all, so out-of-range values wrapped silently instead of erroring.
(define-syntax test-element-range
  (er-macro-transformer
   (lambda (x r c)
     (let* ((name (symbol->string (strip-syntax (cadr x))))
            (lo (caddr x))
            (hi (cadddr x)))
       (define (conc op) (string->symbol (string-append name op)))
       `(let ((v (,(conc "vector") 0)))
          (,(conc "vector-set!") v 0 ,lo)
          (assert (= ,lo (,(conc "vector-ref") v 0)))
          (,(conc "vector-set!") v 0 ,hi)
          (assert (= ,hi (,(conc "vector-ref") v 0)))
          (assert (bulk-error? (lambda () (,(conc "vector-set!") v 0 (- ,lo 1)))))
          (assert (bulk-error? (lambda () (,(conc "vector-set!") v 0 (+ ,hi 1))))))))))

(test-element-range u8 0 255)
(test-element-range s8 -128 127)
(test-element-range u16 0 65535)
(test-element-range s16 -32768 32767)
(test-element-range u32 0 4294967295)
(test-element-range s32 -2147483648 2147483647)
(test-element-range u64 0 18446744073709551615)
(test-element-range s64 -9223372036854775808 9223372036854775807)

;; make-s8vector validated its fill with the unsigned checker
(assert (= -1 (s8vector-ref (make-s8vector 2 -1) 1)))
(assert (bulk-error? (lambda () (make-s8vector 2 200))))

;; bytevector->u64vector and ->s64vector validated against element size 4,
;; so a length that is a multiple of 4 but not of 8 was accepted and the
;; trailing four bytes became unreachable
(import (chicken bytevector))
(assert (= 2 (u64vector-length (bytevector->u64vector (make-bytevector 16 0)))))
(assert (= 2 (s64vector-length (bytevector->s64vector/shared (make-bytevector 16 0)))))
(assert (bulk-error? (lambda () (bytevector->u64vector (make-bytevector 12 0)))))
(assert (bulk-error? (lambda () (bytevector->s64vector (make-bytevector 12 0)))))
(assert (bulk-error? (lambda () (bytevector->u64vector/shared (make-bytevector 12 0)))))
(assert (bulk-error? (lambda () (bytevector->s64vector/shared (make-bytevector 4 0)))))
;; /shared aliases, the copying form does not
(let* ((bv (make-bytevector 16 0)) (v (bytevector->u64vector/shared bv)))
  (u64vector-set! v 0 255)
  (assert (= 255 (bytevector-u8-ref bv 0))))
(let* ((bv (make-bytevector 16 0)) (v (bytevector->u64vector bv)))
  (u64vector-set! v 0 255)
  (assert (= 0 (bytevector-u8-ref bv 0))))

;; -axpy! is documented to be bit-identical to the element-at-a-time loop,
;; which rounds the product before adding; an FMA would not be
(define-syntax test-axpy-identity
  (er-macro-transformer
   (lambda (x r c)
     (let ((name (symbol->string (strip-syntax (cadr x)))))
       (define (conc op) (string->symbol (string-append name op)))
       `(let ((y (,(conc "vector") -0.01 0.3 -7.5))
              (x (,(conc "vector") 0.1 0.7 2.25))
              (w (,(conc "vector") -0.01 0.3 -7.5)))
          (,(conc "vector-axpy!") y 0.1 x)
          ;; the same computation, one element at a time, through the
          ;; safe accessors -- this is the loop the manual names
          (do ((i 0 (add1 i))) ((>= i 3))
            (,(conc "vector-set!") w i
             (+ (* 0.1 (,(conc "vector-ref") x i))
                (,(conc "vector-ref") w i))))
          (do ((i 0 (add1 i))) ((>= i 3))
            (assert (= (,(conc "vector-ref") y i) (,(conc "vector-ref") w i)))))))))

(test-axpy-identity f64)
(test-axpy-identity f32)

;; the manual says the srfi-4 feature identifier is defined when loaded
(import (chicken platform))
(assert (feature? 'srfi-4))

;; sub*vector checked both bounds against 0 and never required FROM <= TO,
;; so a negative size reached the allocator and barfed with an internal
;; byte count instead of naming the procedure
(assert (bulk-error? (lambda () (subf64vector (f64vector 1. 2. 3. 4.) 3 1))))
(assert (bulk-error? (lambda () (subu8vector (u8vector 1 2 3 4) 3 1))))
(assert (bulk-error? (lambda () (subs16vector (s16vector 1 2 3 4) 4 2))))
(assert (equal? (f64vector 2.0 3.0) (subf64vector (f64vector 1. 2. 3. 4.) 1 3)))
(assert (equal? (u8vector 2 3) (subu8vector (u8vector 1 2 3 4) 1 3)))
(assert (equal? (f64vector) (subf64vector (f64vector 1. 2.) 1 1)))

;; move-memory! omitted the complex vectors from its slot-1 structure list
(import (chicken memory))
(let ((a (c64vector 1+2i)) (b (c64vector 0)))
  (move-memory! a b 8)
  (assert (= 1+2i (c64vector-ref b 0))))
(let ((a (c128vector 3+4i)) (b (c128vector 0)))
  (move-memory! a b 16)
  (assert (= 3+4i (c128vector-ref b 0))))

;; printing must be unchanged by the dispatch table hoist
(assert (string=? "#f64(1.5 +nan.0 +inf.0 -0.0)"
                  (with-output-to-string
                    (lambda () (write (f64vector 1.5 +nan.0 +inf.0 -0.0))))))
(assert (string=? "#c64(1.0+2.0i)"
                  (with-output-to-string (lambda () (write (c64vector 1+2i))))))
(assert (string=? "#s64(-1 2)"
                  (with-output-to-string (lambda () (write (s64vector -1 2))))))
(assert (equal? (f64vector 1.5 +inf.0)
                (with-input-from-string
                    (with-output-to-string
                      (lambda () (write (f64vector 1.5 +inf.0))))
                  read)))
