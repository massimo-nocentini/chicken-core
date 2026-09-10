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
