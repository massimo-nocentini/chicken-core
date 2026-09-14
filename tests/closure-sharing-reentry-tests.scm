;;;; closure-sharing-reentry-tests.scm
;
; Closure reuse (-merge-reusable-closures, on from -O1 up) lets a lambda whose
; free variables are exactly those of its containing lambda read them through
; the container's closure object, which is complete when it is allocated and
; is never written afterwards.  The removed closure SHARING pass
; (-merge-shareable-closures, formerly on from -O2 up) let the contained
; lambda grow that set instead: every lambda in the chain wrote the variables
; of its activation that lived in the shared closure into the container's
; closure object on entry, and the contained continuation read them back from
; there when it ran.  That was sound only when the container's closure object
; was not entered again while a reader from an earlier entry could still run.
; A procedure's closure is allocated once (at toplevel for a global, at its
; binding for a local one) and entered by every call, so when such a procedure
; was chosen as a container and activated again while an earlier activation's
; continuation was still pending - by nested recursion, or by a continuation
; captured in the earlier activation and re-entered later - the earlier
; continuation saw the later activation's parameters.
;
; A global procedure could become a container only with -local (so at -O3);
; a local procedure with a free variable (not contractable) already at -O2.
; Every case must print the expected value; the program exits 1 otherwise.

(import (chicken base) (chicken process-context))

(define failures 0)

(define (check what got expected)
  (unless (equal? got expected)
    (set! failures (+ failures 1))
    (print "FAIL " what ": got " got ", expected " expected)))

;;; 1. Global procedure with one call site (in g) and one contained lambda
;;;    (the continuation of (capture n)).  The continuation captured in the
;;;    activation with n = 2 is re-entered after the nested activation with
;;;    n = 1 has run.

(declare (not inline f capture))

(define saved #f)
(define (capture n)
  (call-with-current-continuation
    (lambda (k) (when (= n 2) (set! saved k)) 0)))
(define (f n) (let ((r (capture n))) (list n r)))
(define (g n) (if (= n 0) '() (cons (f n) (g (- n 1)))))

(define entries 0)
(define res (g 2))
(set! entries (+ entries 1))
(cond ((= entries 1)
       (check "global, first pass" res '((2 0) (1 0)))
       (saved 7))
      (else
       (check "global, re-entered with 7" res '((2 7) (1 0)))))

;;; 2. Local procedure with a free variable (so neither contracted nor
;;;    inlined), one call site in a sibling loop, one contained lambda.

(define saved2 #f)
(define (capture2 n)
  (call-with-current-continuation
    (lambda (k) (when (= n 2) (set! saved2 k)) 0)))

(define (h m)
  (let ((f2 (lambda (n) (let ((r (capture2 n))) (list n r m)))))
    (let loop ((n 2))
      (if (= n 0) '() (cons (f2 n) (loop (- n 1)))))))

(define entries2 0)
(define res2 (h 'm))
(set! entries2 (+ entries2 1))
(cond ((= entries2 1)
       (check "local, first pass" res2 '((2 0 m) (1 0 m)))
       (saved2 8))
      (else
       (check "local, re-entered with 8" res2 '((2 8 m) (1 0 m)))))

;;; 3. Backtracking search through two mutually recursive globals: p-term is
;;;    referenced once, contains one lambda (the continuation of amb) and is
;;;    re-entered through p-expr while an earlier activation's continuation
;;;    is still on the stack.  Every parse must be produced exactly once.

(define stack '())
(define (amb)
  (call-with-current-continuation
    (lambda (k) (set! stack (cons (lambda () (k #t)) stack)) #f)))
(define (p-expr cs) (let ((t (p-term cs))) (amb) t))
(define (p-term cs) (if (amb) cs (if (pair? cs) (p-expr (cdr cs)) '())))

(define parses '())
(set! parses (cons (p-expr '(1)) parses))
(if (pair? stack)
    (let ((next (car stack)))
      (set! stack (cdr stack))
      (next))
    (begin
      (check "backtracking parser, parses" (reverse parses)
             '(() () () () () () () () (1) (1)))))

(if (> failures 0)
    (begin (print failures " failure(s)") (exit 1))
    (print "closure-sharing re-entry tests passed"))
