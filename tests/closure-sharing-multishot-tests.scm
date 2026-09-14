;;;; closure-sharing-multishot-tests.scm
;
; Multi-shot re-entry of continuations whose closures the compiler merges.
;
; Closure reuse (-merge-reusable-closures, on from -O1) lets a lambda that
; captures exactly the set of variables its containing lambda captures use
; the container's closure object through a single slot.  That object is
; complete when it is allocated and never written afterwards, so any of the
; closures involved may be entered any number of times in any order.
;
; The closure SHARING pass that this file was written against
; (-merge-shareable-closures, formerly on from -O2) let a compiler
; continuation lambda K that contains exactly one lambda U be the CONTAINER
; of U: K's closure object O held the union of the chain's free variables,
; every lambda of the chain wrote the variables of its own activation that
; lived in O into O on entry, and U read them from there when it ran.
; Assigned variables introduced by the chain that did not escape it were
; un-boxed into O, so O's slot was their only location.  That is sound only
; while O is not entered again before a reader from an earlier entry has
; run; multi-shot call/cc (or shift) that re-enters a chain in non-LIFO
; order breaks it, and cases 1-8 below failed at -O2 and above.  The pass
; has been removed; the cases stay to catch any merging of closures that
; makes a closure object depend on which activation entered it last.
;
; Every expected value below is derived by hand from Scheme semantics
; (R7RS 6.10 call/cc, 6.10 dynamic-wind, Danvy/Filinski shift/reset);
; -O0 (no merging at all) agrees with every line.  Each case prints one
; line; the program exits 1 if any case mismatches.
;
; Conventions.  A test body never RETURNS to its caller (a re-entered
; continuation would return into a stale frame); it hands its result to
; the driver with (top v), where `top' is the continuation of the most
; recent (with-top thunk).  cap1/cap2/cap3 capture the current
; continuation into the globals k1/k2/k3 and return 0; the driver copies
; them right after each step.  fx+ is used so that arithmetic never
; introduces a continuation lambda (the shapes under test contain exactly
; one lambda per level).
(import (chicken base) (chicken fixnum) (chicken continuation)
        (chicken process-context))

(declare (not inline with-top run1 run2 resume))

(define failures 0)
(define (check name got expected)
  (cond ((equal? got expected)
         (print "ok   " name " => " got))
        (else
         (set! failures (fx+ failures 1))
         (print "FAIL " name " => " got "  expected " expected))))

(define top #f)
(define (with-top thunk)
  (call-with-current-continuation
    (lambda (k) (set! top k) (thunk))))

;; The bodies are handed to these helpers as VALUES so that no level
;; (notably -O5's block mode) can inline or contract a body into its
;; driver and change the closure shapes under test.
(define (run1 f a) (with-top (lambda () (f a))))
(define (run2 f a b) (with-top (lambda () (f a b))))
(define (resume k v) (with-top (lambda () (k v))))

;; The capture procedures are made by a generator, so they are unknown
;; procedure values at every level: a known procedure with a single call
;; site is contracted into its caller in block mode (-O5) even when
;; declared not inline, which would put the call/cc lambda into the
;; chain and change its shape.
(define k1 #f) (define k2 #f) (define k3 #f)
(define (make-cap setter)
  (lambda (x) (call-with-current-continuation (lambda (k) (setter k) 0))))
(define cap1 (make-cap (lambda (k) (set! k1 k))))
(define cap2 (make-cap (lambda (k) (set! k2 k))))
(define cap3 (make-cap (lambda (k) (set! k3 k))))


;;; 1. Breadth-first amb.  Each `choose' parks one thunk per alternative on
;;;    a FIFO queue and returns to the scheduler; the queue is drained in
;;;    order, so the continuation of (choose '(1 2)) is entered with 1,
;;;    then with 2, and only THEN are the continuations of
;;;    (choose '(10 20)) parked by those two entries run.  Cartesian
;;;    product in queue order: ((1 10) (1 20) (2 10) (2 20)).

(define bfs-queue '())
(define bfs-results '())
(define (bfs-choose lst)
  (call-with-current-continuation
    (lambda (k)
      (set! bfs-queue (append bfs-queue (map (lambda (v) (lambda () (k v))) lst)))
      (top #f))))
(define (bfs-body)
  (let* ((x (bfs-choose '(1 2)))
         (y (bfs-choose '(10 20))))
    (set! bfs-results (cons (list x y) bfs-results))
    (top #f)))
(define (bfs-run)
  (with-top bfs-body)
  (let loop ()
    (if (null? bfs-queue)
        (reverse bfs-results)
        (let ((th (car bfs-queue)))
          (set! bfs-queue (cdr bfs-queue))
          (with-top th)
          (loop)))))

(check "1 breadth-first amb" (bfs-run) '((1 10) (1 20) (2 10) (2 20)))


;;; 2. A parked USER continuation resumed after a re-entry.  The container
;;;    K_r (continuation of cap1) is entered once.  K_s (continuation of
;;;    cap2) is a user, K_t (continuation of cap3) a deeper user.  Resuming
;;;    K_s enters the chain again with s = 5 and parks a new K_t'; the K_t
;;;    parked by the FIRST entry must still see s = 0.
;;;    Steps: (f 1) -> (1 0 0 0); (K_s 5) -> (1 0 5 0); (K_t 9) -> (1 0 0 9);
;;;    (K_t' 3) -> (1 0 5 3); (K_s 6) -> (1 0 6 0).

(define (user-reentry n)
  (let ((r (cap1 n)))
    (let ((s (cap2 n)))
      (let ((t (cap3 n)))
        (top (list n r s t))))))

(define (case-user-reentry)
  (let* ((v1 (run1 user-reentry 1))
         (ks k2) (kt k3)
         (v2 (resume ks 5))
         (kt2 k3)
         (v3 (resume kt 9))
         (v4 (resume kt2 3))
         (v5 (resume ks 6)))
    (list v1 v2 v3 v4 v5)))

(check "2 parked user resumed after re-entry" (case-user-reentry)
       '((1 0 0 0) (1 0 5 0) (1 0 0 9) (1 0 5 3) (1 0 6 0)))


;;; 3. Generator fork: the continuation of the first yield is resumed
;;;    twice, and the two second-yield continuations that those
;;;    resumptions park are resumed afterwards, interleaved.
;;;    gen 1: yields 1 (a = ?).  K_a 10 -> yields 11, parks K_b; K_a 20 ->
;;;    yields 21, parks K_b'; K_b 100 -> (1 10 100); K_b' 200 -> (1 20 200).

(define gen-k #f)
(define (yield v)
  (call-with-current-continuation
    (lambda (k) (set! gen-k k) (top v))))
(define (gen n)
  (let* ((a (yield n))
         (b (yield (fx+ a n))))
    (top (list n a b))))

(define (case-generator-fork)
  (let* ((v1 (run1 gen 1))
         (ka gen-k)
         (v2 (resume ka 10))
         (kb gen-k)
         (v3 (resume ka 20))
         (kb2 gen-k)
         (v4 (resume kb 100))
         (v5 (resume kb2 200)))
    (list v1 v2 v3 v4 v5)))

(check "3 generator fork" (case-generator-fork)
       '(1 11 21 (1 10 100) (1 20 200)))


;;; 4. set! on a variable LET-BOUND IN THE CONTAINER (acc), seen by a
;;;    re-entered user.  Each entry of K_r creates a fresh `acc'; the two
;;;    parked users must each keep adding to their own entry's acc, and
;;;    re-entering the same user twice must see the same location (5 then
;;;    5+6).  (The removed pass un-boxed acc into O, so entry B's acc and r
;;;    overwrote entry A's.)
;;;    Steps: (g 1) -> (1 0 0); (K_r 100) -> (1 100 100); (K_sA 5) -> (1 0 5);
;;;    (K_sB 7) -> (1 100 107); (K_sA 6) -> (1 0 11).

(define (let-bound-set n)
  (let ((r (cap1 n)))
    (let ((acc 0))
      (set! acc (fx+ acc r))
      (let ((s (cap2 n)))
        (set! acc (fx+ acc s))
        (top (list n r acc))))))

(define (case-let-bound-set)
  (let* ((v1 (run1 let-bound-set 1))
         (kr k1) (ksa k2)
         (v2 (resume kr 100))
         (ksb k2)
         (v3 (resume ksa 5))
         (v4 (resume ksb 7))
         (v5 (resume ksa 6)))
    (list v1 v2 v3 v4 v5)))

(check "4 set! on container let-bound var, per entry" (case-let-bound-set)
       '((1 0 0) (1 100 100) (1 0 5) (1 100 107) (1 0 11)))


;;; 4b. Same with set! on the container's own PARAMETER r.
;;;    Steps: (g 1): r=0 -> r=1 -> (1 1 0); (K_r 100): r=101 -> (1 101 0);
;;;    (K_sA 5): entry A's r is 1 -> (1 1 5); (K_sB 7) -> (1 101 7).

(define (param-set n)
  (let ((r (cap1 n)))
    (set! r (fx+ r 1))
    (let ((s (cap2 n)))
      (top (list n r s)))))

(define (case-param-set)
  (let* ((v1 (run1 param-set 1))
         (kr k1) (ksa k2)
         (v2 (resume kr 100))
         (ksb k2)
         (v3 (resume ksa 5))
         (v4 (resume ksb 7)))
    (list v1 v2 v3 v4)))

(check "4b set! on container parameter, per entry" (case-param-set)
       '((1 1 0) (1 101 0) (1 1 5) (1 101 7)))


;;; 5. set! on an OUTER variable (count, bound in the procedure that calls
;;;    cap1, so it is captured by K_r and K_s but introduced by neither):
;;;    it is ONE location, every entry and every resumption must share it.
;;;    Steps: (h 1): count 1 then 2 -> (1 0 0 2); (K_r 10): 3, 4 -> (1 10 0 4);
;;;    (K_sA 5): 5 -> (1 0 5 5); (K_sB 7): 6 -> (1 10 7 6).

(define (outer-set n)
  (let ((count 0))
    (let ((r (cap1 n)))
      (set! count (fx+ count 1))
      (let ((s (cap2 n)))
        (set! count (fx+ count 1))
        (top (list n r s count))))))

(define (case-outer-set)
  (let* ((v1 (run1 outer-set 1))
         (kr k1) (ksa k2)
         (v2 (resume kr 10))
         (ksb k2)
         (v3 (resume ksa 5))
         (v4 (resume ksb 7)))
    (list v1 v2 v3 v4)))

(check "5 set! on outer var, shared by all entries" (case-outer-set)
       '((1 0 0 2) (1 10 0 4) (1 0 5 5) (1 10 7 6)))


;;; 6. Cases 4 and 5 through native shift/reset, with the shift in a
;;;    CALLEE (sh-cap1/sh-cap2 are not inlined).  A shift's k, when
;;;    invoked, returns the value the delimited segment delivers to its
;;;    reset, so no `top' is needed here.
;;;    6a (let-bound acc):  (reset (sh-let-bound 1)) -> 0 (first shift aborts);
;;;    (K_r 0) -> 0 (second shift aborts, parks K_sA); (K_r 100) -> 0, parks
;;;    K_sB; (K_sA 5) -> (1 0 5); (K_sB 7) -> (1 100 107); (K_sA 6) -> (1 0 11).
;;;    6b (outer count): (reset (sh-outer 1)) -> 0 (count still 0);
;;;    (K_r 0): count 1, the segment aborts at the second shift -> 0, parks
;;;    K_sA; (K_r 10): count 2 -> 0, parks K_sB; (K_sA 5): count 3 -> (1 0 5 3);
;;;    (K_sB 7): count 4 -> (1 10 7 4).

(define sk1 #f) (define sk2 #f)
(define (make-sh-cap setter) (lambda (x) (shift k (setter k) 0)))
(define sh-cap1 (make-sh-cap (lambda (k) (set! sk1 k))))
(define sh-cap2 (make-sh-cap (lambda (k) (set! sk2 k))))

(define (sh-let-bound n)
  (let ((r (sh-cap1 n)))
    (let ((acc 0))
      (set! acc (fx+ acc r))
      (let ((s (sh-cap2 n)))
        (set! acc (fx+ acc s))
        (list n r acc)))))

(define (case-shift-let-bound)
  (let* ((v1 (reset (sh-let-bound 1)))
         (kr sk1)
         (v2 (kr 0))
         (ksa sk2)
         (v3 (kr 100))
         (ksb sk2)
         (v4 (ksa 5))
         (v5 (ksb 7))
         (v6 (ksa 6)))
    (list v1 v2 v3 v4 v5 v6)))

(check "6a shift in callee, container let-bound var" (case-shift-let-bound)
       '(0 0 0 (1 0 5) (1 100 107) (1 0 11)))

(define (sh-outer n)
  (let ((count 0))
    (let ((r (sh-cap1 n)))
      (set! count (fx+ count 1))
      (let ((s (sh-cap2 n)))
        (set! count (fx+ count 1))
        (list n r s count)))))

(define (case-shift-outer)
  (let* ((v1 (reset (sh-outer 1)))
         (kr sk1)
         (v2 (kr 0))
         (ksa sk2)
         (v3 (kr 10))
         (ksb sk2)
         (v4 (ksa 5))
         (v5 (ksb 7)))
    (list v1 v2 v3 v4 v5)))

(check "6b shift in callee, outer var shared" (case-shift-outer)
       '(0 0 0 (1 0 5 3) (1 10 7 4)))


;;; 7. dynamic-wind around a re-entered continuation.  The chain lives in
;;;    the thunk; every entry from outside runs `in', every (top v) escape
;;;    runs `out'.  The trace must interleave in/out with each result.
;;;    (dw 1) -> (1 0 0); (K_r 10) -> (1 10 0); (K_sA 5) -> (1 0 5);
;;;    (K_sB 7) -> (1 10 7).

(define dw-trace '())
(define (dw-note x) (set! dw-trace (cons x dw-trace)))
(define (dw n)
  (dynamic-wind
    (lambda () (dw-note 'in))
    (lambda ()
      (let ((r (cap1 n)))
        (let ((s (cap2 n)))
          (dw-note (list n r s))
          (top #t))))
    (lambda () (dw-note 'out))))

(define (case-dynamic-wind)
  (set! dw-trace '())
  (run1 dw 1)
  (let* ((kr k1) (ksa k2))
    (resume kr 10)
    (let ((ksb k2))
      (resume ksa 5)
      (resume ksb 7)
      (reverse dw-trace))))

(check "7 dynamic-wind around re-entered chain" (case-dynamic-wind)
       '(in (1 0 0) out in (1 10 0) out in (1 0 5) out in (1 10 7) out))


;;; 8. A container entered three times (r = 0, 10, 20), then the three
;;;    parked users resumed out of order, one of them twice.
;;;    (K_sB 5) -> (1 10 5); (K_sA 6) -> (1 0 6); (K_sC 7) -> (1 20 7);
;;;    (K_sA 8) -> (1 0 8).

(define (three n)
  (let ((r (cap1 n)))
    (let ((s (cap2 n)))
      (top (list n r s)))))

(define (case-three-entries)
  (let* ((v1 (run1 three 1))
         (kr k1) (ksa k2)
         (v2 (resume kr 10))
         (ksb k2)
         (v3 (resume kr 20))
         (ksc k2)
         (v4 (resume ksb 5))
         (v5 (resume ksa 6))
         (v6 (resume ksc 7))
         (v7 (resume ksa 8)))
    (list v1 v2 v3 v4 v5 v6 v7)))

(check "8 container entered 3 times, users out of order" (case-three-entries)
       '((1 0 0) (1 10 0) (1 20 0) (1 10 5) (1 0 6) (1 20 7) (1 0 8)))


;;; 9. merge-reusable shapes (-merge-reusable-closures, on from -O1): a
;;;    loop whose two continuation closures per iteration capture exactly
;;;    the same set {acc l lp}, so the second is reused from the first
;;;    (no entry writes: the set is fixed when the first is created).
;;;    `acc' is ONE location outside the loop, so every resumption keeps
;;;    appending to it; each cap returns 0 and (fx+ v (car l)) is consed.
;;;    (reuse-loop 1 2): l=(10 20): 10 10, then 20 20 -> (1 2 (10 10 20 20)),
;;;    k1 = K_1 of iteration 2 (l=(20)), k2 = K_2 of iteration 2.
;;;    (K_2 5): cons 25, l -> () -> (1 2 (10 10 20 20 25)).
;;;    (K_1 7): cons 27, cap2 -> 0, cons 20 -> (1 2 (10 10 20 20 25 27 20)).
;;;    (K_2 5) again: cons 25 -> (1 2 (10 10 20 20 25 27 20 25)).

(define (reuse-loop a b)
  (let ((acc '()))
    (let lp ((l '(10 20)))
      (if (null? l)
          (top (list a b (reverse acc)))
          (begin
            (set! acc (cons (fx+ (cap1 (car l)) (car l)) acc))
            (set! acc (cons (fx+ (cap2 (car l)) (car l)) acc))
            (lp (cdr l)))))))

(define (case-reuse-loop)
  (let* ((v1 (run2 reuse-loop 1 2))
         (kb1 k1) (kb2 k2)
         (v2 (resume kb2 5))
         (v3 (resume kb1 7))
         (v4 (resume kb2 5)))
    (list v1 v2 v3 v4)))

(check "9 reusable loop continuations, multi-shot" (case-reuse-loop)
       '((1 2 (10 10 20 20)) (1 2 (10 10 20 20 25)) (1 2 (10 10 20 20 25 27 20))
         (1 2 (10 10 20 20 25 27 20 25))))

;;; 9b. Reusable shape with sibling continuations that capture the same
;;;     set as their creator and no per-entry variables: (p a b) calls two
;;;     capturing procedures, whose continuations capture exactly {a b};
;;;     re-entering the first after the second must give the same values.
;;;     (same-set 3 4) -> (3 4); (K1 _) -> (3 4); (K2 _) -> (3 4).

(define (same-set a b)
  (cap1 a)
  (cap2 b)
  (top (list a b)))

(define (case-same-set)
  (let* ((v1 (run2 same-set 3 4))
         (ka k1) (kb k2)
         (v2 (resume ka 0))
         (v3 (resume kb 0))
         (v4 (resume ka 0)))
    (list v1 v2 v3 v4)))

(check "9b reusable sibling continuations" (case-same-set)
       '((3 4) (3 4) (3 4) (3 4)))


;;; ---- LIFO cases that must keep working -------------------------------

;;; 10. delimcc: Danvy/Filinski shapes, multi-shot but LIFO.
;;;     (reset (fx+ 1 (shift k (fx+ (k 1) (k 1))))) -> (k 1) = 2 -> 4.
;;;     (reset (fx* 2 (shift k (k (k 4)))))          -> (k 4) = 8, (k 8) = 16.
;;;     shift in a callee: (twice) = (shift k (fx+ (k 1) (k 10)));
;;;     (reset (let ((x (twice))) (fx* x 2)))         -> 2 + 20 = 22.
;;;     nested resets: (reset (fx+ 1 (reset (fx* 10 (shift k (k (k 1))))))) -> 1 + 100 = 101.

(define (twice) (shift k (fx+ (k 1) (k 10))))
(check "10 delimcc LIFO shapes"
       (list (reset (fx+ 1 (shift k (fx+ (k 1) (k 1)))))
             (reset (fx* 2 (shift k (k (k 4)))))
             (reset (let ((x (twice))) (fx* x 2)))
             (reset (fx+ 1 (reset (fx* 10 (shift k (k (k 1))))))))
       '(4 16 22 101))

;;; 11. Depth-first amb (LIFO multi-shot): Pythagorean triples with
;;;     a, b, c in 1..10, a iterated outermost: (3 4 5) (4 3 5) (6 8 10) (8 6 10).

(define amb-fail-stack '())
(define amb-solutions '())
(define (amb-fail)
  (if (null? amb-fail-stack)
      (top 'exhausted)
      (let ((f (car amb-fail-stack)))
        (set! amb-fail-stack (cdr amb-fail-stack))
        (f))))
(define (amb-list lst)
  (call-with-current-continuation
    (lambda (k)
      (let loop ((l lst))
        (if (null? l)
            (amb-fail)
            (begin
              (set! amb-fail-stack (cons (lambda () (loop (cdr l))) amb-fail-stack))
              (k (car l))))))))
(define (iota1 n) (let loop ((i n) (acc '())) (if (fx= i 0) acc (loop (fx- i 1) (cons i acc)))))
(define (dfs-amb)
  (let* ((a (amb-list (iota1 10)))
         (b (amb-list (iota1 10)))
         (c (amb-list (iota1 10))))
    (if (fx= (fx* c c) (fx+ (fx* a a) (fx* b b)))
        (begin (set! amb-solutions (cons (list a b c) amb-solutions))
               (amb-fail))
        (amb-fail))))

(check "11 depth-first amb (LIFO)"
       (begin (with-top dfs-amb) (reverse amb-solutions))
       '((3 4 5) (4 3 5) (6 8 10) (8 6 10)))

;;; 12. Backtracking parser (LIFO multi-shot through two mutually
;;;     recursive procedures).  (p-expr '(1)) = p-term then amb;
;;;     p-term '(1): amb #t -> '(1) (1 way), amb #f -> p-expr '() which has
;;;     2 x 2 = 4 ways all giving '().  The outer amb doubles: 8 x '() and
;;;     2 x '(1); the all-#f path runs first and the #t of the first amb is
;;;     deepest in the stack, so the two '(1) come last.

(define bt-stack '())
(define (bt-amb)
  (call-with-current-continuation
    (lambda (k) (set! bt-stack (cons (lambda () (k #t)) bt-stack)) #f)))
(define (p-expr cs) (let ((t (p-term cs))) (bt-amb) t))
(define (p-term cs) (if (bt-amb) cs (if (pair? cs) (p-expr (cdr cs)) '())))
(define bt-parses '())
(define (bt-run)
  (set! bt-parses (cons (p-expr '(1)) bt-parses))
  (if (pair? bt-stack)
      (let ((next (car bt-stack)))
        (set! bt-stack (cdr bt-stack))
        (next))
      (top (reverse bt-parses))))

(check "12 backtracking parser (LIFO)" (with-top bt-run)
       '(() () () () () () () () (1) (1)))

;;; 13. One-shot interleaved coroutines through shift (each continuation
;;;     resumed exactly once, in FIFO order): two producers alternate.
;;;     Output order: a1 b1 a2 b2 a3 b3.

(define co-queue '())
(define co-log '())
(define (co-enq! x) (set! co-queue (append co-queue (list x))))
(define (co-yield) (shift k (co-enq! k)))
(define (producer tag)
  (let loop ((i 1))
    (when (fx<= i 3)
      (set! co-log (cons (cons tag i) co-log))
      (co-yield)
      (loop (fx+ i 1)))))
(define (co-run)
  (reset (producer 'a))
  (reset (producer 'b))
  (let loop ()
    (unless (null? co-queue)
      (let ((k (car co-queue)))
        (set! co-queue (cdr co-queue))
        (k #f)
        (loop))))
  (reverse co-log))

(check "13 one-shot coroutines via shift" (co-run)
       '((a . 1) (b . 1) (a . 2) (b . 2) (a . 3) (b . 3)))

;;; 14. LIFO re-entry of a chain (entry B completes before entry A's
;;;     reader resumes): (K_r 10) parks K_sB and finishes, then (K_sB 7)
;;;     runs before anything from entry A is touched again.
;;;     (three 1) -> (1 0 0); (K_r 10) -> (1 10 0); (K_sB 7) -> (1 10 7);
;;;     (K_sB 8) -> (1 10 8).

(define (case-lifo-chain)
  (let* ((v1 (run1 three 1))
         (kr k1)
         (v2 (resume kr 10))
         (ksb k2)
         (v3 (resume ksb 7))
         (v4 (resume ksb 8)))
    (list v1 v2 v3 v4)))

(check "14 LIFO re-entry of a shared chain" (case-lifo-chain)
       '((1 0 0) (1 10 0) (1 10 7) (1 10 8)))


(if (fx> failures 0)
    (begin (print failures " failure(s)") (exit 1))
    (print "all closure-sharing multi-shot tests passed"))
