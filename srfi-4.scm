;;;; srfi-4.scm - Homogeneous numeric vectors
;
; Copyright (c) 2008-2022, The CHICKEN Team
; Copyright (c) 2000-2007, Felix L. Winkelmann
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
  (unit srfi-4)
  (uses expand extras)
  (disable-interrupts)
  (not inline ##sys#user-print-hook)
  (foreign-declare #<<EOF
#define C_copy_subvector(to, from, start_to, start_from, bytes)   \
  (C_memcpy((C_char *)C_data_pointer(to) + C_unfix(start_to), (C_char *)C_data_pointer(from) + C_unfix(start_from), C_unfix(bytes)), \
    C_SCHEME_UNDEFINED)

/* Bulk arithmetic kernels for the float vector types.

   Each kernel receives the SRFI-4 structure (not the underlying bytevector)
   and a half-open [start,end) *element* range which the Scheme wrapper has
   already range-checked, so the kernels themselves do no bounds checking.

   All arithmetic is done in `double'.  That is exactly what an
   element-at-a-time Scheme loop does -- f32vector-ref widens a float to a
   flonum, f32vector-set! narrows the flonum again on store -- so the
   elementwise kernels are bit-identical to the Scheme loops they replace,
   for f32 as well as f64.

   The loops are unrolled by hand rather than left to the loop vectorizer.
   The reductions carry a loop-carried FP dependence that clang will not
   reorder at any -O level without -ffast-math, and a rolled `a[i] *= s' is
   left scalar at -Os, which is what the stock CHICKEN build uses (the loop
   vectorizer declines there rather than emit runtime checks).  Written out
   this way the SLP vectorizer takes _scale, _sum, _dot and both halves of
   _axpy from -Os upwards; _fill stays scalar stores, which costs nothing
   because it is store-port bound either way, and _copy is a memmove.

   CONSEQUENCE, and it is a real one: _sum and _dot keep eight independent
   partial sums and combine them pairwise at the end.  That is a
   REASSOCIATION of the naive left-to-right sum.  Results may differ from a
   Scheme accumulator loop in the last ulps (in practice they are more
   accurate, the error growing like sqrt(n/8) rather than n).  The
   elementwise kernels reassociate nothing and are exact. */

/* `d * a[i] + b[i]' is contracted into a single FMA whenever the build has
   FMA available -- a user -march flag on x86-64, or the baseline on AArch64
   and ppc64 -- and that silently breaks the documented bit-identity with the
   Scheme loop, which rounds the product before adding: C_a_i_flonum_times
   materialises a flonum that C_a_i_flonum_plus then reads back, and CHICKEN
   never fuses (+ (* a x) y) on its own.

   Two levers are needed because the compilers disagree about which one they
   implement.  clang honours the standard pragma.  GCC has never implemented
   it -- it warns "ignoring '#pragma STDC FP_CONTRACT'" under -Wall and
   defaults to -ffp-contract=fast, which contracts across statements, so a
   named temporary would not help either; it wants the optimize attribute
   instead.  Both are scoped to this block and neither affects the rest of
   the translation unit.

   NOT covered: x87 excess precision on a 32-bit x86 build, where GCC
   defaults to -mfpmath=387 and FLT_EVAL_METHOD is 2, so the product is kept
   at 80 bits and rounded once.  That needs -fexcess-precision=standard or
   -msse2 -mfpmath=sse in the build, not a pragma here. */
#if defined(__GNUC__) && !defined(__clang__)
# pragma GCC push_options
# pragma GCC optimize ("fp-contract=off")
#endif
#pragma STDC FP_CONTRACT OFF
#if defined(__GNUC__) || defined(__clang__)
# define C_nv_restrict __restrict
#else
# define C_nv_restrict
#endif

#define C_nv_elems(T, v)  ((T *)C_data_pointer(C_block_item((v), 1)))

#define C_nv_define_kernels(T, PFX) \
static C_word PFX ## _fill(C_word v, C_word x, C_word s, C_word e) \
{ \
  T *a = C_nv_elems(T, v); \
  T d = (T)C_flonum_magnitude(x); \
  C_word i = C_unfix(s), n = C_unfix(e); \
  for(; i + 4 <= n; i += 4) { a[i] = d; a[i+1] = d; a[i+2] = d; a[i+3] = d; } \
  for(; i < n; ++i) a[i] = d; \
  return C_SCHEME_UNDEFINED; \
} \
 \
static C_word PFX ## _copy(C_word to, C_word at, C_word from, C_word s, C_word e) \
{ \
  C_word st = C_unfix(s), n = C_unfix(e) - st; \
  if(n > 0) \
    C_memmove(C_nv_elems(T, to) + C_unfix(at), C_nv_elems(T, from) + st, \
              (size_t)n * sizeof(T)); \
  return C_SCHEME_UNDEFINED; \
} \
 \
static C_word PFX ## _scale(C_word v, C_word x, C_word s, C_word e) \
{ \
  T *a = C_nv_elems(T, v); \
  double d = C_flonum_magnitude(x); \
  C_word i = C_unfix(s), n = C_unfix(e); \
  for(; i + 4 <= n; i += 4) { \
    a[i]   = (T)(d * (double)a[i]);   a[i+1] = (T)(d * (double)a[i+1]); \
    a[i+2] = (T)(d * (double)a[i+2]); a[i+3] = (T)(d * (double)a[i+3]); \
  } \
  for(; i < n; ++i) a[i] = (T)(d * (double)a[i]); \
  return C_SCHEME_UNDEFINED; \
} \
 \
static void PFX ## _axpy_same(T *b, double d, C_word i, C_word n) \
{ \
  for(; i + 4 <= n; i += 4) { \
    b[i]   = (T)(d * (double)b[i]   + (double)b[i]); \
    b[i+1] = (T)(d * (double)b[i+1] + (double)b[i+1]); \
    b[i+2] = (T)(d * (double)b[i+2] + (double)b[i+2]); \
    b[i+3] = (T)(d * (double)b[i+3] + (double)b[i+3]); \
  } \
  for(; i < n; ++i) b[i] = (T)(d * (double)b[i] + (double)b[i]); \
} \
 \
static void PFX ## _axpy_disjoint(T *C_nv_restrict b, const T *C_nv_restrict a, \
                                  double d, C_word i, C_word n) \
{ \
  for(; i + 4 <= n; i += 4) { \
    b[i]   = (T)(d * (double)a[i]   + (double)b[i]); \
    b[i+1] = (T)(d * (double)a[i+1] + (double)b[i+1]); \
    b[i+2] = (T)(d * (double)a[i+2] + (double)b[i+2]); \
    b[i+3] = (T)(d * (double)a[i+3] + (double)b[i+3]); \
  } \
  for(; i < n; ++i) b[i] = (T)(d * (double)a[i] + (double)b[i]); \
} \
 \
static C_word PFX ## _axpy(C_word y, C_word x, C_word v, C_word s, C_word e) \
{ \
  T *b = C_nv_elems(T, y); \
  T *a = C_nv_elems(T, v); \
  double d = C_flonum_magnitude(x); \
  C_word i = C_unfix(s), n = C_unfix(e); \
  /* The vectorizer will not version this loop for aliasing at -Os, and the \
     two vectors may legitimately be the same object, so pick the shape by \
     hand: identical, provably disjoint, or (only reachable through storage \
     shared at an offset) a plain scalar loop.  All three compute the same \
     expression in the same order. */ \
  if(a == b) PFX ## _axpy_same(b, d, i, n); \
  else if((C_uword)(a + n) <= (C_uword)(b + i) || \
          (C_uword)(b + n) <= (C_uword)(a + i)) \
    PFX ## _axpy_disjoint(b, a, d, i, n); \
  else for(; i < n; ++i) b[i] = (T)(d * (double)a[i] + (double)b[i]); \
  return C_SCHEME_UNDEFINED; \
} \
 \
static C_word PFX ## _sum(C_word **ptr, C_word c, C_word v, C_word s, C_word e) \
{ \
  T *a = C_nv_elems(T, v); \
  double s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0; \
  double s4 = 0.0, s5 = 0.0, s6 = 0.0, s7 = 0.0, t; \
  C_word i = C_unfix(s), n = C_unfix(e); \
  for(; i + 8 <= n; i += 8) { \
    s0 += (double)a[i];   s1 += (double)a[i+1]; \
    s2 += (double)a[i+2]; s3 += (double)a[i+3]; \
    s4 += (double)a[i+4]; s5 += (double)a[i+5]; \
    s6 += (double)a[i+6]; s7 += (double)a[i+7]; \
  } \
  t = ((s0 + s1) + (s2 + s3)) + ((s4 + s5) + (s6 + s7)); \
  for(; i < n; ++i) t += (double)a[i]; \
  return C_flonum(ptr, t); \
} \
 \
static C_word PFX ## _dot(C_word **ptr, C_word c, C_word x, C_word y, C_word s, C_word e) \
{ \
  T *a = C_nv_elems(T, x); \
  T *b = C_nv_elems(T, y); \
  double s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0; \
  double s4 = 0.0, s5 = 0.0, s6 = 0.0, s7 = 0.0, t; \
  C_word i = C_unfix(s), n = C_unfix(e); \
  for(; i + 8 <= n; i += 8) { \
    s0 += (double)a[i]   * (double)b[i];   s1 += (double)a[i+1] * (double)b[i+1]; \
    s2 += (double)a[i+2] * (double)b[i+2]; s3 += (double)a[i+3] * (double)b[i+3]; \
    s4 += (double)a[i+4] * (double)b[i+4]; s5 += (double)a[i+5] * (double)b[i+5]; \
    s6 += (double)a[i+6] * (double)b[i+6]; s7 += (double)a[i+7] * (double)b[i+7]; \
  } \
  t = ((s0 + s1) + (s2 + s3)) + ((s4 + s5) + (s6 + s7)); \
  for(; i < n; ++i) t += (double)a[i] * (double)b[i]; \
  return C_flonum(ptr, t); \
}

C_nv_define_kernels(double, C_nv_f64)
C_nv_define_kernels(float, C_nv_f32)

#if defined(__GNUC__) && !defined(__clang__)
# pragma GCC pop_options
#endif
EOF
) )

