(import (scheme base)
        (chicken base)
        (chicken io)
        (chicken port)
        (chicken string)
        (scheme char)
        (scheme eval)
        (scheme file)
        (scheme read)
        (scheme write))

(define (read-from-string s)
  (with-input-from-string s read))

(include "test.scm")
                 
(define-syntax test
  (syntax-rules ()
    ((_ val expr) (test-equal expr val))
    ((_ name val expr) (test-equal name expr val))))

(test-begin "r7rs tests")

(test-group "2.1: Identifiers"
  (test "#!(no-)fold-case"
        '(FOO mooh qux blah foo BAR)
        (append
         (with-input-from-string
          "FOO #!fold-case mooh QUX blah #!no-fold-case foo BAR" read-list)))
  (test "#!(no-)fold-case only affects subsequent reads from the same port"
        '(FOO bar baz downcased UPCASED)
        (append
         (with-input-from-string "FOO #!fold-case bar BAZ" read-list)
         (with-input-from-string "downcased UPCASED" read-list))))

(test-group "4.1.7: Inclusion"
  (test-group "include"
    (test "multiple filenames"
          "abcabc"
          (with-output-to-string
           (lambda () (include "include.scm" "include.scm"))))
    (test-error "case sensitivity"
                (with-output-to-string
                 (lambda () (include "include-ci.scm")))))
  (test-group "include-ci"
    (test "multiple filenames"
          "abcabc"
          (with-output-to-string
           (lambda () (include-ci "include.scm" "include.scm"))))
    (test "case sensitivity"
          "abc"
          (with-output-to-string
           (lambda () (include-ci "include-ci.scm"))))))

