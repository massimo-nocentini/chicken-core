;;;; delimcc-paper-bench.scm - the benchmark categories of Gasbichler & Sperber,
;;;; "Final Shift for Call/cc" (ICFP 2002), section 6, on CHICKEN.
;
; Compile twice and diff the KEY = VALUE lines:
;
;   csc -O2 delimcc-paper-bench.scm                  native shift/reset (chicken continuation)
;   csc -O2 -D filinski delimcc-paper-bench.scm      the paper's section 2 code: Filinski's
;                                            *meta-continuation* cell over call/cc
;
; Not -O3: its -local miscompiles multi-shot continuations on this tree,
; since before shift/reset existed (checked back to 63f59d28): the parser
; workload returns 208 results instead of 149, the complete parse 60 times
; over, with call/cc alone exactly as with shift/reset.  -O2 and -O5 are
; correct; every workload checks its result.
;
; Workloads, one per category of the paper:
;   monads  - the ambivalence (nondeterminism) monad: all words of length 3
;             and 4 over a 26-letter alphabet ("www", "wwww"), and a
;             nondeterministic Hutton/Meijer-style parser of arithmetic
;   pe      - continuation-based specialisation: type-directed partial
;             evaluation with let-insertion (Danvy), residualising Church
;             iteration of a dynamic function and a static-exponent power
;   threads - Bruggeman et al.: 100 threads each computing fib(20), a
;             context switch every K calls, K = 1 8 64 512 4096; also the
;             same threads on call/cc, as in the paper's figure 16
; Every workload checks its result.  Medians of RUNS in-process repetitions.

(import (chicken foreign) (chicken gc) (chicken fixnum) (chicken sort)
	(chicken string))

