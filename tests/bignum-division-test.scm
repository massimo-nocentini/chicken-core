;;;; bignum-division-test.scm
;
; Differential tests for the bignum multiplication and division kernels in
; runtime.c (bignum_digits_multiply, bignum_destructive_divide_normalized
; and bignum_digits_destructive_scale_down).
;
; Those kernels have two implementations selected at compile time -- one
; working on halfdigits and one working on whole digits -- so identities
; alone are not enough: an identity check that uses `*' to verify `quotient'
; is checking a kernel against itself.  Every case here is therefore also
; compared against a REFERENCE implementation written in Scheme that uses
; only addition, subtraction, comparison and arithmetic-shift, none of which
; go anywhere near the multiply/divide kernels:
;
;   ref-mul   shift-and-add
;   ref-div   restoring binary long division
;
; The sweep deliberately straddles every boundary the kernels care about:
; the fixnum/bignum boundary, the halfdigit boundary (32 bits), the digit
; boundary (64 bits), the point where a divisor stops fitting in a halfdigit,
; and the Karatsuba threshold.  It includes one-digit divisors, divisors
; whose high half is zero, powers of two, a numerator shorter than the
; divisor, exact division, and the operand shapes that force Knuth D's
; quotient-digit estimate to be corrected (including the rare add-back).

(import (chicken bitwise) (chicken format))

(define failures 0)

(define (check name expected got)
  (unless (equal? expected got)
    (set! failures (add1 failures))
    (printf "FAIL ~a~%  expected ~a~%  got      ~a~%" name expected got)))

;;; --- reference implementations, kernel-independent ------------------------

;; Shift-and-add product of two non-negative integers.
(define (ref-mul* a b)
  (let loop ((b b) (a a) (acc 0))
    (if (zero? b)
        acc
        (loop (arithmetic-shift b -1)
              (arithmetic-shift a 1)
              (if (odd? b) (+ acc a) acc)))))

(define (ref-mul a b)
  (let ((m (ref-mul* (abs a) (abs b))))
    (if (eq? (negative? a) (negative? b)) m (- m))))

;; Restoring binary long division of non-negative n by positive d.
;; Returns (list quotient remainder).
(define (ref-div* n d)
  (let ((shift (- (integer-length n) (integer-length d))))
    (if (negative? shift)
        (list 0 n)
        (let loop ((i shift) (r n) (q 0))
          (if (negative? i)
              (list q r)
              (let ((sd (arithmetic-shift d i)))
                (if (>= r sd)
                    (loop (sub1 i) (- r sd) (+ (arithmetic-shift q 1) 1))
                    (loop (sub1 i) r (arithmetic-shift q 1)))))))))

;; Truncating quotient/remainder with CHICKEN's (= R7RS) sign conventions.
(define (ref-quotient n d)
  (let ((q (car (ref-div* (abs n) (abs d)))))
    (if (eq? (negative? n) (negative? d)) q (- q))))

(define (ref-remainder n d)
  (let ((r (cadr (ref-div* (abs n) (abs d)))))
    (if (negative? n) (- r) r)))

(define (ref-modulo n d)
  (let ((r (ref-remainder n d)))
    (if (or (zero? r) (eq? (negative? r) (negative? d))) r (+ r d))))

;;; --- deterministic pseudo-random integers ---------------------------------

(define seed 88172645463325252)

