;; weak-pointer-test.scm

(import (chicken gc) (chicken port))

(include "test.scm")

;; Ensure weakly held items are not just equal to other references to it, but *identical*
(current-test-comparator eq?)

(test-group "Testing basic pair accessors work on weak pairs, too"
  (let ((my-proper-weak-list (weak-cons 1 (weak-cons 2 '())))
	(my-proper-list (cons 1 (cons 2 '())))
	(my-improper-weak-list (weak-cons 1 (weak-cons 2 3)))
	(my-improper-list (cons 1 (cons 2 3))))

    (test-assert "proper weak lists are pairs" (pair? my-proper-weak-list))
    (test-assert "improper weak lists are pairs" (pair? my-improper-weak-list))

    (test-assert "regular proper lists are not weak pairs" (not (weak-pair? my-proper-list)))
    (test-assert "regular improper lists are not weak pairs" (not (weak-pair? my-improper-list)))

    (test-assert "proper weak lists are lists" (list? my-proper-weak-list))
    (test-assert "improper weak lists are *not* lists" (not (list? my-improper-weak-list)))

    (test-equal "an weak proper list is equal to the same regular proper list" my-proper-weak-list my-proper-list equal?)
    (test-equal "an weak proper list is not *identical* to the same regular proper list" my-proper-weak-list my-proper-list (complement eq?))

    (test-equal "car of weak list returns the first item" (car my-proper-weak-list) 1)
    (test-equal "cdr of weak list returns the cdr" (cdr my-proper-weak-list) (cdr my-proper-list) equal?)
    (test-equal "cadr of weak list returns the second item" (cadr my-proper-weak-list) 2)
    (test-equal "cddr of weak list returns the cdr of the cdr" (cddr my-proper-weak-list) '())

    (test-equal "length of weak proper list returns the length" 2 (length my-proper-weak-list))
    (test-error "length of weak improper list raises an error" (length my-improper-weak-list))

    (let* ((written-proper-weak-list (with-output-to-string (lambda () (write my-proper-weak-list))))
	   (written-improper-weak-list (with-output-to-string (lambda () (write my-improper-weak-list))))
	   (reread-proper-weak-list (with-input-from-string written-proper-weak-list read))
	   (reread-improper-weak-list (with-input-from-string written-improper-weak-list read)))
      (test-equal "a proper weak list is written as a regular proper list" "(1 2)" written-proper-weak-list string=?)
      (test-equal "a proper weak list is read back as regular proper list" my-proper-list reread-proper-weak-list equal?)
      (test-equal "an improper weak list is written as a regular improper list" "(1 2 . 3)" written-improper-weak-list string=?)
      (test-equal "an improper weak list is read back as regular improper list" my-improper-list reread-improper-weak-list equal?))))

(test-group "Testing that basic weak pairs get their car reclaimed"
  (gc #t) ; Improve chances we don't get a minor GC in between
  (let* ((not-held-onto-value (vector 42))
	 (held-onto-vector (vector 'this-one-stays))

	 (weak-list (weak-cons not-held-onto-value
			       (weak-cons (vector 'ohai)
					  (weak-cons held-onto-vector '()))))
	 (weak-immediate-pair (weak-cons 1 2)))

    ;; break other references to the values
    (set! not-held-onto-value #f)

    (gc)

    ;; First item is reclaimed
    (test-assert "first item of weak list is reclaimed" (not (vector? (car weak-list))))
    (test-assert "first item of weak list is set to the broken-weak-pointer object" (bwp-object? (car weak-list)))

    ;; Second item is reclaimed
    (test-assert "second item of weak list is reclaimed" (not (vector? (cadr weak-list))))
    (test-assert "second item of weak list is set to the broken-weak-pointer object" (bwp-object? (cadr weak-list)))

    ;; Third item stays
    (test-assert "third item of weak list is kept around due to other references existing" (vector? (caddr weak-list)))
    (test-equal "third item of weak list is identical to the other reference" (caddr weak-list) held-onto-vector)
    (test-assert "third item of weak list is not set to the broken-weak-pointer object" (not (bwp-object? (caddr weak-list))))

    (test-equal "weak car is kept around when value is an immediate" (car weak-immediate-pair) 1)
    (test-equal "weak cdr is kept around when value is an immediate" (cdr weak-immediate-pair) 2)))


(test-group "Testing that weak pairs do not get broken when holding permanent symbols"
  (gc #t) ; Improve chances we don't get a minor GC in between

  ;; NOTE: When we don't use string-append here, the strings somehow get interned as (permanent) symbols?!
  ;; Perhaps this is somehow caused by the reader.
  (let* ((sym1 (string->symbol (string-append "something" "1234")))
	 (sym2 (string->symbol (string-append "another" "1234")))
	 (weak-permanent-symbol-pair (weak-cons 'scheme#car 'scheme#cdr))
	 (weak-impermanent-symbol-pair (weak-cons sym1 sym2)))

    (set! sym1 #f)
    (set! sym2 #f)

    (gc)

    (test-equal "weak car is kept around when value is a \"permanent\" symbol" (car weak-permanent-symbol-pair) 'scheme#car)
    (test-equal "weak cdr is kept around when value is a \"permanent\" symbol" (cdr weak-permanent-symbol-pair) 'scheme#cdr)

    (test-assert "weak car is reclaimed when value is an \"impermanent\" symbol" (not (symbol? (car weak-impermanent-symbol-pair))))
    (test-assert "weak car is reclaimed when value is an \"impermanent\" symbol" (bwp-object? (car weak-impermanent-symbol-pair)))
    (test-equal "weak cdr is kept around when value is a \"impermanent\" symbol" (cdr weak-impermanent-symbol-pair) (string->symbol (string-append "an" "other1234")))))


(test-group "Testing cars of weak pairs referenced by their cdr do not get collected"
  (gc #t) ; Improve chances we don't get a minor GC in between
  (let* ((obj-a (vector 42))
	 (ref-a (weak-cons obj-a obj-a))
	 (obj-b (vector 'ohai))
	 (ref-b (weak-cons obj-b obj-b))
	 (held-onto-vector (vector 'this-one-stays)) ; should be held onto regardless of this, but here for consistency
	 (ref-c (weak-cons held-onto-vector held-onto-vector)))

    ;; break other references to the values
    (set! obj-a #f)
    (set! obj-b #f)

    (gc)

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