(cond-expand
  (filinski
   ;; Verbatim from the paper, section 2 (Danvy's Scheme 48 code after
   ;; Filinski), with `body ...' in the macros.
   (define-syntax reset
     (syntax-rules ()
       ((reset e ...) (*reset (lambda () e ...)))))
   (define-syntax shift
     (syntax-rules ()
       ((shift k e ...) (*shift (lambda (k) e ...)))))
   (define (*meta-continuation* v)
     (error "You forgot the top-level reset..."))
   (define (*abort thunk)
     (let ((v (thunk)))
       (*meta-continuation* v)))
   (define (*reset thunk)
     (let ((mc *meta-continuation*))
       (call-with-current-continuation
	(lambda (k)
	  (begin
	    (set! *meta-continuation*
		  (lambda (v)
		    (set! *meta-continuation* mc)
		    (k v)))
	    (*abort thunk))))))
   (define (*shift f)
     (call-with-current-continuation
      (lambda (k)
	(*abort (lambda ()
		  (f (lambda (v)
		       (reset (k v)))))))))
   (define IMPL "filinski"))
  (else
   (import (chicken continuation))
   (define IMPL "native")))

(foreign-declare "#include <time.h>")
(define now-ns
  (foreign-lambda* double ()
    "struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);"
    "C_return((double)ts.tv_sec * 1e9 + (double)ts.tv_nsec);"))

(define RUNS 5)
(define (median xs) (list-ref (sort xs <) (quotient (length xs) 2)))
(define (r2 x) (/ (round (* 100 (exact->inexact x))) 100))
(define ok #t)
(define (check! what b) (unless b (set! ok #f) (print "CHECK FAILED: " what)))

;; time THUNK RUNS times, median ms; VERIFY receives the result
(define (bench key thunk verify)
  (let loop ((i 0) (acc '()))
    (if (fx= i RUNS)
	(print key " = " (r2 (/ (median acc) 1e6)) " ms")
	(begin
	  (gc #t)
	  (let* ((t0 (now-ns)) (v (thunk)) (t1 (now-ns)))
	    (check! key (verify v))
	    (loop (fx+ i 1) (cons (- t1 t0) acc)))))))

(print "impl = " IMPL)


;;; 1. Monads: the ambivalence monad

(define (amb lst) (shift k (apply append (map k lst))))
(define (fail) (shift k '()))

(define alphabet (string->list "abcdefghijklmnopqrstuvwxyz"))

;; all words of length n: 26^n strings
(define (words n)
  (reset
   (let loop ((i 0) (acc '()))
     (if (fx= i n)
	 (list (list->string (reverse acc)))
	 (loop (fx+ i 1) (cons (amb alphabet) acc))))))

(bench "monads.www"  (lambda () (words 3)) (lambda (ws) (= (length ws) 17576)))
(bench "monads.wwww" (lambda () (words 4)) (lambda (ws) (= (length ws) 456976)))

;; A nondeterministic parser in the style of Hutton & Meijer's monadic
;; parsers, with the list-of-successes monad realised by amb/fail.  A parser
;; is a procedure from the remaining input to (value . rest).
;;
;;   expr   := term ('+' expr)?
;;   term   := factor ('*' term)?
;;   factor := digit | '(' expr ')'
;;
;; The optional parts are chosen nondeterministically, so a full run
;; enumerates every prefix parse of the input.

(define (filter p l) (cond ((null? l) '()) ((p (car l)) (cons (car l) (filter p (cdr l)))) (else (filter p (cdr l)))))

(define (item cs) (if (null? cs) (fail) (cons (car cs) (cdr cs))))
(define (sat p cs) (let ((r (item cs))) (if (p (car r)) r (fail))))
(define (lit c cs) (sat (lambda (x) (char=? x c)) cs))

(define (p-expr cs)
  (let ((t (p-term cs)))
    (if (amb '(#f #t))
	(let* ((plus (lit #\+ (cdr t)))
	       (e (p-expr (cdr plus))))
	  (cons (+ (car t) (car e)) (cdr e)))
	t)))

(define (p-term cs)
  (let ((f (p-factor cs)))
    (if (amb '(#f #t))
	(let* ((star (lit #\* (cdr f)))
	       (t (p-term (cdr star))))
	  (cons (* (car f) (car t)) (cdr t)))
	f)))

(define (p-factor cs)
  (if (amb '(#f #t))
      (let ((d (sat char-numeric? cs)))
	(cons (- (char->integer (car d)) 48) (cdr d)))
      (let* ((open (lit #\( cs))
	     (e (p-expr (cdr open)))
	     (close (lit #\) (cdr e))))
	(cons (car e) (cdr close)))))

(define PARSES 149)   ; every prefix parse of the input, one of them complete
(define (parse-all str)
  (reset (list (p-expr (string->list str)))))

;; 30 copies of "1+2*(3+4)*5" (= 71) joined by "+(6*7+8)+" (= 50):
;; the one full parse is 30*71 + 29*50 = 3580
(define parser-input
  (let loop ((i 1) (acc "1+2*(3+4)*5"))
    (if (= i 30) acc (loop (+ i 1) (string-append acc "+(6*7+8)+" "1+2*(3+4)*5")))))

(bench "monads.parser-x50"
       (lambda () (let loop ((i 1) (rs (parse-all parser-input))) (if (= i 50) rs (loop (+ i 1) (parse-all parser-input)))))
       (lambda (rs)
	 ;; exactly one parse consumes everything; its value is the sum
	 (and (= (length rs) PARSES)
	      (let ((full (filter (lambda (r) (null? (cdr r))) rs)))
		(and (= (length full) 1) (= (caar full) 3580))))))



;;; 2. Continuation-based partial evaluation: TDPE with let-insertion
;;;
;;; Danvy's type-directed partial evaluation for call-by-value.  A value of
;;; type int is a code expression; a value of arrow type is a procedure.
;;; reflect at an arrow type residualises each application as a let binding
;;; inserted at the nearest reset by shift.  Types: int | (-> t1 t2).

(define var-counter 0)
(define (fresh) (set! var-counter (fx+ var-counter 1)) (string->symbol (string-append "x" (number->string var-counter))))

(define (reify t v)
  (if (eq? t 'int)
      v
      (let ((x (fresh)))
	`(lambda (,x) ,(reset (reify (caddr t) (v (reflect (cadr t) x))))))))

