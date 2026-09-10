;;;; utf-compare-tests.scm
;
; Exercises C_utf_compare through the two Scheme entry points that expose it
; without loss of information:
;
;   `string-compare3' returns C_utf_compare's raw value when it is non-zero,
;   so it pins down the *magnitude* of the answer and not merely its sign.
;   The magnitude is a difference of codepoints, never of bytes: comparing
;   U+00E9 with U+0101 must yield #xe9 - #x101 = -24, not the -1 a byte
;   comparison of their leading #xc3 / #xc4 would produce.
;
;   `substring=?' passes explicit start1/start2/len to C_utf_compare, so it
;   pins down that `len' is measured in CHARACTERS and not in bytes, and that
;   bytes past `len' are never looked at.
;
; C_utf_compare has an ASCII fast path in front of its decode loop.  These
; cases are chosen so that the fast path is entered, exited part-way, and
; skipped altogether, and so that a fast path which compared bytes instead of
; codepoints, or counted `len' in bytes, or ran past the first non-ASCII
; byte, would be caught.
;
; Every case travels through a list, and so through variables rather than
; literals, on purpose.  `substring=?', `string<?', `string>?' and
; `string=?' are declared #:foldable in types.db, so a call on literal
; arguments is evaluated by the *compiler* and the compiled test would say
; nothing about the library it links against.

(import (chicken string) (chicken fixnum) (chicken sort) (chicken time))

;;; --------------------------------------------------------------------
;;; string-compare3: exact values.  (string-compare3 s1 s2) is
;;; C_utf_compare's value at the first differing character, or the length
;;; difference when one string is a prefix of the other.

