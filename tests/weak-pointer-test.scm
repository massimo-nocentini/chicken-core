;; weak-pointer-test.scm

(import (chicken gc))

(include "test.scm")

;; Ensure weakly held items are not just equal to other references to it, but *identical*
(current-test-comparator eq?)

(test-group "Testing that basic weak pairs get their car reclaimed"
  (let* ((car (lambda (x) (##sys#slot x 0))) ; TODO: make list accessors work on weak pairs
	 (cadr (lambda (x) (car (##sys#slot x 1))))
	 (caddr (lambda (x) (car (##sys#slot (##sys#slot x 1) 1))))
	 (not-held-onto-value (vector 42))
	 (held-onto-vector (vector 'this-one-stays))
	 (weak-list (weak-cons not-held-onto-value
			       (weak-cons (vector 'ohai)
					  (weak-cons held-onto-vector '())))))

    ;; break other references to the values
    (set! not-held-onto-value #f)

    (gc #t)

    ;; First item is reclaimed
    (test-assert "first item of weak list is reclaimed" (not (vector? (car weak-list))))
    (test-assert "first item of weak list is set to the broken-weak-pointer object" (bwp-object? (car weak-list)))

    ;; Second item is reclaimed
    (test-assert "second item of weak list is reclaimed" (not (vector? (cadr weak-list))))
    (test-assert "second item of weak list is set to the broken-weak-pointer object" (bwp-object? (cadr weak-list)))

    ;; Third item stays
    (test-assert "third item of weak list is kept around due to other references existing" (vector? (caddr weak-list)))
    (test-equal "third item of weak list is identical to the other reference" (caddr weak-list) held-onto-vector)
    (test-assert "third item of weak list is not set to the broken-weak-pointer object" (not (bwp-object? (caddr weak-list))))))


(test-group "Testing cars of weak pairs referenced by their cdr do not get collected"
  (let* ((car (lambda (x) (##sys#slot x 0))) ; TODO: make list accessors work on weak pairs
	 (cdr (lambda (x) (##sys#slot x 1)))
	 (obj-a (vector 42))
	 (ref-a (weak-cons obj-a obj-a))
	 (obj-b (vector 'ohai))
	 (ref-b (weak-cons obj-b obj-b))
	 (held-onto-vector (vector 'this-one-stays)) ; should be held onto regardless of this, but here for consistency
	 (ref-c (weak-cons held-onto-vector held-onto-vector)))

    ;; break other references to the values
    (set! obj-a #f)
    (set! obj-b #f)

    (gc #t)

    (test-assert "object in first weak cons is still kept around in car" (vector? (car ref-a)))
    (test-assert "object in first weak cons is still kept around in cdr" (vector? (cdr ref-a)))
    (test-equal "object in first weak cons' car is identical to its cdr" (car ref-a) (cdr ref-a))
    (test-assert "car of first weak cons is not a broken weak pair" (not (bwp-object? (car ref-a))))
    (test-assert "cdr of first weak cons is not a broken weak pair" (not (bwp-object? (cdr ref-a))))

    (test-assert "object in second weak cons is still kept around in car" (vector? (car ref-b)))
    (test-assert "object in second weak cons is still kept around in cdr" (vector? (cdr ref-b)))
    (test-equal "object in second weak cons' car is identical to its cdr" (car ref-b) (cdr ref-b))
    (test-assert "car of second weak cons is not a broken weak pair" (not (bwp-object? (car ref-b))))
    (test-assert "cdr of second weak cons is not a broken weak pair" (not (bwp-object? (cdr ref-b))))

    (test-assert "object in third weak cons is still kept around in car" (vector? (car ref-c)))
    (test-assert "object in third weak cons is still kept around in cdr" (vector? (cdr ref-c)))
    (test-equal "object in third weak cons' car is identical to its cdr" (car ref-c) (cdr ref-c))
    (test-equal "object in third weak cons' car is identical to the other reference" (car ref-c) held-onto-vector)
    (test-assert "car of third weak cons is not a broken weak pair" (not (bwp-object? (car ref-c))))
    (test-assert "cdr of third weak cons is not a broken weak pair" (not (bwp-object? (cdr ref-c))))))

(test-exit)
