;;; port.scm - Optional non-standard ports
;
; Copyright (c) 2008-2022, The CHICKEN Team
; Copyright (c) 2000-2007, Felix L. Winkelmann
; All rights reserved.
;
; Redistribution and use in source and binary forms, with or without
; modification, are permitted provided that the following conditions
; are met:
;
;   Redistributions of source code must retain the above copyright
;   notice, this list of conditions and the following disclaimer.
;   Redistributions in binary form must reproduce the above copyright
;   notice, this list of conditions and the following disclaimer in
;   the documentation and/or other materials provided with the
;   distribution.
;   Neither the name of the author nor the names of its contributors
;   may be used to endorse or promote products derived from this
;   software without specific prior written permission.
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
; "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
; LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
; FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
; COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
; INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
; (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
; HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
; STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
; OF THE POSSIBILITY OF SUCH DAMAGE.


(declare
  (unit port)
  (uses extras))

(module chicken.port
  (call-with-input-string
   call-with-output-string
   copy-port
   make-input-port make-binary-input-port
   make-output-port make-binary-output-port
   port-encoding
   port-fold
   port-for-each
   port-map
   port-name
   port-position
   make-bidirectional-port
   make-broadcast-port
   make-concatenated-port
   set-buffering-mode!
   terminal-name
   terminal-port?
   terminal-size
   with-error-output-to-port
   with-input-from-port
   with-input-from-string
   with-output-to-port
   with-output-to-string
   with-error-output-to-string)

(import scheme
	chicken.base
	chicken.fixnum
	chicken.foreign
	chicken.io)
(import (only (scheme base) open-output-string get-output-string open-input-string))

(include "common-declarations.scm")

#>

#if !defined(_WIN32)
# include <sys/ioctl.h>
# include <termios.h>
#endif

#if !defined(__ANDROID__) && defined(TIOCGWINSZ)
static int get_tty_size(int fd, int *rows, int *cols)
{
  struct winsize tty_size;
  int r;

  memset(&tty_size, 0, sizeof tty_size);

  r = ioctl(fd, TIOCGWINSZ, &tty_size);
  if (r == 0) {
     *rows = tty_size.ws_row;
     *cols = tty_size.ws_col;
  }
  return r;
}
#else
static int get_tty_size(int fd, int *rows, int *cols)
{
  *rows = *cols = 0;
  errno = ENOSYS;
  return -1;
}
#endif

#if defined(_WIN32) && !defined(__CYGWIN__)
char *ttyname(int fd) {
  errno = ENOSYS;
  return NULL;
}
#endif

<#


(define-foreign-variable _iofbf int "_IOFBF")
(define-foreign-variable _iolbf int "_IOLBF")
(define-foreign-variable _ionbf int "_IONBF")
(define-foreign-variable _bufsiz int "BUFSIZ")

(define port-encoding
  (getter-with-setter
    (lambda (port)
      (##sys#check-port port 'port-encoding)
      (##sys#slot port 15))
    (lambda (port enc)
      (##sys#check-port port 'port-encoding)
      (##sys#check-symbol enc 'port-encoding)
      (##sys#setslot port 15 enc))
    "(chicken.port#port-encoding port)"))

(define port-name
  (getter-with-setter
    (lambda (#!optional (port ##sys#standard-input))
      (##sys#check-port port 'port-name)
      (##sys#slot port 3))
    (lambda (port name)
      (##sys#check-port port 'set-port-name!)
      (##sys#check-string name 'set-port-name!)
      (##sys#setslot port 3 name))
    "(chicken.port#port-name port)"))

(define (port-position #!optional (port ##sys#standard-input))
  (##sys#check-port port 'port-position)
  (if (##core#inline "C_input_portp" port)
      (##sys#values (##sys#slot port 4) (##sys#slot port 5))
      (##sys#error 'port-position "cannot compute position of port" port)))

(define (set-buffering-mode! port mode . size)
  (##sys#check-port port 'set-buffering-mode!)
  (let ((size (if (pair? size) (car size) _bufsiz))
	(mode (case mode
		((#:full) _iofbf)
		((#:line) _iolbf)
		((#:none) _ionbf)
		(else (##sys#error 'set-buffering-mode! "invalid buffering-mode" mode port)))))
    (##sys#check-fixnum size 'set-buffering-mode!)
    (when (fx< (if (eq? 'stream (##sys#slot port 7))
		   ((foreign-lambda* int ((scheme-object p) (int m) (int s))
		     "C_return(setvbuf(C_port_file(p), NULL, m, s));")
		    port mode size)
		   -1)
	       0)
      (##sys#error 'set-buffering-mode! "cannot set buffering mode" port mode size))))

;;;; Port-mapping (found in Gauche):

(define (port-for-each fn thunk)
  (let loop ()
    (let ((x (thunk)))
      (unless (eof-object? x)
	(fn x)
	(loop) ) ) ) )

(define port-map
  (lambda (fn thunk)
    (let loop ((xs '()))
      (let ((x (thunk)))
	(if (eof-object? x)
	    (##sys#fast-reverse xs)
	    (loop (cons (fn x) xs)))))))

(define (port-fold fn acc thunk)
  (let loop ((acc acc))
    (let ((x (thunk)))
      (if (eof-object? x)
          acc
          (loop (fn x acc))) ) ) )

(define-constant +buf-size+ 1024)

(define copy-port
  (let ((read-char read-char)
        (write-char write-char))
    (define (read-and-write src dest)
      (##sys#check-port src 'copy-port)
      (##sys#check-port dest 'copy-port)
      (let ((buf (##sys#make-bytevector +buf-size+)))
        (let loop ()
          (let ((n (chicken.io#read-bytevector!/port +buf-size+
                     buf src 0)))
            (unless (eq? n 0)
              (chicken.io#write-bytevector buf dest 0 n)
              (loop))))))
    (define (read-and-delegate src dest writer)
      (##sys#check-port src 'copy-port)
      (let ((buf (##sys#make-bytevector +buf-size+)))
        (let loop ((p 0))
          (let* ((n (chicken.io#read-bytevector!/port
                      (fx- +buf-size+ p)
                      buf src p))
                 (fc (##core#inline "C_utf_fragment_counts" buf 0 n))
                 (full (fxshr fc 4))
                 (part (fxand fc 7))
                 (str (##sys#buffer->string buf 0 (fx- n part))))
            (unless (eq? n 0)
              (do ((i 0 (fx+ i 1)))
                      ((fx>= i full))
                (writer (string-ref str i) dest))
              ;; overlaps, buf source will be at end of buffer
              (##core#inline "C_copy_memory_with_offset"
                buf buf
                (fx- (fx- (##sys#size (##sys#slot str 0)) 1) part)
                0 part)
              (loop part))))))
    (define (delegate src reader dest writer)
      (let loop ()
        (let ((x (reader src)))
          (unless (eof-object? x)
            (writer x dest)
            (loop)))))
    (define (delegate-and-write src reader dest)
      (##sys#check-port dest 'copy-port)
      (let ((buf (##sys#make-bytevector (fx+ 4 +buf-size+))))
        (let loop ((n 0))
          (when (fx>= n +buf-size+)
            (chicken.io#write-bytevector buf dest 0 n)
            (set! n 0))
          (let ((c (reader src)))
            (cond ((eof-object? c)
                   (when (fx>= n 0)
                     (chicken.io#write-bytevector buf dest 0 n)))
                  (else
                   (loop (##core#inline "C_utf_insert" buf n c))))))))
    (lambda (src dest #!optional (read read-char) (write write-char))
      ;; does not check port args intentionally
      (cond ((eq? read read-char)
                  (if (eq? write write-char)
                      (read-and-write src dest)
                  (read-and-delegate src dest write)))
            ((eq? write write-char)
             (delegate-and-write src read dest))
            (else (delegate src read dest write))))))


;;;; funky-ports

(define (make-broadcast-port . ports)
  (make-output-port
   (lambda (s) (for-each (cut scheme#write-string s <>) ports))
   void
   (lambda () (for-each flush-output ports)) ) )

(define (make-concatenated-port p1 . ports)
  (let ((ports (cons p1 ports)))
    ;;XXX should also forward other port-methods
    (make-input-port
     (lambda ()
       (let loop ()
	 (if (null? ports)
	     #!eof
	     (let ((c (read-char (car ports))))
	       (cond ((eof-object? c)
		      (set! ports (cdr ports))
		      (loop) )
		     (else c) ) ) ) ) )
     (lambda ()
       (and (not (null? ports))
	    (char-ready? (car ports))))
     void
     peek-char:
     (lambda ()
       (let loop ()
	 (if (null? ports)
	     #!eof
	     (let ((c (peek-char (car ports))))
	       (cond ((eof-object? c)
		      (set! ports (cdr ports))
		      (loop) )
		     (else c))))))
     read-bytevector:
     (lambda (p n dest start)
       (let loop ((n n) (c 0) (p start))
	 (cond ((null? ports) c)
	       ((fx<= n 0) c)
	       (else
		(let ((m (read-bytevector! dest (car ports) p (+ p n))))
		  (when (fx< m n)
		    (set! ports (cdr ports)) )
		  (loop (fx- n m) (fx+ c m) (fx+ p m))))))))))


;;; Redirect standard ports:

(define (with-input-from-port port thunk)
  (##sys#check-input-port port #t 'with-input-from-port)
  (fluid-let ((##sys#standard-input port))
    (thunk) ) )

(define (with-output-to-port port thunk)
  (##sys#check-output-port port #t 'with-output-to-port)
  (fluid-let ((##sys#standard-output port))
    (thunk) ) )

(define (with-error-output-to-port port thunk)
  (##sys#check-output-port port #t 'with-error-output-to-port)
  (fluid-let ((##sys#standard-error port))
    (thunk) ) )

;;; Extended string-port operations:

(define call-with-input-string
  (lambda (str proc)
    (let ((in (open-input-string str)))
      (proc in) ) ) )

(define call-with-output-string
  (lambda (proc)
    (let ((out (open-output-string)))
      (proc out)
      (get-output-string out) ) ) )

(define with-input-from-string
  (lambda (str thunk)
    (fluid-let ([##sys#standard-input (open-input-string str)])
      (thunk) ) ) )

(define with-output-to-string
  (lambda (thunk)
    (fluid-let ((##sys#standard-output (open-output-string)))
      (thunk)
      (get-output-string ##sys#standard-output) ) ) )

(define with-error-output-to-string
  (lambda (thunk)
    (fluid-let ((##sys#standard-error (open-output-string)))
      (thunk)
      (get-output-string ##sys#standard-error) ) ) )

;;; Custom ports:
;
; - Port-slots:
;
;   10: last/peeked

(define make-input-port
  (lambda (read ready? close #!rest r
                #!key peek-char read-bytevector read-line read-buffered)
    ;XXX this is for ensuring old-style calls fail and can be removed at some stage
    (when (and (pair? r) (not (##core#inline "C_i_keywordp" (car r))))
      (error 'make-input-port "invalid invocation - use keyword parameters" r))
    (let* ((class
	    (vector
	     (lambda (p)		; read-char
	       (let ((last (##sys#slot p 10)))
		 (cond (peek-char (read))
		       (last
			(##sys#setislot p 10 #f)
			last)
		       (else (read)) ) ) )
	     (lambda (p)		; peek-char
	       (let ((last (##sys#slot p 10)))
		 (cond (peek-char (peek-char))
		       (last last)
		       (else
			(let ((last (read)))
			  (##sys#setslot p 10 last)
			  last) ) ) ) )
	     #f				; write-char
	     #f				; write-bytevector
	     (lambda (p d)		; close
	       (close))
	     #f				; flush-output
	     (lambda (p)		; char-ready?
	       (ready?) )
	     (or read-bytevector	; read-bytevector!
	         (lambda (p n dest start)
	           (error "binary I/O not supported for custom text input port without bytevector-read method" p)))
	     read-line			; read-line
	     read-buffered))
	   (data (vector #f))
	   (port (##sys#make-port 1 class "(custom)" 'custom)))
      (##sys#setslot port 10 #f)
      (##sys#set-port-data! port data)
      port) ) )

(define make-output-port
  (lambda (write close #!rest r #!key force-output)
    ;XXX this is for ensuring old-style calls fail and can be removed at some stage
    (when (and (pair? r) (not (##core#inline "C_i_keywordp" (car r))))
      (error 'make-output-port "invalid invocation - use keyword parameters" r))
    (let* ((class
	    (vector
	     #f				; read-char
	     #f				; peek-char
	     (lambda (p c)		; write-char
	       (write (string c)) )
	     (lambda (p bv from to)   	; write-bytevector
               (let ((len (fx- to from)))
                 (write (##sys#buffer->string bv from len))))
	     (lambda (p d)		; close
	       (close))
	     (lambda (p)		; flush-output
	       (when force-output (force-output)) )
	     #f				; char-ready?
	     #f				; read-bytevector!
             #f                         ; read-line
             #f))                         ; read-buffered
	   (data (vector #f))
	   (port (##sys#make-port 2 class "(custom)" 'custom)))
      (##sys#set-port-data! port data)
      port) ) )

(define make-binary-input-port
  (lambda (read ready? close #!key peek-u8 read-bytevector)
    (define read-bv
      (if read-bytevector
          (lambda (p n dest start)
            (let* ((off (getlast p dest start))
                   (start (##core#inline "C_fixnum_plus" start off))
                   (n (##core#inline "C_fixnum_difference" n off)))
              (##core#inline "C_fixnum_plus"
               off 
               (read-bytevector dest start (##core#inline "C_fixnum_plus" start n)))))
          (lambda (p n dest start)
            (let* ((off (getlast p dest start))
                   (start (##core#inline "C_fixnum_plus" start off))
                   (n (##core#inline "C_fixnum_difference" n off)))
              (##core#inline "C_fixnum_plus"
               off 
               (let loop ((i 0))
                 (if (##core#inline "C_fixnum_greater_or_equal_p" i n)
                     i
                     (let ((b (read)))
                       (cond ((eof-object? b) i)
                             (else
                               (##core#inline "C_setsubbyte" 
                                dest
                                (##core#inline "C_fixnum_plus" i start)
                                b)
                               (loop (##core#inline "C_fixnum_plus" i 1))))))))))))
    (define (getlast p dest i)
      (let ((last (##sys#slot p 10)))
        (cond (last 
                (##core#inline "C_setsubbyte" dest i (char->integer last))
                (##sys#setislot p 10 #f)
                1)
              (else 0))))
    (define (tochar x) 
      (if (eof-object? x)
          x
          (integer->char x)))
    (let* ((class
             (vector
               (lambda (p)                ; read-char
                 (let ((last (##sys#slot p 10)))
                   (cond (last
                           (##sys#setislot p 10 #f)
                           last)
                         (else (tochar (read)) ) ) ))
               (lambda (p)                ; peek-char
                 (let ((last (##sys#slot p 10)))
                   (cond (peek-u8 (tochar (peek-u8)))
                         (last last)
                         (else
                           (let ((last (tochar (read))))
                             (##sys#setislot p 10 last)
                             last) ) ) ) )
               #f                         ; write-char
               #f                         ; write-bytevector
               (lambda (p d)              ; close
                 (close))
               #f                         ; flush-output
               (lambda (p)                ; char-ready?
                 (ready?) )
               read-bv        ; read-bytevector!
               #f                  ; read-line
               #f))
           (data (vector #f))
           (port (##sys#make-port 1 class "(custom binary)" 'custom)))
      (##sys#setslot port 10 #f)
      (##sys#setslot port 14 'binary)
      (##sys#setslot port 15 'binary)
      (##sys#set-port-data! port data)
      port) ) )
      
(define make-binary-output-port
  (lambda (write close #!key force-output write-bytevector)
    (define write-bv 
      (or write-bytevector
          (lambda (bv start end) 
            (##sys#check-bytevector bv 'make-binary-output-port)
            (let loop ((i start)
                       (end (or end (##sys#size bv))))
               (unless (##core#inline "C_fixnum_greater_or_equal_p" i end)
                 (write (##core#inline "C_subbyte" bv i))
                 (loop (##core#inline "C_fixnum_plus" i 1) end))))))
    (let* ((class
             (vector
               #f                      ; read-char
               #f                      ; peek-char
               (lambda (p c)       ; write-char
                 (let* ((len (##core#inline "C_utf_bytes" c))
                        (buf (##sys#make-bytevector len))
                        (n (##core#inline "C_utf_insert" buf 0 c)))
                   (write-bv buf 0 len)))
               (lambda (p bv from to)           ; write-bytevector
                 (write-bv bv from to))
               (lambda (p d)       ; close
                 (close))
               (lambda (p)           ; flush-output
                 (when force-output (force-output)) )
               #f                      ; char-ready?
               #f                      ; read-bytevector!
               #f                         ; read-line
               #f))                         ; read-buffered
           (data (vector #f))
           (port (##sys#make-port 2 class "(custom binary)" 'custom)))
      (##sys#set-port-data! port data)
      (##sys#setslot port 15 'binary)
      (##sys#setslot port 14 'binary)
      port) ) )
      
(define (make-bidirectional-port i o)
  (let* ((class (vector
		 (lambda (_)             ; read-char
		   (read-char i))
		 (lambda (_)             ; peek-char
		   (peek-char i))
		 (lambda (_ c)           ; write-char
		   (write-char c o))
                 (lambda (_ bv from to)  ; write-bytevector
                   (chicken.io#write-bytevector bv o from to))
		 (lambda (_ d)           ; close
		   (case d
		     ((1) (close-input-port i))
		     ((2) (close-output-port o))))
		 (lambda (_)             ; flush-output
		   (flush-output o))
		 (lambda (_)             ; char-ready?
		   (char-ready? i))
		 (lambda (_ n d s)       ; read-bytevector!
		   (chicken.io#read-bytevector! d i s (fx+ s n)))
		 (lambda (_ l)           ; read-line
		   (read-line i l))
		 (lambda ()              ; read-buffered
		   (read-buffered i))))
	 (port (##sys#make-port 3 class "(bidirectional)" 'bidirectional)))
    (##sys#set-port-data! port (vector #f))
    port))

;; Duplication from posix-common.scm
(define posix-error
  (let ((strerror (foreign-lambda c-string "strerror" int))
	(string-append string-append))
    (lambda (type loc msg . args)
      (let ((rn (##sys#update-errno)))
        (apply ##sys#signal-hook/errno
               type rn loc (string-append msg " - " (strerror rn)) args)))))

;; Terminal ports
(define (terminal-port? port)
  (##sys#check-open-port port 'terminal-port?)
  (let ((fp (##sys#peek-unsigned-integer port 0)))
    (and (not (eq? 0 fp)) (##core#inline "C_tty_portp" port))))

(define (check-terminal! caller port)
  (##sys#check-open-port port caller)
  (unless (and (eq? 'stream (##sys#slot port 7))
	       (##core#inline "C_tty_portp" port))
    (##sys#error caller "port is not connected to a terminal" port)))

(define terminal-name
  (let ((ttyname (foreign-lambda c-string "ttyname" int)))
    (lambda (port)
      (check-terminal! 'terminal-name port)
      (or (ttyname (##core#inline "C_port_fileno" port))
	  (posix-error #:error 'terminal-name
		       "cannot determine terminal name" port)))))

(define terminal-size
  (let ((ttysize (foreign-lambda int "get_tty_size" int
				 (nonnull-c-pointer int)
				 (nonnull-c-pointer int))))
    (lambda (port)
      (check-terminal! 'terminal-size port)
      (let-location ((columns int)
		     (rows int))
	(if (fx= 0 (ttysize (##core#inline "C_port_fileno" port)
			    (location rows)
			    (location columns)))
	    (values rows columns)
	    (posix-error #:error 'terminal-size
			 "cannot determine terminal size" port))))))

)
