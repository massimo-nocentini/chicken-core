;;;; wasm-egg-a.scm - WebAssembly egg test: compiled-only code
;
; Copyright (c) 2026, The CHICKEN Team
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

(module wasm-egg-a (egg-a-add egg-a-times egg-a-scale egg-a-twice egg-a-swap!)

(import scheme (chicken base) (chicken foreign))

(foreign-declare "extern int wasm_egg_a_add(int, int);")

;; defined in wasm-egg-a-c.c, a separate C object
(define egg-a-add (foreign-lambda int "wasm_egg_a_add" int int))

(define egg-a-times
  (foreign-lambda* int ((int x) (int y)) "C_return(x * y);"))

;; WASM_EGG_A_FACTOR comes from the egg's csc-options
(define egg-a-scale
  (foreign-lambda* int ((int x)) "C_return(x * WASM_EGG_A_FACTOR);"))

(define (egg-a-twice x)
  (##core#inline "C_fixnum_times" x 2))

(define-syntax egg-a-swap!
  (syntax-rules ()
    ((_ a b) (let ((t a)) (set! a b) (set! b t)))))

)

;; a second module: its import library is installed too
(module wasm-egg-a-extra (egg-a-extra)

(import scheme)

(define (egg-a-extra) 'extra)

)
