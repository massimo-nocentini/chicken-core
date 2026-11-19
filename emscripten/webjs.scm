;;;; webjs.scm - the bridge between Scheme and JavaScript in the web csi
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


; The module `js' lets Scheme in the REPL and in notebook cells call
; the JavaScript of the worker that runs csi (repl-worker.js), and
; that JavaScript call Scheme back:
;
;   (import js)
;   (js-call (js-global "Math.max") 1 5 3)              => 5
;   (js-invoke (js-eval "[3,1,2]") "map" (lambda (x) (* x x)))
;   (js-await (js-eval "fetch('data.json')"))
;
; The unit is linked into the web csi (csi-web.c is translated with
; "-uses webjs") and only registers the module, whose library is the
; unit itself, so (import js) loads nothing.  It talks to the
; JavaScript half of the bridge (webjs-pre.js) through webjs-main.c:
; the arguments of an operation are pushed onto a stack there, the
; operation runs (webjs_op, a foreign-safe-lambda, the only call that
; runs JavaScript of the user's), and its result is read back from
; descriptors JavaScript made of it.
;
; Values cross as copies when they are numbers, strings, booleans,
; vectors and bytevectors (and SRFI-4 vectors), as JavaScript objects
; held by a js-object record (a handle), or as Scheme objects held by
; an opaque wrapper, which comes back as the very same object.  A
; procedure crosses as a function: called while Scheme waits on the
; operation that runs it (the user's code inside js-call, a map, an
; event Scheme dispatched), it runs at once as a callback (the
; trampoline below), and returns its value or throws its error, a
; SchemeError, which is raised again as itself in Scheme if nothing
; catches it.  A continuation that leaves such a callback (an early
; exit from a forEach) is carried out of the JavaScript frames below
; it first; re-entering a callback that has returned is an error.  A
; call from JavaScript at any other time (a timer, a promise reaction)
; is queued, and gives a promise: it runs at the next toplevel wait --
; the REPL's prompt (webio.scm), the notebook kernel's wait for a
; request (webnb.scm), js-await -- as Scheme of its own, with standard
; ports of its own and its own exception handler, whose error it
; reports and rejects the promise with (see "Calls from JavaScript
; that wait" below).
;
; js-await waits for a promise in state AWAITING (webrepl-main.c),
; returning to the host until it settles or Stop interrupts it, and
; runs the queued calls meanwhile.  The worker's console writes to the
; standard ports through this unit (console-writer).
;
; JavaScript cells of the notebook run here too (run-js, which webnb
; calls through ##webnb#js-hook): their source is evaluated by
; JavaScript as a script named after the cell, whose top-level
; declarations outlive it, and its value comes back with the
; JavaScript text that shows it (a promise is waited for, as js-await
; does).  JavaScript reaches Scheme through the worker's global
; `scheme' (eval, env, call, async, list, toArray and the notebook's
; rich output), whose procedures are entries of the table below.  The
; notebook kernel attributes the calls from JavaScript to the cell they
; come from: it sets ##webjs#crossing-hook, whose value tags each entry
; of the table, and ##webjs#call-hook, which runs a queued call (as
; that cell's, framed by the events async-start and async-done when
; the cell no longer runs) and says whether it reported its outcome.
;
; The REPL's toplevel command ",js SOURCE" runs SOURCE with run-js
; too, as the script js[N], so that its names persist from line to
; line as a cell's do, and prints the value as the REPL prints one, or
; the JavaScript error with its stack.  csi gets the command at its
; first prompt (##webio#first-prompt-hook), once its body has run.
;
; Only the ##webjs# globals are visible outside the unit, so cells
; cannot clobber its state; redefining an export -- (define (js-call
; . x) 'clobbered) in a cell -- assigns the exported global, never
; what webjs itself calls.  Nor can a cell break it by redefining a
; library procedure: it calls its own copies (see "Library
; procedures" below).


(declare
  (unit webjs)
  (uses webio webnb)
  (disable-interrupts)
  ;; every toplevel name but the ##webjs# ones (not "block": it would
  ;; take the ##sys# globals assigned here for this unit's own)
  (hide run-op args-begin! push-undefined! push-null! push-bool! push-number!
	push-digits-utf8! push-utf8! push-handle! push-scheme! push-array! push-bytes!
	desc-kind desc-number desc-length desc-copy! desc-bytes-type desc-id
	desc-gen desc-child handle-text-length handle-text-copy! unref!
	callback-result! make-error! make-function! release-function!
	released-count released-index released-gen released-clear! ops-active
	object-tag null-tag js-null max-safe srfi-4-tags
	table gens table-free table-next grow-table! table-add! table-ref
	table-free! drain-released! make-handle release-record! live-id
	handle-text read-text signal-error type-error safe-integer?
	push-string! push-digits! push-object! push-value! push! push-vector!
	push-list! push-key! srfi-4-type read-value raise-js-error run! op
	escape-k interrupt-pending interrupt-condition user-interrupt?
	condition-text callback-error! max-arity read-args trampoline
	run-callback webjs_callback check-handle check-string push-args!
	js-global js-ref js-set! js-has? js-delete! js-keys js-call js-invoke
	js-new js-eval js-object? js-null? js-undefined js-undefined?
	js-nullish? make-function js-function js-method js-release! js->list
	js->vector list->js vector->js js->alist alist->js js-obj js-typeof
	js-instanceof? js-same? js->string js->bytevector js->number-vector
	pending-take pending-drop! settle! await-state await-take! await-abandon!
	set-console! inbox-size interrupted? default-interrupt-hook
	run-one-pending! call-clean settle-call! report-call-error js-await
	await-loop js-async-function console-writer
	run-js read-shown pending-rid set-api! lookup resolve given notebook-only
	map-list api-eval api-env-ref api-env-set api-env-has api-call api-list
	api-to-array api-show api-clear api-html api-svg api-markdown api-text
	api-table api-image
	incomplete-js js-incomplete? js-count blank? read-js-source js-condition?
	report-js-error print-js-value js-command
	;; the library procedures it calls (see below)
	value-of call/cc dynamic-wind apply with-exception-handler abort
	eval read string->symbol list? read-line
	get-condition-property make-property-condition
	make-composite-condition error set-finalizer! set-record-printer!
	procedure-information string->uninterned-symbol keyword?
	keyword->string symbol->string string->number number->string
	inexact->exact exact->inexact list->vector make-vector
	open-output-string get-output-string bytevector-length make-bytevector
	string->utf8 utf8->string open-input-string display)
  (foreign-declare "#include \"webrepl.h\""))

(import (except scheme call-with-current-continuation dynamic-wind apply
		symbol->string string->number number->string inexact->exact
		exact->inexact list->vector make-vector open-input-string display
		eval read string->symbol list?)
	(except chicken.base error procedure-information
		string->uninterned-symbol set-record-printer!)
	(except chicken.condition with-exception-handler abort
		get-condition-property make-property-condition
		make-composite-condition)
	(except chicken.gc set-finalizer!)
	(except chicken.keyword keyword? keyword->string)
	(except chicken.bytevector bytevector-length make-bytevector string->utf8
		utf8->string)
	chicken.fixnum chicken.foreign)

;;; Library procedures
;
; A cell's toplevel define assigns the global of the name it defines,
; scheme#apply say, as csi lets it.  The bridge calls these copies
; instead: its own hidden globals (the names are left out of the
; imports above), taken when the unit is loaded, after the units it
; uses and before any cell.  The procedures the compiler open-codes,
; car or fx+, need none.

;; not (define apply scheme#apply): a hidden global never assigned
;; again is an alias, which the compiler replaces with what it names
(define (value-of global) (##sys#slot global 0))

;; (not ##sys#call-with-current-continuation, whose continuations skip
;; the after thunks of dynamic-wind)
(define call/cc (value-of 'scheme#call-with-current-continuation))
(define dynamic-wind (value-of 'scheme#dynamic-wind))
(define apply (value-of 'scheme#apply))
(define symbol->string (value-of 'scheme#symbol->string))
(define string->number (value-of 'scheme#string->number))
(define number->string (value-of 'scheme#number->string))
(define inexact->exact (value-of 'scheme#inexact->exact))
(define exact->inexact (value-of 'scheme#exact->inexact))
(define list->vector (value-of 'scheme#list->vector))
(define make-vector (value-of 'scheme#make-vector))
(define open-output-string (value-of 'scheme#open-output-string))
(define get-output-string (value-of 'scheme#get-output-string))
(define open-input-string (value-of 'scheme#open-input-string))
(define display (value-of 'scheme#display))
(define eval (value-of 'scheme#eval))
(define read (value-of 'scheme#read))
(define string->symbol (value-of 'scheme#string->symbol))
(define list? (value-of 'scheme#list?))
(define read-line (value-of 'chicken.io#read-line))
(define error (value-of 'chicken.base#error))
(define procedure-information (value-of 'chicken.base#procedure-information))
(define string->uninterned-symbol (value-of 'chicken.base#string->uninterned-symbol))
(define set-record-printer! (value-of 'chicken.base#set-record-printer!))
(define with-exception-handler (value-of 'chicken.condition#with-exception-handler))
(define abort (value-of 'chicken.condition#abort))
(define get-condition-property (value-of 'chicken.condition#get-condition-property))
(define make-property-condition (value-of 'chicken.condition#make-property-condition))
(define make-composite-condition (value-of 'chicken.condition#make-composite-condition))
(define set-finalizer! (value-of 'chicken.gc#set-finalizer!))
(define keyword? (value-of 'chicken.keyword#keyword?))
(define keyword->string (value-of 'chicken.keyword#keyword->string))
(define bytevector-length (value-of 'chicken.bytevector#bytevector-length))
(define make-bytevector (value-of 'chicken.bytevector#make-bytevector))
(define string->utf8 (value-of 'chicken.bytevector#string->utf8))
(define utf8->string (value-of 'chicken.bytevector#utf8->string))


;;; The C entries (webjs-main.c).  The constants are those of
;;; webjs-main.c and webjs-pre.js.

;; descriptor kinds
(define-constant K-UNDEFINED 0)
(define-constant K-NULL 1)
(define-constant K-FALSE 2)
(define-constant K-TRUE 3)
(define-constant K-INTEGER 4)
(define-constant K-FLONUM 5)
(define-constant K-BIGINT 6)
(define-constant K-STRING 7)
(define-constant K-HANDLE 8)
(define-constant K-SCHEME 9)
(define-constant K-LIST 10)
(define-constant K-BYTES 11)

;; ops
(define-constant OP-GLOBAL 1)
(define-constant OP-REF 2)
(define-constant OP-SET 3)
(define-constant OP-HAS 4)
(define-constant OP-DELETE 5)
(define-constant OP-KEYS 6)
(define-constant OP-CALL 7)
(define-constant OP-INVOKE 8)
(define-constant OP-NEW 9)
(define-constant OP-EVAL 10)
(define-constant OP-AWAIT 11)
(define-constant OP-INSTANCEOF 12)
(define-constant OP-SAME 13)
(define-constant OP-TOSTRING 14)
(define-constant OP-FROM 15)
(define-constant OP-ENTRIES 16)
(define-constant OP-OBJECT 17)
(define-constant OP-BYTES 18)
(define-constant OP-IDENTITY 19)
(define-constant OP-RUN-JS 20)

;; and their statuses
(define-constant OP-VALUE 0)
(define-constant OP-JS-ERROR 1)
(define-constant OP-SCHEME-ERROR 2)
(define-constant OP-ESCAPE 3)
(define-constant OP-PENDING 4)

;; the statuses of a callback (webjs_dispatch)
(define-constant CB-OK 0)
(define-constant CB-ERROR 1)
(define-constant CB-ESCAPE 2)
(define-constant CB-RELEASED 4)

;; what a Scheme object crosses as
(define-constant KIND-OBJECT 0)
(define-constant KIND-FUNCTION 1)
(define-constant KIND-METHOD 2)
(define-constant KIND-ASYNC 3)

;; how a queued call is settled (webjs_settle)
(define-constant SETTLE-RESOLVE 0)
(define-constant SETTLE-SCHEME-ERROR 1)
(define-constant SETTLE-ERROR 2)

;; the procedures of the global `scheme' (webjs-pre.js's API_...)
(define-constant API-EVAL 0)
(define-constant API-ENV-REF 1)
(define-constant API-ENV-SET 2)
(define-constant API-ENV-HAS 3)
(define-constant API-CALL 4)
(define-constant API-LIST 5)
(define-constant API-TO-ARRAY 6)
(define-constant API-SHOW 7)
(define-constant API-CLEAR 8)
(define-constant API-HTML 9)
(define-constant API-SVG 10)
(define-constant API-MARKDOWN 11)
(define-constant API-TEXT 12)
(define-constant API-TABLE 13)
(define-constant API-IMAGE 14)

(define-constant ST-AWAITING 7)

(define run-op            (foreign-safe-lambda int "webjs_op" int int))
(define args-begin!       (foreign-lambda void "webjs_args_begin"))
(define push-undefined!   (foreign-lambda void "webjs_push_undefined"))
(define push-null!        (foreign-lambda void "webjs_push_null"))
(define push-bool!        (foreign-lambda void "webjs_push_bool" bool))
(define push-number!      (foreign-lambda void "webjs_push_number" double))
(define push-digits-utf8! (foreign-lambda void "webjs_push_bigint" bytevector int))
(define push-utf8!        (foreign-lambda void "webjs_push_string" bytevector int))
(define push-handle!      (foreign-lambda void "webjs_push_handle" int))
(define push-scheme!      (foreign-lambda void "webjs_push_scheme" int int int))
(define push-array!       (foreign-lambda void "webjs_push_array" int))
(define push-bytes!       (foreign-lambda void "webjs_push_bytes" int bytevector int))
(define desc-kind         (foreign-lambda int "webjs_kind" int))
(define desc-number       (foreign-lambda double "webjs_number" int))
(define desc-length       (foreign-lambda int "webjs_length" int))
(define desc-copy!        (foreign-lambda void "webjs_copy" int bytevector))
(define desc-bytes-type   (foreign-lambda int "webjs_bytes_type" int))
(define desc-id           (foreign-lambda int "webjs_id" int))
(define desc-gen          (foreign-lambda int "webjs_gen" int))
(define desc-child        (foreign-lambda int "webjs_child" int int))
(define handle-text-length (foreign-lambda int "webjs_text" int int))
(define handle-text-copy! (foreign-lambda void "webjs_text_copy" bytevector))
(define unref!            (foreign-lambda void "webjs_unref" int))
(define callback-result!  (foreign-lambda void "webjs_callback_result"))
(define make-error!       (foreign-lambda void "webjs_make_error"))
(define make-function!    (foreign-lambda int "webjs_make_function" int int int))
(define release-function! (foreign-lambda void "webjs_release_function" int))
(define released-count    (foreign-lambda int "webjs_released_count"))
(define released-index    (foreign-lambda int "webjs_released_index" int))
(define released-gen      (foreign-lambda int "webjs_released_gen" int))
(define released-clear!   (foreign-lambda void "webjs_released_clear"))
(define ops-active        (foreign-lambda int "webjs_ops_active"))
(define inbox-size        (foreign-lambda int "webjs_inbox_size"))
(define pending-take      (foreign-lambda int "webjs_pending_take"))
(define pending-drop!     (foreign-lambda void "webjs_pending_drop" int))
(define settle!           (foreign-lambda void "webjs_settle" int int))
(define await-state       (foreign-lambda int "webjs_await_state" int))
(define await-take!       (foreign-lambda void "webjs_await_take" int))
(define await-abandon!    (foreign-lambda void "webjs_await_abandon" int))
(define set-console!      (foreign-lambda void "webjs_set_console" int int))
(define pending-rid       (foreign-lambda int "webjs_pending_rid"))
(define set-api!          (foreign-lambda void "webjs_set_api" int int int))
(define incomplete-js     (foreign-lambda int "webjs_incomplete"))
(define interrupted?      (foreign-lambda bool "webio_take_interrupt"))


;;; Records.  A js-object record holds the id of a JavaScript object,
;;; #f once released, and for a function made by js-function, js-method
;;; or js-async-function the table entry of its procedure.  The tags are
;;; uninterned, so no record a user defines is taken for one.  JS
;;; interns its objects: records of the same object have the same id,
;;; so equal? holds for them (eq? need not).

(define object-tag (string->uninterned-symbol "js-object"))
(define null-tag (string->uninterned-symbol "js-null"))
(define js-null (##sys#make-structure null-tag))

;; Each record holds one count of its id, released by its finalizer or
;; by js-release!, whichever comes first.
(define (release-record! r)
  (let ((id (##sys#slot r 1)))
    (when id
      (##sys#setslot r 1 #f)
      (unref! id))))

(define (make-handle id windex wgen)
  (let ((r (##sys#make-structure object-tag id windex wgen)))
    (set-finalizer! r release-record!)
    r))

(define (signal-error loc msg)
  (if loc (error loc msg) (error msg)))

(define (type-error loc msg x)
  (##sys#signal-hook #:type-error loc msg x))

(define (live-id h loc)
  (or (##sys#slot h 1) (signal-error loc "released JavaScript object")))

(define (check-handle x loc)
  (unless (##sys#structure? x object-tag)
    (type-error loc "bad argument type - not a JavaScript object" x)))

(define (check-string x loc)
  (unless (string? x) (type-error loc "bad argument type - not a string" x)))

;; DESC (WHAT 0) or the typeof (1) JavaScript recorded for handle ID
(define (handle-text id what)
  (let ((bv (make-bytevector (handle-text-length id what))))
    (handle-text-copy! bv)
    (utf8->string bv)))

(set-record-printer! object-tag
  (lambda (r port)
    (let ((id (##sys#slot r 1)))
      (##sys#print "#<js-object " #f port)
      (##sys#print (if id (handle-text id 0) "released") #f port)
      (##sys#print ">" #f port))))

(set-record-printer! null-tag
  (lambda (r port) (##sys#print "#<js-null>" #f port)))


;;; The table of the Scheme objects held by JavaScript: an entry
;;; (object . tag) per crossing, the tag being what
;;; ##webjs#crossing-hook gives then.  An entry is freed when
;;; JavaScript's garbage collector frees its wrapper (the release queue
;;; of webjs-pre.js, drained at every op), and its generation goes up,
;;; so that a late or repeated release never frees a reused entry.

(define table (make-vector 64 #f))
(define gens (make-vector 64 0))
(define table-free '())
(define table-next 0)

(define (##webjs#crossing-hook) #f)

(define (grow-table!)
  (let* ((n (vector-length table))
	 (t (make-vector (fx* 2 n) #f))
	 (g (make-vector (fx* 2 n) 0)))
    (do ((i 0 (fx+ i 1))) ((fx= i n))
      (vector-set! t i (vector-ref table i))
      (vector-set! g i (vector-ref gens i)))
    (set! table t)
    (set! gens g)))

(define (table-add! x)
  (let ((i (if (pair? table-free)
	       (let ((i (car table-free)))
		 (set! table-free (cdr table-free))
		 i)
	       (begin
		 (when (fx= table-next (vector-length table)) (grow-table!))
		 (set! table-next (fx+ table-next 1))
		 (fx- table-next 1)))))
    (vector-set! table i (cons x (##webjs#crossing-hook)))
    i))

(define (table-ref i g)
  (and (fx>= i 0) (fx< i table-next) (fx= (vector-ref gens i) g)
       (vector-ref table i)))

(define (table-free! i g)
  (when (table-ref i g)
    (vector-set! table i #f)
    (vector-set! gens i (fxand (fx+ g 1) #x3fffffff))
    (set! table-free (cons i table-free))))

(define (drain-released!)
  (let ((n (released-count)))
    (unless (fx= n 0)
      (do ((k 0 (fx+ k 1))) ((fx= k n))
	(table-free! (released-index k) (released-gen k)))
      (released-clear!))))


;;; Scheme -> JavaScript: each value is pushed with one pusher, vectors
;;; element by element first.

(define max-safe 9007199254740991)	; 2^53-1: integers JS numbers hold
(define-constant max-depth 512)
;; the element types of SRFI-4 vectors, as webjs-pre.js has them (u8
;; vectors are bytevectors)
(define srfi-4-tags
  '#(u8vector s8vector u16vector s16vector u32vector s32vector
	      u64vector s64vector f32vector f64vector))

(define (safe-integer? x)
  (and (##core#inline "C_i_exact_integerp" x) (<= x max-safe) (>= x (- max-safe))))

(define (push-string! s)
  (let ((bv (string->utf8 s)))
    (push-utf8! bv (bytevector-length bv))))

(define (push-digits! x)		; a BigInt
  (let ((bv (string->utf8 (number->string x))))
    (push-digits-utf8! bv (bytevector-length bv))))

(define (push-object! x kind)
  (let ((i (table-add! x)))
    (push-scheme! i (vector-ref gens i) kind)))

(define (srfi-4-type x)
  (and (##core#inline "C_structurep" x)
       (let ((tag (##sys#slot x 0)))
	 (let loop ((t 1))
	   (cond ((fx= t (vector-length srfi-4-tags)) #f)
		 ((eq? tag (vector-ref srfi-4-tags t))
		  (and (bytevector? (##sys#slot x 1)) t))
		 (else (loop (fx+ t 1))))))))

(define (push-value! x loc) (push! x loc '() 0))

;; PATH: the vectors (and lists, for list->js) X is inside
(define (push! x loc path depth)
  (cond ((eq? x (##core#undefined)) (push-undefined!))
	((eq? x js-null) (push-null!))
	((boolean? x) (push-bool! x))
	((##core#inline "C_i_exact_integerp" x)
	 (if (safe-integer? x) (push-number! (exact->inexact x)) (push-digits! x)))
	((flonum? x) (push-number! x))
	((and (number? x) (real? x)) (push-number! (exact->inexact x))) ; a ratio
	((string? x) (push-string! x))
	((char? x) (push-string! (string x)))
	((keyword? x) (push-string! (keyword->string x)))
	((symbol? x) (push-string! (symbol->string x)))
	((##sys#structure? x object-tag) (push-handle! (live-id x loc)))
	((procedure? x) (push-object! x KIND-FUNCTION))
	((vector? x) (push-vector! x loc path depth))
	((bytevector? x) (push-bytes! 0 x (bytevector-length x)))
	((srfi-4-type x) =>
	 (lambda (t)
	   (let ((bv (##sys#slot x 1)))
	     (push-bytes! t bv (bytevector-length bv)))))
	(else (push-object! x KIND-OBJECT))))

(define (push-vector! v loc path depth)
  (cond ((memq v path) (signal-error loc "circular structure"))
	((fx>= depth max-depth) (signal-error loc "too deeply nested"))
	(else
	 (let ((n (vector-length v))
	       (path (cons v path)))
	   (do ((i 0 (fx+ i 1))) ((fx= i n))
	     (push! (vector-ref v i) loc path (fx+ depth 1)))
	   (push-array! n)))))

;; a proper list L as an Array; DEEP? converts the proper lists in it so
(define (push-list! l loc deep? path depth)
  (cond ((memq l path) (signal-error loc "circular structure"))
	((fx>= depth max-depth) (signal-error loc "too deeply nested"))
	(else
	 (let ((path (cons l path)))
	   (let loop ((l l) (n 0))
	     (if (pair? l)
		 (let ((x (car l)))
		   (if (and deep? (list? x))
		       (push-list! x loc deep? path (fx+ depth 1))
		       (push! x loc path (fx+ depth 1)))
		   (loop (cdr l) (fx+ n 1)))
		 (push-array! n)))))))

;; a property key: a string, a symbol or keyword (its name), an
;; integer, or a handle of a JavaScript Symbol
(define (push-key! k loc)
  (cond ((string? k) (push-string! k))
	((keyword? k) (push-string! (keyword->string k)))
	((symbol? k) (push-string! (symbol->string k)))
	((safe-integer? k) (push-number! (exact->inexact k)))
	((and (##sys#structure? k object-tag)
	      (string=? "symbol" (handle-text (live-id k loc) 1)))
	 (push-handle! (##sys#slot k 1)))
	(else (type-error loc "bad argument type - not a property key" k))))

(define (push-args! l loc)		; -> how many
  (let loop ((l l) (n 0))
    (if (pair? l)
	(begin
	  (push-value! (car l) loc)
	  (loop (cdr l) (fx+ n 1)))
	n)))


;;; JavaScript -> Scheme: the descriptors of the inbox, read whole by
;;; the procedure that ran the op, before anything else can replace
;;; them.

(define (read-text i)
  (let ((bv (make-bytevector (desc-length i))))
    (desc-copy! i bv)
    (utf8->string bv)))

(define (read-value i loc)
  (let ((k (desc-kind i)))
    (cond ((fx= k K-UNDEFINED) (##core#undefined))
	  ((fx= k K-NULL) js-null)
	  ((fx= k K-FALSE) #f)
	  ((fx= k K-TRUE) #t)
	  ((fx= k K-INTEGER) (inexact->exact (desc-number i)))
	  ((fx= k K-FLONUM) (desc-number i))
	  ((fx= k K-BIGINT) (string->number (read-text i)))
	  ((fx= k K-STRING) (read-text i))
	  ((fx= k K-HANDLE) (make-handle (desc-id i) #f #f))
	  ((fx= k K-SCHEME)
	   (let ((e (table-ref (desc-id i) (desc-gen i))))
	     (if e (car e) (signal-error loc "released Scheme object"))))
	  ((fx= k K-LIST)
	   (let loop ((j (fx- (desc-length i) 1)) (l '()))
	     (if (fx< j 0)
		 l
		 (loop (fx- j 1) (cons (read-value (desc-child i j) loc) l)))))
	  ((fx= k K-BYTES)
	   (let ((bv (make-bytevector (desc-length i)))
		 (t (desc-bytes-type i)))
	     (desc-copy! i bv)
	     (if (fx= t 0) bv (##sys#make-structure (vector-ref srfi-4-tags t) bv))))
	  (else (signal-error loc "released Scheme object"))))) ; a released wrapper

;; the error the user's JavaScript threw, as a condition (exn js): its
;; frames are (where proc) lists of strings, the innermost last, and
;; incomplete says that a JavaScript cell's source was not finished
(define (raise-js-error loc)
  (let* ((n (inbox-size))
	 (val (read-value 0 loc))
	 (msg (read-value 1 loc))
	 (name (read-value 2 loc))
	 (stack (read-value 3 loc))
	 (frames (if (fx> n 4) (read-value 4 loc) '()))
	 (incomplete (and (fx> n 5) (eq? #t (read-value 5 loc)))))
    (abort
     (make-composite-condition
      (make-property-condition 'exn 'message msg 'location loc 'arguments '())
      (make-property-condition 'js 'error val 'name (and (string? name) name)
			       'stack (and (string? stack) stack)
			       'frames (if (list? frames) frames '())
			       'incomplete incomplete)))))


;;; Operations.  A continuation that left a callback inside the op
;;; (ESCAPE, see the trampoline) goes on from here; a Scheme error that
;;; crossed the user's JavaScript is raised again as itself.  run!
;;; returns the status of the others (VALUE, or PENDING for js-await).

(define escape-k #f)			; the rest of the escape
;; A Stop seen inside a callback: every later callback fails at once
;; with it, until the outermost op returns, which raises it again
;; (whatever JavaScript did with the error).
(define interrupt-pending #f)
(define interrupt-condition #f)

(define (run! code argc loc)
  (##webio#flush)			; what Scheme wrote comes first
  (drain-released!)
  (when (fx= (ops-active) 0)		; left by an exit that skipped run!
    (set! interrupt-pending #f)
    (set! escape-k #f))
  (let ((st (run-op code argc)))
    (when (and interrupt-pending (fx= (ops-active) 0))
      (set! interrupt-pending #f)
      (set! escape-k #f)
      (##sys#user-interrupt-hook))
    (cond ((fx= st OP-JS-ERROR) (raise-js-error loc))
	  ((fx= st OP-SCHEME-ERROR) (abort (read-value 0 loc)))
	  ((fx= st OP-ESCAPE)
	   (let ((k escape-k))
	     (set! escape-k #f)
	     (k #f)))
	  (else st))))

(define (op code argc loc)
  (run! code argc loc)
  (read-value 0 loc))


;;; Calls from JavaScript (webjs_dispatch, webjs-main.c), running
;;; procedure INDEX of the table with the ARGC arguments of the inbox.
;;;
;;; The procedure runs inside a dynamic-wind (and the copy of call/cc
;;; that honours it), with an exception handler innermost:
;;;
;;; - its value (the first one, or undefined for none) is pushed and
;;;   returned (CB-OK);
;;; - an exception is passed to JavaScript as a SchemeError (CB-ERROR),
;;;   carrying what was raised;
;;; - a continuation that leaves the callback (an escape: call/cc, an
;;;   error caught by a handler outside the op, shift to a reset
;;;   outside it) is seen by the after thunk, which keeps the rest of
;;;   the escape and returns CB-ESCAPE instead: the callback returns
;;;   normally to C (C_callback restores its restart point), JavaScript
;;;   throws a SchemeEscape through the user's frames, and the op that
;;;   ran them goes on with the escape (run!).  Through several levels
;;;   of callbacks, this repeats one level out each time;
;;; - re-entering a continuation captured inside a callback that has
;;;   returned raises an error (in the before thunk): its C frames are
;;;   gone.
;;;
;;; The winds of the after thunk are those of the callback's start
;;; (they are popped before it runs), which are those of the op's call
;;; (##sys#dynamic-winds is one global): neither the jump to RET nor
;;; resuming the escape from the op unwinds anything twice.  `leaving'
;;; is set only just before the jump to RET, and the handler cannot
;;; raise (callback-error!), so that nothing it does is taken for a
;;; normal exit.
;;;
;;; Escapes with ##sys#call-with-current-continuation skip dynamic-wind
;;; and are not supported: they leave the callback's C frames below, its
;;; exception handler current and its wind in the winds, which
;;; continuations captured later (the REPL's own, at its next prompt)
;;; take along.  The bridge cannot tell such frames from those of a
;;; live callback, so no toplevel wait drops them (see webio's
;;; drop-abandoned!): the REPL may then report errors until Restart.

(define-external (webjs_callback (int index) (int gen) (int argc)) int
  (trampoline index gen argc))

(define (trampoline index gen argc)
  (let ((entry (table-ref index gen)))
    (cond ((not entry) CB-RELEASED)
	  (interrupt-pending
	   (callback-error! interrupt-condition)
	   CB-ERROR)
	  (else (run-callback (car entry) argc)))))

(define (run-callback proc argc)
  (let ((entered #f) (leaving #f))
    (call/cc
     (lambda (ret)
       (dynamic-wind
	   (lambda ()
	     (if entered
		 (error "re-entry into a call from JavaScript that has returned")
		 (set! entered #t)))
	   (lambda ()
	     (with-exception-handler
	      (lambda (c)
		(when (user-interrupt? c)
		  (set! interrupt-pending #t)
		  (set! interrupt-condition c))
		(callback-error! c)
		(set! leaving #t)
		(ret CB-ERROR))
	      (lambda ()
		(let ((args (read-args (max-arity proc argc) 0)))
		  (##sys#call-with-values
		   (lambda () (apply proc args))
		   (lambda vs
		     (args-begin!)
		     (push-value! (if (pair? vs) (car vs) (##core#undefined)) #f)
		     (callback-result!)
		     (set! leaving #t)
		     CB-OK))))))
	   (lambda ()
	     (unless leaving
	       (call/cc
		(lambda (resume)
		  (set! leaving #t)
		  (set! escape-k resume)
		  (ret CB-ESCAPE))))))))))

;; at most as many arguments as PROC takes when its lambda list says
;; so (map's three arguments to (lambda (x) ...)); all of them for
;; optional, rest or keyword arguments, or when it says nothing
(define (max-arity proc argc)
  (let ((info (procedure-information proc)))
    (if (pair? info)
	(let loop ((ll (cdr info)) (n 0))
	  (cond ((null? ll) (fxmin n argc))
		((and (pair? ll) (symbol? (car ll))
		      (not (memq (car ll) '(#!optional #!rest #!key))))
		 (loop (cdr ll) (fx+ n 1)))
		(else argc)))
	argc)))

(define (read-args n start)		; the rest stay unread (released)
  (let loop ((i (fx- n 1)) (l '()))
    (if (fx< i 0)
	l
	(loop (fx- i 1) (cons (read-value (fx+ start i) #f) l)))))

(define (user-interrupt? c)
  (and (##sys#structure? c 'condition)
       (memq 'user-interrupt (##sys#slot c 1))
       #t))

;; What print-error-message writes for C with header "Error", without
;; it: "(car) bad argument type: 5", "bad: 42"
(define (condition-text c)
  (let ((o (open-output-string)))
    (define (put x) (##sys#print x #f o))
    (define (put-written x)
      (##sys#with-print-length-limit 80 (lambda () (##sys#print x #t o))))
    (cond ((##sys#structure? c 'condition)
	   (let ((msg (get-condition-property c 'exn 'message #f))
		 (loc (get-condition-property c 'exn 'location #f))
		 (args (get-condition-property c 'exn 'arguments #f)))
	     (cond (msg
		    (when (symbol? loc) (put "(") (put loc) (put ") "))
		    (put msg))
		   ((equal? '(user-interrupt) (##sys#slot c 1))
		    (put "*** user interrupt ***"))
		   (else (put "<condition> ") (put (##sys#slot c 1))))
	     (when (and (list? args) (pair? args))
	       (put (if (null? (cdr args)) ": " "\n"))
	       (let loop ((l args))
		 (put-written (car l))
		 (when (pair? (cdr l))
		   (put "\n")
		   (loop (cdr l)))))))
	  ((string? c) (put c))
	  (else (put "uncaught exception: ") (put-written c)))
    (get-output-string o)))

;; Never raises: when C cannot cross (a crossing hook that raises, say),
;; JavaScript gets an Error of its message instead of a SchemeError
(define (callback-error! c)
  (let ((msg #f))
    (call/cc
     (lambda (k)
       (with-exception-handler
	(lambda (e)
	  (args-begin!)
	  (push-undefined!)
	  (push-string! (or msg "an error in a call from JavaScript"))
	  (make-error!)
	  (k #f))
	(lambda ()
	  (set! msg (condition-text c))
	  (args-begin!)
	  (push-object! c KIND-OBJECT)
	  (push-string! msg)
	  (make-error!)))))))


;;; The API

(define (js-global #!optional path)
  (args-begin!)
  (cond ((not path) (op OP-GLOBAL 0 'js-global))
	(else
	 (check-string path 'js-global)
	 (push-string! path)
	 (op OP-GLOBAL 1 'js-global))))

(define (js-ref obj key)
  (args-begin!)
  (push-value! obj 'js-ref)
  (push-key! key 'js-ref)
  (op OP-REF 2 'js-ref))

(define (js-set! obj key val)
  (check-handle obj 'js-set!)
  (args-begin!)
  (push-value! obj 'js-set!)
  (push-key! key 'js-set!)
  (push-value! val 'js-set!)
  (op OP-SET 3 'js-set!))

(define (js-has? obj key)
  (args-begin!)
  (push-value! obj 'js-has?)
  (push-key! key 'js-has?)
  (op OP-HAS 2 'js-has?))

(define (js-delete! obj key)
  (check-handle obj 'js-delete!)
  (args-begin!)
  (push-value! obj 'js-delete!)
  (push-key! key 'js-delete!)
  (op OP-DELETE 2 'js-delete!))

(define (js-keys obj)
  (args-begin!)
  (push-value! obj 'js-keys)
  (op OP-KEYS 1 'js-keys))

(define (js-call f . args)
  (args-begin!)
  (push-value! f 'js-call)
  (op OP-CALL (fx+ 1 (push-args! args 'js-call)) 'js-call))

(define (js-invoke obj method . args)
  (check-handle obj 'js-invoke)
  (args-begin!)
  (push-value! obj 'js-invoke)
  (push-key! method 'js-invoke)
  (op OP-INVOKE (fx+ 2 (push-args! args 'js-invoke)) 'js-invoke))

(define (js-new ctor . args)
  (check-handle ctor 'js-new)
  (args-begin!)
  (push-value! ctor 'js-new)
  (op OP-NEW (fx+ 1 (push-args! args 'js-new)) 'js-new))

(define (js-eval src)
  (check-string src 'js-eval)
  (args-begin!)
  (push-string! src)
  (op OP-EVAL 1 'js-eval))

(define (js-object? x) (##sys#structure? x object-tag))
(define (js-null? x) (eq? x js-null))
(define js-undefined (##core#undefined))
(define (js-undefined? x) (eq? x (##core#undefined)))
(define (js-nullish? x) (or (eq? x js-null) (eq? x (##core#undefined))))

;; a function for good: the same one every time its handle crosses
(define (make-function proc kind loc)
  (unless (procedure? proc) (type-error loc "bad argument type - not a procedure" proc))
  (let* ((i (table-add! proc))
	 (g (vector-ref gens i)))
    (make-handle (make-function! i g kind) i g)))

(define (js-function proc) (make-function proc KIND-FUNCTION 'js-function))
(define (js-method proc) (make-function proc KIND-METHOD 'js-method))
(define (js-async-function proc) (make-function proc KIND-ASYNC 'js-async-function))

(define (js-release! h)
  (check-handle h 'js-release!)
  (let ((id (##sys#slot h 1)))
    (when id
      (##sys#setslot h 1 #f)
      (when (##sys#slot h 2)		; the function throws from now on
	(release-function! id)
	(table-free! (##sys#slot h 2) (##sys#slot h 3)))
      (unref! id))))

(define (js->list x)
  (args-begin!)
  (push-value! x 'js->list)
  (op OP-FROM 1 'js->list))

(define (js->vector x)
  (args-begin!)
  (push-value! x 'js->vector)
  (list->vector (op OP-FROM 1 'js->vector)))

(define (list->js lst #!optional deep?)
  (unless (list? lst) (type-error 'list->js "bad argument type - not a proper list" lst))
  (args-begin!)
  (push-list! lst 'list->js deep? '() 0)
  (op OP-IDENTITY 1 'list->js))

(define (vector->js vec)
  (unless (vector? vec) (type-error 'vector->js "bad argument type - not a vector" vec))
  (args-begin!)
  (push-value! vec 'vector->js)
  (op OP-IDENTITY 1 'vector->js))

(define (js->alist x)
  (args-begin!)
  (push-value! x 'js->alist)
  (let loop ((l (op OP-ENTRIES 1 'js->alist)))
    (if (pair? l)
	(let ((kv (car l)))
	  (cons (cons (car kv) (cadr kv)) (loop (cdr l))))
	'())))

(define (alist->js alist)
  (unless (list? alist) (type-error 'alist->js "bad argument type - not a proper list" alist))
  (args-begin!)
  (let loop ((l alist) (n 0))
    (if (pair? l)
	(let ((p (car l)))
	  (unless (pair? p) (type-error 'alist->js "bad argument type - not a pair" p))
	  (push-key! (car p) 'alist->js)
	  (push-value! (cdr p) 'alist->js)
	  (loop (cdr l) (fx+ n 2)))
	(op OP-OBJECT n 'alist->js))))

(define (js-obj . kvs)
  (args-begin!)
  (let loop ((l kvs) (n 0))
    (cond ((null? l) (op OP-OBJECT n 'js-obj))
	  ((null? (cdr l)) (error 'js-obj "odd number of arguments" kvs))
	  (else
	   (push-key! (car l) 'js-obj)
	   (push-value! (cadr l) 'js-obj)
	   (loop (cddr l) (fx+ n 2))))))

;; the typeof of X once it crossed (no op: a handle's was recorded)
(define (js-typeof x)
  (cond ((eq? x (##core#undefined)) "undefined")
	((eq? x js-null) "object")
	((boolean? x) "boolean")
	((##core#inline "C_i_exact_integerp" x) (if (safe-integer? x) "number" "bigint"))
	((and (number? x) (real? x)) "number")
	((or (string? x) (char? x) (keyword? x) (symbol? x)) "string")
	((procedure? x) "function")
	((##sys#structure? x object-tag) (handle-text (live-id x 'js-typeof) 1))
	(else "object")))

(define (js-instanceof? x ctor)
  (args-begin!)
  (push-value! x 'js-instanceof?)
  (push-value! ctor 'js-instanceof?)
  (op OP-INSTANCEOF 2 'js-instanceof?))

(define (js-same? a b)
  (args-begin!)
  (push-value! a 'js-same?)
  (push-value! b 'js-same?)
  (op OP-SAME 2 'js-same?))

(define (js->string x)
  (args-begin!)
  (push-value! x 'js->string)
  (op OP-TOSTRING 1 'js->string))

(define (js->bytevector x)
  (args-begin!)
  (push-value! x 'js->bytevector)
  (push-number! 0.0)
  (op OP-BYTES 2 'js->bytevector))

(define (js->number-vector x)
  (args-begin!)
  (push-value! x 'js->number-vector)
  (push-number! -1.0)			; the element type of X
  (op OP-BYTES 2 'js->number-vector))


;;; Waiting for a promise.  A value that is no thenable is itself (the
;;; very object: a handle too).  An op registers the wait (an await
;;; slot of webjs-pre.js), and the loop runs the calls from JavaScript
;;; that are queued, until none is left, and else yields AWAITING until
;;; the promise settles (webrepl_js_wake).  Inside a callback nothing
;;; can yield: a thenable is an error there.  Stop interrupts the wait,
;;; as does a Stop in one of the calls it runs (after that call's
;;; promise is rejected); leaving the wait, anyhow, gives the slot up,
;;; and re-entering it (a continuation captured in a call it ran) is an
;;; error, as the slot is gone.  Nested waits (a queued call that waits)
;;; each have a slot, and the innermost one is waited for first.
;;;
;;; A call run at the REPL's prompt or by the idle notebook kernel that
;;; waits so holds the prompt or the kernel until its promise settles:
;;; typed input and the cells posted meanwhile wait for it, and Stop
;;; interrupts that call (not what comes after it).

(define (js-await x)
  (if (not (##sys#structure? x object-tag))
      x
      (let ((inside (pair? ##sys#callback-continuation-stack)))
	(args-begin!)
	(push-handle! (live-id x 'js-await))
	(push-bool! (not inside))
	(let ((st (run! OP-AWAIT 2 'js-await)))
	  (cond ((fx= st OP-VALUE) x)	; no thenable
		(inside (error 'js-await "cannot wait inside a call from JavaScript"))
		(else (await-loop (read-value 0 'js-await) 'js-await
				  (lambda () (read-value 0 'js-await)))))))))

;; -> (READ) once slot ID has a value; LOC names the waiter in errors
(define (await-loop id loc read)
  (let ((entered #f) (done #f))
    (dynamic-wind
	(lambda ()
	  (if entered
	      (signal-error loc "re-entry into a wait that has ended")
	      (set! entered #t)))
	(lambda ()
	  (let loop ()
	    (let ((r (run-one-pending! #t)))
	      (cond ((eq? r 'interrupted) (##sys#user-interrupt-hook) (loop))
		    (r (loop))
		    (else
		     (let ((st (await-state id)))
		       (cond ((fx= st 0)
			      (##webio#yield ST-AWAITING)
			      (when (interrupted?) (##sys#user-interrupt-hook))
			      (loop))
			     ((fx< st 0)	; never yield for a slot that is gone
			      (signal-error loc "re-entry into a wait that has ended"))
			     (else
			      (set! done #t)
			      (await-take! id)
			      (cond ((fx= st 1) (read))
				    ((fx= st 2) (raise-js-error loc))
				    (else (abort (read-value 0 loc))))))))))))
	(lambda () (unless done (await-abandon! id))))))


;;; JavaScript cells (webnb.scm) and the REPL's ,js: SRC evaluated by
;;; op RUN-JS as the script NAME, whose top-level let, const and class
;;; declarations are rewritten to var first (js-lexer.js), so that they
;;; outlive it.  A value that is a thenable is waited for, as js-await
;;; does (inside a callback, an error).  A JavaScript error is raised
;;; with no location ("Error: TypeError: ..."), with its frames, and
;;; incomplete when the source ended unfinished.

;; SRC evaluated as JavaScript file NAME -> (value . text): text the
;; JavaScript text of value, or #f when Scheme shows it (undefined, a
;; Scheme object)
(define (run-js src name console?)
  (let ((inside (pair? ##sys#callback-continuation-stack)))
    (args-begin!)
    (push-string! src)
    (push-string! name)
    (push-bool! console?)
    (push-bool! (not inside))
    (let ((st (run! OP-RUN-JS 4 #f)))
      (cond ((fx= st OP-PENDING)
	     (if inside
		 (error "cannot wait inside a call from JavaScript")
		 (await-loop (read-value 0 #f) #f read-shown)))
	    (else (read-shown))))))

(define (read-shown)			; (value text) in the inbox
  (let ((l (read-value 0 #f)))
    (cons (car l) (and (string? (cadr l)) (cadr l)))))

(set! ##webnb#js-hook (lambda (src name) (run-js src name #f)))


;;; ",js SOURCE" in the REPL: SOURCE evaluated as a JavaScript cell is
;;; (run-js), file "js[N]", its value printed as the REPL prints one.
;;; SOURCE is the rest of the line, with the lines entered with it
;;; (Shift+Enter: one input, which webio never takes together with the
;;; next), and more lines while it is incomplete (an open bracket,
;;; string, template or comment): ",js" alone (or with only blanks
;;; after it) takes the next line.  A JavaScript error is reported
;;; here, in the REPL's way, with its stack; the REPL goes on.

(define (js-incomplete? s)
  (args-begin!)
  (push-string! s)
  (fx= 1 (incomplete-js)))

(define js-count 0)

;; whether S is only blanks (csi leaves the rest of the command's line
;; to the command but for a newline right after it: ",js " leaves " ")
(define (blank? s)
  (let loop ((i 0))
    (or (fx= i (string-length s))
	(and (char-whitespace? (string-ref s i)) (loop (fx+ i 1))))))

;; -> the source, or #!eof at the end of the input
(define (read-js-source)
  (let loop ((src (let ((l (read-line)))
		    (if (and (string? l) (blank? l) (not (##webio#chunk-pending?)))
			(read-line)
			l))))
    (if (and (string? src) (or (##webio#chunk-pending?) (js-incomplete? src)))
	(let ((more (read-line)))
	  (if (eof-object? more)
	      src
	      (loop (##sys#string-append src (##sys#string-append "\n" more)))))
	src)))

(define (js-condition? c)
  (and (##sys#structure? c 'condition) (memq 'js (##sys#slot c 1)) #t))

;; as the REPL reports an error, with the JavaScript stack (the
;; innermost frame last) for the call history
(define (report-js-error c)
  (let ((port ##sys#standard-error)
	(frames (get-condition-property c 'js 'frames '())))
    (##sys#print "\nError: " #f port)
    (##sys#print (condition-text c) #f port)
    (##sys#print "\n" #f port)
    (when (pair? frames)
      (##sys#print "\n\tJavaScript stack:\n\n" #f port)
      (let loop ((l frames))
	(when (pair? l)
	  (##sys#print "\t" #f port)
	  (##sys#print (car (car l)) #f port)
	  (##sys#print "\t  " #f port)
	  (##sys#print (cadr (car l)) #f port)
	  (when (null? (cdr l)) (##sys#print "\t<--" #f port))
	  (##sys#print "\n" #f port)
	  (loop (cdr l)))))
    (set! ##sys#last-exception c)
    (##sys#flush-output port)))

;; R: (value . text), as run-js gives it
(define (print-js-value r)
  (let ((port ##sys#standard-output))
    (cond ((cdr r)
	   (##sys#print (cdr r) #f port)
	   (##sys#write-char-0 #\newline port))
	  ((not (eq? (car r) (##core#undefined)))
	   (##sys#repl-print-hook (car r) port))))) ; a lazy stream as it comes

;; A JavaScript error is reported; any other condition (a Scheme error
;; that crossed, Stop) goes on to the REPL
(define (js-command)
  (let ((src (read-js-source)))
    (unless (eof-object? src)
      (set! js-count (fx+ js-count 1))
      (let ((r (call/cc
		(lambda (k)
		  (with-exception-handler
		   (lambda (c)
		     (if (js-condition? c)
			 (begin (report-js-error c) (k #f))
			 (abort c)))
		   (lambda ()
		     (run-js src (##sys#string-append
				  "js[" (##sys#string-append (number->string js-count) "]"))
			     #t)))))))
	(when r (print-js-value r))))))

;; the console's only: the notebook kernel has JavaScript cells
(set! ##webio#first-prompt-hook
  (lambda ()
    (when (and (not (##webnb#kernel-running?))
	       (##sys#symbol-has-toplevel-binding? 'chicken.csi#toplevel-command))
      ((value-of 'chicken.csi#toplevel-command)
       'js js-command
       ",js SOURCE        evaluate the rest of the line as JavaScript (as a notebook JavaScript cell)"))))


;;; Calls from JavaScript that wait (made while Scheme waited on no op,
;;; or by a js-async-function), run by the REPL's prompt and the idle
;;; notebook kernel (##webio#pending-hook) and by js-await, one per
;;; run-one-pending!, which says whether one ran.  Each runs as Scheme
;;; of its own: stdin empty, the standard ports webio's (open again),
;;; reset ending it, the default Stop, and an exception handler of its
;;; own.  Its value resolves its promise; an error rejects it with a
;;; SchemeError, a reset with an Error.  A Stop there ends the call;
;;; inside js-await it interrupts the wait too (WAITER? and the result
;;; 'interrupted).  A continuation leaving the call leaves its promise
;;; pending.
;;;
;;; ##webjs#call-hook runs it, as (hook TAG THUNK): TAG is the context
;;; JavaScript queued the call in (the rid of a notebook cell, see
;;; webjs-pre.js), else the tag of its procedure's entry; THUNK runs and
;;; settles the call, and returns its outcome, (ok VALUE ...), (raised
;;; OBJ) or (reset), or does not return (a continuation left it).  The
;;; hook returns whether it reported the outcome itself (the notebook
;;; kernel frames a call of a cell that no longer runs, and reports
;;; there).  Else an error is written on stderr here, but for a Stop
;;; inside js-await.

;; the library's: raises the condition user-interrupt
(define default-interrupt-hook (value-of '##sys#user-interrupt-hook))

(define (##webjs#call-hook tag thunk) (thunk) #f)

(define (run-one-pending! waiter?)
  (drain-released!)
  (let ((id (pending-take)))
    (if (fx= id 0)
	#f
	(let ((entry (and (fx= (desc-kind 0) K-SCHEME)
			  (table-ref (desc-id 0) (desc-gen 0))))
	      (rid (pending-rid)))
	  (if entry
	      (let* ((proc (car entry))
		     (argc (fx- (inbox-size) 1))
		     (tag (if (fx> rid 0) rid (cdr entry)))
		     (outcome #f)
		     (result #t)
		     (reported
		      (##webjs#call-hook
		       tag
		       (lambda ()
			 (let ((r (call-clean proc argc)))
			   (receive (r* res) (settle-call! id r waiter?)
			     (set! outcome r*)
			     (set! result res)
			     r*))))))
		(when (and (not reported) (pair? outcome) (eq? (car outcome) 'raised)
			   (not (eq? result 'interrupted)))
		  (report-call-error (cadr outcome)))
		(##webio#slice-yield!)
		result)
	      (begin (pending-drop! id) #t))))))

;; -> (ok VALUE ...), (raised OBJ) or (reset)
(define (call-clean proc argc)
  (call/cc
   (lambda (k)
     (let ((in #f) (out #f) (err #f) (reset #f) (stop #f))
       (dynamic-wind
	   (lambda ()
	     (set! in ##sys#standard-input)
	     (set! out ##sys#standard-output)
	     (set! err ##sys#standard-error)
	     (set! reset (##sys#reset-handler))
	     (set! stop ##sys#user-interrupt-hook)
	     (##webio#reopen-std!)
	     (set! ##sys#standard-input (open-input-string ""))
	     (set! ##sys#standard-output ##webio#web-stdout)
	     (set! ##sys#standard-error ##webio#web-stderr)
	     (##sys#reset-handler (lambda () (k '(reset))))
	     (set! ##sys#user-interrupt-hook default-interrupt-hook))
	   (lambda ()
	     (with-exception-handler
	      (lambda (c) (k (list 'raised c)))
	      (lambda ()
		(let ((args (read-args (max-arity proc argc) 1)))
		  (##sys#call-with-values
		   (lambda () (apply proc args))
		   (lambda vs (cons 'ok vs)))))))
	   (lambda ()
	     (set! ##sys#standard-input in)
	     (set! ##sys#standard-output out)
	     (set! ##sys#standard-error err)
	     (##sys#reset-handler reset)
	     (set! ##sys#user-interrupt-hook stop)))))))

;; -> the outcome as settled (a value that cannot cross is an error),
;; and #t, or 'interrupted for a Stop in a waiter
(define (settle-call! id r waiter?)
  (let ((r (if (eq? (car r) 'ok)
	       (call/cc			; the value, converted: may fail
		(lambda (k)
		  (with-exception-handler
		   (lambda (c) (k (list 'raised c)))
		   (lambda ()
		     (args-begin!)
		     (push-value! (if (pair? (cdr r)) (cadr r) (##core#undefined)) 'js-call)
		     r))))
	       r)))
    (case (car r)
      ((ok)
       (settle! id SETTLE-RESOLVE)
       (values r #t))
      ((reset)
       (args-begin!)
       (push-string! "reset")
       (settle! id SETTLE-ERROR)
       (values r #t))
      (else
       (let ((c (cadr r)))
	 (args-begin!)
	 (push-object! c KIND-OBJECT)
	 (push-string! (condition-text c))
	 (settle! id SETTLE-SCHEME-ERROR)
	 (values r (if (and waiter? (user-interrupt? c)) 'interrupted #t)))))))

(define (report-call-error c)
  (let ((port ##webio#web-stderr))
    (##sys#print "\nError in a call from JavaScript: " #f port)
    (##sys#print (condition-text c) #f port)
    (##sys#print "\n" #f port)))

(set! ##webio#pending-hook (lambda () (run-one-pending! #f)))


;;; The worker's console (webjs-pre.js's console(), repl-worker.js)
;;; writes with this procedure while an op runs: on the current ports,
;;; in order with what Scheme wrote.  Its entry of the table is never
;;; released.

(define (console-writer fd s)
  (display s (if (eqv? fd 2) ##sys#standard-error ##sys#standard-output)))

(let ((i (table-add! console-writer)))
  (set-console! i (vector-ref gens i)))


;;; JavaScript's way into Scheme: the procedures of the worker's global
;;; `scheme' (webjs-pre.js), entries of the table for good.  A
;;; JavaScript undefined is (void) here: arguments are tested for what
;;; they are, never for being true.  The notebook's procedures are its
;;; kernel's hooks (##webnb#, not user names).

;; NAME's value as eval finds it, in a list, or #f when it has none
;; (unbound, syntax)
(define (lookup name)
  (let ((sym (string->symbol name)))
    (call/cc
     (lambda (k)
       (with-exception-handler
	(lambda (c) (k #f))
	(lambda ()
	  (fluid-let ((##sys#unbound-in-eval #f))	; no notice of it
	    (list (eval sym)))))))))

(define (resolve name loc)
  (let ((r (lookup name)))
    (if r (car r) (error loc "unbound variable" name))))

(define (given x) (and (not (js-nullish? x)) x))

(define (map-list f l)
  (if (pair? l) (cons (f (car l)) (map-list f (cdr l))) '()))

(define (notebook-only loc)
  (unless (##webnb#kernel-running?) (error loc "only in a notebook")))

;; the forms of SRC evaluated one by one, as a cell's: the first value
;; of the last
(define (api-eval src)
  (let ((p (open-input-string src)))
    (let loop ((v (##core#undefined)))
      (let ((x (read p)))
	(if (eof-object? x)
	    v
	    (loop (##sys#call-with-values
		   (lambda () (eval x))
		   (lambda vs (if (pair? vs) (car vs) (##core#undefined))))))))))

(define (api-env-ref name)		; -> #(value), or #f
  (let ((r (lookup name)))
    (and r (make-vector 1 (car r)))))

;; FN?: V is a handle of a JavaScript function, which NAME then calls
(define (api-env-set name v fn?)
  (let ((x (if (eq? fn? #t) (lambda args (apply js-call v args)) v)))
    (eval (list 'define (string->symbol name) (list 'quote x)))
    (##core#undefined)))

(define (api-env-has name) (and (lookup name) #t))

(define (api-call name . args)
  (apply (resolve name 'scheme.call) args))

(define (api-list . xs) xs)

(define (api-to-array x deep)
  (cond ((list? x) (list->js x (eq? deep #t)))
	((vector? x) x)			; copied as it crosses
	(else (type-error 'scheme.toArray "bad argument type - not a list or vector" x))))

(define (api-show x #!optional id)
  (notebook-only 'scheme.show)
  (##webnb#show x (given id)))

(define (api-clear)
  (notebook-only 'scheme.clearOutput)
  (##webnb#clear))

(define (api-html x) (##webnb#html x))
(define (api-svg x) (##webnb#svg x))
(define (api-markdown x) (##webnb#markdown x))
(define (api-text x) (##webnb#text x))

;; ROWS and HEADER: Scheme lists, or Arrays (of Arrays)
(define (api-table rows #!optional header)
  (define (row r) (if (js-object? r) (js->list r) r))
  (##webnb#table (if (js-object? rows) (map-list row (js->list rows)) rows)
		 (cond ((js-object? header) (js->list header))
		       ((list? header) header)
		       (else #f))))

(define (api-image bytes #!optional mime)
  (##webnb#image (if (js-object? bytes) (js->bytevector bytes) bytes)
		 (if (string? mime) mime "image/png")))

(for-each
 (lambda (e)
   (let ((i (table-add! (cdr e))))
     (set-api! (car e) i (vector-ref gens i))))
 (list (cons API-EVAL api-eval) (cons API-ENV-REF api-env-ref)
       (cons API-ENV-SET api-env-set) (cons API-ENV-HAS api-env-has)
       (cons API-CALL api-call) (cons API-LIST api-list)
       (cons API-TO-ARRAY api-to-array) (cons API-SHOW api-show)
       (cons API-CLEAR api-clear) (cons API-HTML api-html) (cons API-SVG api-svg)
       (cons API-MARKDOWN api-markdown) (cons API-TEXT api-text)
       (cons API-TABLE api-table) (cons API-IMAGE api-image)))


;;; The exports, assigned from the hidden names only (see above)

(define ##webjs#js-global js-global)
(define ##webjs#js-ref js-ref)
(define ##webjs#js-set! js-set!)
(define ##webjs#js-has? js-has?)
(define ##webjs#js-delete! js-delete!)
(define ##webjs#js-keys js-keys)
(define ##webjs#js-call js-call)
(define ##webjs#js-invoke js-invoke)
(define ##webjs#js-new js-new)
(define ##webjs#js-eval js-eval)
(define ##webjs#js-object? js-object?)
(define ##webjs#js-null js-null)
(define ##webjs#js-null? js-null?)
(define ##webjs#js-undefined js-undefined)
(define ##webjs#js-undefined? js-undefined?)
(define ##webjs#js-nullish? js-nullish?)
(define ##webjs#js-function js-function)
(define ##webjs#js-method js-method)
(define ##webjs#js-async-function js-async-function)
(define ##webjs#js-await js-await)
(define ##webjs#js-release! js-release!)
(define ##webjs#js->list js->list)
(define ##webjs#js->vector js->vector)
(define ##webjs#list->js list->js)
(define ##webjs#vector->js vector->js)
(define ##webjs#js->alist js->alist)
(define ##webjs#alist->js alist->js)
(define ##webjs#js-obj js-obj)
(define ##webjs#js-typeof js-typeof)
(define ##webjs#js-instanceof? js-instanceof?)
(define ##webjs#js-same? js-same?)
(define ##webjs#js->string js->string)
(define ##webjs#js->bytevector js->bytevector)
(define ##webjs#js->number-vector js->number-vector)

;; lib #f: (import js) loads nothing, the unit is linked in
(##sys#register-core-module
 'js #f
 '((js-global . ##webjs#js-global)
   (js-ref . ##webjs#js-ref)
   (js-set! . ##webjs#js-set!)
   (js-has? . ##webjs#js-has?)
   (js-delete! . ##webjs#js-delete!)
   (js-keys . ##webjs#js-keys)
   (js-call . ##webjs#js-call)
   (js-invoke . ##webjs#js-invoke)
   (js-new . ##webjs#js-new)
   (js-eval . ##webjs#js-eval)
   (js-await . ##webjs#js-await)
   (js-object? . ##webjs#js-object?)
   (js-null . ##webjs#js-null)
   (js-null? . ##webjs#js-null?)
   (js-undefined . ##webjs#js-undefined)
   (js-undefined? . ##webjs#js-undefined?)
   (js-nullish? . ##webjs#js-nullish?)
   (js-function . ##webjs#js-function)
   (js-method . ##webjs#js-method)
   (js-async-function . ##webjs#js-async-function)
   (js-release! . ##webjs#js-release!)
   (js->list . ##webjs#js->list)
   (js->vector . ##webjs#js->vector)
   (list->js . ##webjs#list->js)
   (vector->js . ##webjs#vector->js)
   (js->alist . ##webjs#js->alist)
   (alist->js . ##webjs#alist->js)
   (js-obj . ##webjs#js-obj)
   (js-typeof . ##webjs#js-typeof)
   (js-instanceof? . ##webjs#js-instanceof?)
   (js-same? . ##webjs#js-same?)
   (js->string . ##webjs#js->string)
   (js->bytevector . ##webjs#js->bytevector)
   (js->number-vector . ##webjs#js->number-vector)))
