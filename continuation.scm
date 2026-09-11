;;;; continuation.scm - A better API for continuations
;
; Copyright (c) 2008-2022, The CHICKEN Team
; Copyright (c) 2007, Felix L. Winkelmann
; All rights reserved.
;
; Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following
; conditions are met:
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
  (unit continuation)
  (disable-interrupts))

(foreign-declare "#define C_direct_continuation(dummy) t1")

(module chicken.continuation
  (continuation?
   continuation-capture
   continuation-graft
   continuation-return
   reset
   shift)

(import scheme chicken.base chicken.fixnum)

(include "common-declarations.scm")

;;; Delimited continuations.
;
; (reset E)   delimits E: the value of E is the value of the `reset'.
; (shift F E) captures the continuation of the `shift' up to - and not
;             including - the nearest enclosing `reset', binds F to it as
;             an ordinary one-argument procedure, and evaluates E with the
;             `reset' itself as its continuation.
;
; These expand to the calls that `perform-cps-conversion' (core.scm)
; recognises and compiles into Danvy and Filinski's rules
;
;   (reset E)   = (lambda (c) (c (E (lambda (v) v))))
;   (shift f E) = (lambda (c)
;                   (let ((f (lambda (x) (lambda (c2) (c2 (c x))))))
;                     (E (lambda (v) v))))
;
; directly, reifying `c' from the continuation the CPS pass already holds.
; Interpreted code, and any use the compiler's pattern match does not
; recognise, reaches the equivalent library procedures in library.scm.

(define-syntax reset
  (syntax-rules ()
    ((_ body ...) (##sys#reset (lambda () body ...)))))

(define-syntax shift
  (syntax-rules ()
    ((_ var body ...) (##sys#shift (lambda (var) body ...)))))

(define (continuation-capture proc)
  (let ((winds ##sys#dynamic-winds)
	(dcs ##sys#dc-stack)
	(k (##core#inline "C_direct_continuation" #f)))
    (proc (##sys#make-structure 'continuation k winds dcs))))

(define (continuation? x)
  (##sys#structure? x 'continuation))

(define (continuation-graft k thunk)
  (##sys#check-structure k 'continuation 'continuation-graft)
  (let ([winds (##sys#slot k 2)])
    (unless (eq? ##sys#dynamic-winds winds)
      (##sys#dynamic-unwind winds (fx- (length ##sys#dynamic-winds) (length winds))))
    ;; the metacontinuation stored in slot 3 is restored by
    ;; C_continuation_graft itself, because a compiled call to this
    ;; procedure is rewritten straight to that primitive
    ((##core#primitive "C_continuation_graft") k thunk)))

(define continuation-return
  (lambda (k . vals)
    (##sys#check-structure k 'continuation 'continuation-return)
    ((##core#primitive "C_continuation_graft") k (lambda () (apply values vals))))))