(define compare-cases
  ;; s1 s2 expected
  `(;; ASCII against ASCII - wholly inside the fast path
    ("" "" 0)
    ("a" "a" 0)
    ("abcdef" "abcdef" 0)
    ("a" "b" -1)
    ("b" "a" 1)
    ("abcz" "abca" 25)
    ("A" "a" -32)
    (,(string (integer->char 0)) ,(string (integer->char 1)) -1)
    (,(string #\a (integer->char 0) #\c) ,(string #\a (integer->char 0) #\d) -1)

    ;; a prefix compares by length difference
    ("abc" "abcdef" -3)
    ("abcdef" "abc" 3)
    ("" "abc" -3)
    ("abc" "" 3)

    ;; ASCII against non-ASCII: the fast path must hand over at the first
    ;; non-ASCII byte and the decode loop must produce a codepoint difference
    ("a" "\x3b1;" ,(fx- 97 945))
    ("\x3b1;" "a" ,(fx- 945 97))
    ("abc" "ab\x3b1;" ,(fx- 99 945))
    ("ab\x3b1;" "abc" ,(fx- 945 99))
    ("\x7f;" "\x80;" -1)
    ("\x80;" "\x7f;" 1)

    ;; non-ASCII against non-ASCII: the fast path never runs.  The first two
    ;; pairs differ in their *second* byte, so a byte comparison would answer
    ;; -1 and 1 instead of the codepoint difference.
    ("\xe9;" "\x101;" ,(fx- #xe9 #x101))
    ("\x101;" "\xe9;" ,(fx- #x101 #xe9))
    ("\x3b1;\x3b2;" "\x3b1;\x3b3;" -1)
    ("\x3b1;\x3b2;" "\x3b1;\x3b2;" 0)
    ("\x4e2d;" "\x4e2e;" -1)
    ("\x1f600;" "\x1f601;" -1)
    ("\x7ff;" "\x800;" -1)
    ("\xffff;" "\x10000;" -1)

    ;; a multi-byte character in front of the difference: the decode loop has
    ;; to consume it before the comparison that decides the answer
    ("\x3b1;a" "\x3b1;b" -1)
    ("\x3b1;abc" "\x3b1;abc" 0)
    ("a\x3b1;b" "a\x3b1;c" -1)
    ("abcdefgh" "abcdefgi" -1)
    ("abcdefgh\x3b1;" "abcdefgh\x3b2;" -1)))

(for-each
 (lambda (c)
   (let ((s1 (car c)) (s2 (cadr c)) (want (caddr c)))
     (assert (fx= (string-compare3 s1 s2) want) "string-compare3" s1 s2 want)
     ;; the three orderings must agree with the sign of that value
     (assert (eq? (string<? s1 s2) (fx< (string-compare3 s1 s2) 0))
             "string<? agrees with string-compare3" s1 s2)
     (assert (eq? (string>? s1 s2) (fx> (string-compare3 s1 s2) 0))
             "string>? agrees with string-compare3" s1 s2)
     (assert (eq? (string=? s1 s2) (fx= (string-compare3 s1 s2) 0))
             "string=? agrees with string-compare3" s1 s2)))
 compare-cases)

;;; --------------------------------------------------------------------
;;; substring=?: `len' is in characters, and bytes past `len' are not read

(define substring-cases
  ;; expected s1 s2 start1 start2 len
  '(;; a length-0 compare is true whatever follows it
    (#t "abc" "xyz" 0 0 0)
    (#t "\x3b1;bc" "\x4e2d;yz" 0 0 0)
    (#t "" "" 0 0 0)

    ;; strings that differ only past `len'
    (#t "abcX" "abcY" 0 0 3)
    (#f "abcX" "abcY" 0 0 4)

    ;; `len' counts characters: "\x3b1;\x3b2;\x3b3;" is 3 characters and 6
    ;; bytes, so len 3 must stop before the differing 4th character.  A byte
    ;; count would compare only the first three bytes and then, at len 4,
    ;; still not reach the difference.
    (#t "\x3b1;\x3b2;\x3b3;X" "\x3b1;\x3b2;\x3b3;Y" 0 0 3)
    (#f "\x3b1;\x3b2;\x3b3;X" "\x3b1;\x3b2;\x3b3;Y" 0 0 4)
    (#t "ab\x3b1;X" "ab\x3b1;Y" 0 0 3)
    (#f "ab\x3b1;X" "ab\x3b1;Y" 0 0 4)

    ;; non-zero starts, behind 2-, 3- and 4-byte characters
    (#t "\x3b1;abc" "\x4e2d;abc" 1 1 3)
    (#t "xx\x1f600;abc" "\x3b1;abc" 3 1 3)
    (#f "\x3b1;abc" "\x4e2d;abd" 1 1 3)
    (#t "aaa\x3b1;\x3b2;" "zzz\x3b1;\x3b2;" 3 3 2)
    (#f "aaa\x3b1;\x3b2;" "zzz\x3b1;\x3b3;" 3 3 2)

    ;; whole-string comparisons and empty strings
    (#t "abc" "abc" 0 0 3)
    (#t "\x3b1;\x4e2d;\x1f600;" "\x3b1;\x4e2d;\x1f600;" 0 0 3)
    (#f "abc" "abd" 0 0 3)
    (#t "" "" 0 0 0)))

(for-each
 (lambda (c)
   (let ((want (car c)) (s1 (cadr c)) (s2 (caddr c))
         (st1 (cadddr c)) (st2 (list-ref c 4)) (n (list-ref c 5)))
     (assert (eq? want (substring=? s1 s2 st1 st2 n))
             "substring=?" s1 s2 st1 st2 n)))
 substring-cases)

;; with no explicit len, substring=? compares min(len1, len2) characters, so
;; a comparison against the empty string is a length-0 compare and is true
(for-each
 (lambda (c)
   (assert (eq? (car c) (substring=? (cadr c) (caddr c))) "substring=? default len" c))
 '((#t "abc" "abc")
   (#f "abc" "abd")
   (#t "" "")
   (#t "" "a")
   (#t "a" "")
   (#t "\x3b1;\x4e2d;" "\x3b1;\x4e2d;")
   (#f "\x3b1;\x4e2d;" "\x3b1;\x4e2e;")))

;;; --------------------------------------------------------------------
;;; sorting: the shape the ASCII fast path was added for

(let* ((ws (list "alpha" "alp" "alpine" "beta" "bet" "abc" "abd" "abcd" "aa" "ab"
                 "\x3b1;lpha" "\x3b1;lp" "\x4e2d;" "\x4e2d;a" "" "z" "zz"))
       (sorted (sort ws string<?)))
  (assert (equal? sorted (sort (reverse ws) string<?)) "sort is order-independent")
  (let loop ((l sorted))
    (when (and (pair? l) (pair? (cdr l)))
      (assert (not (string<? (cadr l) (car l))) "sorted ascending" (car l) (cadr l))
      (loop (cdr l)))))

(print "utf-compare tests passed")

;;; --------------------------------------------------------------------
;;; The memoised index cursor (slots 2 and 3 of a string) that utf_index1
;;; maintains, as seen through substring / string-ref / string-set!.
;;;
;;; C_utf_range now puts the cursor back on `start' before returning, so that
;;; the C_utf_copy which follows it inside ##sys#substring finds it there.
;;; Everything below checks that the cursor still tells the truth: for
;;; ascending, descending and random access, across mutation that changes a
;;; character's byte length, and when the cursor has been parked past the
;;; mutation.

;; a mostly-ASCII string with one 2-byte character at the front: the shape
;; where the cursor matters, because the byte-index == character-index
;; shortcut in utf_index cannot be taken and every index has to be walked
(define (make-mixed n)
  (list->string
   (cons (integer->char #xe9)
         (let loop ((i (fx- n 1)) (acc (list)))
           (if (fx< i 0)
               acc
               (loop (fx- i 1) (cons (integer->char (fx+ 97 (fxmod i 26))) acc)))))))

(define mixed (make-mixed 600))
(define mixed-chars (list->vector (string->list mixed)))

(define (ref-substring v from to)
  (let loop ((i (fx- to 1)) (acc (list)))
    (if (fx< i from)
        (list->string acc)
        (loop (fx- i 1) (cons (vector-ref v i) acc)))))

(assert (fx= (string-length mixed) 601) "mixed string length")

;; ascending tokenisation - the access pattern that was quadratic
(let loop ((i 0))
  (when (fx< i (string-length mixed))
    (let ((e (fxmin (string-length mixed) (fx+ i 7))))
      (assert (string=? (substring mixed i e) (ref-substring mixed-chars i e))
              "ascending substring" i e)
      (loop e))))

;; descending tokenisation
(let loop ((e (string-length mixed)))
  (when (fx> e 0)
    (let ((i (fxmax 0 (fx- e 7))))
      (assert (string=? (substring mixed i e) (ref-substring mixed-chars i e))
              "descending substring" i e)
      (loop i))))

;; random access, interleaved with string-ref so that both users of the
;; cursor take turns moving it
(define seed 12345)
(define (rnd n)
  (set! seed (fxmod (fx+ (fx* seed 1103515) 12345) 1048576))
  (fxmod seed n))

(let loop ((k 0))
  (when (fx< k 400)
    (let* ((n (string-length mixed))
           (a (rnd n))
           (b (rnd n))
           (from (fxmin a b))
           (to (fxmax a b)))
      (assert (string=? (substring mixed from to) (ref-substring mixed-chars from to))
              "random substring" from to)
      (assert (char=? (string-ref mixed from) (vector-ref mixed-chars from))
              "string-ref after substring" from)
      (loop (fx+ k 1)))))

;; mutation: string-set! can change a character's byte length, which moves
;; every byte offset after it, so no cursor may survive as a stale answer
(let ((s (make-mixed 200))
      (v (list->vector (string->list (make-mixed 200)))))
  (define (check tag)
    (assert (string=? s (list->string (vector->list v))) "mutated string" tag)
    (let loop ((i 0))
      (when (fx< i (string-length s))
        (assert (char=? (string-ref s i) (vector-ref v i)) "mutated string-ref" tag i)
        (loop (fx+ i 1)))))
  (define (put! i c)
    (string-set! s i c)
    (vector-set! v i c))
  (assert (char=? (string-ref s 150) (vector-ref v 150)) "move the cursor right")
  (put! 3 (integer->char #x4e2d))       ; 1 byte -> 3 bytes, left of the cursor
  (check 'grow-left)
  (assert (string=? (substring s 100 120) (ref-substring v 100 120)) "substring after grow")
  (put! 3 #\x)                          ; 3 bytes -> 1 byte
  (check 'shrink-left)
  (put! 199 (integer->char #x1f600))    ; 1 byte -> 4 bytes, at the end
  (check 'grow-right)
  (put! 0 #\a)                          ; 2 bytes -> 1 byte, at the very front
  (check 'shrink-front)
  (assert (string=? (substring s 0 10) (ref-substring v 0 10)) "substring at head")
  (assert (string=? (substring s 190 201) (ref-substring v 190 201)) "substring at tail")
  (assert (string=? (substring s 0 (string-length s)) (list->string (vector->list v)))
          "whole substring"))

;; the same, with the cursor deliberately parked past the mutation by a
;; substring call made before the string-set!
(let ((s (make-mixed 100))
      (v (list->vector (string->list (make-mixed 100)))))
  (assert (string=? (substring s 80 100) (ref-substring v 80 100)) "park the cursor")
  (string-set! s 5 (integer->char #x4e2d))
  (vector-set! v 5 (integer->char #x4e2d))
  (assert (string=? (substring s 80 100) (ref-substring v 80 100)) "cursor past mutation")
  (assert (char=? (string-ref s 5) (vector-ref v 5)) "read the mutated character")
  (assert (string=? (substring s 0 20) (ref-substring v 0 20)) "substring across mutation")
  (assert (string=? s (list->string (vector->list v))) "string after parked mutation"))

;; ASCII-only strings take the other branch of utf_index (byte index ==
;; character index, no cursor walk) and must be unaffected
(let* ((a (make-string 500 #\q))
       (b (string-append (substring a 0 100) (substring a 100 500))))
  (assert (string=? a b) "ascii shortcut path")
  (assert (char=? (string-ref a 499) #\q) "ascii shortcut string-ref"))

;;; --------------------------------------------------------------------
;;; Ascending substring tokenisation must be linear, not quadratic.
;;;
;;; This is a timing check because the defect it guards is a complexity
;;; defect and nothing else: the answers were always right, they just took
;;; O(n^2) to produce.  Quadrupling the input quadruples the work when the
;;; cursor survives and multiplies it by sixteen when it does not, so the
;;; bound below - eight, plus 50 ms of slack for timer granularity and
;;; scheduling - sits well clear of either.  Best of three runs each way.

(define (tokenise str)
  (let ((n (string-length str)))
    (let loop ((i 0) (acc 0))
      (if (fx>= i n)
          acc
          (let ((e (fxmin n (fx+ i 5))))
            (loop e (fx+ acc (string-length (substring str i e)))))))))

(define (best-of-3 thunk)
  (let loop ((k 0) (b 1000000000))
    (if (fx>= k 3)
        b
        (let* ((t0 (current-process-milliseconds))
               (ignored (thunk))
               (d (fx- (current-process-milliseconds) t0)))
          (loop (fx+ k 1) (fxmin b d))))))

(let* ((small (make-mixed 40000))
       (big (make-mixed 160000))
       (ts (best-of-3 (lambda () (tokenise small))))
       (tb (best-of-3 (lambda () (tokenise big)))))
  (assert (fx< tb (fx+ (fx* ts 8) 50))
          "ascending substring tokenisation is not quadratic" ts tb))

(print "utf index/memo tests passed")
