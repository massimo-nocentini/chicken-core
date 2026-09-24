;;;; utf-string-set-tests.scm
;
; Growing a string in place by storing multibyte characters into it.
;
; `string-set!' of a character whose UTF-8 encoding is longer than the one
; it replaces (e.g. #\μ over #\space) cannot update the string's byte
; buffer in place: C_utf_setsubchar allocates a larger buffer in scratch
; space.  When the old buffer is itself in scratch space (because an
; earlier `string-set!' grew it), the allocation may resize the scratch
; space, which moves every registered scratch object and frees the old
; area.  C_utf_setsubchar used to unregister the old buffer *before*
; allocating and then copied from its stale address, i.e. from freed
; memory, so the head of the string came out as garbage (typically NUL
; bytes).  C_utf_overwrite (used by `read-string!') had the same pattern.
;
; This showed up as NUL runs in `pretty-print' output written to a file
; for data with non-ASCII symbols (pp builds lines with
; `reverse-string-append', which fills a `make-string' result with
; `string-set!'), and therefore as corrupted *.import.scm files for
; modules exporting non-ASCII names.

(import (chicken string) (chicken pretty-print) (chicken file)
        (chicken io) (chicken port) (chicken bytevector))

(define (iota* n)
  (let loop ((i (- n 1)) (acc '()))
    (if (< i 0) acc (loop (- i 1) (cons i acc)))))

(define (fill-and-check n ch)
  (let ((s (make-string n #\a)))
    (do ((i 0 (+ i 1))) ((= i n))
      (string-set! s i ch))
    (do ((i 0 (+ i 1))) ((= i n))
      (assert (char=? (string-ref s i) ch)
              "string-set! lost a character" n i (string-ref s i)))
    (assert (= (bytevector-length (string->utf8 s))
               (* n (bytevector-length (string->utf8 (string ch))))))))

(for-each (lambda (n)
            (fill-and-check n #\μ)       ; 2 bytes
            (fill-and-check n #\x20ac)   ; 3 bytes
            (fill-and-check n #\x1f600)) ; 4 bytes
          '(1 10 100 1000 3000 10000))

;; reverse-string-append builds its result with make-string + string-set!
(let* ((parts (map (lambda (i) (conc "μkanren-" i " ")) (iota* 500)))
       (expected (apply string-append (reverse parts))))
  (assert (string=? (reverse-string-append parts) expected)))

;; The original report: pretty-print of non-ASCII symbols to a file.
(define data
  (list 'register
        (map (lambda (i)
               (let ((n (string->symbol (conc "μkanren-state-f" i))))
                 (cons n (string->symbol (conc "aux.kanren.micro#" n)))))
             (iota* 60))))

(define file "utf-string-set-tests.out")

(with-output-to-file file (lambda () (pretty-print data)))

(let ((from-file (with-input-from-file file read-string))
      (from-string (with-output-to-string (lambda () (pretty-print data)))))
  (delete-file file)
  (assert (not (substring-index (string #\nul) from-file))
          "NUL byte in pretty-print output")
  (assert (string=? from-file from-string))
  (assert (equal? (with-input-from-string from-file read) data)))

(print "utf string-set! tests passed")
