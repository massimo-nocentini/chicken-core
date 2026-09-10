(import chicken.condition chicken.file chicken.file.posix
	chicken.flonum chicken.format chicken.io chicken.port
        chicken.bytevector chicken.string
	chicken.process chicken.process.signal chicken.tcp chicken.number-vector)

(import (only (scheme base) input-port-open? output-port-open? open-input-string
              write-string open-output-string get-output-string
              flush-output-port peek-u8 u8-ready? read-u8 write-u8))

(include "test.scm")
(test-begin "ports")

(define-syntax assert-error
  (syntax-rules ()
    ((_ expr)
     (assert (handle-exceptions _ #t expr #f)))))

(define *text* #<<EOF
this is a test
<foof> #;33> (let ((in (open-input-string ""))) (close-input-port in)
       (read-char in)) [09:40]
<foof> Error: (read-char) port already closed: #<input port "(string)">
<foof> #;33> (let ((in (open-input-string ""))) (close-input-port in)
       (read-line in))
<foof> Error: call of non-procedure: #t
<foof> ... that's a little odd
<Bunny351> yuck. [09:44]
<Bunny351> double yuck. [10:00]
<sjamaan> yuck squared! [10:01]
<Bunny351> yuck powered by yuck
<Bunny351> (to the power of yuck, of course) [10:02]
<pbusser3> My yuck is bigger than yours!!!
<foof> yuck!
<foof> (that's a factorial)
<sjamaan> heh
<sjamaan> I think you outyucked us all [10:03]
<foof> well, for large enough values of yuck, yuck! ~= yuck^yuck [10:04]
ERC>
EOF
)

(define p (open-input-string *text*))

(assert (string=? "this is a test" (read-line p)))

(assert
 (string=?
  "<foof> #;33> (let ((in (open-input-string \"\"))) (close-input-port in)"
  (read-line p)))
(assert (= 20 (length (read-lines (open-input-string *text*)))))

(assert (char-ready? (open-input-string "")))

(let ((out (open-output-string)))
  (test-equal "Initially, output string is empty"
              (get-output-string out) "")
  (display "foo" out)
  (test-equal "output can be extracted from output string"
              (get-output-string out) "foo")
  (close-output-port out)
  (test-equal "closing a string output port has no effect on the returned data"
              (get-output-string out) "foo")
  (test-error "writing to a closed string output port is an error"
              (display "bar" out)))

;;; copy-port

(assert
 (string=?
  *text*
  (with-output-to-string
    (lambda ()
      (copy-port (open-input-string *text*) (current-output-port)))))) ; read-char -> write-char

(assert
 (equal?
  '(3 2 1)
  (let ((out '()))
    (copy-port				; read -> custom
     (open-input-string "1 2 3")
     #f
     read
     (lambda (x port) (set! out (cons x out))))
    out)))

(assert
 (equal?
  "abc"
  (let ((out (open-output-string)))
    (copy-port				; read-char -> custom
     (open-input-string "abc")
     out
     read-char
     (lambda (x out) (write-char x out)))
    (get-output-string out))))

(assert
 (equal?
  "abc"
  (let ((in (open-input-string "abc") )
	(out (open-output-string)))
    (copy-port				; custom -> write-char
     in out
     (lambda (in) (read-char in)))
    (get-output-string out))))

;; {input,output}-port-open?

(assert (input-port-open? (open-input-string "abc")))
(assert (output-port-open? (open-output-string)))
(assert-error (input-port-open? (open-output-string)))
(assert-error (output-port-open? (open-input-string "abc")))

;; direction-specific port closure

(let* ((n 0)
       (p (make-input-port (constantly #\a)
			   (constantly #t)
			   (lambda () (set! n (add1 n))))))
  (close-output-port p)
  (assert (input-port-open? p))
  (assert (= n 0))
  (close-input-port p)
  (assert (not (input-port-open? p)))
  (assert (= n 1))
  (close-input-port p)
  (assert (not (input-port-open? p)))
  (assert (= n 1)))

(let* ((n 0)
       (p (make-output-port (lambda () (display #\a))
			    (lambda () (set! n (add1 n))))))
  (close-input-port p)
  (assert (output-port-open? p))
  (assert (= n 0))
  (close-output-port p)
  (assert (not (output-port-open? p)))
  (assert (= n 1))
  (close-output-port p)
  (assert (not (output-port-open? p)))
  (assert (= n 1)))

;; bidirectional ports

(let* ((b (string))
       (w (lambda (s)
	    (set! b (string-append b s))))
       (e (lambda ()
	    (positive? (string-length b))))
       (r (lambda ()
	    (let ((s b))
	      (set! b (substring s 1))
	      (string-ref s 0))))
       (i (make-input-port r e void))
       (o (make-output-port w void))
       (p (make-bidirectional-port i o)))
  (assert (input-port? p))
  (assert (output-port? p))
  (assert (input-port-open? p))
  (assert (output-port-open? p))
  (display "quartz ruby" p)
  (newline p)
  (assert (equal? (read p) 'quartz))
  (assert (equal? (read i) 'ruby))
  (display "emerald topaz" p)
  (newline p)
  (close-output-port p)
  (assert (not (output-port-open? o)))
  (assert (not (output-port-open? p)))
  (assert (equal? (read p) 'emerald))
  (assert (equal? (read i) 'topaz))
  (close-input-port p)
  (assert (not (input-port-open? i)))
  (assert (not (input-port-open? p))))

;; fill buffers
(with-input-from-file "compiler.scm" read-string)

(print "slow...")
(time
 (with-input-from-file "compiler.scm"
   (lambda ()
     (with-output-to-file "compiler.scm.2"
       (lambda ()
	 (copy-port
	  (current-input-port) (current-output-port)
	  (lambda (port) (read-char port))
	  (lambda (x port) (write-char x port))))))))

(print "fast...")
(time
 (with-input-from-file "compiler.scm"
   (lambda ()
     (with-output-to-file "compiler.scm.2"
       (lambda ()
	 (copy-port (current-input-port) (current-output-port)))))))

(delete-file "compiler.scm.2")

(define-syntax check
  (syntax-rules ()
    ((_ (expr-head expr-rest ...))
     (check 'expr-head (expr-head expr-rest ...)))
    ((_ name expr)
     (let ((okay (list 'okay)))
       (assert
        (eq? okay
             (condition-case
                 (begin (print* name "...")
                        (flush-output)
                        (let ((output expr))
                          (printf "FAIL [ ~S ]\n" output)))
               ((exn i/o file) (printf "OK\n") okay))))))))

(cond-expand
  ((not windows)

   (define proc (process-fork (lambda () (tcp-accept (tcp-listen 8080)))))

   (on-exit (lambda () (handle-exceptions exn #f (process-signal proc))))

   (print "\n\nProcedures check on TCP ports being closed\n")

   (receive (in out)
       (let lp ()
	 (condition-case (tcp-connect "localhost" 8080)
	   ((exn i/o net) (lp))))
     (close-output-port out)
     (close-input-port in)
     (check (tcp-addresses in))
     (check (tcp-port-numbers in))
     (check (tcp-abandon-port in)))	; Not sure about abandon-port


   ;; This tests for two bugs which occurred on NetBSD and possibly
   ;; other platforms, possibly due to multiprocessing:
   ;; read-line with EINTR would loop endlessly and process-wait would
   ;; signal a condition when interrupted rather than retrying.
   (set-signal-handler! signal/chld void) ; Should be a noop but triggers EINTR
   (receive (in out)
     (create-pipe)
     (receive (pid ok? status)
       (process-wait
        (process-fork
         (lambda ()
           (file-close in)              ; close receiving end
           (with-output-to-port (open-output-file* out)
             (lambda ()
               (display "hello, world\n")
               ;; exit prevents buffers from being discarded by implicit _exit
               (exit 0))))))
       (file-close out)                 ; close sending end
       (assert (equal? '(#t 0 ("hello, world"))
                       (list ok? status (read-lines (open-input-file* in)))))))
   )
  (else))

(print "\n\nProcedures check on output ports being closed\n")

(with-output-to-file "empty-file" void)

(call-with-output-file "empty-file"
  (lambda (out)
    (close-output-port out)
    (check (write '(foo) out))
    (check (fprintf out "blabla"))
    (check "print-call-chain" (begin (print-call-chain out) (void)))
    (check (print-error-message (make-property-condition 'exn 'message "foo") out))
    (check "print" (with-output-to-port out
		     (lambda () (print "foo"))))
    (check "print*" (with-output-to-port out
		      (lambda () (print* "foo"))))
    (check (display "foo" out))
    (check (terminal-port? out))   ; Calls isatty() on C_SCHEME_FALSE?
    (check (newline out))
    (check (write-char #\x out))
    (check (write-line "foo" out))
    (check (write-bytevector '#u8(1 2 3) out))
    ;;(check (port->fileno in))
    (check (flush-output out))

    (check (write-byte 120 out))
    (check (write-string "foo" out))))


(print "\n\nProcedures check on input ports being closed\n")
(call-with-input-file "empty-file"
  (lambda (in)
    (close-input-port in)
    (check (read in))
    (check (read-char in))
    (check (char-ready? in))
    (check (peek-char in))
    ;;(check (port->fileno in))
    (check (terminal-port? in))	   ; Calls isatty() on C_SCHEME_FALSE?
    (check (read-line in 5))
    (check (read-bytevector 5 in))
    (check "read-bytevector!" (let ((dest (make-u8vector 5)))
                              (read-bytevector! dest in 0 5)))

    (check (read-byte in))
    (check (read-token (constantly #t) in))
    (check (read-string 10 in))
    (check "read-string!" (let ((buf (make-string 10)))
                            (read-string! 10 buf in) buf))))

(print "\nEmbedded NUL bytes in filenames are rejected\n")
(assert-error (with-output-to-file "embedded\x00;null-byte" void))

;;; #978 -- port-position checks for read-line

(define (read-line/pos p limit)  ;; common
  (let ((s (read-line p limit)))
    (let-values (((row col) (port-position p)))
      (list s row col))))

(define (read-string-line/pos str limit)
  (read-line/pos (open-input-string str) limit))

(define (read-process-line/pos cmd args limit)
  (let-values (((i o pid) (process cmd args)))
    (let ((rc (read-line/pos i limit)))
      (close-input-port i)
      (close-output-port o)
      rc)))
(define (read-echo-line/pos str limit)
  (read-process-line/pos "echo" (list "-n" str) limit))

(define (test-port-position proc)
  (test-equal "advance row when encountering delim"
	      (proc "abcde\nfghi" 6)
	      '("abcde" 2 0))
  (test-equal "reaching limit sets col to limit, and does not advance row"
	      (proc "abcdefghi" 6)
	      '("abcdef" 1 6))
  (test-equal "delimiter counted in limit" ;; observed behavior, strange
	      (proc "abcdef\nghi" 6)
	      '("abcdef" 1 6))
  (test-equal "EOF reached"
	      (proc "abcde" 6)
	      '("abcde" 1 5)))

(test-group
 "read-line string port position tests"
 (test-port-position read-string-line/pos))

;; TODO: include the other documented keyword arguments:
;;       #:peek-u8 #:peek-char and #:read-line
(test-group "make[-binary]-input-port callbacks"
  (let ()

    (define (test-sequence in)
      (test-equal "read-char"        (read-char in)         #\1)
      (test-equal "read-string"      (read-string 2 in)     "23")
      (test-equal "read-char again"  (read-char in)         #\4)
      (test-equal "read-bytevector"  (read-bytevector 2 in) #u8("56"))
      (test-equal "read-string "     (read-string 2 in)     "78")
      (test-equal "read-string"      (read-string #f in)    "90"))

    (test-group "make-input-port read sequences"
     (test-sequence
      (let* ((p (open-input-string "1234567890")))
        (make-input-port
         (lambda () (read-char p))
         (lambda () (char-ready? p))
         (lambda () (close-input-port p))
         #:peek-u8 #f
         #:read-bytevector
         (lambda (bv start end)
           (read-bytevector! bv p start end))))))

    (test-group "make-binary-input-port read sequences"
     (test-sequence
      (let* ((p (open-input-string "1234567890")))
        (make-binary-input-port
         (lambda () (read-u8 p))
         (lambda () (char-ready? p))
         (lambda () (close-input-port p))
         #:peek-u8 #f
         #:read-bytevector
         (lambda (bv start end)
           (read-bytevector! bv p start end))))))))

(test-group "read-string!"
  (let ((in (open-input-string "1234567890"))
        (buf (make-string 5)))
    (test-equal "peek-char won't influence the result of read-string!"
                (peek-char in)
                #\1)
    (test-equal "read-string! won't read past buffer if given #f"
                (read-string! #f buf in)
                5)
    (test-equal "read-string! reads the requested bytes with #f"
                buf
                "12345")
    (test-equal "read-string! won't read past buffer if given #f and offset"
                (read-string! #f buf in 3)
                2)
    (test-equal "read-string! reads the requested bytes with #f and offset"
                buf
                "12367")
    (test-equal "read-string! reads until the end correctly"
                (read-string! #f buf in)
                3)
    (test-equal "read-string! leaves the buffer's tail intact"
                buf
                "89067")
    (test-equal "after peek-char at EOF, read-string! doesn't mutate the buffer"
                (begin (peek-char in)
                       (read-string! #f buf in)
                       buf)
                "89067"))
  (let ((in (open-input-string "1234567890"))
        (buf (make-string 5)))
    (test-equal "read-string! won't read past buffer if given size"
                (read-string! 10 buf in)
                5)
    (test-equal "read-string! reads the requested bytes with buffer size"
                buf
                "12345")
    (test-equal "read-string! won't read past buffer if given size and offset"
                (read-string! 10 buf in 3)
                2)
    (test-equal "read-string! reads the requested bytes with buffer size and offset"
                buf
                "12367")
    (test-equal "read-string! reads until the end correctly with buffer size"
                (read-string! 10 buf in)
                3)
    (test-equal "read-string! leaves the buffer's tail intact"
                buf
                "89067")
    (test-equal "read-string! at EOF reads nothing"
                (read-string! 10 buf in)
                0)
    (test-equal "read-string! at EOF doesn't mutate the buffer"
                buf
                "89067")))

(test-group "line endings"
  (let ((s "foo\nbar\rbaz\r\nqux")
	(f (lambda ()
	     (test-equal "\\n" (read-line) "foo")
	     (test-equal "\\r" (read-line) "bar")
	     (test-equal "\\r\\n" (read-line) "baz")
	     (test-equal "eof" (read-line) "qux"))))
    (test-group "string port"
      (with-input-from-string s f))
    (test-group "file port"
      (let ((file "mixed-line-endings"))
	(with-output-to-file file (lambda () (display s)))
	(with-input-from-file file f)
	(delete-file* file)))
    (test-group "custom port"
      (let* ((p (open-input-string s))
	     (p* (make-input-port (lambda () (read-char p))
				  (lambda () (char-ready? p))
				  (lambda () (close-input-port p)))))
	(with-input-from-port p* f)))))

;;; ##sys#scan-buffer-line: terminators at and across buffer boundaries.
;;;
;;; This is the scanner behind read-line for string ports (library.scm),
;;; fd and process ports (posixunix.scm) and TCP ports (tcp.scm); the
;;; buffered file ports go through fast_read_line_from_file in C instead,
;;; so they do not exercise it.

;; Bounded so that a scanner which fails to advance the port position
;; produces a wrong answer instead of hanging the test run.
(define (string-port-lines s) (read-lines (open-input-string s) 6))

(define (fd-port-lines s)
  (let ((file "scan-buffer-line-test"))
    (with-output-to-file file (lambda () (display s)))
    (let* ((p (open-input-file* (file-open file open/rdonly)))
           (ls (read-lines p 6)))
      (close-input-port p)
      (delete-file* file)
      ls)))

(define (test-line-terminators what lines-of)
  ;; The #568 arm of ##sys#scan-buffer-line handles a \r that is the last
  ;; byte the scanner may look at, which is where a CRLF can be split by a
  ;; refill.  Its EOF branch used to put the \r back into the line and
  ;; return the caller's position unadvanced, so over "a\r" a string port
  ;; answered "a\r" and then "\r" forever: read-lines never terminated.
  ;; A bare \r at EOF is a terminator exactly like a bare \r anywhere else.
  (test-equal (conc what ": trailing CR terminates the last line")
              (lines-of "a\r") '("a"))
  (test-equal (conc what ": a lone CR is one empty line")
              (lines-of "\r") '(""))
  (test-equal (conc what ": trailing CR after a CR")
              (lines-of "a\r\r") '("a" ""))
  (test-equal (conc what ": trailing CR after a CRLF")
              (lines-of "a\r\n\r") '("a" ""))
  (test-equal (conc what ": trailing CR after a LF")
              (lines-of "a\n\r") '("a" ""))
  (test-equal (conc what ": bare CR mid-stream")
              (lines-of "a\rb") '("a" "b"))
  (test-equal (conc what ": CRLF mid-stream")
              (lines-of "a\r\nb") '("a" "b"))
  (test-equal (conc what ": trailing CRLF")
              (lines-of "a\r\n") '("a"))
  (test-equal (conc what ": bare LF mid-stream")
              (lines-of "a\nb") '("a" "b"))
  (test-equal (conc what ": trailing LF")
              (lines-of "a\n") '("a"))
  (test-equal (conc what ": no terminator at EOF")
              (lines-of "a") '("a"))
  (test-equal (conc what ": empty input")
              (lines-of "") '())
  (test-equal (conc what ": CR, LF and CRLF mixed")
              (lines-of "a\rb\nc\r\nd") '("a" "b" "c" "d"))
  ;; Walk the terminator across the scanner's buffer boundaries: the
  ;; interesting offsets are the ones where the refill splits a CRLF or
  ;; leaves the CR as the very last readable byte.
  (for-each
   (lambda (n)
     (let ((pad (make-string n #\x)))
       (test-equal (conc what ": CR at offset " n)
                   (lines-of (conc pad "\r")) (list pad))
       (test-equal (conc what ": CRLF at offset " n)
                   (lines-of (conc pad "\r\n")) (list pad))
       (test-equal (conc what ": CRLF then more, at offset " n)
                   (lines-of (conc pad "\r\ny")) (list pad "y"))
       (test-equal (conc what ": CR then more, at offset " n)
                   (lines-of (conc pad "\ry")) (list pad "y"))))
   '(0 1 2 255 256 257 511 512 513 1023 1024 1025 2046 2047 2048 2049 4095 4096 4097)))

(test-group "line terminators, string port"
  (test-line-terminators "string port" string-port-lines))

(test-group "line terminators, fd port"
  (test-line-terminators "fd port" fd-port-lines))

;; ##sys#scan-buffer-line accumulates into a 1024-byte bytevector that
;; `grow' doubled exactly once per call.  But `conc' appends a whole
;; buffer's worth at a time - a string port hands over everything that is
;; left in one call - so a single append longer than 1024 bytes was
;; memcpy'd into a bytevector that had only been doubled to 2048.  Around
;; 2100 bytes read-line returned silently wrong content; by 3000 it
;; segfaulted.
(test-group "lines longer than the scanner's accumulator"
  (for-each
   (lambda (n)
     (let ((line (make-string n #\x)))
       (test-equal (conc "read-line of " n " bytes, LF-terminated")
                   (read-line (open-input-string (conc line "\n"))) line)
       (test-equal (conc "read-line of " n " bytes, CR then more")
                   (read-line (open-input-string (conc line "\rz"))) line)
       (test-equal (conc "read-line of " n " bytes, unterminated")
                   (read-line (open-input-string line)) line)))
   '(1023 1024 1025 2046 2047 2048 2049 2100 3000 4096 5000 20000 100000))
  ;; byte length and codepoint length differ here: 3 bytes per character
  (for-each
   (lambda (n)
     (let ((line (make-string n (integer->char #x4e2d))))
       (test-equal (conc "read-line of " n " 3-byte characters")
                   (read-line (open-input-string (conc line "\n"))) line)))
   '(683 684 685 1000 4000))
  (test-equal "read-lines over many long lines"
              (let* ((line (make-string 5000 #\y))
                     (text (conc line "\n" line "\r\n" line "\rz")))
                (read-lines (open-input-string text)))
              (list (make-string 5000 #\y) (make-string 5000 #\y)
                    (make-string 5000 #\y) "z")))

;; Disabled because it requires `echo -n` for
;; the EOF test, and that is not available on all systems.
;; Uncomment locally to run.
#;
(test-group
 "read-line process port position tests"
 (test-port-position read-echo-line/pos))
 
;; binary custom ports

(define count 1)
(define open #t)

(define (rdb)
  (let ((c count))
    (cond ((> c 5) #!eof)
          (else
            (set! count (+ count 1))
            c))))

(define (brdy?) #t)
(define (cls) (set! open #f))

(define (rbv bv from to)
  (let loop ((i from))
    (if (>= i to) 
        (- i from)
        (let ((b (rdb)))
          (if (eof-object? b)
          	  (- i from)
              (begin
                (u8vector-set! bv i b)
                (loop (+ i 1))))))))
      
(define (pkb) count)
     
(define written '())

(define (wrb b)
  (set! written (append written (list b))))
  
(define (wrbv bv from to)
  (do ((i from (+ i 1)))
      ((>= i to) (- from to))
      (wrb (u8vector-ref bv i))))

(define p1 (make-binary-input-port rdb brdy? cls))

(assert (u8-ready? p1))
(assert (= (read-u8 p1) 1))
(assert (= (peek-u8 p1) 2))
(assert (= (read-u8 p1) 2))
(assert (equal? (read-bytevector 4 p1) '#u8(3 4 5)))
(assert (eof-object? (read-u8 p1)))
(close-output-port p1)

(set! count 1)
(define p2 (make-binary-input-port rdb brdy? cls peek-u8: pkb read-bytevector: rbv))

(assert (u8-ready? p2))
(assert (= (read-u8 p2) 1))
(assert (= (peek-u8 p2) 2))
(assert (= (read-u8 p2) 2))
(assert (equal? (read-bytevector 4 p2) '#u8(3 4 5)))
(assert (eof-object? (read-u8 p2)))
(close-output-port p2)

(define p3 (make-binary-output-port wrb cls))
(write-u8 99 p3)
(write-bytevector '#u8(10 11 12) p3)
(close-output-port p3)
(assert (equal? written '(99 10 11 12)))

(set! written '())
(define p4 (make-binary-output-port wrb cls force-output: void write-bytevector: wrbv))
(write-u8 99 p4)
(write-bytevector '#u8(10 11 12) p4)
(flush-output-port p4)
(close-output-port p4)
(assert (equal? written '(99 10 11 12)))

;; bytevector I/O, moved here from srf-4-tests.scm:
;; Ticket #1124: read-u8vector! w/o length, dest smaller than source.
(test-group
 "bytevector I/O"
(let ((input (open-input-string "abcdefghijklmnopqrstuvwxyz"))
      (u8vec (make-bytevector 10)))
  (assert (= 10 (read-bytevector! u8vec input)))
  (assert (equal? u8vec #u8(97 98 99 100 101 102 103 104 105 106)))
  (assert (= 5  (read-bytevector! u8vec input 5)))
  (assert (equal? u8vec #u8(97 98 99 100 101 107 108 109 110 111)))
  (assert (= 5  (read-bytevector! u8vec input 0 5)))
  (assert (equal? u8vec #u8(112 113 114 115 116 107 108 109 110 111)))
  (assert (= 6  (read-bytevector! u8vec input 0 10)))
  (assert (equal? u8vec #u8(117 118 119 120 121 122 108 109 110 111))))

(let ((input (open-input-string "abcdefghijklmnopqrs")))
  (assert (equal? (read-bytevector 5 input)
		  #u8(97 98 99 100 101)))
  (assert (equal? (read-bytevector 5 input) #u8(102 103 104 105 106)))
  (assert (equal? (read-bytevector #f input)
		  #u8(107 108 109 110 111 112 113 114 115)))
  (with-input-from-string "abcdefghijklmnopqrs"
   (lambda ()
     (assert (equal? (read-bytevector 5)
		     #u8(97 98 99 100 101)))
     (assert (equal? (read-bytevector 5) #u8(102 103 104 105 106)))
     (assert (equal? (read-bytevector)
		     #u8(107 108 109 110 111 112 113 114 115))))))

(assert (string=?
	 "abc"
	 (with-output-to-string
	   (lambda ()
	     (write-bytevector #u8(97 98 99))))))

(assert (string=?
	 "bc"
	 (with-output-to-string
	   (lambda ()
	     (write-bytevector #u8(97 98 99) (current-output-port) 1)))))

(assert (string=?
	 "a"
	 (with-output-to-string
	   (lambda ()
	     (write-bytevector #u8(97 98 99) (current-output-port) 0 1)))))

(assert (string=?
	 "b"
	 (with-output-to-string
	   (lambda ()
	     (write-bytevector #u8(97 98 99) (current-output-port) 1 2)))))

(assert (string=?
	 ""
	 (with-output-to-string
	   (lambda ()
	     (write-bytevector #u8())))))
)

;;;

(test-end)

(test-exit)