(define (rnd!)                          ; xorshift64
  (set! seed (bitwise-and (bitwise-xor seed (arithmetic-shift seed 13))
                          #xFFFFFFFFFFFFFFFF))
  (set! seed (bitwise-xor seed (arithmetic-shift seed -7)))
  (set! seed (bitwise-and (bitwise-xor seed (arithmetic-shift seed 17))
                          #xFFFFFFFFFFFFFFFF))
  seed)

;; A number of exactly `bits' bits (top bit set), so operand lengths in
;; digits are what the sweep says they are.
(define (rand-bits bits)
  (if (zero? bits)
      0
      (let loop ((n 0) (b 0))
        (if (>= b bits)
            (bitwise-ior (bitwise-and n (sub1 (arithmetic-shift 1 (sub1 bits))))
                         (arithmetic-shift 1 (sub1 bits)))
            (loop (+ (arithmetic-shift n 64) (rnd!)) (+ b 64))))))

;;; --- multiplication -------------------------------------------------------

; Sizes straddle the halfdigit (32), digit (64) and Karatsuba (70 digits =
; 4480 bits) boundaries.  ref-mul is O(bits) big additions, so the sweep for
; it stops well short of the huge sizes; the identity sweep below covers those.
(define mul-sizes '(1 2 31 32 33 63 64 65 96 127 128 129 191 192 256 320 512 1024))

(for-each
 (lambda (bx)
   (for-each
    (lambda (by)
      (let ((a (rand-bits bx)) (b (rand-bits by)))
        (check (sprintf "mul ~a x ~a" bx by) (ref-mul a b) (* a b))
        (check (sprintf "mul -~a x ~a" bx by) (ref-mul (- a) b) (* (- a) b))
        (check (sprintf "mul -~a x -~a" bx by) (ref-mul (- a) (- b)) (* (- a) (- b)))
        ;; all-ones operands: every partial product carries
        (let ((f (sub1 (arithmetic-shift 1 bx))) (g (sub1 (arithmetic-shift 1 by))))
          (check (sprintf "mul ones ~a x ~a" bx by) (ref-mul f g) (* f g)))))
    mul-sizes))
 mul-sizes)

;; Big sizes: cross-check the schoolbook kernel against Karatsuba, which is
;; built out of smaller multiplications, shifts, additions and subtractions.
(for-each
 (lambda (bits)
   (let* ((a (rand-bits bits))
          (b (rand-bits bits))
          (h (arithmetic-shift bits -1))
          (ah (arithmetic-shift a (- h)))
          (al (bitwise-and a (sub1 (arithmetic-shift 1 h))))
          ;; (ah*2^h + al) * b, expanded so the operands are half as long
          (split (+ (arithmetic-shift (* ah b) h) (* al b))))
     (check (sprintf "mul split ~a" bits) split (* a b))
     (check (sprintf "sqr ~a" bits) (* a a) (ref-mul* a a))))
 '(2048 4096 4480 4544 8192))

;;; --- division -------------------------------------------------------------

(define (check-div name n d)
  (let ((q (quotient n d))
        (r (remainder n d))
        (m (modulo n d)))
    (check (sprintf "quotient ~a" name) (ref-quotient n d) q)
    (check (sprintf "remainder ~a" name) (ref-remainder n d) r)
    (check (sprintf "modulo ~a" name) (ref-modulo n d) m)
    ;; n = q*d + r, and |r| < |d|
    (check (sprintf "identity ~a" name) n (+ (* q d) r))
    (check (sprintf "remainder magnitude ~a" name) #t (< (abs r) (abs d)))))

(define div-sizes '(1 2 31 32 33 63 64 65 96 127 128 129 191 192 255 256 257
                    320 512 640 1024 1088 2048))

(for-each
 (lambda (bn)
   (for-each
    (lambda (bd)
      (let ((n (rand-bits bn)) (d (rand-bits bd)))
        (check-div (sprintf "~a/~a" bn bd) n d)
        (check-div (sprintf "-~a/~a" bn bd) (- n) d)
        (check-div (sprintf "~a/-~a" bn bd) n (- d))
        (check-div (sprintf "-~a/-~a" bn bd) (- n) (- d))
        ;; exact division, and one more than exact
        (let ((p (* n d)))
          (check (sprintf "exact ~a/~a" bn bd) n (quotient p d))
          (check (sprintf "exact rem ~a/~a" bn bd) 0 (remainder p d))
          (check (sprintf "exact+1 ~a/~a" bn bd) n (quotient (+ p (sub1 d)) d)))))
    div-sizes))
 div-sizes)

;;; Divisors that exercise the special shapes of the kernels: powers of two
;;; (handled by shifting), values that fit a halfdigit (scale-down loop),
;;; values with a zero high half, one-digit divisors, and 2^k-1.
(define special-divisors
  (append
   (list 1 2 3 7 10 255 256 65535 65536 1000000007)
   (list (sub1 (arithmetic-shift 1 32))      ; largest halfdigit
         (arithmetic-shift 1 32)             ; power of two, zero low half
         (add1 (arithmetic-shift 1 32))
         (sub1 (arithmetic-shift 1 62))      ; fixnum boundary
         (arithmetic-shift 1 62)
         (sub1 (arithmetic-shift 1 63))
         (arithmetic-shift 1 63)             ; normalised one-digit divisor
         (add1 (arithmetic-shift 1 63))
         (sub1 (arithmetic-shift 1 64))      ; largest one-digit divisor
         (arithmetic-shift 1 64)             ; two digits, high half of top zero
         (add1 (arithmetic-shift 1 64))
         (arithmetic-shift 1 95)
         (sub1 (arithmetic-shift 1 96))
         (arithmetic-shift 1 127)
         (sub1 (arithmetic-shift 1 128))
         (arithmetic-shift 1 191)
         (sub1 (arithmetic-shift 1 256)))))

(for-each
 (lambda (bn)
   (let ((n (rand-bits bn)))
     (for-each
      (lambda (d)
        (check-div (sprintf "special ~a/~a" bn d) n d)
        (check-div (sprintf "special -~a/~a" bn d) (- n) d))
      special-divisors)))
 '(1 64 65 128 129 200 256 512 1000 2048))

;;; Numerator shorter than the divisor: quotient must be 0 and the
;;; remainder the numerator itself.
(for-each
 (lambda (p)
   (let ((n (rand-bits (car p))) (d (rand-bits (cadr p))))
     (check (sprintf "short ~a/~a q" (car p) (cadr p)) 0 (quotient n d))
     (check (sprintf "short ~a/~a r" (car p) (cadr p)) n (remainder n d))
     (check (sprintf "short -~a/~a r" (car p) (cadr p)) (- n) (remainder (- n) d))))
 '((1 64) (63 64) (64 65) (64 128) (65 129) (127 128) (128 129) (200 1024)
   (1023 1024) (1024 1025) (2000 4096)))

;;; Knuth D correction cases.  With a normalised divisor v, the estimate
;;; qhat computed from the top two digits is at most 2 too large, and the
;;; "add back" branch is taken only for very particular operands.  Feeding
;;; the divider numerators of the form q*v + (v-1) for extreme q, and
;;; divisors that are just above/below a power of two, walks straight into
;;; those branches.
(define B (arithmetic-shift 1 64))

(for-each
 (lambda (n-digits)
   (for-each
    (lambda (v)
      (for-each
       (lambda (q)
         (let ((n (+ (* q v) (sub1 v))))
           (check-div (sprintf "knuth ~a" n-digits) n v)
           (check-div (sprintf "knuth+1 ~a" n-digits) (add1 n) v)
           (check-div (sprintf "knuth-1 ~a" n-digits) (sub1 n) v)))
       (list (sub1 (arithmetic-shift 1 (* 64 n-digits)))
             (arithmetic-shift 1 (* 64 n-digits))
             (rand-bits (* 64 n-digits))
             (sub1 B)
             B)))
    ;; normalised divisors of 2..5 digits with adversarial low digits
    (list (sub1 (arithmetic-shift 1 128))
          (+ (arithmetic-shift 1 127) 1)
          (+ (arithmetic-shift 1 127) (sub1 B))
          (- (arithmetic-shift 1 128) B)
          (sub1 (arithmetic-shift 1 192))
          (+ (arithmetic-shift 1 191) (sub1 B))
          (sub1 (arithmetic-shift 1 320))
          (+ (arithmetic-shift 1 319) B)))
   )
 '(1 2 3 4))

;;; Operands large enough to take the Burnikel-Ziegler path (divisor above
;;; C_BURNIKEL_ZIEGLER_THRESHOLD = 300 digits = 19200 bits), which recurses
;;; down into the same two kernels.  ref-div is O(bits) big shifts and would
;;; be far too slow here, so these are checked by reconstruction instead:
;;; the multiplication has already been checked against ref-mul above.

(define (check-big name n d)
  (let ((q (quotient n d))
        (r (remainder n d)))
    (check (sprintf "bz identity ~a" name) n (+ (* q d) r))
    (check (sprintf "bz magnitude ~a" name) #t (< (abs r) (abs d)))
    (check (sprintf "bz exact ~a" name) q (quotient (* q d) d))
    (check (sprintf "bz exact rem ~a" name) 0 (remainder (* q d) d))
    (check (sprintf "bz modulo ~a" name) (modulo n d)
           (if (or (zero? r) (eq? (negative? r) (negative? d))) r (+ r d)))))

(for-each
 (lambda (p)
   (let* ((bn (car p)) (bd (cadr p))
          (n (rand-bits bn)) (d (rand-bits bd))
          (name (sprintf "~a/~a" bn bd)))
     (check-big name n d)
     (check-big (string-append "-" name) (- n) d)
     (check-big (string-append name "-neg-d") n (- d))
     ;; all-ones operands at these sizes
     (check-big (string-append name " ones")
                (sub1 (arithmetic-shift 1 bn))
                (sub1 (arithmetic-shift 1 bd)))))
 '((19200 19200) (19300 19250) (25000 19500) (40000 20000)
   (64000 19201) (38400 19200) (20000 19200)))

;;; --- scale-down (number->string with a non-power-of-two radix) ------------

(for-each
 (lambda (bits)
   (let ((n (rand-bits bits)))
     (for-each
      (lambda (radix)
        (check (sprintf "radix ~a base ~a" bits radix)
               n (string->number (number->string n radix) radix))
        (check (sprintf "radix ~a base ~a neg" bits radix)
               (- n) (string->number (number->string (- n) radix) radix)))
      '(2 3 7 8 10 11 16 36))
     ;; digits of the decimal expansion must agree with repeated division
     (check (sprintf "decimal ~a" bits)
            (number->string n 10)
            (let loop ((n n) (acc '()))
              (if (zero? n)
                  (if (null? acc) "0" (list->string acc))
                  (loop (quotient n 10)
                        (cons (integer->char (+ 48 (remainder n 10))) acc)))))))
 '(1 64 65 128 200 512 1024 4096 8192))

;;; --- gcd, expt and modular exponentiation --------------------------------

(do ((i 0 (add1 i))) ((= i 25))
  (let* ((a (rand-bits (+ 65 (* i 37))))
         (b (rand-bits (+ 33 (* i 19))))
         (m (add1 (rand-bits (+ 64 (* i 11)))))
         (g (gcd a b)))
    (check (sprintf "gcd divides a ~a" i) 0 (remainder a g))
    (check (sprintf "gcd divides b ~a" i) 0 (remainder b g))
    (check (sprintf "lcm ~a" i) (* a b) (* g (lcm a b)))
    ;; square-and-multiply modular exponentiation exercises both kernels
    (check (sprintf "modexp ~a" i)
           (modulo (expt a 7) m)
           (let loop ((e 7) (base (modulo a m)) (acc 1))
             (if (zero? e)
                 acc
                 (loop (arithmetic-shift e -1)
                       (modulo (* base base) m)
                       (if (odd? e) (modulo (* acc base) m) acc)))))))

(if (zero? failures)
    (print "bignum division tests passed")
    (begin (printf "~a bignum division test(s) FAILED~%" failures)
           (exit 1)))
