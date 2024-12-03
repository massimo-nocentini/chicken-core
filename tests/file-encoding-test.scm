(import (chicken io))
(import (only (scheme base) write-string))

(include "test.scm")

(define utf-file "i-dont-know-i-just-work-here.utf-8.txt")
(define latin-file "i-dont-know-i-just-work-here.latin-1.txt")

(test-begin "file encoding")

(define utf (with-input-from-file utf-file read-string #:unix))
(define latin (with-input-from-file latin-file read-string #:unix 'latin-1))

(test-equal "latin-1 decoded matches utf" latin utf)

(with-output-to-file "latin.out"
  (lambda () (write-string utf))
  #:unix 'latin-1)

(with-output-to-file "utf.out"
  (lambda () (write-string latin))
  #:unix)

(let ((a (with-input-from-file "latin.out" read-bytevector #:binary))
      (b (with-input-from-file latin-file read-bytevector #:binary)))
  (test-equal "latin-1 encoded matches original" a b))

(let ((a (with-input-from-file "utf.out" read-bytevector #:binary))
      (b (with-input-from-file utf-file read-bytevector #:binary)))
  (test-equal "utf-8 encoded matches original" a b))

(with-output-to-file "chars.out"
  (lambda ()
    (display "äöü")
    (write-char #\ß)
    (display #\á))
  #:unix 'latin-1)

(define in (open-input-file "chars.out" #:unix 'latin-1))

(test-equal "read latin-1 char" (read-char in) #\ä)
(test-equal "peek latin-1 char" (peek-char in) #\ö)

(test-equal "read remaining latin-1 chars" 
  (read-string #f in) "öüßá")

(test-end)
(test-exit)
