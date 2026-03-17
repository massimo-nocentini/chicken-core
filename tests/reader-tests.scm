;;;; reader-tests.scm

(import (only chicken.io read-line read-string)
        (only chicken.port with-input-from-string with-output-to-string)
        chicken.read-syntax)

(set-sharp-read-syntax! #\& (lambda (p) (read p) (values)))
(set-sharp-read-syntax! #\^ (lambda (p) (read p)))
(set-read-syntax! #\! (lambda (p) (read-line p) (values)))

(define output
  (with-output-to-string
    (lambda ()
      (print "hi") ! this is fortran
      (print "foo") #&(print "amp-comment") (print "baz")
      #^(print "bye"))))

!! output:
!! hi
!! foo
!! baz
!! bye

(assert (string=? output "hi\nfoo\nbaz\nbye\n"))
(assert (string=? "   ." (with-input-from-string "\x20;\u0020\U00000020\056" read-string)))

(set-read-syntax! #\! #f)
(assert (equal? '! (with-input-from-string "! " read)))

;; unicode

(set-read-syntax! #\⋄ (lambda (p) (vector (read p))))

(assert (equal? '#(99) (with-input-from-string "  ⋄99" read)))

;; parameterized read-syntax

(set-parameterized-read-syntax! #\& 
  (lambda (p n) 
    (let ((x (read p)))
      (let loop ((n n))
        (if (zero? n) '()
            (cons x (loop (- n 1))))))))

(assert (equal? '(4 4 4) (with-input-from-string "#3&4" read)))
