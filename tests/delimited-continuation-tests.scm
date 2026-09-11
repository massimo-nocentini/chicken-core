;;;; delimited-continuation-tests.scm - `shift' and `reset'
;
; Every expected value here is derived from Danvy and Filinski's rules
;
;   x             = (lambda (c) (c x))
;   (lambda (x) E)= (lambda (c) (c (lambda (x) E)))
;   (E1 E2)       = (lambda (c) (E1 (lambda (f) (E2 (lambda (x) ((f x) c))))))
;   (reset E)     = (lambda (c) (c (E (lambda (v) v))))
;   (shift f E)   = (lambda (c)
;                     (let ((f (lambda (x) (lambda (c2) (c2 (c x))))))
;                       (E (lambda (v) v))))
;
; The same file is run interpreted and compiled.  Interpreted, every
; `shift'/`reset' goes through the library procedures in library.scm;
; compiled, `perform-cps-conversion' recognises the form and emits the
; rules directly (see `walk-shift'/`walk-reset' in core.scm).  The two
; paths must agree on all of it.

(import (chicken continuation)
	(chicken condition)
	(chicken format))

(define failures 0)

(define (chk name got want)
  (cond ((equal? got want)
	 (printf "~a => ~s~%" name got))
	(else
	 (set! failures (add1 failures))
	 (printf "~a => ~s  *** EXPECTED ~s~%" name got want))))

