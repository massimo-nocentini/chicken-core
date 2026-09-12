;;;; delimcc-retention.scm - what a captured delimited continuation keeps alive
;
; A segment captured by `shift' must retain the segment - the continuation
; closures between the `shift' and its delimiter, and the dynamic-wind
; frames between them - and nothing of the delimiter's own continuation.
; Until 2d10f241 it retained all of it: the reset body's abort continuation
; was given the reset's reified continuation as the (never invoked)
; continuation argument of ##sys#dc-abort, so every segment captured
; inside the body kept the delimiter's outer continuation alive - the
; "dead meta-continuation" of Gasbichler and Sperber.  Measured then:
; 16,000,168 bytes per held segment and 56 bytes per nesting level;
; now: 64 bytes and none.
;
; COMPILED ONLY.  Interpreted, csi keeps the previous toplevel form's data
; alive for one more form, which makes single-drop measurements read tens
; of MB high with no `reset' involved at all.  The two paths are covered
; anyway: the direct one, and library.scm's fallback procedures reached
; through variables, which the compiler's pattern match cannot see.

(import (chicken continuation)
	(chicken gc)
	(chicken fixnum)
	(chicken format))

(define failures 0)

(define (chk key got ok?)
  (printf "~a = ~a~a~%" key got (if (ok? got) "" "  *** FAILED"))
  (unless (ok? got) (set! failures (add1 failures))))

(define (small? n) (< n 65536))		; 64 KB: 250x below the leak
(define (is v) (lambda (x) (equal? x v)))

;; Three major collections, then bytes in use.
(define (used) (gc #t) (gc #t) (gc #t) (vector-ref (memory-statistics) 1))

(define BIG 2000000)				; 16 MB of slots

(define fb-reset #f)				; library.scm's fallbacks, reached
(define fb-shift #f)				;  so that dc-match cannot fire
(set! fb-reset ##sys#reset)
(set! fb-shift ##sys#shift)

;;; The shape under test: a reset whose OUTER continuation uses a large
;;; vector, a shift inside that saves its continuation.  The vector is
;;; reachable from nothing but that outer continuation once RUN returns.

(define saved #f)
(define big #f)

(define (capture-direct big)
  (let ((r (reset (+ 1 (shift k (set! saved k) 0)))))
    (fx+ r (vector-length big))))

(define (nocapture-direct big)
  (let ((r (reset (+ 1 (shift k 0)))))
    (fx+ r (vector-length big))))

(define (capture-fallback big)
  (let ((r (fb-reset (lambda () (+ 1 (fb-shift (lambda (k) (set! saved k) 0)))))))
    (fx+ r (vector-length big))))

(define (nocapture-fallback big)
  (let ((r (fb-reset (lambda () (+ 1 (fb-shift (lambda (k) 0)))))))
    (fx+ r (vector-length big))))

(define (run f)
  (set! big (make-vector BIG 0))
  (let ((v (f big)))
    (set! big #f)
    v))

(define (retention name capture nocapture)
  (set! saved #f)
  (let ((v0 (run nocapture)))
    (used)
    (let* ((base (used))
	   (v1 (run capture))
	   (held (begin (used) (used))))
      (chk (string-append name ".values") (list v0 v1) (is (list BIG BIG)))
      (chk (string-append name ".retained_held") (- held base) small?)
      (chk (string-append name ".resume") (saved 41) (is 42))
      (chk (string-append name ".resume_again") (saved 1) (is 2))
      (set! saved #f)
      (used)
      (chk (string-append name ".retained_dropped") (- (used) base) small?))))

(retention "direct" capture-direct nocapture-direct)
(retention "fallback" capture-fallback nocapture-fallback)

;;; Nested delimiters: N resets deep, capture at the innermost.  What is
;;; retained must not grow with N.

(define (nest n)
  (if (fx= n 0)
      (reset (+ 1 (shift k (set! saved k) 0)))
      (reset (fx+ 1 (nest (fx- n 1))))))

(define (nested n)
  (set! saved #f)
  (used)
  (let* ((v (nest n))
	 (live (used))
	 (rv (saved 1)))
    (set! saved #f)
    (chk (sprintf "nest.~a.values" n) (list v rv) (is (list n 2)))
    live))

(let* ((live0 (nested 0))
       (live1 (nested 10000)))
  (chk "nest.retained_10000_over_0" (- live1 live0) small?))

(newline)
(printf "~a failure(s)~%" failures)
(when (positive? failures)
  (error "delimited continuation retention tests failed" failures))
