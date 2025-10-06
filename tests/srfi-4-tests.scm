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
               ("#u8(\"\")" #u8())
               ("#u8(\"\" \"a\")" #u8(97))
               ("#u8(\"a\" \"\")" #u8(97))
               ("#u8\"\"" #u8())
               ("#s8\"\"" #s8())
               ("#u64(\" \" #\\! 1 \"A\")" #u64(32 33 1 65))
               ("#u64(\" \" #\\! \"A\" 1)" #u64(32 33 65 1)))))
  (do ((cs cases (cdr cs)))
      ((null? cs))
      (let ((x (with-input-from-string (caar cs) read)))
        (unless (equal? x (cadar cs))
          (error "failed" x (cadar cs))))))

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
