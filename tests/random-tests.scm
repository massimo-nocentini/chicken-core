;;;; random number tests


(import (chicken random))

(define seed (random-bytes))

(define (nums n)
  (let loop ((n n))
    (if (zero? n)
        '()
        (cons (pseudo-random-integer 10000)
              (nums (- n 1))))))

(set-pseudo-random-seed! seed)
(define n1 (nums 100))
(set-pseudo-random-seed! seed)
(assert n1 (nums 100))


;;; Seeding (set-pseudo-random-seed!)

(import (chicken bytevector) (chicken bitwise) (chicken platform))

(define (stream seed . size)
  (apply set-pseudo-random-seed! seed size)
  (let loop ((i 0) (acc '()))
    (if (= i 20)
        (reverse acc)
        (loop (+ i 1) (cons (pseudo-random-integer 1000000000) acc)))))

;; A seed that would leave the generator in its all-zero state, a fixed
;; point of WELL512, must not: from there every word drawn is 0, so
;; `pseudo-random-real' returned 0.0 forever and the rejection loop of
;; `pseudo-random-integer' never returned.  The reals are checked first,
;; so that a regression fails here instead of hanging below.
(set-pseudo-random-seed! (make-bytevector 16 0))
(assert (not (equal? '(0.0 0.0 0.0 0.0)
                     (list (pseudo-random-real) (pseudo-random-real)
                           (pseudo-random-real) (pseudo-random-real)))))
(set-pseudo-random-seed! (make-bytevector 16 0))
(let ((s (list (pseudo-random-integer 100) (pseudo-random-integer 100)
               (pseudo-random-integer 100) (pseudo-random-integer 100))))
  (assert (not (equal? s '(0 0 0 0)))))

;; The state is the seed's little-endian words XORed onto a SplitMix64
;; stream keyed on the seed's length.  A seed equal to that stream is the
;; one seed that maps to the all-zero state, so it has to be nudged off it.
(define word-bytes (if (feature? #:64bit) 8 4))
(define state-words 16)

(define (splitmix64-stream key n)
  (let ((mask (- (arithmetic-shift 1 64) 1)))
    (let loop ((x key) (i 0) (acc '()))
      (if (= i n)
          (reverse acc)
          (let* ((x (bitwise-and (+ x #x9E3779B97F4A7C15) mask))
                 (z (bitwise-and (* (bitwise-xor x (arithmetic-shift x -30))
                                    #xBF58476D1CE4E5B9)
                                 mask))
                 (z (bitwise-and (* (bitwise-xor z (arithmetic-shift z -27))
                                    #x94D049BB133111EB)
                                 mask))
                 (z (bitwise-xor z (arithmetic-shift z -31))))
            (loop x (+ i 1) (cons z acc)))))))

(define zero-state-seed
  (let* ((n (* state-words word-bytes))
         (bv (make-bytevector n 0)))
    (let loop ((ws (splitmix64-stream n state-words)) (i 0))
      (unless (null? ws)
        (do ((k 0 (+ k 1)))
            ((= k word-bytes))
          (bytevector-u8-set!
           bv (+ (* i word-bytes) k)
           (bitwise-and (arithmetic-shift (car ws) (* -8 k)) 255)))
        (loop (cdr ws) (+ i 1))))
    bv))

(set-pseudo-random-seed! zero-state-seed)
(assert (not (equal? '(0.0 0.0 0.0 0.0)
                     (list (pseudo-random-real) (pseudo-random-real)
                           (pseudo-random-real) (pseudo-random-real)))))
(set-pseudo-random-seed! zero-state-seed)
(assert (not (equal? (list (pseudo-random-integer 100) (pseudo-random-integer 100)
                           (pseudo-random-integer 100) (pseudo-random-integer 100))
                     '(0 0 0 0))))

;; Seeds shorter than a word, and the bytes of a partial last word, count:
;; every seed of 1 to 17 bytes is deterministic and they all differ, also
;; when one is a prefix of another padded with zeros.  Only the first SIZE
;; bytes are read, so what lies beyond them makes no difference.
(define (seed-of n fill)
  (let ((bv (make-bytevector n fill)))
    (bytevector-u8-set! bv (- n 1) 7)
    bv))

(let loop ((n 1) (seen '()))
  (when (<= n 17)
    (let ((s (stream (seed-of n 0))))
      (assert (equal? s (stream (seed-of n 0))) "seed is not deterministic" n)
      (assert (not (member s seen)) "two seed lengths give the same stream" n)
      (loop (+ n 1) (cons s seen)))))

(assert (not (equal? (stream (bytevector 0)) (stream (bytevector 0 0)))))
(assert (not (equal? (stream (bytevector 1 2 3 4 5 6 7 8 9))
                     (stream (bytevector 1 2 3 4 5 6 7 8 10)))))
(assert (equal? (stream (bytevector 1 2 3 4 5 6 7 8) 4)
                (stream (bytevector 1 2 3 4 9 9 9 9) 4)))
(assert (equal? (stream (bytevector 1 2 3 4 5 6 7 8) 4)
                (stream (bytevector 1 2 3 4))))
(assert (equal? (stream (bytevector)) (stream (bytevector))))
(assert (equal? (stream (bytevector 1 2 3) 0) (stream (bytevector))))

;; Bytes past the 16 words of state are folded in rather than ignored.
(let ((a (make-bytevector 300 1))
      (b (make-bytevector 300 1)))
  (bytevector-u8-set! b 299 2)
  (assert (not (equal? (stream a) (stream b)))))