(test-group "4.2.1: Conditionals"
  (test-group "cond-expand"
    (test "(scheme base)"
          'scheme-base
          (cond-expand
           ((library (scheme base)) 'scheme-base)
           (else #f)))
    (test "(chicken base)"
          'chicken-base
          (cond-expand
           ((library (chicken base)) 'chicken-base)
           (else #f)))
    (test "chicken.base"
          'chicken.base
          (cond-expand
           ((library chicken.base) 'chicken.base)
           (else #f)))
    (test "(bogus identifier)"
          #f
          (cond-expand
           ((library (bogus identifier)) 'bogus-identifier)
           (else #f)))))

(test-group "6.2.6: numerical operations"
  (test-group "floor/...truncate-remainder"
    (test '(2 1)      (receive (floor/ 5 2)))
    (test 2           (floor-quotient 5 2))
    (test 1           (floor-remainder 5 2))
    (test '(-3 1)     (receive (floor/ -5 2)))
    (test -3          (floor-quotient -5 2))
    (test 1           (floor-remainder -5 2))
    (test '(-3 -1)    (receive (floor/ 5 -2)))
    (test -3          (floor-quotient 5 -2))
    (test -1          (floor-remainder 5 -2))
    (test '(2 -1)     (receive (floor/ -5 -2)))
    (test 2           (floor-quotient -5 -2))
    (test -1          (floor-remainder -5 -2))
    (test '(2.0 -1.0) (receive (floor/ -5 -2.0)))
    ;; From the Guile manual
    (test 12          (floor-quotient 123 10))
    (test 3           (floor-remainder 123 10))
    (test '(12 3)     (receive (floor/ 123 10)))
    (test '(-13 -7)   (receive (floor/ 123 -10)))
    (test '(-13 7)    (receive (floor/ -123 10)))
    (test '(12 -3)    (receive (floor/ -123 -10)))
  
    (test '(2 1)      (receive (truncate/ 5 2)))
    (test 2           (truncate-quotient 5 2))
    (test 1           (truncate-remainder 5 2))
    (test '(-2 -1)    (receive (truncate/ -5 2)))
    (test -2          (truncate-quotient -5 2))
    (test -1          (truncate-remainder -5 2))
    (test '(-2 1)     (receive (truncate/ 5 -2)))
    (test -2          (truncate-quotient 5 -2))
    (test 1           (truncate-remainder 5 -2))
    (test '(2 -1)     (receive (truncate/ -5 -2)))
    (test 2           (truncate-quotient -5 -2))
    (test -1          (truncate-remainder -5 -2))
    (test '(2.0 -1.0) (receive (truncate/ -5.0 -2)))
    (test 2.0         (truncate-quotient -5.0 -2))
    (test -1.0        (truncate-remainder -5.0 -2))
    ;; From the Guile manual
    (test 12          (truncate-quotient 123 10))
    (test 3           (truncate-remainder 123 10))
    (test '(12 3)     (receive (truncate/ 123 10)))
    (test '(-12 3)    (receive (truncate/ 123 -10)))
    (test '(-12 -3)   (receive (truncate/ -123 10)))
    (test '(12 -3)    (receive (truncate/ -123 -10))))

  (test-group "quotient, remainder and modulo"
    (test 1 (modulo 13 4))
    (test 1 (remainder 13 4))
    (test 3 (modulo -13 4))
    (test -1 (remainder -13 4))
    (test -3 (modulo 13 -4))
    (test 1 (remainder 13 -4))
    (test -1 (modulo -13 -4))
    (test -1 (remainder -13 -4))
    (test -1.0 (remainder -13 -4.0)))

  (test-group "square"
    (test 1 (square 1))
    (test 16 (square 4))
    (test 16.0 (square 4.0))))

(test-group "6.3: booleans"
  ;; How silly...
  (test-group "not"
    (test #f (not #t))
    (test #f (not 3))
    (test #f (not (list 3)))
    (test #t (not #f))
    (test #f (not '()))
    (test #f (not (list)))
    (test #f (not 'nil))
    (test-error (not))
    (test-error (not 1 2)))
  
  (test-group "long boolean literals"
    (test #t (read-from-string "#t"))
    (test #f (read-from-string "#f"))
    (test #t (read-from-string "#true"))
    (test #f (read-from-string "#false"))
    (test-error (read-from-string "#faux")))

  (test-group "boolean=?"
    (test #t (boolean=? #t #t))
    (test #t (boolean=? #t #t #t #t))
    (test #t (boolean=? #f #f))
    (test #t (boolean=? #f #f #f #f))
    (test #f (boolean=? #f #t))
    (test #f (boolean=? #f #t #t #t))
    (test #f (boolean=? #f #f #t #t))
    (test #f (boolean=? #f #f #f #t))
    (test #f (boolean=? #t #f #f #f))
    (test #f (boolean=? #t #f #f #t))
    (test #f (boolean=? #t #t #f #t))
    (test #f (boolean=? #f #f #f #t))
    (test #f (boolean=? #f #t #f #f))
    (test-error (boolean=? #f))
    (test-error (boolean=? #f 1))
    (test-error "no shortcutting" (boolean=? #f #t 2))))

(test-group "6.4: pairs and lists"
  (test-group "pair?"
    (test #t (pair? '(a . b)))
    (test #t (pair? '(a b c)))
    (test #f (pair? '()))
    (test #f (pair? '#(a b)))
    (test #f (pair? #f))
    (test #f (pair? #t))
    (test #f (pair? "some string"))
    (test #f (pair? 123)))

  (test-group "cons"
    (test '(a) (cons 'a '()))
    (test '((a) b c d) (cons '(a) '(b c d)))
    (test '("a" b c) (cons "a" '(b c)))
    (test '(a . 3) (cons 'a 3))
    (test '((a b) . c) (cons '(a b) 'c)))

  (test-group "car"
    (test 'a (car '(a b c)))
    (test '(a) (car '((a) b c d)))
    (test 1 (car '(1 . 2)))
    (test-error (car '()))
    (test-error (car '#(1 2 3)))
    (test-error (car "not a pair")))

  (test-group "cdr"
    (test '(b c d) (cdr '((a) b c d)))
    (test 2 (cdr '(1 . 2)))
    (test-error (cdr '()))
    (test-error (cdr '#(1 2 3)))
    (test-error (cdr "not a pair")))

  (test-group "set-car!"
    (define (f) (list 'not-a-constant-list))
    (define (g) '(constant-list))
    ;; Examples from the text are very incomplete and strange
    (let ((res (f)))
      (set-car! res 2)
      (test 2 (car res))
      (set-car! (f) 3)
      (test 'not-a-constant-list (car (f))))
    ;; XXX Should this *raise* an error?  R5RS also says this it "is an error"
    #;(test-error (set-car! (g) 3))
    (test-error (set-car! 'x 'y)))

  (test-group "set-cdr!"
    (define (f) (list 'not-a-constant-list))
    (define (g) '(constant-list))
    ;; Examples from the text are very incomplete and strange
    (let ((res (f)))
      (set-cdr! res 2)
      (test 2 (cdr res))
      (set-cdr! (f) 3)
      (test '() (cdr (f))))
    ;; XXX Should this *raise* an error?  R5RS also says this it "is an error"
    #;(test-error (set-cdr! (g) 3))
    (test-error (set-cdr! 'x 'y)))

  (test-group "c..r (base)"
    (test 'x (caar '((x) y)))
    (test-error (caar '(x y)))
    (test 'y (cadr '((x) y)))
    (test-error (cadr '(x)))
    (test '() (cdar '((x) y)))
    (test-error (cdar '(x)))
    (test '() (cddr '((x) y)))
    (test-error (cddr '(x))))

  ;; TODO: c..r (cxr)
  
  (test-group "null?"
    (test #t (null? '()))
    (test #t (null? (list)))
    (test #f (null? '(a)))
    (test #f (null? 'a))
    (test #f (null? '#()))
    (test #f (null? "foo")))

  (test-group "list?"
    (test #t (list? '(a b c)))
    (test #t (list? (list 'a 'b 'c)))
    (test #t (list? '()))
    (test #f (list? '(a . b)))
    (let ((x (list 'a)))
      (set-cdr! x x)
      (test #f (list? x)))
    (test #f (list? 'a))
    (test #f (list? '#()))
    (test #f (list? "foo")))

  (test-group "make-list"
    (test-error (make-list))
    (test '() (make-list 0))
    (test '(#f) (make-list 1))          ; Unspecified
    
    (test '(#f) (make-list 1 #f))
    ;(test-error (make-list 1 2 3))
    (test '(3 3) (make-list 2 3))
    (test '() (make-list 0 3))
    (test-error (make-list -1 3))
    (test-error (make-list #f 3)))

  (test-group "list"
    (test '(a 7 c) (list 'a (+ 3 4) 'c))
    (test '() (list))
    (test '(#f) (list #f))
    (test '(a b c) (list 'a 'b 'c)))

  (test-group "length"
    (test 3 (length '(a b c)))
    (test 3 (length '(a (b) (c d e))))
    (test 0 (length '()))

    (test-error (length '(x . y)))
    (test-error (length '#(x y)))
    (test-error (length "foo")))

  (test-group "append"
    (test '(x y) (append '(x) '(y)))
    (test '(a b c d) (append '(a) '(b c d)))
    (test '(a (b) (c)) (append '(a (b)) '((c))))
    (test '(a b c . d) (append '(a b) '(c . d)))
    (test 'a (append '() 'a))
    (test '(a b . c) (append '(a b) 'c))
    (test-error (append 'x '()))
    (test-error (append '(x) 'y '())))

  (test-group "reverse"
    (test '(c b a) (reverse '(a b c)))
    (test '((e (f)) d (b c) a) (reverse '(a (b c) d (e (f)))))
    (test '() (reverse '()))
    (test-error (reverse '(a . b)))
    (test-error (reverse '(a b) '(c d)))
    (test-error (reverse 'a))
    (test-error (reverse '#(a b c)))
    (test-error (reverse "foo")))

  (test-group "list-tail"
    (test '(a b c d e f) (list-tail '(a b c d e f) 0))
    (test '(d e f) (list-tail '(a b c d e f) 3))
    (test '() (list-tail '(a b c d e f) 6))
    (test '() (list-tail '() 0))
    (test-error (list-tail '(a b c d e f) -1))
    (test-error (list-tail '(a b c d e f) 7))
    (test-error (list-tail '(a b c d e . f) 6)))

  (test-group "list-ref"
    (test 'a (list-ref '(a b c d) 0))
    (test 'b (list-ref '(a b c d) 1))
    (test 'c (list-ref '(a b c d) 2))
    (test 'd (list-ref '(a b c d) 3))
    (test-error (list-ref '(a b c d) 4))
    (test-error (list-ref '(a b c d) -1)))

  (test-group "list-set!"
    (let ((ls (list 'one 'two 'five!)))
      (list-set! ls 2 'three)
      (test '(two three) (cdr ls)))
    ;; Should be an error?
    #;(list-set! '(0 1 2) 1 "oops")
    (test-error (list-set! (list 1 2 3) 3 'foo)))

  (test-group "mem*"
    (test '(a b c) (memq 'a '(a b c)))
    (test '(b c) (memq 'b '(a b c)))
    (test #f (memq 'a '(b c d)))
    (test #f (memq (list 'a) '(b (a) c)))
    (test '((a) c) (member (list 'a) '(b (a) c)))
    (test '("b" "c") (member "B" '("a" "b" "c") string-ci=?))
    (test '(101 102) (memq 101 '(100 101 102))) ; unspecified in R7RS
    (test '(101 102) (memv 101 '(100 101 102))))

  (test-group "ass*"
    (define e '((a 1) (b 2) (c 3)))
    (test '(a 1) (assq 'a e))
    (test '(b 2) (assq 'b e))
    (test #f (assq 'd e))
    (test #f (assq (list 'a) '(((a)) ((b)) ((c)))))
    (test '((a)) (assoc (list 'a) '(((a)) ((b)) ((c)))))
    (test '(2 4) (assoc 2.0 '((1 1) (2 4) (3 9)) =))
    (test '(5 7) (assq 5 '((2 3) (5 7) (11 13)))) ; unspecified in R7RS
    (test '(5 7) (assv 5 '((2 3) (5 7) (11 13))))
    (test-error (assq 5 '(5 6 7)))
    (test-error (assv 5 '(5 6 7)))
    (test-error (assoc 5 '(5 6 7))))

  (test-group "list-copy"
   (define a '(1 8 2 8)) ; a may be immutable
   (define b (list-copy a))
   (set-car! b 3)        ; b is mutable
   (test '((3 8 2 8)) (list b))
   (test '((1 8 2 8)) (list a))))

(test-group "6.5: Symbols"
  (test-group "symbol=?"
    (test-error (symbol=?))
    (test-error (symbol=? 'a))
    (test-error (symbol=? 'a 1))
    (test-error (symbol=? 'a 'b 1))
    (test #t (symbol=? '|| '||))
    (test #t (symbol=? '|a b| '|a b|))
    (test #t (symbol=? 'a 'a))
    (test #f (symbol=? 'a 'b))
    (test #t (symbol=? 'a 'a 'a))
    (test #f (symbol=? 'a 'a 'b))
    (test #f (symbol=? 'a 'b 'b))
    (test #t (symbol=? 'a 'a 'a 'a))
    (test #f (symbol=? 'a 'a 'a 'b))
    (test #f (symbol=? 'a 'a 'b 'b))
    (test #f (symbol=? 'a 'b 'b 'b))))

(test-group "6.6: characters"
  (test-group "char*?"
    (test-error "arity" (char=? #\a))
    (test-error "type check" (char=? #\a #\a 1))
    (test-error "no shortcutting" (char=? #\a #\b 1))
    (test #f (char? 1))
    (test #t (char? #\a))
    (test #t (char=? #\a #\a))
    (test #f (char=? #\a #\b))
    (test #t (char=? #\a #\a #\a))
    (test #f (char=? #\a #\b #\a))
    (test #f (char=? #\a #\a #\b))
    (test #t (char=? #\a #\a #\a #\a))
    (test #f (char=? #\a #\b #\a #\a))
    (test #f (char=? #\a #\a #\a #\b))
    (test #t (char<? #\a #\b #\c))
    (test #f (char<? #\a #\b #\b))
    (test #t (char<=? #\a #\b #\b))
    (test #f (char<=? #\a #\b #\a))
    (test #t (char>? #\c #\b #\a))
    (test #f (char>? #\a #\a #\a))
    (test #t (char>=? #\b #\b #\a))
    (test #f (char>=? #\b #\a #\b))))

(test-group "6.7: strings"

  (test-group "string*?"
    (test-error "arity" (string=? "a"))
    (test-error "type check" (string=? "a" "a" 1))
    (test-error "no shortcutting" (string=? "a" "b" 1))
    (test #f (string? 1))
    (test #t (string? "a"))
    (test #t (string=? "a" "a"))
    (test #f (string=? "a" "b"))
    (test #t (string=? "a" "a" "a"))
    (test #f (string=? "a" "b" "a"))
    (test #f (string=? "a" "a" "b"))
    (test #t (string=? "a" "a" "a" "a"))
    (test #f (string=? "a" "b" "a" "a"))
    (test #f (string=? "a" "a" "a" "b"))
    (test #t (string<? "a" "b" "c"))
    (test #f (string<? "a" "b" "b"))
    (test #t (string<=? "a" "b" "b"))
    (test #f (string<=? "a" "b" "a"))
    (test #t (string>? "c" "b" "a"))
    (test #f (string>? "c" "b" "b"))
    (test #t (string>=? "b" "b" "a"))
    (test #f (string>=? "b" "a" "b")))

  (test-group "string->list"
    (test-error (string->list "" 1))
    (test-error (string->list "a" 1 2))
    (test '(#\a) (string->list "a"))
    (test '() (string->list "a" 1))
    (test '(#\b) (string->list "abc" 1 2))
    (test '() (string->list "abc" 2 2)))
  
  (test-group "string->vector"
    (test-error (string->vector "" 1))
    (test-error (string->vector "a" 0 2))
    (test #(#\a) (string->vector "a"))
    (test #() (string->vector "a" 1 1))
    (test #(#\b) (string->vector "abc" 1 2))
    (test #() (string->vector "abc" 2 2)))

  (test-group "string-copy!"
    (let ((r "abcdef"))
      (string-copy! r 2 r 0 3)
      (test "string-copy! r 2 r 0 3)" "ababcf" r)))

  (test-group "vector->string"
    (test-error (vector->string #() 1))
    (test-error (vector->string #(1)))
    (test-error (vector->string #(#\a) 0 2))
    (test "a" (vector->string #(#\a)))
    (test "" (vector->string #(#\a) 1 1))
    (test "b" (vector->string #(#\a #\b #\c) 1 2))
    (test "" (vector->string #(#\a #\b #\c) 2 2))))

(test-group "6.8: vectors"

  (test-group "vector-copy"
    (test-error (vector-copy ""))
    (test-error (vector-copy #() #()))
    (test-error (vector-copy #() 1))
    (test-error (vector-copy #(0) -1))
    (test-error (vector-copy #(0) 0 2))
    (test #() (vector-copy #()))
    (test #(0 1 2) (vector-copy #(0 1 2)))
    (test #(1 2) (vector-copy #(0 1 2) 1))
    (test #(1) (vector-copy #(0 1 2) 1 2))
    (test #() (vector-copy #(0 1 2) 1 1)))

  (test-group "vector-copy!"
    (test-error (vector-copy! ""))
    (test-error (vector-copy! #(0) 0 ""))
    (test-error (vector-copy! #() #() 0))
    (test-error (vector-copy! #() 0 #(0)))
    (test-error (vector-copy! #(0) 1 #(0)))
    (test-error (vector-copy! #(0) 1 #(0) 0))
    (test-error (vector-copy! #(0) 0 #(0) 0 2))
    (test-error (vector-copy! #(0) 0 #(0 1) 1 0))
    (test-assert (vector-copy! #() 0 #()))
    (let ((t #(0 1 2))
	  (f #(3 4 5 6))
          (r #(1 2 3 4 5)))
      (vector-copy! t 0 f 1 1)
      (test "(vector-copy! t 1 f 1 1)" #(0 1 2) t)
      (vector-copy! t 0 f 0 1)
      (test "(vector-copy! t 0 f 0 1)" #(3 1 2) t)
      (vector-copy! t 0 f 1 3)
      (test "(vector-copy! t 0 f 1 3)" #(4 5 2) t)
      (vector-copy! t 1 f 2)
      (test "(vector-copy! t 1 f 1)" #(4 5 6) t)
      (vector-copy! t 0 f 1)
      (test "(vector-copy! t 0 f)" #(4 5 6) t)
      (vector-copy! r 2 r 0 3)
      (test "(vector-copy! r 2 r 0 3)" #(1 2 1 2 3) r)))

  (test-group "vector-append"
    (test-error (vector-append ""))
    (test-error (vector-append #() 1))
    (test #() (vector-append))
    (test #(0) (vector-append #(0)))
    (test #() (vector-append #() #()))
    (test #(0 1) (vector-append #(0) #(1)))
    (test #(0 1 2 3 4 5) (vector-append #(0 1) #(2 3) #(4 5))))

  (test-group "vector->list"
    (test-error (vector->list ""))
    (test-error (vector->list #() 1))
    (test '() (vector->list #()))
    (test '(0 1 2) (vector->list #(0 1 2)))
    (test '(1 2) (vector->list #(0 1 2) 1))
    (test '(1) (vector->list #(0 1 2) 1 2))
    (test '() (vector->list #(0 1 2) 2 2))))

(test-group "6.9: bytevectors"

  (test-group "bytevector-copy"
    (test-error (bytevector-copy ""))
    (test-error (bytevector-copy #u8() #u8()))
    (test-error (bytevector-copy #u8() 1))
    (test-error (bytevector-copy #u8(0) -1))
    (test-error (bytevector-copy #u8(0) 0 2))
    (test #u8() (bytevector-copy #u8()))
    (test #u8(0 1 2) (bytevector-copy #u8(0 1 2)))
    (test #u8(1 2) (bytevector-copy #u8(0 1 2) 1))
    (test #u8(1) (bytevector-copy #u8(0 1 2) 1 2))
    (test #u8() (bytevector-copy #u8(0 1 2) 1 1)))

  (test-group "bytevector-copy!"
    (test-error (bytevector-copy! ""))
    (test-error (bytevector-copy! #u8(0) 0 ""))
    (test-error (bytevector-copy! #u8() #u8() 0))
    (test-error (bytevector-copy! #u8() 0 #u8(0)))
    (test-error (bytevector-copy! #u8(0) 1 #u8(0)))
    (test-error (bytevector-copy! #u8(0) 1 #u8(0) 0))
    (test-error (bytevector-copy! #u8(0) 0 #u8(0) 0 2))
    (test-error (bytevector-copy! #u8(0) 0 #u8(0 1) 1 0))
    (test-assert (bytevector-copy! #u8() 0 #u8()))
    (let ((t #u8(0 1 2))
	  (f #u8(3 4 5 6))
          (r #u8(1 2 3 4 5)))
      (bytevector-copy! t 0 f 1 1)
      (test "(bytevector-copy! t 1 f 1 1)" #u8(0 1 2) t)
      (bytevector-copy! t 0 f 0 1)
      (test "(bytevector-copy! t 0 f 0 1)" #u8(3 1 2) t)
      (bytevector-copy! t 0 f 1 3)
      (test "(bytevector-copy! t 0 f 1 3)" #u8(4 5 2) t)
      (bytevector-copy! t 1 f 2)
      (test "(bytevector-copy! t 1 f 1)" #u8(4 5 6) t)
      (bytevector-copy! t 0 f 1)
      (test "(bytevector-copy! t 0 f)" #u8(4 5 6) t)
      (bytevector-copy! r 2 r 0 3)
      (test "(bytevector-copy! r 2 r 0 3)" #u8(1 2 1 2 3) r)))

  (test-group "bytevector-append"
    (test-error (bytevector-append #u8() 1))
    (test #u8() (bytevector-append))
    (test #u8(0) (bytevector-append #u8(0)))
    (test #u8() (bytevector-append #u8() #u8()))
    (test #u8(0 1) (bytevector-append #u8(0) #u8(1)))
    (test #u8(0 1 2 3 4 5) (bytevector-append #u8(0 1) #u8(2 3) #u8(4 5))))

  (test-group "bytevector read syntax"
    (test (bytevector 1 2 3) (read-from-string "#u8(1 2 3)")))

  )

(test-group "6.10: Control features"

  (define (1st . a) (car a))
  (define (2nd . a) (cadr a))
  (define (acc proc f . rest) ; accumulate results of `f`
    (let ((a '()))
      (apply proc (lambda args (set! a (cons (apply f args) a))) rest)
      (reverse a)))

  (define char-add1
    (compose integer->char add1 char->integer))

  (test-group "string-map"
    (test-error (string-map "abc"))
    (test-error (string-map values))
    (test-error (string-map values '(1 2 3)))
    (test-error (string-map (constantly 1) "abc"))
    (test "" (string-map values ""))
    (test "abc" (string-map values "abc"))
    (test "aaa" (string-map (constantly #\a) "abc"))
    (test "bcd" (string-map char-add1 "abc"))
    (test "abc" (string-map 1st "abc" "123"))
    (test "123" (string-map 2nd "abc" "123"))
    (test "abc" (string-map 1st "abc" "123456"))
    (test "123" (string-map 2nd "abc" "123456")))

  (test-group "string-for-each"
    (test-error (string-for-each "abc"))
    (test-error (string-for-each values))
    (test-error (string-for-each values '(1 2 3)))
    (test '() (acc string-for-each values ""))
    (test '(#\a #\b #\c) (acc string-for-each values "abc"))
    (test '(#\b #\c #\d) (acc string-for-each char-add1 "abc"))
    (test '((#\a #\1) (#\b #\2) (#\c #\3)) (acc string-for-each list "abc" "123"))
    (test '(#\1 #\2 #\3) (acc string-for-each 2nd "abc" "123"))
    (test '(#\a #\b #\c) (acc string-for-each 1st "abc" "123456"))
    (test '(#\1 #\2 #\3) (acc string-for-each 2nd "abc" "123456")))

  (test-group "vector-map"
    (test-error (vector-map #(1 2 3)))
    (test-error (vector-map values))
    (test-error (vector-map values '(1 2 3)))
    (test #() (vector-map values #()))
    (test #(1 2 3) (vector-map values #(1 2 3)))
    (test #(1 1 1) (vector-map (constantly 1) #(1 2 3)))
    (test #(2 3 4) (vector-map add1 #(1 2 3)))
    (test #(1 2 3) (vector-map 1st #(1 2 3) #(4 5 6)))
    (test #(4 5 6) (vector-map 2nd #(1 2 3) #(4 5 6)))
    (test #(1 2 3) (vector-map 1st #(1 2 3) #(4 5 6 7 8 9)))
    (test #(4 5 6) (vector-map 2nd #(1 2 3) #(4 5 6 7 8 9))))

  (test-group "vector-for-each"
    (test-error (vector-for-each #(1 2 3)))
    (test-error (vector-for-each values))
    (test-error (vector-for-each values '(1 2 3)))
    (test '() (acc vector-for-each values #()))
    (test '(1 2 3) (acc vector-for-each values #(1 2 3)))
    (test '(2 3 4) (acc vector-for-each add1 #(1 2 3)))
    (test '((1 4) (2 5) (3 6)) (acc vector-for-each list #(1 2 3) #(4 5 6)))
    (test '(4 5 6) (acc vector-for-each 2nd #(1 2 3) #(4 5 6)))
    (test '(1 2 3) (acc vector-for-each 1st #(1 2 3) #(4 5 6 7 8 9)))
    (test '(4 5 6) (acc vector-for-each 2nd #(1 2 3) #(4 5 6 7 8 9)))))

(test-group "6.13: Input"
  (test-assert "read-string returns eof-object for empty string"
               (eof-object? (with-input-from-string "" (lambda () (read-string 1)))))
  (test-assert "read-bytevector returns eof-object for empty string"
               (eof-object? (with-input-from-string "" (lambda () (read-bytevector 1))))))

(define-syntax catch
  (syntax-rules ()
    ((_ . body) (handle-exceptions e e . body))))

(test-group "exceptions"
  (test "with-exception-handler (escape)"
        'exception
        (call-with-current-continuation
         (lambda (k)
           (with-exception-handler
            (lambda (e) (k 'exception))
            (lambda () (+ 1 (raise 'an-error)))))))
  (test-error "with-exception-handler (return)"
              (with-exception-handler
               (lambda (e) 'ignore)
               (lambda () (+ 1 (raise 'an-error)))))
  (test-error "with-exception-handler (raise)"
              (with-exception-handler
               (lambda (e) (raise 'another-error))
               (lambda () (+ 1 (raise 'an-error)))))
  (test "with-exception-handler (raise-continuable)"
        '("should be a number" 65)
        (let* ((exception-object #f)
               (return-value 
                (with-exception-handler
                 (lambda (e) (set! exception-object e) 42)
                 (lambda () (+ (raise-continuable "should be a number") 23)))))
          (list exception-object return-value)))
  (test "error-object? (#f)" #f (error-object? 'no))
  (test "error-object? (#t)" #t (error-object? (catch (car '()))))
  (test "error-object-message" "fubar" (error-object-message (catch (error "fubar"))))
  (test "error-object-irritants" '(42) (error-object-irritants (catch (error "fubar" 42))))
  (test "read-error? (#f)" #f (read-error? (catch (car '()))))
  (test "read-error? (#t)" #t (read-error? (catch (read-from-string ")"))))
  (test "file-error? (#f)" #f (file-error? (catch (car '()))))
  (test "file-error? (#t)" #t (file-error? (catch (open-input-file "foo"))))
  (test-error "guard (no match)"
              (guard (condition ((assq 'c condition))) (raise '((a . 42)))))
  (test "guard (match)"
        '(b . 23)
        (guard (condition ((assq 'b condition))) (raise '((b . 23)))))
  (test "guard (=>)"
        42
        (guard (condition ((assq 'a condition) => cdr)) (raise '((a . 42)))))
  (test "guard (multiple)"
        '(b . 23)
        (guard (condition
                ((assq 'a condition) => cdr)
                ((assq 'b condition)))
               (raise '((b . 23))))))

;; call-with-port is not supposed to close its port when leaving the
;; dynamic extent, only on normal return.
;;
;; XXX TODO: Rewrite in terms of SRFI-6 string port interface, so
;; no call-with-*-string, but use get-output-string and such!
;; Do this when it's clear how to re-export Chicken stuff.
(test-group "string ports"
  (receive (jump-back? jump!)
      (call/cc (lambda (k) (values #f k)))
    (when jump-back? (jump! (void)))
    (let ((string (call-with-output-string
                   (lambda (the-string-port)
                     (receive (one two three)
                         (call-with-port the-string-port
                          (lambda (p)
                            (display "foo" p)
                            ;; Leave the dynamic extent momentarily;
                            ;; jump! will immediately return with #t.
                            (call/cc (lambda (k) (jump! #t k)))
                            (test-assert "Port is still open after excursion"
                                         (output-port-open? the-string-port))
                            (display "bar" p)
                            (values 1 2 3)))
                       (test "call-with-port returns all values yielded by proc"
                             '(1 2 3)
                             (list one two three)))
                     (test-assert "call-with-port closes the port on normal return"
                                  (not (output-port-open? the-string-port)))
                     (test-assert "It's ok to close output ports that are closed"
                                  (close-port the-string-port))
                     (test-error "input-port-open? fails on output ports"
                                 (input-port-open? the-string-port))))))
      (test "call-with-port passes the port correctly and allows temporary escapes"
            "foobar" string)))

  (call-with-input-string "foo"
    (lambda (the-string-port)
      (test-error "output-port-open? fails on input ports"
                  (output-port-open? the-string-port))
      (test-assert "Initially, string port is open"
                   (input-port-open? the-string-port))
      (test "Reading from string delivers the data"
            'foo (read the-string-port))
      (test "After reading all, we get the eof-object"
            (eof-object) (read the-string-port))
      (test-assert "Port is still open after all reads"
                   (input-port-open? the-string-port))
      (close-port the-string-port)
      (test-assert "Port is no longer open after closing it"
                   (not (input-port-open? the-string-port)))
      (test-assert "It's ok to close input ports that are already closed"
                   (close-port the-string-port)))))

;; This is for later. We can't define it inside a group because that
;; would make it locally scoped (as a letrec rewrite), which breaks
;; the syntax-rules underscore tests.  Very subtle (and annoying), this!
(define (_) 'underscore-procedure)
(define ___ 'triple-underscore-literal)

(test-group "syntax-rules"
  (test "let-syntax w/ basic syntax-rules"
        100
        (let-syntax ((foo (syntax-rules ()
                            ((_ x form)
                             (let ((tmp x))
                               (if (number? tmp)
                                   form
                                   (error "not a number" tmp)))))))
          (foo 2 100)))
  (let-syntax ((foo (syntax-rules ()
                      ((_ #(a ...)) (list a ...)))))
    (test "Basic matching of vectors"
          '(1 2 3) (foo #(1 2 3))))
  ;; ellipsis pattern element wasn't matched - reported by Jim Ursetto (fixed rev. 13582)
  (let-syntax ((foo (syntax-rules ()
                      ((_ (a b) ...)
                       (list 'first '(a b) ...))
                      ((_ a ...)
                       (list 'second '(a) ...)))))
    (test "Basic ellipsis match"
          '(first (1 2) (3 4) (5 6)) (foo (1 2) (3 4) (5 6)))
    (test "Ellipsis match of length 1 does not match length 2"
          '(second (1)) (foo 1))
    (test "Ellipsis match of lists with mismatched lengths (used to fail)"
          '(second ((1 2)) ((3)) ((5 6))) (foo (1 2) (3) (5 6))))

  (test "letrec-syntax"
        34
        (letrec-syntax ((foo (syntax-rules () ((_ x) (bar x))))
                        (bar (syntax-rules () ((_ x) (+ x 1)))))
          (foo 33)))
  (test "Basic hygienic rename of syntactic keywords"
        'now
        (let-syntax ((when (syntax-rules ()
                             ((when test stmt1 stmt2 ...)
                              (if test
                                  (begin stmt1
                                         stmt2 ...))))))
          (let ((if #t))
            (when if (set! if 'now))
            if)))
  (test "Basic hygienic rename of shadowed outer let"
        'outer
        (let ((x 'outer))
          (let-syntax ((m (syntax-rules () ((m) x))))
            (let ((x 'inner))
              (m)))))
  (test "Simple recursive letrec expansion"
        7
        (letrec-syntax
            ((my-or (syntax-rules ()
                      ((my-or) #f)
                      ((my-or e) e)
                      ((my-or e1 e2 ...)
                       (let ((temp e1))
                         (if temp
                             temp
                             (my-or e2 ...)))))))
          (let ((x #f)
                (y 7)
                (temp 8)
                (let odd?)
                (if even?))
            (my-or x
                   (let temp)
                   (if y)
                   y))))
  ;; From Al* Petrofsky's "An Advanced Syntax-Rules Primer for the Mildly Insane"
  (let ((a 1))
    (letrec-syntax
        ((foo (syntax-rules ()
                ((_ b)
                 (bar a b))))
         (bar (syntax-rules ()
                ((_ c d)
                 (cons c (let ((c 3))
                           (list d c 'c)))))))
      (let ((a 2))
        (test "Al* Petrofsky torture test" '(1 2 3 a) (foo a)))))
  (let-syntax
      ((foo (syntax-rules ()
              ((_)
               '#(b)))))
    (test "Quoted symbols inside vectors are stripped of syntactic info"
          '#(b) (foo)))
  (let-syntax ((kw (syntax-rules (baz)
                     ((_ baz) "baz")
                     ((_ any) "no baz"))))
    (test "syntax-rules keywords match" "baz" (kw baz))
    (test "syntax-rules keywords no match" "no baz" (kw xxx))
    (let ((baz 100))
      (test "keyword loses meaning if shadowed" "no baz" (kw baz))))
  (test "keyword also loses meaning for builtins (from R7RS section 4.3.2)"
        'ok
        (let ((=> #f))
          (cond (#t => 'ok))))
  (test "Nested identifier shadowing works correctly"
        '(3 4)
        (let ((foo 3))
          (let-syntax ((bar (syntax-rules () ((_ x) (list foo x)))))
            (let ((foo 4))
              (bar foo)))))
  (let-syntax ((c (syntax-rules ()
                    ((_)
                     (let ((x 10))
                       (let-syntax ((z (syntax-rules ()
                                         ((_) (quote x)))))
                         (z))))))
               (c2 (syntax-rules ()
                     ((_)
                      (let ((x 10))
                        (let-syntax
                            ((z (syntax-rules ()
                                  ((_) (let-syntax
                                           ((w (syntax-rules ()
                                                 ((_) (quote x)))))
                                         (w))))))
                          (z)))))))
    ;; Reported by Matthew Flatt
    (test "strip-syntax cuts across three levels of syntax"
          "x" (symbol->string (c)))
    (test "strip-syntax cuts across four levels of syntax"
          "x" (symbol->string (c2))))
  (let-syntax ((foo (syntax-rules 
                        ___ () 
                        ((_ vals ___) (list '... vals ___)))))
    (test "Alternative ellipsis (from SRFI-46)"
          '(... 1 2 3) (foo 1 2 3)))
  (let-syntax ((let-alias (syntax-rules
                              ___ ()
                              ((_ new old code ___)
                               (let-syntax
                                   ((new
                                     (syntax-rules ()
                                       ((_ args ...) (old args ...)))))
                                 code ___)))))
    (let-alias inc (lambda (x) (+ 1 x))
               (test "Ellipsis rules are reset in new macro expansion phase"
                     3 (inc 2))))
  (let-syntax ((foo (syntax-rules ()
                      ((_ (a ... b) ... (c d))
                       (list (list (list a ...) ... b ...) c d))
                      ((_ #(a ... b) ... #(c d) #(e f))
                       (list (list (vector a ...) ... b ...) c d e f))
                      ((_ #(a ... b) ... #(c d))
                       (list (list (vector a ...) ... b ...) c d)))))
    (test-group "rest patterns after ellipsis (SRFI-46 smoke test)"
      (test '(() 1 2) (foo (1 2)))
      (test '(((1) 2) 3 4) (foo (1 2) (3 4)))
      (test '(((1 2) (4) 3 5) 6 7)
            (foo (1 2 3) (4 5) (6 7)))
      (test '(() 1 2)
            (foo #(1 2)))
      (test '((#() 1) 2 3)
            (foo #(1) #(2 3)))
      (test '((#(1 2) 3) 4 5)
            (foo #(1 2 3) #(4 5)))
      (test '((#(1 2) 3) 4 5 6 7)
            (foo #(1 2 3) #(4 5) #(6 7)))
      (test '(() 1 2 3 4)
            (foo #(1 2) #(3 4)))
      (test '((#(1) 2) 3 4 5 6)
            (foo #(1 2) #(3 4) #(5 6)))
      (test '((#(1 2) #(4) 3 5) 6 7 8 9)
            (foo #(1 2 3) #(4 5) #(6 7) #(8 9)))))
  (let-syntax ((foo (syntax-rules ()
                      ((_ #((a) ...)) (list a ...)))))
    (test "Bug discovered during implementation of rest patterns"
          '(1)
          (foo #((1)))))
  ;; R7RS: (<ellipsis> <template>) is like <template>, ignoring
  ;; occurrances of <ellipsis> inside the template.
  (let-syntax ((be-like-begin
                (syntax-rules ()
                  ((be-like-begin name)
                   (define-syntax name
                     (syntax-rules ()
                       ((name expr (... ...))
                        (begin expr (... ...)))))))))
    (be-like-begin sequence)
    (test "be-like-begin from R7RS 4.3.2 (nested ellipsis are not expanded)"
          4 (sequence 1 2 3 4)))
  (let-syntax ((ignore-underscores
                (syntax-rules ()
                  ((_ _ _ _) (_)))))
    (test "underscores are ignored in patterns"
          'underscore-procedure (ignore-underscores _ b c)))

  (test-group "undefined behaviours: mixing keywords, ellipsis and underscores"
    (test-group "underscore as keyword literal"
      (define-syntax match-literal-underscores ; for eval
        (syntax-rules (_)
          ((x a _ c) (_))
          ((x _ b c) 1)))
      (test-error "Missing literal underscore keyword causes syntax-error"
                  (eval '(match-literal-underscores d e f)))
      (test "Literal underscore matches"
            1 (match-literal-underscores _ h i))
      (test "Literal underscore matches even if it refers to toplevel binding"
            'underscore-procedure (match-literal-underscores g _ i)))
    
    (test-group "underscore as ellipsis"
     ;; It's undefined what this should do.  Logically, it should be
     ;; possible to bind _ as an ellipsis identifier.
     (define-syntax match-ellipsis-underscores ; for eval
       (syntax-rules _ () ((x a _ c) (list a _ c))))
     (test-error "No rule matching if prefix is omitted"
                 (eval '(match-ellipsis-underscores)))
     (test "Only prefix is supplied"
           '(1) (match-ellipsis-underscores 1))
     (test "Ellipsis does its work if multiple arguments given"
           '(1 2 3 4 5 6) (match-ellipsis-underscores 1 2 3 4 5 6)))

    (test-group "underscore as ellipsis mixed with underscore literal"
      ;; Even more undefined behaviour: mixing literals and ellipsis identifiers
      ;; Currently, ellipsis identifiers have precedence over the other two.
      (define-syntax match-ellipsis-and-literals-underscores ; for eval
        (syntax-rules _ (_) ((x a _ c) (list a _ c))))
      (test-error "No rule matching if prefix is omitted"
                  (eval '(match-ellipsis-and-literals-underscores)))
      (test '(1) (match-ellipsis-and-literals-underscores 1))
      (test '(1 2 3) (match-ellipsis-and-literals-underscores 1 2 3))
      (test '(1 2 3 4 5 6) (match-ellipsis-and-literals-underscores 1 2 3 4 5 6)))

    (test-group "\"custom\" ellipsis and literal of the same identifier"
      ;; This is similar to the above, but maybe a little simpler because
      ;; it does not use reserved names:
      (define-syntax match-ellipsis-literals
        (syntax-rules ___ (___)
                      ((_ x ___) (list x ___))))
      (test "Ellipsis as literals"
            '(1) (match-ellipsis-literals 1))
      (test "Ellipsis as literals multiple args"
            '(1 2) (match-ellipsis-literals 1 2))
      (test "Toplevel binding of the same name as ellipsis"
            '(1 triple-underscore-literal) (match-ellipsis-literals 1 ___))))

  (letrec-syntax ((usetmp
                   (syntax-rules ()
                     ((_ var) 
                      (list var))))
                  (withtmp
                   (syntax-rules ()
                     ((_ val exp)
                      (let ((tmp val))
                        (exp tmp))))))
    (test "Passing a macro as argument to macro"
          '(99)
          (withtmp 99 usetmp)))

  ;; renaming of keyword argument (#277)
  (let-syntax ((let-hello-proc
                (syntax-rules ()
                  ((_ procname code ...)
                   (let ((procname (lambda (#!key (who "world"))
                                     (string-append "hello, " who))))
                     code ...)))))
    (let-hello-proc bar
         ;; This is not R7RS, but R7RS should not interfere with other
         ;; CHICKEN features!
         (test "DSSSL keyword arguments aren't renamed (not R7RS)"
               "hello, XXX" (bar who: "XXX")))))

(test-group "define-record-type"
  (define-record-type foo (make-foo) foo?)
  (define foo1 (make-foo))
  (test-assert "Record instances satisfy their predicates" (foo? foo1))
  (define-record-type foo (make-foo) foo?)
  (test-assert "Record type definitions are generative" (not (foo? foo1))))

(test-group "open-input-bytevector"
  (test (bytevector 0 1 2 10 13 40 41 42 128 140 240 255)
        (let ((bv (bytevector 0 1 2 10 13 40 41 42 128 140 240 255)))
          (read-bytevector 12 (open-input-bytevector bv)))))

(test-group "open-output-bytevector"
  (test (bytevector 0 1 2 10 13 40 41 42 128 140 240 255)
        (let ((p (open-output-bytevector)))
          (write-bytevector (bytevector 0 1 2 10 13) p)
          (write-bytevector (bytevector 40 41 42 128) p)
          (write-bytevector (bytevector 140 240 255) p)
          (close-output-port p)
          (get-output-bytevector p))))

;; this was submitted as broken by Lukas Bröger:
(test-group "eval environments"
  (test 42 (eval '42 (scheme-report-environment 5))))

(test-end "r7rs tests")

(test-exit)
