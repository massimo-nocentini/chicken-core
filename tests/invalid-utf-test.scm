;;; ensure invalid UTF-8 sequences are reproducibly read and written

(import (chicken io) (chicken irregex) (chicken file))
(import (chicken bytevector) (chicken file posix))

(define in "UTF-8-test.txt")
(define out "UTF-8-test.out")

(when (file-exists? out) (delete-file out))

(with-input-from-file in
  (lambda ()
    (call-with-output-file out
      (lambda (o)
        (let loop ()
          (let ((line (read-line)))
            (unless (eof-object? line)
              (display line o)
              (newline o)
              (loop)))))
      #:unix))
  #:unix)

(define sz (file-size in))

;(assert (= sz (file-size out)))
(let ((old (with-input-from-file in (cut read-bytevector sz) #:binary))
      (new (with-input-from-file out (cut read-bytevector sz) #:binary)))
  (assert (bytevector=? old new)))
