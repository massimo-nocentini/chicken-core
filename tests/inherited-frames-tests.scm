;;;; inherited-frames-tests.scm - frames a thread inherits from its creator
;
; A thread starts in the `dynamic-wind' frames of its creator.  When it
; leaves one, by invoking a continuation its creator captured outside
; it, the frame's after thunk runs in the thread, and the creator leaves
; the same frame again later.  Neither exit may disturb the other's, nor
; crash.  The thread is made with the scheduler's own procedures, as the
; core has no SRFI 18.

(declare (uses scheduler))

(import (chicken condition)
	(chicken format))

(define failures 0)

(define (chk name got want)
  (cond ((equal? got want)
	 (printf "~a => ~s~%" name got))
	(else
	 (set! failures (add1 failures))
	 (printf "~a => ~s  *** EXPECTED ~s~%" name got want))))

(define handlers ##sys#current-exception-handler)

(define (exit-thread)
  (##sys#thread-kill! ##sys#current-thread 'dead)
  (##sys#schedule))

(define (spawn thunk)
  (let ((t (##sys#make-thread #f 'created 'child
			      (##sys#slot ##sys#current-thread 9))))
    (##sys#setslot t 1 (lambda () (thunk) (exit-thread)))
    (##sys#setslot t 3 'ready)
    (##sys#add-to-ready-queue t)))

(define child-saw #f)

;; ENTER runs its argument inside a frame; the thread started there
;; leaves the frame by a continuation captured outside it, records what
;; REPORT returns and dies, while the creator waits for it inside the
;; frame and then leaves the frame itself.
(define (leave-in-child enter report)
  (set! child-saw #f)
  (let ((r (call-with-current-continuation (lambda (k) (cons 'k k)))))
    (if (eq? (car r) 'child)
	(begin (set! child-saw (report)) (exit-thread))
	(let ((k (cdr r)))
	  (enter (lambda ()
		   (spawn (lambda () (k (list 'child))))
		   (let wait ()
		     (unless child-saw (##sys#thread-yield!) (wait)))))))))

(chk "with-exception-handler frame left by a thread, then by its creator"
     (list (leave-in-child
	    (lambda (body)
	      (with-exception-handler
	       (lambda (e) (list 'handled e))
	       (lambda () (body) (signal 'inside))))
	    (lambda () 'child))
	   child-saw
	   (eq? ##sys#current-exception-handler handlers))
     '((handled inside) child #t))

(newline)
(printf "~a failure(s)~%" failures)
(when (positive? failures)
  (error "inherited frames tests failed" failures))