(define (reflect t e)
  (if (eq? t 'int)
      e
      (lambda (v)
	(let ((r (fresh)))
	  (shift k `(let ((,r (,e ,(reify (cadr t) v))))
		      ,(k (reflect (caddr t) r))))))))

;; Church iteration: apply a dynamic f n times - residualises n lets
(define (iterate n) (lambda (f) (lambda (x) (let loop ((i 0) (x x)) (if (fx= i n) x (loop (fx+ i 1) (f x)))))))
(define t-iter '(-> (-> int int) (-> int int)))

(define (count-lets e)
  (cond ((pair? e) (+ (if (eq? (car e) 'let) 1 0) (apply + (map count-lets (cdr e)))))
	(else 0)))

(bench "pe.iterate-20000"
       (lambda () (set! var-counter 0) (reify t-iter (iterate 20000)))
       (lambda (code) (= (count-lets code) 20000)))

;; power with a static exponent and a dynamic multiply: the classic
;; specialisation, exponent 60 by repeated squaring through a dynamic mul
(define (power n)
  (lambda (mul)
    (lambda (x)
      (let loop ((n n))
	(cond ((= n 0) 1)
	      ((even? n) (let ((h (loop (quotient n 2)))) ((mul h) h)))
	      (else ((mul x) (loop (- n 1)))))))))
(define t-power '(-> (-> int (-> int int)) (-> int int)))

(bench "pe.power-60x5000"
       (lambda () (set! var-counter 0)
	       (let loop ((i 0) (last #f)) (if (= i 5000) last (loop (+ i 1) (reify t-power (power 60))))))
       (lambda (code) (= (count-lets code) 18)))


;;; 3. Threads: 100 threads of fib(20), a switch every K calls

(define NTHREADS 100)

(define (threads-dc nthreads K)
  (let ((head '()) (tail '()) (counter 0) (total 0))
    (define (enq! x)
      (let ((cell (cons x '())))
	(if (null? head) (begin (set! head cell) (set! tail cell))
	    (begin (set-cdr! tail cell) (set! tail cell)))))
    (define (deq!) (let ((x (car head))) (set! head (cdr head)) x))
    (define (fib n)
      (set! counter (fx+ counter 1))
      (when (fx= counter K) (set! counter 0) (shift k (enq! (cons 'k k))))
      (if (fx< n 2) n (fx+ (fib (fx- n 1)) (fib (fx- n 2)))))
    (do ((i 0 (fx+ i 1))) ((fx= i nthreads))
      (enq! (cons 'start (lambda (v) (set! total (fx+ total (fib 20)))))))
    (let loop ()
      (unless (null? head)
	(let ((t (deq!)))
	  (if (eq? (car t) 'start) (reset ((cdr t) #f)) ((cdr t) #f))
	  (loop))))
    total))

(define (threads-cc nthreads K)
  (let ((head '()) (tail '()) (counter 0) (total 0) (exit-k #f))
    (define (enq! x)
      (let ((cell (cons x '())))
	(if (null? head) (begin (set! head cell) (set! tail cell))
	    (begin (set-cdr! tail cell) (set! tail cell)))))
    (define (deq!) (let ((x (car head))) (set! head (cdr head)) x))
    (define (dispatch) (if (null? head) (exit-k #f) ((deq!) #f)))
    (define (yield) (call-with-current-continuation (lambda (k) (enq! k) (dispatch))))
    (define (fib n)
      (set! counter (fx+ counter 1))
      (when (fx= counter K) (set! counter 0) (yield))
      (if (fx< n 2) n (fx+ (fib (fx- n 1)) (fib (fx- n 2)))))
    (do ((i 0 (fx+ i 1))) ((fx= i nthreads))
      (enq! (lambda (v) (set! total (fx+ total (fib 20))) (dispatch))))
    (call-with-current-continuation (lambda (k) (set! exit-k k) (dispatch)))
    total))

(define (fib-total? v) (= v (* NTHREADS 6765)))

(for-each
 (lambda (K)
   (bench (string-append "threads.shift-reset.K" (number->string K))
	  (lambda () (threads-dc NTHREADS K)) fib-total?))
 '(1 8 64 512 4096))

(for-each
 (lambda (K)
   (bench (string-append "threads.callcc.K" (number->string K))
	  (lambda () (threads-cc NTHREADS K)) fib-total?))
 '(1 8 64 512 4096))

(print "checks_ok = " (if ok 1 0) " bool")