(module chicken.number-vector
  (bytevector->f32vector bytevector->f32vector/shared
   bytevector->f64vector bytevector->f64vector/shared
   bytevector->s16vector bytevector->s16vector/shared
   bytevector->s32vector bytevector->s32vector/shared
   bytevector->s64vector bytevector->s64vector/shared
   bytevector->s8vector bytevector->s8vector/shared
   bytevector->u16vector bytevector->u16vector/shared
   bytevector->u32vector bytevector->u32vector/shared
   bytevector->u64vector bytevector->u64vector/shared
   bytevector->c64vector bytevector->c64vector/shared
   bytevector->c128vector bytevector->c128vector/shared
   f32vector f32vector->bytevector f32vector->bytevector/shared f32vector->list
   f32vector-length f32vector-ref f32vector-set! f32vector?
   f64vector f64vector->bytevector f64vector->bytevector/shared f64vector->list
   f64vector-length f64vector-ref f64vector-set! f64vector?
   s8vector s8vector->bytevector s8vector->bytevector/shared s8vector->list
   s8vector-length s8vector-ref s8vector-set! s8vector?
   s16vector s16vector->bytevector s16vector->bytevector/shared s16vector->list
   s16vector-length s16vector-ref s16vector-set! s16vector?
   s32vector s32vector->bytevector s32vector->bytevector/shared s32vector->list
   s32vector-length s32vector-ref s32vector-set! s32vector?
   s64vector s64vector->bytevector s64vector->bytevector/shared s64vector->list
   s64vector-length s64vector-ref s64vector-set! s64vector?
   u8vector u8vector->list
   u8vector-length u8vector-ref u8vector-set! u8vector?
   u16vector u16vector->bytevector u16vector->bytevector/shared u16vector->list
   u16vector-length u16vector-ref u16vector-set! u16vector?
   u32vector u32vector->bytevector u32vector->bytevector/shared u32vector->list
   u32vector-length u32vector-ref u32vector-set! u32vector?
   u64vector u64vector->bytevector u64vector->bytevector/shared u64vector->list
   u64vector-length u64vector-ref u64vector-set! u64vector?
   c64vector c64vector->bytevector c64vector->bytevector/shared c64vector->list
   c64vector-length c64vector-ref c64vector-set! c64vector?
   c128vector c128vector->bytevector c128vector->bytevector/shared c128vector->list
   c128vector-length c128vector-ref c128vector-set! c128vector?
   list->f32vector list->f64vector list->s16vector list->s32vector
   list->s64vector list->s8vector list->u16vector list->u32vector
   list->u8vector list->u64vector list->c64vector list->c128vector
   make-f32vector make-f64vector make-s16vector make-s32vector
   make-s64vector make-s8vector make-u16vector make-u32vector
   make-u64vector make-u8vector make-c64vector make-c128vector
   number-vector? release-number-vector
   subf32vector subf64vector subs16vector subs32vector subs64vector
   subs8vector subu16vector subu8vector subu32vector subu64vector
   subc64vector subc128vector
   f64vector-fill! f64vector-copy! f64vector-scale! f64vector-axpy!
   f64vector-sum f64vector-dot
   f32vector-fill! f32vector-copy! f32vector-scale! f32vector-axpy!
   f32vector-sum f32vector-dot)

(import scheme
	chicken.base
	chicken.bitwise
        chicken.bytevector
	chicken.fixnum
	chicken.foreign
	chicken.gc
	chicken.platform
	chicken.syntax)

(include "common-declarations.scm")


;;; Helper routines:

(define-inline (check-int/flonum x loc)
  (unless (or (##core#inline "C_i_exact_integerp" x)
	      (##core#inline "C_i_flonump" x))
    (##sys#error-hook (foreign-value "C_BAD_ARGUMENT_TYPE_NO_FLONUM_ERROR" int) loc x) ) )

(define-inline (check-uint-length obj len loc)
  (##sys#check-exact-uinteger obj loc)
  (when (fx> (integer-length obj) len)
    (##sys#error-hook
     (foreign-value "C_BAD_ARGUMENT_TYPE_NUMERIC_RANGE_ERROR" int) loc obj)))

(define-inline (check-int-length obj len loc)
  (##sys#check-exact-integer obj loc)
  (when (fx> (integer-length obj) (fx- len 1))
    (##sys#error-hook
     (foreign-value "C_BAD_ARGUMENT_TYPE_NUMERIC_RANGE_ERROR" int)
     loc obj)))

(define-syntax ->f
  (syntax-rules ()
    ((_ x)
     (let ((tmp x))
       (if (##core#inline "C_i_flonump" tmp)
           tmp
           (##core#inline_allocate ("C_a_u_i_int_to_flo" 4) tmp))))))

;; `->f' is only safe for values `check-int/flonum' accepts: C_a_u_i_int_to_flo
;; tests C_FIXNUM_BIT and otherwise falls through to C_a_u_i_big_to_flo, which
;; reads a ratnum's numerator -- an immediate -- as a bignum pointer.  The
;; complex paths take their arguments apart with real-part/imag-part, so they
;; must check each part rather than the number as a whole.
(define-syntax ->f/checked
  (syntax-rules ()
    ((_ x loc)
     (let ((tmp x))
       (check-int/flonum tmp loc)
       (->f tmp)))))

;;; Get vector length:

(define (u8vector-length x)
  (##core#inline "C_i_bytevector_length" x))

(define (s8vector-length x)
  (##core#inline "C_i_s8vector_length" x))

(define (u16vector-length x)
  (##core#inline "C_i_u16vector_length" x))

(define (s16vector-length x)
  (##core#inline "C_i_s16vector_length" x))

(define (u32vector-length x)
  (##core#inline "C_i_u32vector_length" x))

(define (s32vector-length x)
  (##core#inline "C_i_s32vector_length" x))

(define (u64vector-length x)
  (##core#inline "C_i_u64vector_length" x))

(define (s64vector-length x)
  (##core#inline "C_i_s64vector_length" x))

(define (f32vector-length x)
  (##core#inline "C_i_f32vector_length" x))

(define (f64vector-length x)
  (##core#inline "C_i_f64vector_length" x))

(define (c64vector-length x)
  (##sys#check-structure x 'c64vector 'c64vector-length)
  (fx/ (##core#inline "C_i_bytevector_length" (##sys#slot x 1)) 8))

(define (c128vector-length x)
  (##sys#check-structure x 'c128vector 'c128vector-length)
  (fx/ (##core#inline "C_i_bytevector_length" (##sys#slot x 1)) 16))


;;; Safe accessors:

(define u8vector-set! bytevector-u8-set!)

(define (s8vector-set! x i y)
  (##core#inline "C_i_s8vector_set" x i y))

(define (u16vector-set! x i y)
  (##core#inline "C_i_u16vector_set" x i y))

(define (s16vector-set! x i y)
  (##core#inline "C_i_s16vector_set" x i y))

(define (u32vector-set! x i y)
  (##core#inline "C_i_u32vector_set" x i y))

(define (s32vector-set! x i y)
  (##core#inline "C_i_s32vector_set" x i y))

(define (u64vector-set! x i y)
  (##core#inline "C_i_u64vector_set" x i y))

(define (s64vector-set! x i y)
  (##core#inline "C_i_s64vector_set" x i y))

(define (f32vector-set! x i y)
  (##core#inline "C_i_f32vector_set" x i y))

(define (f64vector-set! x i y)
  (##core#inline "C_i_f64vector_set" x i y))

(define (c64vector-set! x i y)
  (##sys#check-structure x 'c64vector 'c64vector-set!)
  (let* ((bv (##sys#slot x 1))
         (len (fx/ (##core#inline "C_i_bytevector_length" bv) 8)))
    (##sys#check-range i 0 len 'c64vector-set!)
    (##sys#check-number y 'c64vector-set!)
    (##core#inline "C_u_i_f32vector_set" x (fx* i 2)
                   (->f/checked (real-part y) 'c64vector-set!))
    (##core#inline "C_u_i_f32vector_set" x (fx+ (fx* i 2) 1)
                   (->f/checked (imag-part y) 'c64vector-set!))))

(define (c128vector-set! x i y)
  (##sys#check-structure x 'c128vector 'c128vector-set!)
  (let* ((bv (##sys#slot x 1))
         (len (fx/ (##core#inline "C_i_bytevector_length" bv) 16)))
    (##sys#check-range i 0 len 'c128vector-set!)
    (##sys#check-number y 'c128vector-set!)
    (##core#inline "C_u_i_f64vector_set" x (fx* i 2)
                   (->f/checked (real-part y) 'c128vector-set!))
    (##core#inline "C_u_i_f64vector_set" x (fx+ (fx* i 2) 1)
                   (->f/checked (imag-part y) 'c128vector-set!))))

(define u8vector-ref bytevector-u8-ref)

(define s8vector-ref
  (getter-with-setter
   (lambda (x i) (##core#inline "C_i_s8vector_ref" x i))
   s8vector-set!
   "(chicken.number-vector#s8vector-ref v i)"))

(define u16vector-ref
  (getter-with-setter
   (lambda (x i) (##core#inline "C_i_u16vector_ref" x i))
   u16vector-set!
   "(chicken.number-vector#u16vector-ref v i)"))

(define s16vector-ref
  (getter-with-setter
   (lambda (x i) (##core#inline "C_i_s16vector_ref" x i))
   s16vector-set!
   "(chicken.number-vector#s16vector-ref v i)"))
   
(define u32vector-ref
  (getter-with-setter
   (lambda (x i) (##core#inline_allocate ("C_a_i_u32vector_ref" 5) x i))
   u32vector-set!
   "(chicken.number-vector#u32vector-ref v i)"))

(define s32vector-ref
  (getter-with-setter
   (lambda (x i) (##core#inline_allocate ("C_a_i_s32vector_ref" 5) x i))
   s32vector-set!
   "(chicken.number-vector#s32vector-ref v i)"))

(define u64vector-ref
  (getter-with-setter
   (lambda (x i) (##core#inline_allocate ("C_a_i_u64vector_ref" 7) x i))
   u64vector-set!
   "(chicken.number-vector#u64vector-ref v i)"))

(define s64vector-ref
  (getter-with-setter
   (lambda (x i) (##core#inline_allocate ("C_a_i_s64vector_ref" 7) x i))
   s64vector-set!
   "(chicken.number-vector#s64vector-ref v i)"))

(define f32vector-ref
  (getter-with-setter
   (lambda (x i) (##core#inline_allocate ("C_a_i_f32vector_ref" 4) x i))
   f32vector-set!
   "(chicken.number-vector#f32vector-ref v i)"))

(define f64vector-ref
  (getter-with-setter
   (lambda (x i) (##core#inline_allocate ("C_a_i_f64vector_ref" 4) x i))
   f64vector-set!
   "(chicken.number-vector#f64vector-ref v i)"))

(define c64vector-ref
  (getter-with-setter
   (lambda (x i)
     (##sys#check-structure x 'c64vector 'c64vector-ref)
     (##sys#check-range
       i 0 (##core#inline "C_u_fixnum_divide"
             (##core#inline "C_i_bytevector_length" (##sys#slot x 1))
             8)
       'c64vector-ref)
     (let ((p (##core#inline "C_fixnum_times" i 2)))
       (make-rectangular
         (##core#inline_allocate ("C_a_u_i_f32vector_ref" 4) x p)
         (##core#inline_allocate ("C_a_u_i_f32vector_ref" 4)
           x (##core#inline "C_u_fixnum_plus" p 1)))))
   c64vector-set!
   "(chicken.number-vector#c64vector-ref v i)"))

(define c128vector-ref
  (getter-with-setter
   (lambda (x i)
     (##sys#check-structure x 'c128vector 'c128vector-ref)
     (##sys#check-range
       i 0 (##core#inline "C_u_fixnum_divide"
             (##core#inline "C_i_bytevector_length" (##sys#slot x 1))
             16)
       'c128vector-ref)
     (let ((p (##core#inline "C_fixnum_times" i 2)))
       (make-rectangular
          (##core#inline_allocate ("C_a_u_i_f64vector_ref" 4) x p)
          (##core#inline_allocate ("C_a_u_i_f64vector_ref" 4)
            x (##core#inline "C_u_fixnum_plus" p 1)))))
   c128vector-set!
   "(chicken.number-vector#c128vector-ref v i)"))


;;; Basic constructors:

(define make-f32vector)
(define make-f64vector)
(define make-s16vector)
(define make-s32vector)
(define make-s64vector)
(define make-s8vector)
(define make-u8vector)
(define make-u16vector)
(define make-u32vector)
(define make-u64vector)
(define make-c64vector)
(define make-c128vector)
(define release-number-vector)

(let* ((ext-alloc
        (foreign-lambda* scheme-object ((size_t bytes))
          "if (bytes > C_HEADER_SIZE_MASK) C_return(C_SCHEME_FALSE);"
          "C_word *buf = (C_word *)C_malloc(bytes + sizeof(C_header));"
          "if(buf == NULL) C_return(C_SCHEME_FALSE);"
          "C_block_header_init(buf, C_make_header(C_BYTEVECTOR_TYPE, bytes));"
          "C_return(buf);") )
       ;; A u8vector is the bytevector itself, not a (tag . bytevector)
       ;; structure, so for one of those slot 1 is the second word of the
       ;; user data rather than the block ext-alloc malloc'd.
       (ext-free
        (foreign-lambda* void ((scheme-object v))
          "C_free(C_header_bits(v) == C_BYTEVECTOR_TYPE"
          "       ? (void *)v : (void *)C_block_item(v, 1));") )
       (real-part real-part)
       (imag-part imag-part)
       (alloc
        (lambda (loc elem-size elems ext? #!optional (fill #f))
          (##sys#check-fixnum elems loc)
          (when (fx< elems 0) (##sys#error loc "size is negative" elems))
          (let ((len (fx*? elems elem-size)))
            (unless len (##sys#error "overflow - cannot allocate the required number of elements" elems))
            (if ext?
                (let ((bv (ext-alloc len)))
                  (or bv
                      (##sys#error loc "not enough memory - cannot allocate external number vector" len)) )
                (##sys#allocate-bytevector len fill))))))

  (set! release-number-vector
    (lambda (v)
      (if (number-vector? v)
          (ext-free v)
          (##sys#error 'release-number-vector "bad argument type - not a number vector" v)) ) )

  (set! make-u8vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (when init (check-uint-length init 8 'make-u8vector))
      (let ((v (alloc 'make-u8vector 1 len ext? (and (not ext?) init))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        ;; the garbage-collected path was filled by the allocator
        (when (and init ext?)
          (do ((i 0 (##core#inline "C_fixnum_plus" i 1)))
              ((##core#inline "C_fixnum_greater_or_equal_p" i len))
            (##core#inline "C_setsubbyte" v i init)))
        v) ) )

  (set! make-s8vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (when init (check-int-length init 8 'make-s8vector))
      (let ((v (##sys#make-structure
                's8vector
                ;; C_memset takes the fill as an int and keeps the low byte,
                ;; which is the two's-complement encoding s8vector-set! would
                ;; have stored
                (alloc 'make-s8vector 1 len ext? (and (not ext?) init)))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        (when (and init ext?)
          (do ((i 0 (##core#inline "C_fixnum_plus" i 1)))
              ((##core#inline "C_fixnum_greater_or_equal_p" i len))
            (##core#inline "C_u_i_s8vector_set" v i init)))
        v) ) )

  (set! make-u16vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (let ((v (##sys#make-structure 'u16vector (alloc 'make-u16vector 2 len ext?))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        (if (not init)
            v
            (begin
              (check-uint-length init 16 'make-u16vector)
              (do ((i 0 (##core#inline "C_fixnum_plus" i 1)))
                  ((##core#inline "C_fixnum_greater_or_equal_p" i len) v)
                (##core#inline "C_u_i_u16vector_set" v i init) ) ) ) ) ) )

  (set! make-s16vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (let ((v (##sys#make-structure 's16vector (alloc 'make-s16vector 2 len ext?))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        (if (not init)
            v
            (begin
              (check-int-length init 16 'make-s16vector)
              (do ((i 0 (##core#inline "C_fixnum_plus" i 1)))
                  ((##core#inline "C_fixnum_greater_or_equal_p" i len) v)
                (##core#inline "C_u_i_s16vector_set" v i init) ) ) ) ) ) )

  (set! make-u32vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (let ((v (##sys#make-structure 'u32vector (alloc 'make-u32vector 4 len ext?))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        (if (not init)
            v
            (begin
              (check-uint-length init 32 'make-u32vector)
              (do ((i 0 (##core#inline "C_fixnum_plus" i 1)))
                  ((##core#inline "C_fixnum_greater_or_equal_p" i len) v)
                (##core#inline "C_u_i_u32vector_set" v i init) ) ) ) ) ) )

  (set! make-u64vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (let ((v (##sys#make-structure 'u64vector (alloc 'make-u64vector 8 len ext?))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        (if (not init)
            v
            (begin
              (check-uint-length init 64 'make-u64vector)
              (do ((i 0 (##core#inline "C_fixnum_plus" i 1)))
                  ((##core#inline "C_fixnum_greater_or_equal_p" i len) v)
                (##core#inline "C_u_i_u64vector_set" v i init) ) ) ) ) ) )

  (set! make-s32vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (let ((v (##sys#make-structure 's32vector (alloc 'make-s32vector 4 len ext?))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        (if (not init)
            v
            (begin
              (check-int-length init 32 'make-s32vector)
              (do ((i 0 (##core#inline "C_fixnum_plus" i 1)))
                  ((##core#inline "C_fixnum_greater_or_equal_p" i len) v)
                (##core#inline "C_u_i_s32vector_set" v i init) ) ) ) ) ) )

   (set! make-s64vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (let ((v (##sys#make-structure 's64vector (alloc 'make-s64vector 8 len ext?))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        (if (not init)
            v
            (begin
              (check-int-length init 64 'make-s64vector)
              (do ((i 0 (##core#inline "C_fixnum_plus" i 1)))
                  ((##core#inline "C_fixnum_greater_or_equal_p" i len) v)
                (##core#inline "C_u_i_s64vector_set" v i init) ) ) ) ) ) )

  (set! make-f32vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (let ((v (##sys#make-structure 'f32vector (alloc 'make-f32vector 4 len ext?))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        (if (not init)
            v
            (begin
              (check-int/flonum init 'make-f32vector)
              ;; the kernel returns C_SCHEME_UNDEFINED, so V stays the result
              (##core#inline "C_nv_f32_fill" v (->f init) 0 len)
              v) ) ) ) )

  (set! make-f64vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (let ((v (##sys#make-structure 'f64vector (alloc 'make-f64vector 8 len ext?))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        (if (not init)
            v
            (begin
              (check-int/flonum init 'make-f64vector)
              ;; the kernel returns C_SCHEME_UNDEFINED, so V stays the result
              (##core#inline "C_nv_f64_fill" v (->f init) 0 len)
              v) ) ) ) )

  (set! make-c64vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (let ((v (##sys#make-structure 'c64vector (alloc 'make-c64vector 8 len ext?))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        (if (not init)
            v
            (let ((len2 (fx* len 2))
                  (rp (->f/checked (real-part init) 'make-c64vector))
                  (ip (->f/checked (imag-part init) 'make-c64vector)))
              (do ((i 0 (fx+ i 2)))
                  ((fx>= i len2) v)
                (##core#inline "C_u_i_f32vector_set" v i rp)
                (##core#inline "C_u_i_f32vector_set" v (fx+ i 1) ip)))))))

  (set! make-c128vector
    (lambda (len #!optional (init #f)  (ext? #f) (fin? #t))
      (let ((v (##sys#make-structure 'c128vector (alloc 'make-c128vector 16 len ext?))))
        (when (and ext? fin?) (set-finalizer! v ext-free))
        (if (not init)
            v
            (let ((len2 (fx* len 2))
                  (rp (->f/checked (real-part init) 'make-c128vector))
                  (ip (->f/checked (imag-part init) 'make-c128vector)))
              (do ((i 0 (fx+ i 2)))
                  ((fx>= i len2) v)
                (##core#inline "C_u_i_f64vector_set" v i rp)
                (##core#inline "C_u_i_f64vector_set" v (fx+ i 1) ip))))))))


;;; Creating vectors from a list:

(define-syntax list->NNNvector
  (er-macro-transformer
   (lambda (x r c)
     (let* ((tag (strip-syntax (cadr x)))
            (tagstr (symbol->string tag))
            (name (string->symbol (string-append "list->" tagstr)))
            (make (string->symbol (string-append "make-" tagstr)))
            (set (string->symbol (string-append tagstr "-set!"))))
       `(define ,name
          (let ((,make ,make))
            (lambda (lst)
              (##sys#check-list lst ',tag)
              (let* ((n (##core#inline "C_i_length" lst))
                     (v (,make n)) )
                (do ((p lst (##core#inline "C_slot" p 1))
                     (i 0 (##core#inline "C_fixnum_plus" i 1)) )
                    ((##core#inline "C_eqp" p '()) v)
                  (,set v i (##core#inline "C_slot" p 0)) ) ) )))))))

(define list->u8vector ##sys#list->bytevector)

(list->NNNvector s8vector)
(list->NNNvector u16vector)
(list->NNNvector s16vector)
(list->NNNvector u32vector)
(list->NNNvector s32vector)
(list->NNNvector u64vector)
(list->NNNvector s64vector)
(list->NNNvector f32vector)
(list->NNNvector f64vector)

(define list->c64vector
  (let ((real-part real-part)
        (imag-part imag-part)
        (make-c64vector make-c64vector))
    (lambda (lst)
      (##sys#check-list lst 'list->c64vector)
      (let* ((n (##core#inline "C_i_length" lst))
             (v (make-c64vector n)))
        (do ((i 0 (##core#inline "C_u_fixnum_plus" i 2))
             (lst lst (##core#inline "C_slot" lst 1)))
            ((##core#inline "C_eqp" lst '()) v)
            (let ((x (##core#inline "C_slot" lst 0)))
              (##core#inline "C_u_i_f32vector_set" v i
               (->f/checked (real-part x) 'list->c64vector))
              (##core#inline "C_u_i_f32vector_set"
               v (##core#inline "C_u_fixnum_plus" i 1)
               (->f/checked (imag-part x) 'list->c64vector))))))))

(define list->c128vector
  (let ((real-part real-part)
        (imag-part imag-part)
        (make-c128vector make-c128vector))
    (lambda (lst)
      (##sys#check-list lst 'list->c128vector)
      (let* ((n (##core#inline "C_i_length" lst))
             (v (make-c128vector n)))
        (do ((i 0 (##core#inline "C_u_fixnum_plus" i 2))
             (lst lst (##core#inline "C_slot" lst 1)))
            ((##core#inline "C_eqp" lst '()) v)
            (let ((x (##core#inline "C_slot" lst 0)))
              (##core#inline "C_u_i_f64vector_set" v i
               (->f/checked (real-part x) 'list->c128vector))
              (##core#inline "C_u_i_f64vector_set"
               v (##core#inline "C_u_fixnum_plus" i 1)
               (->f/checked (imag-part x) 'list->c128vector))))))))


;;; More constructors:

(define u8vector
  (lambda xs (list->u8vector xs)) )

(define s8vector
  (lambda xs (list->s8vector xs)) )

(define u16vector
  (lambda xs (list->u16vector xs)) )

(define s16vector
  (lambda xs (list->s16vector xs)) )

(define u32vector
  (lambda xs (list->u32vector xs)) )

(define s32vector
  (lambda xs (list->s32vector xs)) )

(define u64vector
  (lambda xs (list->u64vector xs)) )

(define s64vector
  (lambda xs (list->s64vector xs)) )

(define f32vector
  (lambda xs (list->f32vector xs)) )

(define f64vector
  (lambda xs (list->f64vector xs)) )

(define c64vector
  (lambda xs (list->c64vector xs)) )

(define c128vector
  (lambda xs (list->c128vector xs)) )


;;; Creating lists from a vector:

(define-syntax NNNvector->list
  (er-macro-transformer
   (lambda (x r c)
     (let* ((tag (symbol->string (strip-syntax (cadr x))))
            (alloc (and (pair? (cddr x)) (caddr x)))
            (name (string->symbol (string-append tag "->list"))))
       `(define (,name v #!optional (start 0) end)
          (##sys#check-structure v ',(string->symbol tag) ',name)
          (let* ((len (##core#inline ,(string-append "C_u_i_" tag "_length") v))
                 (e (if end end len)))
            (##sys#check-range/including start 0 len ',name)
            (##sys#check-range/including e start len ',name)
            (let loop ((i (fx- e 1)) (acc '()))
              (if (fx< i start)
                  acc
                  (loop (fx- i 1)
                        (cons
                         ,(if alloc
                              `(##core#inline_allocate (,(string-append "C_a_u_i_" tag "_ref") ,alloc) v i)
                              `(##core#inline ,(string-append "C_u_i_" tag "_ref") v i))
                         acc) ) ) ) ) ) ) )))

(define (u8vector->list v #!optional (start 0) end)
  (##sys#check-bytevector v 'u8vector->list)
  (let* ((len (##sys#size v))
         (e (if end end len)))
    (##sys#check-range/including start 0 len 'u8vector->list)
    (##sys#check-range/including e start len 'u8vector->list)
    (if (and (eq? 0 start) (eq? e len))
        (##sys#bytevector->list v)
        (let loop ((i (fx- e 1)) (acc '()))
          (if (fx< i start)
              acc
              (loop (fx- i 1)
                    (cons (##core#inline "C_u_i_u8vector_ref" v i) acc)))))))

(NNNvector->list s8vector)
(NNNvector->list u16vector)
(NNNvector->list s16vector)
;; The alloc amounts here are for 32-bit words; this over-allocates on 64-bits
(NNNvector->list u32vector 6)
(NNNvector->list s32vector 6)
(NNNvector->list u64vector 7)
(NNNvector->list s64vector 7)
(NNNvector->list f32vector 4)
(NNNvector->list f64vector 4)

(define c64vector->list
  (let ((c64vector-length c64vector-length)
        (c64vector-ref c64vector-ref))
    (lambda (v #!optional (start 0) end)
      (##sys#check-structure v 'c64vector 'c64vector->list)
      (let* ((len (c64vector-length v))
             (e (if end end len)))
        (##sys#check-range/including start 0 len 'c64vector->list)
        (##sys#check-range/including e start len 'c64vector->list)
        (let loop ((i (fx- e 1)) (acc '()))
          (if (fx< i start)
              acc
              (loop (fx- i 1)
                    (cons (c64vector-ref v i) acc) ) ) ) ))))
    
(define c128vector->list
  (let ((c128vector-length c128vector-length)
        (c128vector-ref c128vector-ref))
    (lambda (v #!optional (start 0) end)
      (##sys#check-structure v 'c128vector 'c128vector->list)
      (let* ((len (c128vector-length v))
             (e (if end end len)))
        (##sys#check-range/including start 0 len 'c128vector->list)
        (##sys#check-range/including e start len 'c128vector->list)
        (let loop ((i (fx- e 1)) (acc '()))
          (if (fx< i start)
              acc
              (loop (fx- i 1)
                    (cons (c128vector-ref v i) acc) ) ) ) ) )))


;;; Predicates:

(define (u8vector? x) (##core#inline "C_i_bytevectorp" x))
(define (s8vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_i_s8vectorp" x)))
(define (u16vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_i_u16vectorp" x)))
(define (s16vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_i_s16vectorp" x)))
(define (u32vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_i_u32vectorp" x)))
(define (s32vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_i_s32vectorp" x)))
(define (u64vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_i_u64vectorp" x)))
(define (s64vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_i_s64vectorp" x)))
(define (f32vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_i_f32vectorp" x)))
(define (f64vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_i_f64vectorp" x)))
(define (c64vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_i_structurep" x 'c64vector)))
(define (c128vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_i_structurep" x 'c128vector)))

;; Catch-all predicate
(define (number-vector? x)
  (or (bytevector? x) (##sys#srfi-4-vector? x)))

;;; Accessing the packed bytevector:

(define (pack tag loc)
  (lambda (v)
    (##sys#check-structure v tag loc)
    (##sys#slot v 1) ) )

(define (pack-copy tag loc)
  (lambda (v)
    (##sys#check-structure v tag loc)
    (let* ((old (##sys#slot v 1))
	   (new (##sys#allocate-bytevector (##sys#size old) #f)))
      (##core#inline "C_copy_block" old new) ) ) )

(define (unpack tag sz loc)
  (lambda (str)
    (##sys#check-bytevector str loc)
    (let ((len (##sys#size str)))
      (if (or (eq? #t sz)
	      (eq? 0 (##core#inline "C_fixnum_modulo" len sz)))
	  (##sys#make-structure tag str)
	  (##sys#error loc "bytevector does not have correct size for packing" tag len sz) ) ) ) )

(define (unpack-copy tag sz loc)
  (lambda (str)
    (##sys#check-bytevector str loc)
    (let ((len (##sys#size str)))
      (if (or (eq? #t sz)
	      (eq? 0 (##core#inline "C_fixnum_modulo" len sz)))
	  ;; allocate unfilled, and only once the size is known to be good:
	  ;; ##sys#make-bytevector defaults its fill to 0, and C_fix(0) is
	  ;; truthy, so it memset a buffer C_copy_block immediately overwrote
	  (##sys#make-structure
	   tag
	   (##core#inline "C_copy_block" str (##sys#allocate-bytevector len #f)) )
	  (##sys#error loc "bytevector does not have correct size for packing" tag len sz) ) ) ) )

(define s8vector->bytevector/shared (pack 's8vector 's8vector->bytevector/shared))
(define u16vector->bytevector/shared (pack 'u16vector 'u16vector->bytevector/shared))
(define s16vector->bytevector/shared (pack 's16vector 's16vector->bytevector/shared))
(define u32vector->bytevector/shared (pack 'u32vector 'u32vector->bytevector/shared))
(define s32vector->bytevector/shared (pack 's32vector 's32vector->bytevector/shared))
(define u64vector->bytevector/shared (pack 'u64vector 'u64vector->bytevector/shared))
(define s64vector->bytevector/shared (pack 's64vector 's64vector->bytevector/shared))
(define f32vector->bytevector/shared (pack 'f32vector 'f32vector->bytevector/shared))
(define f64vector->bytevector/shared (pack 'f64vector 'f64vector->bytevector/shared))
(define c64vector->bytevector/shared (pack 'c64vector 'c64vector->bytevector/shared))
(define c128vector->bytevector/shared (pack 'c128vector 'c128vector->bytevector/shared))

(define s8vector->bytevector (pack-copy 's8vector 's8vector->bytevector))
(define u16vector->bytevector (pack-copy 'u16vector 'u16vector->bytevector))
(define s16vector->bytevector (pack-copy 's16vector 's16vector->bytevector))
(define u32vector->bytevector (pack-copy 'u32vector 'u32vector->bytevector))
(define s32vector->bytevector (pack-copy 's32vector 's32vector->bytevector))
(define u64vector->bytevector (pack-copy 'u64vector 'u64vector->bytevector))
(define s64vector->bytevector (pack-copy 's64vector 's64vector->bytevector))
(define f32vector->bytevector (pack-copy 'f32vector 'f32vector->bytevector))
(define f64vector->bytevector (pack-copy 'f64vector 'f64vector->bytevector))
(define c64vector->bytevector (pack-copy 'c64vector 'c64vector->bytevector))
(define c128vector->bytevector (pack-copy 'c128vector 'c128vector->bytevector))

(define bytevector->s8vector/shared (unpack 's8vector #t 'bytevector->s8vector/shared))
(define bytevector->u16vector/shared (unpack 'u16vector 2 'bytevector->u16vector/shared))
(define bytevector->s16vector/shared (unpack 's16vector 2 'bytevector->s16vector/shared))
(define bytevector->u32vector/shared (unpack 'u32vector 4 'bytevector->u32vector/shared))
(define bytevector->s32vector/shared (unpack 's32vector 4 'bytevector->s32vector/shared))
(define bytevector->u64vector/shared (unpack 'u64vector 8 'bytevector->u64vector/shared))
(define bytevector->s64vector/shared (unpack 's64vector 8 'bytevector->s64vector/shared))
(define bytevector->f32vector/shared (unpack 'f32vector 4 'bytevector->f32vector/shared))
(define bytevector->f64vector/shared (unpack 'f64vector 8 'bytevector->f64vector/shared))
(define bytevector->c64vector/shared (unpack 'c64vector 8 'bytevector->c64vector/shared))
(define bytevector->c128vector/shared (unpack 'c128vector 16 'bytevector->c128vector/shared))

(define bytevector->s8vector (unpack-copy 's8vector #t 'bytevector->s8vector))
(define bytevector->u16vector (unpack-copy 'u16vector 2 'bytevector->u16vector))
(define bytevector->s16vector (unpack-copy 's16vector 2 'bytevector->s16vector))
(define bytevector->u32vector (unpack-copy 'u32vector 4 'bytevector->u32vector))
(define bytevector->s32vector (unpack-copy 's32vector 4 'bytevector->s32vector))
(define bytevector->u64vector (unpack-copy 'u64vector 8 'bytevector->u64vector))
(define bytevector->s64vector (unpack-copy 's64vector 8 'bytevector->s64vector))
(define bytevector->f32vector (unpack-copy 'f32vector 4 'bytevector->f32vector))
(define bytevector->f64vector (unpack-copy 'f64vector 8 'bytevector->f64vector))
(define bytevector->c64vector (unpack-copy 'c64vector 8 'bytevector->c64vector))
(define bytevector->c128vector (unpack-copy 'c128vector 16 'bytevector->c128vector))

;;; Subvectors:

(define (subnvector v t es from to loc)
  (##sys#check-structure v t loc)
  (let* ([bv (##sys#slot v 1)]
	 [len (##sys#size bv)]
	 [ilen (##core#inline "C_u_fixnum_divide" len es)]
	 [to (if to to ilen)] )
    (##sys#check-range/including from 0 ilen loc)
    ;; anchor the second bound at FROM: checking both against 0 lets
    ;; FROM > TO through, and the negative size then barfs out of the
    ;; allocator with an internal byte count instead of the arguments
    (##sys#check-range/including to from ilen loc)
    (let* ([size2 (fx* es (fx- to from))]
	   [bv2 (##sys#allocate-bytevector size2 #f)] )
      (let ([v (##sys#make-structure t bv2)])
	(##core#inline "C_copy_subvector" bv2 bv 0 (fx* from es) size2)
	v) ) ) )

(define (subu8vector v #!optional (from 0) to)
  (##sys#check-bytevector v 'subu8vector)
  (let* ((n (##sys#size v))
         (to (if to to n)))
    (##sys#check-range/including from 0 n 'subu8vector)
    (##sys#check-range/including to from n 'subu8vector)
    (bytevector-copy v from to)))
  
(define (subu16vector v #!optional (from 0) to)
  (subnvector v 'u16vector 2 from to 'subu16vector))
(define (subu32vector v #!optional (from 0) to)
  (subnvector v 'u32vector 4 from to 'subu32vector))
(define (subu64vector v #!optional (from 0) to)
  (subnvector v 'u64vector 8 from to 'subu64vector))
(define (subs8vector v #!optional (from 0) to)
  (subnvector v 's8vector 1 from to 'subs8vector))
(define (subs16vector v #!optional (from 0) to)
  (subnvector v 's16vector 2 from to 'subs16vector))
(define (subs32vector v #!optional (from 0) to)
  (subnvector v 's32vector 4 from to 'subs32vector))
(define (subs64vector v #!optional (from 0) to)
  (subnvector v 's64vector 8 from to 'subs64vector))
(define (subf32vector v #!optional (from 0) to)
  (subnvector v 'f32vector 4 from to 'subf32vector))
(define (subf64vector v #!optional (from 0) to)
  (subnvector v 'f64vector 8 from to 'subf64vector))
(define (subc64vector v #!optional (from 0) to)
  (subnvector v 'c64vector 8 from to 'subc64vector))
(define (subc128vector v #!optional (from 0) to)
  (subnvector v 'c128vector 16 from to 'subc128vector))


;;; Bulk arithmetic and reduction on float vectors:
;
; Range convention.  Every operation takes an optional half-open [START END)
; *element* range which defaults to the whole vector -- the same convention as
; `subf64vector' above and as the R7RS `bytevector-copy' / `vector-fill!' in
; this tree.  `-copy!' additionally takes the destination index AT right after
; the destination vector, exactly like R7RS `bytevector-copy!', and copies with
; memmove semantics so overlapping ranges of the same vector are well defined.
; The two-vector combining operations (`-dot', `-axpy!') apply the SAME index
; range to both vectors and range-check both: a shorter second vector is an
; error, never a silent truncation.
;
; Checking.  The type and range checks are per call, not per element, so they
; are amortized to nothing by the kernel they guard and are therefore always
; performed; compiling the caller with `-unsafe' does not remove them, because
; these are ordinary out-of-line library procedures and not inlined intrinsics.
;
; Accuracy.  The elementwise operations are bit-identical to the equivalent
; element-at-a-time Scheme loop.  The reductions (`-sum', `-dot') sum into
; eight independent accumulators combined pairwise; see the C above.

(define-inline (%nvector-elements v es)
  (##core#inline "C_u_fixnum_divide" (##sys#size (##sys#slot v 1)) es))

(define (%nvector-check-range v tag es start end loc)
  (##sys#check-structure v tag loc)
  (let* ((len (%nvector-elements v es))
         (e (if end end len)))
    (##sys#check-range/including start 0 len loc)
    (##sys#check-range/including e start len loc)
    e))

(define (%nvector-check-covers v tag es end loc)
  (##sys#check-structure v tag loc)
  (##sys#check-range/including end 0 (%nvector-elements v es) loc))

(define-syntax define-nvector-bulk-ops
  (syntax-rules ()
    ((_ tag es fill! copy! scale! axpy! sum dot
        c-fill c-copy c-scale c-axpy c-sum c-dot)
     (begin
       (define (fill! v x #!optional (start 0) end)
         (let ((e (%nvector-check-range v 'tag es start end 'fill!)))
           (check-int/flonum x 'fill!)
           (##core#inline c-fill v (->f x) start e)))
       (define (copy! to at from #!optional (start 0) end)
         (let* ((e (%nvector-check-range from 'tag es start end 'copy!))
                (n (fx- e start)))
           (##sys#check-structure to 'tag 'copy!)
           (let ((tlen (%nvector-elements to es)))
             ;; Hand-rolled rather than ##sys#check-range/including
             ;; because the bound on AT is `at + n', which folds the
             ;; three conditions into one test.  The overflow of
             ;; (fx+ at n) is harmless: (fx> at tlen) has already
             ;; returned by then.
             (##sys#check-fixnum at 'copy!)
             (when (or (fx< at 0) (fx> at tlen) (fx> (fx+ at n) tlen))
               (##sys#error-hook
                (foreign-value "C_OUT_OF_BOUNDS_ERROR" int) 'copy! tlen at)))
           (##core#inline c-copy to at from start e)))
       (define (scale! v a #!optional (start 0) end)
         (let ((e (%nvector-check-range v 'tag es start end 'scale!)))
           (check-int/flonum a 'scale!)
           (##core#inline c-scale v (->f a) start e)))
       (define (axpy! y a x #!optional (start 0) end)
         (let ((e (%nvector-check-range y 'tag es start end 'axpy!)))
           (%nvector-check-covers x 'tag es e 'axpy!)
           (check-int/flonum a 'axpy!)
           (##core#inline c-axpy y (->f a) x start e)))
       (define (sum v #!optional (start 0) end)
         (let ((e (%nvector-check-range v 'tag es start end 'sum)))
           (##core#inline_allocate (c-sum 4) v start e)))
       (define (dot x y #!optional (start 0) end)
         (let ((e (%nvector-check-range x 'tag es start end 'dot)))
           (%nvector-check-covers y 'tag es e 'dot)
           (##core#inline_allocate (c-dot 4) x y start e)))))))

(define-nvector-bulk-ops
  f64vector 8
  f64vector-fill! f64vector-copy! f64vector-scale! f64vector-axpy!
  f64vector-sum f64vector-dot
  "C_nv_f64_fill" "C_nv_f64_copy" "C_nv_f64_scale" "C_nv_f64_axpy"
  "C_nv_f64_sum" "C_nv_f64_dot")

(define-nvector-bulk-ops
  f32vector 4
  f32vector-fill! f32vector-copy! f32vector-scale! f32vector-axpy!
  f32vector-sum f32vector-dot
  "C_nv_f32_fill" "C_nv_f32_copy" "C_nv_f32_scale" "C_nv_f32_axpy"
  "C_nv_f32_sum" "C_nv_f32_dot")

(register-feature! 'srfi-4)

) ; module chicken.number-vector

(module srfi-4
  (f32vector f32vector->list
   f32vector-length f32vector-ref f32vector-set! f32vector?
   f64vector f64vector->list
   f64vector-length f64vector-ref f64vector-set! f64vector?
   s8vector s8vector->list
   s8vector-length s8vector-ref s8vector-set! s8vector?
   s16vector s16vector->list
   s16vector-length s16vector-ref s16vector-set! s16vector?
   s32vector s32vector->list
   s32vector-length s32vector-ref s32vector-set! s32vector?
   s64vector s64vector->list
   s64vector-length s64vector-ref s64vector-set! s64vector?
   u8vector u8vector->list
   u8vector-length u8vector-ref u8vector-set! u8vector?
   u16vector u16vector->list
   u16vector-length u16vector-ref u16vector-set! u16vector?
   u32vector u32vector->list
   u32vector-length u32vector-ref u32vector-set! u32vector?
   u64vector u64vector->list
   u64vector-length u64vector-ref u64vector-set! u64vector?
   list->f32vector list->f64vector list->s16vector list->s32vector
   list->s64vector list->s8vector list->u16vector list->u32vector
   list->u8vector list->u64vector
   make-f32vector make-f64vector make-s16vector make-s32vector
   make-s64vector make-s8vector make-u16vector make-u32vector
   make-u64vector make-u8vector)
(import (chicken number-vector)))

           
;;; Read syntax:

(import scheme (chicken number-vector))
           
(set! ##sys#user-read-hook
  (let ((old-hook ##sys#user-read-hook)
	(consers (list 'u8 chicken.number-vector#list->u8vector
		       's8 chicken.number-vector#list->s8vector
		       'u16 chicken.number-vector#list->u16vector
		       's16 chicken.number-vector#list->s16vector
		       'u32 chicken.number-vector#list->u32vector
		       's32 chicken.number-vector#list->s32vector
		       'u64 chicken.number-vector#list->u64vector
		       's64 chicken.number-vector#list->s64vector
		       'f32 chicken.number-vector#list->f32vector
		       'f64 chicken.number-vector#list->f64vector
                       'c64 chicken.number-vector#list->c64vector
                       'c128 chicken.number-vector#list->c128vector) ) )
    (lambda (char port)
      (if (memq char '(#\u #\s #\f #\c))
	  (let* ((x (##sys#read port ##sys#default-read-info-hook))
		 (tag (and (symbol? x) x)) )
	    (cond ((or (eq? tag 'f) (eq? tag 'false)) #f)
		  ((memq tag consers) => 
                    (lambda (c) 
                      (let ((d (##sys#read-numvector-data port)))
                        (cond ((or (null? d) (pair? d))
                               ((cadr c) (##sys#canonicalize-number-list! d)))
                              ((eq? tag 'u8) 
                               ;; reuse already created bytevector
                               (##core#inline "C_chop_bv" (##sys#slot d 0)))
                              (else 
                               ((cadr c) (##sys#canonicalize-number-list! (list d))))))))
		  (else (##sys#read-error port "invalid sharp-sign read syntax" tag)) ) )
	  (old-hook char port) ) ) ) )


;;; Printing:

(set! ##sys#user-print-hook
  ;; the dispatch table is built once, not per call: its unquotes are
  ;; global variables, so a quasiquote in the body allocated it afresh
  ;; every time -- and library.scm routes every structure through this
  ;; hook, so the cost fell on records, conditions, ports and hash tables
  ;; as much as on number vectors
  (let ((old-hook ##sys#user-print-hook)
        (tags `((u8vector u8 ,chicken.number-vector#u8vector->list)
          (s8vector s8 ,chicken.number-vector#s8vector->list)
          (u16vector u16 ,chicken.number-vector#u16vector->list)
          (s16vector s16 ,chicken.number-vector#s16vector->list)
          (u32vector u32 ,chicken.number-vector#u32vector->list)
          (s32vector s32 ,chicken.number-vector#s32vector->list)
          (u64vector u64 ,chicken.number-vector#u64vector->list)
          (s64vector s64 ,chicken.number-vector#s64vector->list)
          (f32vector f32 ,chicken.number-vector#f32vector->list)
          (f64vector f64 ,chicken.number-vector#f64vector->list)
          (c64vector c64 ,chicken.number-vector#c64vector->list)
          (c128vector c128 ,chicken.number-vector#c128vector->list))))
    (lambda (x readable port)
      (let ((tag (assq (##core#inline "C_slot" x 0) tags)))
	(cond (tag
	       (##sys#print #\# #f port)
	       (##sys#print (cadr tag) #f port)
	       (##sys#print ((caddr tag) x) #t port) )
	      (else (old-hook x readable port)) ) ) ) ) )
