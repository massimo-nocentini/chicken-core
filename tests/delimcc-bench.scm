;;;; delimcc-bench.scm - cost of `shift'/`reset', as `KEY = VALUE UNIT' lines
;
; Compiled -O3 or better.  Every line has a fixed key, so a before/after is
; one `diff' of two runs.  Medians of RUNS in-process repetitions; every
; loop checks its result.  Reference numbers, this file at 2d10f241 on a
; clang -Os build: pair 148 ns, reset_only 43, abort 76, resume_twice 226,
; fallback_pair 200; coroutine switch 238 ns via shift/reset, 175 via
; call/cc; a major GC with 8000 held segments 0.55 ms (was 155.6 before the
; retention fix of 2d10f241).

(import (chicken continuation)
	(chicken foreign)
	(chicken gc)
	(chicken time)
	(chicken fixnum)
	(chicken sort))

(foreign-declare "#include <time.h>")

(define now-ns
  (foreign-lambda* double ()
    "struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);"
    "C_return((double)ts.tv_sec * 1e9 + (double)ts.tv_nsec);"))

(define RUNS 5)
(define (median xs) (list-ref (sort xs <) (quotient (length xs) 2)))
(define (r2 x) (/ (round (* 100 (exact->inexact x))) 100))
(define ok #t)
(define (check! b) (unless b (set! ok #f)))

;; library.scm's fallbacks, reached so that the compiler cannot match them
(define fb-reset #f)
(define fb-shift #f)
(set! fb-reset ##sys#reset)
(set! fb-shift ##sys#shift)


;;; 1. ns per operation

(define N 2000000)

(define-syntax defloop
  (syntax-rules ()
    ((_ name expr)
     (define (name n)
       (let loop ((i 0) (acc 0))
	 (if (fx= i n) acc (loop (fx+ i 1) (fx+ acc expr))))))))

(defloop pair-loop     (reset (fx+ 1 (shift f (f 1)))))
(defloop reset-loop    (reset (fx+ 1 1)))
(defloop abort-loop    (reset (fx+ 1 (shift f 7))))
(defloop twice-loop    (reset (fx+ 1 (shift k (fx+ (k 1) (k 1))))))
(defloop fallback-loop (fb-reset (lambda () (fx+ 1 (fb-shift (lambda (f) (f 1)))))))
(defloop empty-loop    2)

(define (time-once f expect)
  (gc #t)
  (let* ((t0 (now-ns)) (v (f N)) (t1 (now-ns)))
    (check! (eqv? v (fx* expect N)))
    (/ (- t1 t0) N)))

(define (bench key f expect)
  (let loop ((i 0) (acc '()))
    (if (fx= i RUNS)
	(print "bench." key " = " (r2 (median acc)) " ns")
	(loop (fx+ i 1) (cons (time-once f expect) acc)))))

(bench "pair"          pair-loop     2)
(bench "reset_only"    reset-loop    2)
(bench "abort"         abort-loop    7)
(bench "resume_twice"  twice-loop    4)
(bench "fallback_pair" fallback-loop 2)
(bench "empty_loop"    empty-loop    2)


;;; 2. Coroutines: 100 of them, each computing fib(20), round-robin,
;;; switching on every call - via shift/reset and via call/cc.

(define NTHREADS 100)
(define CALLS 21891)				; calls made by fib(20)
(define SWITCHES (fx* NTHREADS CALLS))

(define (coro-dc nthreads k-every)
  (let ((head '()) (tail '()) (counter 0) (total 0))
    (define (enq! x)
      (let ((cell (cons x '())))
	(if (null? head)
	    (begin (set! head cell) (set! tail cell))
	    (begin (set-cdr! tail cell) (set! tail cell)))))
    (define (deq!) (let ((x (car head))) (set! head (cdr head)) x))
    (define (fib n)
      (set! counter (fx+ counter 1))
      (when (fx= counter k-every)
	(set! counter 0)
	(shift k (enq! (cons 'k k))))
      (if (fx< n 2) n (fx+ (fib (fx- n 1)) (fib (fx- n 2)))))
    (do ((i 0 (fx+ i 1))) ((fx= i nthreads))
      (enq! (cons 'start (lambda (v) (set! total (fx+ total (fib 20)))))))
    (let loop ()
      (unless (null? head)
	(let ((t (deq!)))
	  (if (eq? (car t) 'start)
	      (reset ((cdr t) #f))
	      ((cdr t) #f))
	  (loop))))
    total))

(define (coro-cc nthreads k-every)
  (let ((head '()) (tail '()) (counter 0) (total 0) (exit-k #f))
    (define (enq! x)
      (let ((cell (cons x '())))
	(if (null? head)
	    (begin (set! head cell) (set! tail cell))
	    (begin (set-cdr! tail cell) (set! tail cell)))))
    (define (deq!) (let ((x (car head))) (set! head (cdr head)) x))
    (define (dispatch) (if (null? head) (exit-k #f) ((deq!) #f)))
    (define (yield) (call-with-current-continuation (lambda (k) (enq! k) (dispatch))))
    (define (fib n)
      (set! counter (fx+ counter 1))
      (when (fx= counter k-every) (set! counter 0) (yield))
      (if (fx< n 2) n (fx+ (fib (fx- n 1)) (fib (fx- n 2)))))
    (do ((i 0 (fx+ i 1))) ((fx= i nthreads))
      (enq! (lambda (v) (set! total (fx+ total (fib 20))) (dispatch))))
    (call-with-current-continuation (lambda (k) (set! exit-k k) (dispatch)))
    total))

(define (coro-once f k-every)
  (gc #t)
  (let* ((t0 (now-ns)) (v (f NTHREADS k-every)) (t1 (now-ns)))
    (check! (eqv? v (fx* NTHREADS 6765)))
    (- t1 t0)))

(define (coro-ns f k-every)
  (let loop ((i 0) (acc '()))
    (if (fx= i RUNS) (median acc) (loop (fx+ i 1) (cons (coro-once f k-every) acc)))))

(define (coro label f)
  (let ((base (coro-ns f 1000000000))		; never switches
	(sw (coro-ns f 1)))			; switches on every call
    (print "coro." label ".no_switch = " (r2 (/ base 1e6)) " ms")
    (print "coro." label ".every_call = " (r2 (/ sw 1e6)) " ms")
    (print "coro." label ".per_switch = " (r2 (/ (- sw base) SWITCHES)) " ns")))

(coro "shift_reset" coro-dc)
(coro "callcc" coro-cc)
(print "coro.switches = " SWITCHES " int")


;;; 3. What held segments cost the collector.  N captured segments whose
;;; delimiter's OUTER continuation each references a 64 KB vector; time a
;;; major GC.  "dead_outer" is the control: the vector is dead before the
;;; reset.  With the retention fix the two agree.

(define kept '())
(define sink 0)
(define (touch v) (set! sink (fx+ sink (vector-ref v 0))))

(define (capture-live-outer big)
  (let ((r (reset (+ 1 (shift k (set! kept (cons k kept)) 0)))))
    (touch big)
    r))

(define (capture-dead-outer big)
  (touch big)
  (reset (+ 1 (shift k (set! kept (cons k kept)) 0))))

(define GCS 20)

(define (gctime label f n)
  (set! kept '())
  (gc #t)
  (do ((i 0 (fx+ i 1))) ((fx= i n))
    (f (make-vector 8192 1)))			; 64 KB per vector
  (gc #t) (gc #t)
  (let* ((live (vector-ref (memory-statistics) 1))
	 (t0 (current-process-milliseconds)))
    (do ((i 0 (fx+ i 1))) ((fx= i GCS)) (gc #t))
    (let ((t1 (current-process-milliseconds)))
      (print "gctime." label "_" n ".live = " (quotient live 1024) " KB")
      (print "gctime." label "_" n ".major_gc = " (r2 (/ (- t1 t0) GCS)) " ms")))
  (set! kept '())
  (gc #t))

(gctime "live_outer" capture-live-outer 2000)
(gctime "dead_outer" capture-dead-outer 2000)
(gctime "live_outer" capture-live-outer 8000)
(gctime "dead_outer" capture-dead-outer 8000)
(check! (eqv? sink 20000))

(print "checks_ok = " (if ok 1 0) " bool")