;; An effect log, used instead of a string port: `with-output-to-port'
;; is itself built on `dynamic-wind', which would make the evaluation
;; order tests below test two things at once.
(define trace '())
(define (em x) (set! trace (cons x trace)) x)
(define (out thunk)
  (set! trace '())
  (let ((v (thunk))) (cons (reverse trace) v)))
(define (outs thunk)
  (set! trace '())
  (thunk)
  (reverse trace))


;;; A. The three classics

(chk "A1 (+ 1 (reset (+ 2 (shift f (f (f 3))))))"
     (+ 1 (reset (+ 2 (shift f (f (f 3)))))) 8)
(chk "A2 (reset (+ 1 (shift f 10)))"
     (reset (+ 1 (shift f 10))) 10)
(chk "A3 (reset (* 2 (shift f (f (f 1)))))"
     (reset (* 2 (shift f (f (f 1))))) 4)


;;; B. Generators

(define (yield x) (shift k (cons x (k #f))))
(chk "B1 begin-yield"
     (reset (begin (yield 1) (yield 2) (yield 3) '())) '(1 2 3))

(define (yield* x) (shift k (cons x (k 'ig))))
(chk "B2 list-yield"
     (reset (list (yield* 1) (yield* 2))) '(1 2 ig ig))


;;; C. Non-deterministic choice

(define (choose lst)
  (shift k (apply append (map (lambda (x) (k x)) lst))))

(chk "C1 amb let*"
     (reset (let* ((a (choose '(1 2))) (b (choose '(10 20)))) (list (+ a b))))
     '(11 21 12 22))
(chk "C2 amb argument position"
     (reset (list (+ (choose '(1 2)) (choose '(10 20))))) '(11 21 12 22))
(chk "C3 amb with filter"
     (reset (let ((a (choose '(1 2 3)))) (if (even? a) (list a) '()))) '(2))
(chk "C4 fmap"
     (reset (list (* (choose '(1 2 3)) 10))) '(10 20 30))


;;; D. A state monad

(define (get) (shift k (lambda (s) ((k s) s))))
(define (put s) (shift k (lambda (ignored) ((k 'unit) s))))
(define (run-state th s0)
  ((reset (let ((v (th))) (lambda (s) (cons v s)))) s0))

(chk "D1 state"
     (run-state (lambda ()
		  (let* ((a (get)) (x (put (+ a 1))) (b (get)))
		    (* a b)))
		10)
     '(110 . 11))


;;; E. Nested delimiters

(chk "E1 inner shift, inner reset"
     (reset (+ 1 (reset (+ 2 (shift f (f 10)))))) 13)
(chk "E2 abort to inner delimiter only"
     (+ 100 (reset (+ 1 (reset (+ 2 (shift f 0)))))) 101)
(chk "E3 resume under a new delimiter"
     (reset (+ 1 (shift f (+ 100 (reset (+ 2 (f 3))))))) 106)


;;; F. The delimiter is dynamic, not lexical

(define (p x) (shift f (list 'shifted x (f (* x 2)))))
(chk "F1 delimiter is the caller's" (reset (+ 1 (p 5))) '(shifted 5 11))
(chk "F2 same shift, other context" (reset (* 3 (p 5))) '(shifted 5 30))

(define thunk1 (reset (lambda () (shift f (f (f 1))))))
(chk "F3 lexically enclosing reset is already gone"
     (reset (+ 2 (thunk1))) 5)

(define saved #f)
(chk "F4 capture a segment"    (reset (+ 1 (shift f (set! saved f) 'r0))) 'r0)
(chk "F5 use it out of extent" (saved 5) 6)
(chk "F6 inside an expression" (+ 100 (saved 5)) 106)
(chk "F7 under a new reset"    (reset (* 2 (saved 5))) 12)
(chk "F8 twice"                (+ (saved 1) (saved 10)) 13)

(define saved2 #f)
(chk "F9 capture"
     (reset (begin (shift f (set! saved2 f) 'r0) (shift g 'inner) 'never)) 'r0)
(chk "F10 a shift inside the resumed segment" (saved2 'x) 'inner)


;;; G. Abandoning the continuation

(chk "G1 abort" (reset (+ 1 (* 2 (shift f 'aborted)))) 'aborted)
(chk "G2 effects before the abort"
     (out (lambda () (reset (begin (em 'A) (shift f (em 'B) 'v) (em 'C) 'w))))
     '((A B) . v))


;;; H. Zero, one and many resumptions

(define (t n)
  (reset (+ 1 (shift f (case n ((0) 100) ((1) (f 10)) ((2) (f (f 10))))))))
(chk "H0 never resumed" (t 0) 100)
(chk "H1 resumed once"  (t 1) 11)
(chk "H2 composed"      (t 2) 12)
(chk "H3 two-shot"      (reset (list (shift f (append (f 1) (f 2))))) '(1 2))
(chk "H4 zero-shot"     (reset (list (shift f '()))) '())
(chk "H5 effects repeat with the segment"
     (out (lambda () (reset (begin (shift f (f 0) (f 0) 'done) (em 'y) 'z))))
     '((y y) . done))


;;; I. Every syntactic position

(chk "I1 tail"            (reset (shift f 42)) 42)
(chk "I2 tail, resumed"   (reset (shift f (f 42))) 42)
(chk "I3 tail, twice"     (reset (shift f (list (f 1) (f 2)))) '(1 2))
(define (g x) (shift f (f (f x))))
(chk "I4 tail of a call"  (reset (+ 1 (g 5))) 7)
(chk "I5 argument"        (reset (list 'a (shift f (f (f 'b))) 'c)) '(a (a b c) c))
(chk "I6 left argument"   (reset (- 10 (shift f (f 3)))) 7)
(chk "I7 right argument"  (reset (- (shift f (f 3)) 10)) -7)
(chk "I8 two in one call" (reset (list (shift f (f 1)) (shift g2 (g2 2)))) '(1 2))
(chk "I9 let body"        (reset (let ((x 10)) (+ x (shift f (f (f 1)))))) 21)
(chk "I10 let init"       (reset (let ((x (shift f (f (f 1))))) (* x 2))) 4)
(define yes (car '(#t)))			; not a constant, so the branch stays
(chk "I11 if branch"      (reset (+ 1 (if yes (shift f (f (f 0))) 99))) 2)
(chk "I12 if test"        (reset (if (shift f (list (f #t) (f #f))) 'yes 'no))
     '(yes no))


;;; J. Evaluation order

(chk "J1"
     (out (lambda () (reset (begin (em 1) (shift f (em 2) (f 'v)) (em 3) 'end))))
     '((1 2 3) . end))
(chk "J2"
     (out (lambda ()
	    (reset (begin (em 1)
			  (shift f (em 2) (f 'v) (em 3) (f 'w) (em 4) 'end)
			  (em 5)
			  'z))))
     '((1 2 5 3 5 4) . end))
(chk "J3"
     (out (lambda ()
	    (reset (let* ((a (em 1))
			  (b (shift f (em 'S) (f (em 2))))
			  (c (em 3)))
		     (list a b c)))))
     '((1 S 2 3) . (1 2 3)))
(chk "J4"
     (out (lambda ()
	    (reset (begin (em 'A)
			  (reset (begin (em 'B)
					(shift f (em 'C) (f 0) (em 'D) 1)
					(em 'E)
					2))
			  (em 'F)
			  3))))
     '((A B C E D F) . 3))
(define saved3 #f)
(chk "J5 the tail of the segment runs on resumption"
     (outs (lambda ()
	     (em (reset (begin (em 'in)
			       (shift f (set! saved3 f) 'r0)
			       (em 'tail)
			       'r1)))
	     (em (saved3 'x))))
     '(in r0 tail r1))


;;; K. dynamic-wind
;
; Leaving a delimited segment runs the `after' thunks between the `shift'
; and its delimiter; resuming one runs the corresponding `before' thunks
; again.  So a segment that is resumed twice is wound twice.

(define (dw thunk)
  (dynamic-wind (lambda () (em 'in)) thunk (lambda () (em 'out))))

(chk "K1 escape runs `after'"
     (out (lambda () (reset (dw (lambda () (shift f 'escaped))))))
     '((in out) . escaped))
(chk "K2 no shift at all"
     (out (lambda () (reset (dw (lambda () 'plain))))) '((in out) . plain))
(chk "K3 resumed twice, wound twice"
     (out (lambda () (reset (dw (lambda () (+ 1 (shift f (f (f 1)))))))))
     '((in out in out in out) . 3))
(chk "K4 resumed once"
     (out (lambda () (reset (dw (lambda () (+ 1 (shift f (f 1))))))))
     '((in out in out) . 2))
(chk "K5 the delimiter is outside the wind"
     (out (lambda () (dw (lambda () (reset (+ 1 (shift f (f (f 1)))))))))
     '((in out) . 3))
(chk "K6 winds are balanced afterwards"
     (begin (reset (dw (lambda () (shift f 'x)))) 'balanced) 'balanced)

;; A delimited continuation carries the winds BETWEEN the shift and its
;; delimiter, and nothing else: neither the winds outside the reset nor the
;; winds of wherever it is later resumed.

(define kk #f)
(define (dwc thunk)
  (dynamic-wind (lambda () (em 'c-in)) thunk (lambda () (em 'c-out))))
(define (dwb thunk)
  (dynamic-wind (lambda () (em 'b-in)) thunk (lambda () (em 'b-out))))

(dwc (lambda () (reset (begin (shift k (set! kk k) 0) (em 'seg) 'v))))
(chk "K7 a wind outside the reset is not part of the segment"
     (outs (lambda () (kk 'x))) '(seg))

(define kk2 #f)
(reset (dw (lambda () (shift k (set! kk2 k) 0) (em 'seg) 'v)))
(chk "K8 resuming does not disturb the winds at the resume site"
     (outs (lambda () (dwb (lambda () (kk2 'x)))))
     '(b-in in seg out b-out))
(chk "K9 and the resume site's winds are left balanced"
     (let ((before ##sys#dynamic-winds))		; not '(): csi loads inside one
       (dwb (lambda () (kk2 'x)))
       (eq? ##sys#dynamic-winds before))
     #t)


;;; L. Errors and non-local exit

(define (caught thunk)
  (handle-exceptions e 'caught (thunk)))

(chk "L1 shift with no enclosing reset is an error"
     (caught (lambda () (+ 1 (shift f 99)))) 'caught)
(chk "L2 and the metacontinuation is still balanced afterwards"
     (caught (lambda () (+ 1 (shift f 99)))) 'caught)
(chk "L3 a reset still works after that"
     (reset (+ 1 (shift f (f 1)))) 2)
(chk "L4 an error thrown out of a reset body"
     (caught (lambda () (reset (+ 1 (error "boom"))))) 'caught)
(chk "L5 ... leaves no stale delimiter behind"
     (caught (lambda () (+ 1 (shift f 99)))) 'caught)
(chk "L6 an error thrown out of a shift body"
     (caught (lambda () (reset (+ 1 (shift f (error "boom")))))) 'caught)
(chk "L7 ... also leaves none"
     (caught (lambda () (+ 1 (shift f 99)))) 'caught)
(chk "L8 call/cc escape out of a reset"
     (call-with-current-continuation
      (lambda (k) (reset (+ 1 (shift f (k 'escaped)))))) 'escaped)
(chk "L9 ... leaves no stale delimiter behind"
     (caught (lambda () (+ 1 (shift f 99)))) 'caught)
(chk "L10 a reset still works after all that"
     (reset (+ 1 (shift f (f (f 1))))) 3)


;;; M. Interaction with the other continuation operators

(chk "M1 call/cc used entirely inside a reset"
     (reset (+ 1 (call-with-current-continuation (lambda (k) (k 1))))) 2)
(chk "M2 call/cc and shift together"
     (reset (+ 1 (call-with-current-continuation
		  (lambda (k) (shift f (f (k 1))))))) 2)
(chk "M3 continuation-return escaping a reset body"
     (continuation-capture
      (lambda (k) (reset (+ 1 (shift f (continuation-return k 'escaped))))))
     'escaped)
(chk "M4 ... leaves no stale delimiter behind"
     (caught (lambda () (+ 1 (shift f 99)))) 'caught)
(chk "M5 continuation-graft escaping a reset body"
     (continuation-capture
      (lambda (k)
	(reset (+ 1 (shift f (continuation-graft k (lambda () 'grafted)))))))
     'grafted)
(chk "M6 ... also leaves none"
     (caught (lambda () (+ 1 (shift f 99)))) 'caught)


;;; N. Multiple values are truncated at a delimiter
;
; Inherent to the rules: the metacontinuation of `(E (lambda (v) v))'
; takes exactly one value.  Locked in here so that it cannot change by
; accident.

(chk "N1 values through a reset"
     (call-with-values (lambda () (reset (values 1 2))) list) '(1))


;;; O. The two implementations, mixed in one program
;
; The compiler only recognises a literal lambda, so these calls fall through
; to the library procedures even when compiled.  Mixing them with the
; directly-compiled form must compose, because both push the same kind of
; frame onto the same ##sys#dc-stack.

(define (indirect-shift proc) ((let ((s ##sys#shift)) s) proc))
(define (indirect-reset thunk) ((let ((r ##sys#reset)) r) thunk))

(chk "O1 fallback shift under a direct reset"
     (reset (+ 2 (indirect-shift (lambda (f) (f (f 3)))))) 7)
(chk "O2 direct shift under a fallback reset"
     (indirect-reset (lambda () (+ 2 (shift f (f (f 3)))))) 7)
(chk "O3 both indirect"
     (indirect-reset (lambda () (+ 2 (indirect-shift (lambda (f) (f (f 3))))))) 7)
(chk "O4 alternating, three deep"
     (reset (+ 1 (indirect-reset
		  (lambda ()
		    (+ 2 (shift f (+ 10 (indirect-shift (lambda (g) (g (f 3)))))))))))
     16)
(chk "O5 a fallback-captured segment resumed under a direct delimiter"
     (let ((k #f))
       (indirect-reset (lambda () (+ 1 (indirect-shift (lambda (f) (set! k f) 'r)))))
       (reset (* 2 (k 5))))
     12)


;;; P. Many resumptions, with garbage collection in between

(define (yield-n n)
  (let loop ((i 0))
    (if (< i n)
	(begin (shift k (cons i (k #f))) (loop (+ i 1)))
	'())))

(chk "P1 10000 yields"
     (let ((l (reset (yield-n 10000))))
       (list (length l) (car l) (car (list-tail l 9999))))
     '(10000 0 9999))

(define resumable #f)
(reset (+ 1 (shift f (set! resumable f) 'ignored)))
(chk "P2 the same segment resumed 100000 times"
     (let loop ((i 0) (acc 0))
       (if (= i 100000) acc (loop (+ i 1) (+ acc (resumable 1)))))
     200000)


(newline)
(printf "~a failure(s)~%" failures)
(when (positive? failures)
  (error "delimited continuation tests failed" failures))
