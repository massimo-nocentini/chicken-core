;;; data-structures.scm - Optional data structures extensions
;
; Copyright (c) 2008-2022, The CHICKEN Team
; All rights reserved.
;
; Redistribution and use in source and binary forms, with or without
; modification, are permitted provided that the following conditions
; are met:
;
;   Redistributions of source code must retain the above copyright notice, this list of conditions and the following
;     disclaimer.
;   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
;     disclaimer in the documentation and/or other materials provided with the distribution.
;   Neither the name of the author nor the names of its contributors may be used to endorse or promote
;     products derived from this software without specific prior written permission.
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
; AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
; CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
; OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
; POSSIBILITY OF SUCH DAMAGE.


(declare
 (unit data-structures))

(module chicken.string
  (conc ->string string-chop string-chomp
   string-compare3 string-compare3-ci
   reverse-list->string reverse-string-append
   string-intersperse string-split
   string-translate string-translate*
   substring=? substring-ci=?
   substring-index substring-index-ci)

(import scheme)
(import chicken.base)
(import chicken.condition)
(import chicken.fixnum)
(import chicken.foreign)
(import (only (scheme base) open-output-string get-output-string))

; (reverse-string-append l) = (apply string-append (reverse l))

(define (reverse-string-append l)
  (define (rev-string-append l i)
    (if (pair? l)
      (let* ((str (car l))
	     (len (string-length str))
	     (result (rev-string-append (cdr l) (fx+ i len))))
	(let loop ((j 0) (k (fx- (fx- (string-length result) i) len)))
	  (if (fx< j len)
	    (begin
	      (string-set! result k (string-ref str j))
	      (loop (fx+ j 1) (fx+ k 1)))
	    result)))
      (make-string i)))
  (rev-string-append l 0))

(define (reverse-list->string l)
  (##sys#reverse-list->string l))

;;; Anything->string conversion:

(define ->string
  (lambda (x)
    (cond [(string? x) x]
	  [(symbol? x) (symbol->string x)]
	  [(char? x) (string x)]
	  [(number? x) (##sys#number->string x)]
	  [else
	   (let ([o (open-output-string)])
	     (display x o)
	     (get-output-string o) ) ] ) ) )

(define conc
  (lambda args
    (apply string-append (map ->string args)) ) )


;;; Search one string inside another:

(let ()
  (define (traverse which where start test loc)
    (##sys#check-string which loc)
    (##sys#check-string where loc)
    (let* ((wherelen (string-length where))
           (whichlen (string-length which))
           (end (fx- wherelen whichlen)))
      (##sys#check-fixnum start loc)
      (if (and (fx>= start 0)
               (fx>= wherelen start))
          (if (fx= whichlen 0)
              start
              (and (fx>= end 0)
                   (let loop ((istart start))
                     (cond ((fx> istart end) #f)
                           ((test istart whichlen) istart)
                           (else (loop (fx+ istart 1)))))))
          (##sys#error-hook (foreign-value "C_OUT_OF_BOUNDS_ERROR" int)
                            loc
                            where
                            start))))

  (set! ##sys#substring-index
    (lambda (which where start)
      (traverse
       which where start
       (lambda (i l)
         (##core#inline "C_u_i_substring_equal_p" which where 0 i l))
       'substring-index) ) )
  (set! ##sys#substring-index-ci
    (lambda (which where start)
      (traverse
       which where start
       (lambda (i l) (##core#inline "C_u_i_substring_ci_equal_p" which where 0 i l))
       'substring-index-ci) ) ) )

(define (substring-index which where #!optional (start 0))
  (##sys#substring-index which where start) )

(define (substring-index-ci which where #!optional (start 0))
  (##sys#substring-index-ci which where start) )


;;; 3-Way string comparison:

(define (string-compare3 s1 s2)
  (##sys#check-string s1 'string-compare3)
  (##sys#check-string s2 'string-compare3)
  (let ((len1 (string-length s1))
	(len2 (string-length s2)) )
    (let* ((len-diff (fx- len1 len2))
	   (cmp (##core#inline "C_utf_compare" s1 s2 0 0
                        (if (fx< len-diff 0) len1 len2))))
      (if (fx= cmp 0)
	  len-diff
	  cmp))))

(define (string-compare3-ci s1 s2)
  (##sys#check-string s1 'string-compare3-ci)
  (##sys#check-string s2 'string-compare3-ci)
  (let ((len1 (string-length s1))
	(len2 (string-length s2)) )
    (let* ((len-diff (fx- len1 len2))
	   (cmp (##core#inline "C_utf_compare_ci"
                        s1 s2 0 0
                        (if (fx< len-diff 0) len1 len2))))
      (if (fx= cmp 0)
	  len-diff
	  cmp))))


;;; Substring comparison:

(define (##sys#substring=? s1 s2 start1 start2 n)
  (##sys#check-string s1 'substring=?)
  (##sys#check-string s2 'substring=?)
  (##sys#check-fixnum start1 'substring=?)
  (##sys#check-fixnum start2 'substring=?)
  (let* ((l1 (string-length s1))
         (l2 (string-length s2))
         (maxlen (fxmin (fx- l1 start1)
	                (fx- l2 start2) ) )
         (len (if n
                  (begin (##sys#check-range n 0 (fx+ maxlen 1) 'substring=?) n)
                  maxlen)))
    (##sys#check-range start1 0 (fx+ l1 1) 'substring=?)
    (##sys#check-range start2 0 (fx+ l2 1) 'substring=?)
    (##core#inline "C_u_i_substring_equal_p" s1 s2 start1 start2 len) ) )

(define (substring=? s1 s2 #!optional (start1 0) (start2 0) len)
  (##sys#substring=? s1 s2 start1 start2 len) )

(define (##sys#substring-ci=? s1 s2 start1 start2 n)
  (##sys#check-string s1 'substring-ci=?)
  (##sys#check-string s2 'substring-ci=?)
  (##sys#check-fixnum start1 'substring-ci=?)
  (##sys#check-fixnum start2 'substring-ci=?)
  (let* ((l1 (string-length s1))
         (l2 (string-length s2))
         (maxlen (fxmin (fx- l1 start1)
		        (fx- l2 start2) ) )
         (len (if n
                  (begin (##sys#check-range n 0 (fx+ maxlen 1) 'substring-ci=?) n)
                  maxlen)))
    (##sys#check-range start1 0 (fx+ l1 1) 'substring=?)
    (##sys#check-range start2 0 (fx+ l2 1) 'substring=?)
    (##core#inline "C_u_i_substring_ci_equal_p" s1 s2 start1 start2 len) ) )

(define (substring-ci=? s1 s2 #!optional (start1 0) (start2 0) len)
  (##sys#substring-ci=? s1 s2 start1 start2 len) )


;;; Split string into substrings:

(define string-split
  (lambda (str . delstr-and-flag)
    (##sys#check-string str 'string-split)
    (let* ([del (if (null? delstr-and-flag) "\t\n " (car delstr-and-flag))]
	   [flag (if (fx= (length delstr-and-flag) 2) (cadr delstr-and-flag) #f)]
	   [strlen (string-length str)] )
      (##sys#check-string del 'string-split)
      (let ([dellen (string-length del)]
	    [first #f] )
	(define (add from to last)
	  (let ([node (cons (##sys#substring str from to) '())])
	    (if first
		(##sys#setslot last 1 node)
		(set! first node) )
	    node) )
	(let loop ([i 0] [last #f] [from 0])
	  (cond [(fx>= i strlen)
		 (when (or (fx> i from) flag) (add from i last))
		 (or first '()) ]
		[else
		 (let ([c (string-ref str i)])
		   (let scan ([j 0])
		     (cond [(fx>= j dellen) (loop (fx+ i 1) last from)]
			   [(eq? c (string-ref del j))
			    (let ([i2 (fx+ i 1)])
			      (if (or (fx> i from) flag)
				  (loop i2 (add from i last) i2)
				  (loop i2 last i2) ) ) ]
			   [else (scan (fx+ j 1))] ) ) ) ] ) ) ) ) ) )


;;; Concatenate list of strings:

(define (string-intersperse strs #!optional (ds " "))
  (##sys#check-list strs 'string-intersperse)
  (##sys#check-string ds 'string-intersperse)
  (let* ((dsbv (##sys#slot ds 0))
         (dslen (fx- (##sys#size dsbv) 1)))
    (let loop1 ((ss strs) (n 0))
      (cond ((##core#inline "C_eqp" ss '())
	     (if (##core#inline "C_eqp" strs '())
		 ""
		 (let* ((bytes (fx- n dslen))
                        (bv (##sys#allocate-bytevector (fx+ bytes 1) 0)))
		   (let loop2 ((ss2 strs) (n2 0))
		     (let* ((stri (##sys#slot ss2 0))
			    (next (##sys#slot ss2 1))
                            (bvi (##sys#slot stri 0))
			    (count (fx- (##sys#size bvi) 1)))
		       (##core#inline "C_copy_memory_with_offset" bv bvi n2 0 count)
		       (let ((n3 (fx+ n2 count)))
			 (if (##core#inline "C_eqp" next '())
                             (##core#inline_allocate ("C_a_ustring" 5) bv
                                                     (##core#inline "C_utf_range_length"
                                                                    bv 0 n3))

                     			     (begin
			       (##core#inline "C_copy_memory_with_offset"
                                              bv dsbv n3 0 dslen)
			       (loop2 next (fx+ n3 dslen)) ) ) ) ) ) ) ) )
	    ((and (##core#inline "C_blockp" ss) (##core#inline "C_pairp" ss))
	     (let ((stri (##sys#slot ss 0)))
	       (##sys#check-string stri 'string-intersperse)
	       (loop1 (##sys#slot ss 1)
		      (fx+ (fx- (##sys#size (##sys#slot stri 0)) 1)
                           (fx+ dslen n)) ) ) )
	    (else (##sys#error-not-a-proper-list strs)) ) ) ) )


;;; Translate elements of a string:

(define string-translate
  (lambda (str from . to)
    (define (instring s)
      (let ([len (string-length s)])
	(lambda (c)
	  (let loop ([i 0])
	    (cond [(fx>= i len) #f]
		  [(eq? c (string-ref s i)) i]
		  [else (loop (fx+ i 1))] ) ) ) ) )
    (let* ([from
	    (cond [(char? from) (lambda (c) (eq? c from))]
		  [(pair? from) (instring (list->string from))]
		  [else
		   (##sys#check-string from 'string-translate)
		   (instring from) ] ) ]
	   [to
	    (and (pair? to)
		 (let ([tx (##sys#slot to 0)])
		   (cond [(char? tx) tx]
			 [(pair? tx) (list->string tx)]
			 [else
			  (##sys#check-string tx 'string-translate)
			  tx] ) ) ) ]
	   [tlen (and (string? to) (string-length to))] )
      (##sys#check-string str 'string-translate)
      (let* ([slen (string-length str)]
	     [str2 (make-string slen)] )
	(let loop ([i 0] [j 0])
	  (if (fx>= i slen)
	      (if (fx< j i)
		  (##sys#substring str2 0 j)
		  str2)
	      (let* ([ci (string-ref str i)]
		     [found (from ci)] )
		(cond [(not found)
		       (string-set! str2 j ci)
		       (loop (fx+ i 1) (fx+ j 1)) ]
		      [(not to) (loop (fx+ i 1) j)]
		      [(char? to)
		       (string-set! str2 j to)
		       (loop (fx+ i 1) (fx+ j 1)) ]
		      [(fx>= found tlen)
		       (##sys#error 'string-translate "invalid translation destination" i to) ]
		      [else
		       (string-set! str2 j (string-ref to found))
		       (loop (fx+ i 1) (fx+ j 1)) ] ) ) ) ) ) ) ) )

(define (fragments->string total fs)
  (let ((dest (##sys#make-bytevector (fx+ total 1))))
    (let loop ((fs fs) (pos 0))
      (if (null? fs)
	  (##core#inline_allocate ("C_a_ustring" 5) dest
                           (##core#inline "C_utf_length" dest))
	  (let* ((f (##sys#slot fs 0))
		 (flen (fx- (##sys#size f) 1)))
	    (##core#inline "C_copy_memory_with_offset" dest f pos 0 flen)
	    (loop (##sys#slot fs 1) (fx+ pos flen)) ) ) ) ) )

(define (string-translate* str smap)
  (##sys#check-string str 'string-translate*)
  (##sys#check-list smap 'string-translate*)
  (let ((len (string-length str)))
    (define (collect i from total fs)
      (if (fx>= i len)
	  (begin
            (when (fx> i from)
              (let ((bv (##sys#slot (##sys#substring str from i) 0)))
                (set! fs (cons bv fs))
                (set! total (fx+ total (fx- (##sys#size bv) 1)))))
  	    (fragments->string total (##sys#fast-reverse fs)))
	  (let loop ((smap smap))
	    (if (null? smap)
		(collect (fx+ i 1) from total fs)
		(let* ((p (car smap))
		       (sm (car p))
		       (smlen (string-length sm))
		       (st (cdr p)) )
		  (if (and (fx<= (fx+ i smlen) len)
			   (##core#inline "C_u_i_substring_equal_p" str sm i 0 smlen))
		      (let ((i2 (fx+ i smlen))
                            (stbv (##sys#slot st 0)))
			(when (fx> i from)
                          (let ((bv (##sys#slot (##sys#substring str from i) 0)))
                            (set! fs (cons bv fs))
                            (set! total (fx+ total (fx- (##sys#size bv) 1)))))
			(collect
			 i2 i2
			 (fx+ total (fx- (##sys#size stbv) 1))
			 (cons stbv fs) ) )
		      (loop (cdr smap)) ) ) ) ) ) )
    (collect 0 0 0 '()) ) )


;;; Chop string into substrings:

(define (string-chop str len)
  (##sys#check-string str 'string-chop)
  (##sys#check-fixnum len 'string-chop)
  (let ([total (string-length str)])
    (let loop ([total total] [pos 0])
      (cond [(fx<= total 0) '()]
	    [(fx<= total len) (list (##sys#substring str pos (fx+ pos total)))]
	    [else (cons (##sys#substring str pos (fx+ pos len)) (loop (fx- total len) (fx+ pos len)))] ) ) ) )


;;; Remove suffix

(define (string-chomp str #!optional (suffix "\n"))
  (##sys#check-string str 'string-chomp)
  (##sys#check-string suffix 'string-chomp)
  (let* ((len (string-length str))
	 (slen (string-length suffix))
	 (diff (fx- len slen)) )
    (if (and (fx>= len slen)
	     (##core#inline "C_u_i_substring_equal_p" str suffix diff 0 slen) )
	(##sys#substring str 0 diff)
	str) ) )

) ; chicken.string


(module chicken.sort
    (merge merge! sort sort! sorted? topological-sort)

(import scheme chicken.base chicken.condition chicken.fixnum)

;;; Defines: sorted?, merge, merge!, sort, sort!
;;; Author : Richard A. O'Keefe (based on Prolog code by D.H.D.Warren)
;;;
;;; This code is in the public domain.

;;; Updated: 11 June 1991
;;; Modified for scheme library: Aubrey Jaffer 19 Sept. 1991
;;; Updated: 19 June 1995

;;; (sorted? sequence less?)
;;; is true when sequence is a list (x0 x1 ... xm) or a vector #(x0 ... xm)
;;; such that for all 1 <= i <= m,
;;;	(not (less? (list-ref list i) (list-ref list (- i 1)))).

; Modified by flw for use with CHICKEN:
;


(define (sorted? seq less?)
    (cond
	((null? seq)
	    #t)
	((vector? seq)
	    (let ((n (vector-length seq)))
		(if (<= n 1)
		    #t
		    (do ((i 1 (+ i 1)))
			((or (= i n)
			     (less? (vector-ref seq i)
				    (vector-ref seq (- i 1))))
			    (= i n)) )) ))
	(else
	    (let loop ((last (car seq)) (next (cdr seq)))
		(or (null? next)
		    (and (not (less? (car next) last))
			 (loop (car next) (cdr next)) )) )) ))


;;; (merge a b less?)
;;; takes two lists a and b such that (sorted? a less?) and (sorted? b less?)
;;; and returns a new list in which the elements of a and b have been stably
;;; interleaved so that (sorted? (merge a b less?) less?).
;;; Note:  this does _not_ accept vectors.  See below.

(define (merge a b less?)
    (cond
	((null? a) b)
	((null? b) a)
	(else (let loop ((x (car a)) (a (cdr a)) (y (car b)) (b (cdr b)))
	    ;; The loop handles the merging of non-empty lists.	 It has
	    ;; been written this way to save testing and car/cdring.
	    (if (less? y x)
		(if (null? b)
		    (cons y (cons x a))
		    (cons y (loop x a (car b) (cdr b)) ))
		;; x <= y
		(if (null? a)
		    (cons x (cons y b))
		    (cons x (loop (car a) (cdr a) y b)) )) )) ))


;;; (merge! a b less?)
;;; takes two sorted lists a and b and smashes their cdr fields to form a
;;; single sorted list including the elements of both.
;;; Note:  this does _not_ accept vectors.

(define (merge! a b less?)
    (define (loop r a b)
	(if (less? (car b) (car a))
	    (begin
		(set-cdr! r b)
		(if (null? (cdr b))
		    (set-cdr! b a)
		    (loop b a (cdr b)) ))
	    ;; (car a) <= (car b)
	    (begin
		(set-cdr! r a)
		(if (null? (cdr a))
		    (set-cdr! a b)
		    (loop a (cdr a) b)) )) )
    (cond
	((null? a) b)
	((null? b) a)
	((less? (car b) (car a))
	    (if (null? (cdr b))
		(set-cdr! b a)
		(loop b a (cdr b)))
	    b)
	(else ; (car a) <= (car b)
	    (if (null? (cdr a))
		(set-cdr! a b)
		(loop a (cdr a) b))
	    a)))


;;; (sort! sequence less?)
;;; sorts the list or vector sequence destructively.  It uses a version
;;; of merge-sort invented, to the best of my knowledge, by David H. D.
;;; Warren, and first used in the DEC-10 Prolog system.	 R. A. O'Keefe
;;; adapted it to work destructively in Scheme.

(define (sort! seq less?)
    (define (step n)
	(cond
	    ((> n 2)
		(let* ((j (quotient n 2))
		       (a (step j))
		       (k (- n j))
		       (b (step k)))
		    (merge! a b less?)))
	    ((= n 2)
		(let ((x (car seq))
		      (y (cadr seq))
		      (p seq))
		    (set! seq (cddr seq))
		    (if (less? y x) (begin
			(set-car! p y)
			(set-car! (cdr p) x)))
		    (set-cdr! (cdr p) '())
		    p))
	    ((= n 1)
		(let ((p seq))
		    (set! seq (cdr seq))
		    (set-cdr! p '())
		    p))
	    (else
		'()) ))
    (if (vector? seq)
	(let ((n (vector-length seq))
	      (vec seq))
	  (set! seq (vector->list seq))
	  (do ((p (step n) (cdr p))
	       (i 0 (+ i 1)))
	      ((null? p) vec)
	    (vector-set! vec i (car p)) ))
	;; otherwise, assume it is a list
	(step (length seq)) ))

;;; (sort sequence less?)
;;; sorts a vector or list non-destructively.  It does this by sorting a
;;; copy of the sequence.  My understanding is that the Standard says
;;; that the result of append is always "newly allocated" except for
;;; sharing structure with "the last argument", so (append x '()) ought
;;; to be a standard way of copying a list x.

(define (sort seq less?)
    (if (vector? seq)
	(list->vector (sort! (vector->list seq) less?))
	(sort! (append seq '()) less?)))


;;; Topological sort with cycle detection:
;;
;; A functional implementation of the algorithm described in Cormen,
;; et al. (2009), Introduction to Algorithms (3rd ed.), pp. 612-615.

(define (topological-sort dag pred)
  (define (visit dag node edges path state)
    (case (alist-ref node (car state) pred)
      ((grey)
       (abort
        (##sys#make-structure
         'condition
         '(exn runtime cycle)
         `((exn . message) "cycle detected"
           (exn . arguments) ,(list (cons node (reverse path)))
           (exn . call-chain) ,(get-call-chain)
           (exn . location) topological-sort))))
      ((black)
       state)
      (else
       (let walk ((edges (or edges (alist-ref node dag pred '())))
                  (state (cons (cons (cons node 'grey) (car state))
                               (cdr state))))
         (if (null? edges)
             (cons (alist-update! node 'black (car state) pred)
                   (cons node (cdr state)))
             (let ((edge (car edges)))
               (walk (cdr edges)
                     (visit dag
                            edge
                            #f
                            (cons edge path)
                            state))))))))
  (define normalized-dag
    (foldl (lambda (result node)
             (alist-update! (car node)
                            (append (cdr node)
                                    (or (alist-ref (car node) dag pred) '()))
                            result
                            pred))
           '()
           dag))
  (let loop ((dag normalized-dag)
             (state (cons (list) (list))))
    (if (null? dag)
        (cdr state)
        (loop (cdr dag)
              (visit dag
                     (caar dag)
                     (cdar dag)
                     '()
                     state)))))
) ; chicken.sort

