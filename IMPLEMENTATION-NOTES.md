# CHICKEN Scheme — How the implementation works, and where it could go faster

*Notes written against this repository — `chicken-core` at commit `d6442142`,
which `git describe` calls **6.0.1pre1-68-gd6442142**, i.e. 68 commits past
6.0.1pre1 on `master`. Every file:line citation below refers to this tree, and
because it is a git checkout you can check any of them directly:*

```sh
git describe --tags            # 6.0.1pre1-68-gd6442142
git show d6442142:c-platform.scm | sed -n '192,228p'
```

*It was built with **clang** (`config.make`: `C_COMPILER = clang`) at the stock
optimization level — `-Os`, not `-O0` and not `-O3` (see §9.1).*

*An earlier revision of these notes was written against the CHICKEN **6.0.0**
release tarball (rev `2e30c07e`, an ancestor of this commit). All citations have
been re-verified against this tree; where 6.0.0 and master differ in a way that
matters to the text it is called out at the point of use — see §5.4 and §6 in
particular, which describe passes that genuinely changed.*

*Every generated-C listing below was produced by **this tree's own compiler**, and
each says which flags produced it. Reproduce any of them with:*

```sh
T=~/Developer/working-copies/chicken-core
cd <scratch dir> && LD_LIBRARY_PATH=$T $T/chicken foo.scm -output-file foo.c -optimize-level N
```

*Items in §9 marked **[measured]** were run on this machine; the numbers are in
§10.1. Items marked **[proposal]** have not been measured and are argued from the
source only.*

---

## 1. Orientation: three artefacts in one repository

The repo contains three things that share a build system. The first two are the
ones people describe; the third is where most of the code actually is.

| | Written in | Entry point | What it is |
|---|---|---|---|
| **The compiler** | Scheme (self-hosting) | `chicken.scm` → `batch-driver.scm` | Translates a Scheme source file into a single `.c` file |
| **The runtime** | C | `runtime.c` + `chicken.h` (+ `utf.c`) | Object representation, GC, arithmetic, I/O, the trampoline |
| **The Scheme-level system** | Scheme, compiled to C by the compiler | `library.scm`, `expand.scm`, `eval.scm`, `port.scm`, `srfi-4.scm`, `posix*.scm`, … | The standard library, macro expander, interpreter and port layer, all linked into `libchicken` |

That third row matters for performance work: `string-ref`, `read-char` and
`f64vector-ref` are Scheme procedures in `library.scm` / `srfi-4.scm` that bottom
out in `C_*` primitives, so a cost can live in the C primitive, in the Scheme
wrapper, or in the compiler's failure to inline the wrapper away. §9.2 (C0) was a
case where it was the third — and is now fixed on this tree.

The unifying idea, and the reason the whole design hangs together, is a single
sentence:

> **A Scheme program is compiled into a set of C functions that never return.**

Everything else — the GC, the calling convention, the treatment of `call/cc`,
even the way the C stack is used — follows from that decision. (With one
deliberate exception: the leaf-routine transform of §5.1 produces C functions
that *do* return. That is the whole point of it.)

---

## 2. Data representation

### 2.1 The word

Every Scheme value is one machine word, `C_word` (`chicken.h:529-541`;
`long` on LP64, `int` on 32-bit, `__int64` on LLP64/Win64 — `C_s64` is
`__int64` only under MinGW, `int64_t` otherwise, `chicken.h:521-524`).

Tagging uses the low bits (`chicken.h:316-338`):

```
    bit 0 == 1                    →  fixnum        (value = word >> 1)
    low 4 bits == 0b0110          →  boolean       (#f = 0x06, #t = 0x16)
    low 4 bits == 0b1010          →  character     (codepoint = word >> 8)
    low 4 bits == 0b1110          →  "special"     ('(), #<unspecified>,
                                                    unbound, eof, broken-weak-ptr)
    low 2 bits == 0b00            →  pointer to a heap block
```

`C_immediatep(x)` is therefore just `(x & 3)` (`chicken.h:1077`,
`C_IMMEDIATE_MARK_BITS` = `0x3` at `chicken.h:316`) — a value is a pointer exactly
when its low two bits are zero. That single test is the hottest predicate in
the entire runtime; the GC executes it once per slot scanned (`_mark`,
`runtime.c:3392-3397`, driven by `while(n--) mark(p++);` at `runtime.c:3826`).

One bit is the tag, so a fixnum carries a full **63-bit signed** payload on
64-bit: `C_MOST_POSITIVE_FIXNUM = 0x3fffffffffffffff` (`chicken.h:340`), giving
the range [-2⁶², 2⁶²-1]. Live check: `most-positive-fixnum` is
4611686018427387903. Note that the *character* range is deliberately limited to
a Unicode codepoint, and the source says so — `chicken.h:335-337`:
`/* Character range is that of a UTF-8 codepoint, not representable range */`,
`C_CHAR_BIT_MASK 0x1fffff`.

### 2.2 Blocks

A heap object is a header word followed by data (`chicken.h:777-781`):

```c
typedef struct C_block_struct {
  C_header header;
  C_word   data[];
} C_SCHEME_BLOCK;
```

The header packs three flag bits, a 4-bit type, and a size
(`chicken.h:405-465`, layout table at `chicken.h:383-404`):

```
  BYTEBLOCK_BIT    data contains bytes instead of slots  → GC must not scan it
  SPECIALBLOCK_BIT 1st item is a non-value               → GC must skip data[0]
  8ALIGN_BIT       data is aligned to 8-byte boundary    → matters only on 32-bit
```

The last one is worth confirming rather than assuming: every use of
`C_8ALIGN_BIT` in `runtime.c` is inside `#ifndef C_SIXTY_FOUR`
(`runtime.c:3191-3197`, `:3886-3892`, `:12695-12701`).

```
  Symbol     = [  1|3, Value, Name, Plist]        Name = bytevector, 0-terminated
  String     = [  2|4, Name, Count, Offset, Index] Name = bytevector, 0-terminated
  Pair       = [  3|2, Car, Cdr]
  Closure    = [ S4|1+N, Ptr, Slot, ...]
  Flonum     = [AB5|8, IEEEDouble]
  Bignum     = [  6|1, Bits]                       Bits = bytevector
  Structure  = [  8|1+N, Tag, Slots, ...]
  Bytevector = [ B12|N, Bytes, ...]
  ...
```

Three entries deserve comment.

**Closure.** A closure is a block whose slot 0 is a raw C function pointer
(hence `SPECIALBLOCK` — `C_CLOSURE_TYPE` ORs in `C_SPECIALBLOCK_BIT` at
`chicken.h:420`) and whose remaining slots are the captured values.
Calling a closure is `((C_proc)(void*)(*((C_word*)f+1)))(argc, argv)`
(`C_proc` is `chicken.h:805`). This is *flat* closure conversion: no environment
chain, no display, just a vector.

**Bytevector.** In 6.0 the bytevector is the single underlying byte container:
symbol names, string bytes and bignum digits are all bytevectors, and the
`Symbol`/`String` rows above point at one.

**String.** In 6.0 a string is no longer a byte array. It is a 4-slot block
(`C_STRING_TAG` = `C_STRING_TYPE | 4`, `chicken.h:495`; and `C_STRING_TYPE`
carries no `C_BYTEBLOCK_BIT`): a UTF-8 bytevector, a codepoint `Count`, and a
cached `(Offset, Index)` cursor pair. Live: `(##sys#size "abc")` ⇒ 4.

The performance consequences are sharper than "O(1) for ASCII, O(n) otherwise",
and §9.5 (S1) depends on getting them right:

* `string-length` is **O(1) always** — `C_i_string_length` (`runtime.c:5993`)
  just returns the cached `Count` out of slot 1.
* `string-ref` goes through `utf_index` (`utf.c:3273`), which short-circuits on
  `i == 0` and on the all-ASCII test `bytelength == codepoints`
  (`utf.c:3280-3284`), returning a direct byte index.
* Otherwise it falls into `utf_index1` (`utf.c:3247`), which memoises a forward
  cursor in slots 2 and 3 (read at `:3255-3258`, written back at `:3261-3262`).
  So *sequential forward* access is O(1) amortised even on non-ASCII text.
* The bad quadrant is **non-ASCII accessed non-sequentially**, where the cursor
  is defeated and every reference re-decodes from the memoised position.
  Measured (§10.1 D): sequential non-ASCII costs 1.6× ASCII; strided non-ASCII
  costs ~2000×.
* The ASCII fast path is all-or-nothing: one non-ASCII character anywhere in a
  100 000-character string makes the whole string as slow as fully non-ASCII text.

Counting, conversely, happens at string **construction** — every string built
from bytes pays a full `C_utf_count` pass to fill in slot 1 (see §9.5 S1).

---

## 3. The compiler pipeline

`compile-source-file` (`batch-driver.scm:185 (definition); pass sequence at :632-895`) drives the whole thing. In
order:

```
  source
    │
    ├─ read + macroexpand + canonicalize        core.scm:532   canonicalize-expression
    │     → "core language" S-expressions
    │
    ├─ (optional user pass)                     user-pass.scm
    ├─ build the node graph                     support.scm    build-node-graph
    │
    ├─ analysis                                 core.scm:2063  analyze-expression
    ├─ scrutiny (type checking / specialization) scrutinizer.scm:179   [§3.1]
    │
    ├─ CPS conversion                            core.scm:1925  perform-cps-conversion
    │     → every call is a tail call
    │
    ├─ ┌ analysis                                core.scm:2063  analyze-expression
    │  │   → the "database": per-variable and per-lambda facts
    │  ├ high-level optimization                 optimizer.scm:158
    │  │   → inlining, constant folding, contraction, rewriting
    │  └ leaf-routine / direct-lambda transform  optimizer.scm:1516   [-O1 and up]
    │      loop until no more progress
    │
    ├─ secondary flow analysis + float unboxing  lfa2.scm:247, lfa2.scm:522   [-O2 and up]
    │
    ├─ closure conversion                        core.scm:2540  perform-closure-conversion
    │     → lambdas become explicit ##core#closure vectors, free vars become ##core#ref
    │
    ├─ preparation                               core.scm:3108  prepare-for-code-generation
    │     → variables become numbered temporaries, allocation demand is counted,
    │       literals are collected, the "lambda table" is built
    │
    └─ C code generation                         c-backend.scm:93  generate-code
```

Two things the diagram is easy to misread. Canonicalization produces core-language
*S-expressions*; the mutable node graph is built by a separate step afterwards.
And the two bracketed passes are **opt-in**: the leaf-routine transform needs
`-optimize-leaf-routines` (implied by `-O1` and above, `batch-driver.scm:413`),
and `lfa2` needs the `lfa2` option (`-O2` and above). Neither runs for a plain
`csc foo.scm` — `csc.scm:112` sets `default-translation-optimization-options` to
`'()`. This is why §5.3's showcase output needs a flag to reproduce.

The node graph is a mutable tree of `(class, parameters, subexpressions)` triples
(`support.scm`); each pass rewrites it. The three language levels — source, core,
and closure-converted — are documented as grammars in the header comment of
`core.scm:97-238`, which is the single most useful thing to read in the repo.

### 3.1 The scrutinizer and `types.db`

`scrutinize` (`scrutinizer.scm:179`) does two jobs, and only the first is obvious
from its name. It type-checks, producing the warnings; and, when `-specialize` is
on, it *rewrites* the node tree, replacing checked primitives with unchecked ones
wherever the inferred types make the check redundant.

The rules live in `types.db` (2484 lines), one line per binding; anything after
the type is a specialization clause pairing argument types with a replacement.
The effect is visible directly: the same source compiled with `-specialize`
emits `C_u_i_car(t2)` where the default emits `C_i_car(t2)`.

This matters for reading §9: the scrutinizer is the *existing* mechanism that
most of §9.2's proposals want to extend. It is also cheap — 177 ms of the 3588 ms
of pass time on `library.scm` (§9.4) — so it is not itself an optimization target.

---

## 4. CPS conversion

This is the heart of the design, and it is only ~130 lines
(`core.scm:1923-2060`). The whole pass is a classic Fischer/Plotkin-style
one-pass CPS transform written in "compiler-in-CPS" style: `walk` takes a node
and a *meta-continuation* `k`, a Scheme procedure from "the node holding the
result value" to "the node for the rest of the computation".

### 4.1 The three interesting cases

**Lambda** — every user lambda gets one extra leading parameter, the
continuation `k`, and its body is walked with a meta-continuation that calls `k`:

```scheme
(define (cps-lambda id llist subs k)
  (let ([t1 (gensym 'k)])
    (k (make-node
        '##core#lambda (list id #t (cons t1 llist) 0)
        (list (walk (car subs)
                    (lambda (r)
                      (make-node '##core#call (list #t)
                                 (list (varnode t1) r)))))))))
```

**If** — the join point is reified as a real continuation `t1` so the code for
`k` is emitted once rather than duplicated into both branches:

```scheme
((if) (let* ((t1 (gensym 'k))
             (t2 (gensym 'r))
             (k1 (lambda (r) (make-node '##core#call (list #t)
                                        (list (varnode t1) r)))))
        (make-node 'let (list t1)
          (list (make-node '##core#lambda (list (gensym-f-id) #f (list t2) 0)
                           (list (k (varnode t2))))
                (walk (car subs)
                      (lambda (v)
                        (make-node 'if '() (list v (walk (cadr subs) k1)
                                                   (walk (caddr subs) k1)))))))))
```

That `let`-bound `##core#lambda` is exactly the `k125`, `k141`, `k148`
functions you see in generated C.

**Call** — a call becomes a tail call to the callee with a freshly built
continuation closure, after all arguments have been let-bound in order:

```scheme
(define (walk-call fn args params k)
  (let ((t0 (gensym 'k)) (t3 (gensym 'r)))
    (make-node 'let (list t0)
      (list (make-node '##core#lambda (list (gensym-f-id) #f (list t3) 0)
                       (list (k (varnode t3))))
            (walk-arguments args
              (lambda (vars)
                (walk fn (lambda (r)
                  (make-node '##core#call params
                             (cons* r (varnode t0) vars))))))))))
```

Note that the pass makes **no tail/non-tail distinction**:
`((##core#call) (walk-call (car subs) (cdr subs) params k))` sends *every* call
through `walk-call`, so a tail call also gets a freshly allocated continuation
here. Removing the redundant ones is the optimizer's job (§5), not this pass's.

### 4.2 Two small but important refinements

`walk-arguments` does **not** name atomic arguments (`atomic?`,
`core.scm:2050-2056`): constants, variables, `##core#undefined`, and inline
operations with atomic operands are spliced straight into the call node instead
of being let-bound to a fresh temporary. You can see both halves in the raw CPS
dump of the example below (`chicken fact.scm -debug 3`): the constant argument in
`(fact 10)` survives as `(fact k158 10)`, while the non-atomic argument of
`print` is named — `(let ((a157 r159)) (chicken.base#print k148 a157))`.

`(- n 1)` is *not* an example of this, contrary to what the final C suggests. At
CPS time it is still a call to the global `scheme#-`, and its result does get a
binding:

```scheme
(let ((k145 (##core#lambda (r146) (let ((a144 r146)) (fact k141 a144)))))
  (scheme#- k145 n10 1))
```

The `##core#inline_allocate ("C_s_a_i_minus" 29)` node that eventually becomes
`t4=C_s_a_i_minus(&a,2,t2,C_fix(1));` is produced later, by the optimizer
(`chicken fact.scm -debug 7`) — and even there it stays a separate temporary
that is stored into `av2[2]`, rather than an expression built inside the
argument vector. Both `walk-arguments` (`core.scm:2043`) and the `let` case
(`core.scm:1967`) also check `node-for-var?` to avoid emitting `(let ((x x)) …)`.

Notice also what CPS conversion *deletes*: `##core#the`, `##core#the/result`
and `##core#typecase` are dropped here, because after scrutiny their information
has already been consumed.

### 4.3 Worked example

```scheme
(define (fact n)
  (if (= n 0) 1 (* n (fact (- n 1)))))
(print (fact 10))
```

compiled with this tree's compiler at default settings
(`chicken fact.scm -output-file fact.c`), abridged from the generated `fact.c`.
`tmp` is a function-local `C_word` the backend declares in every prologue:

```c
/* fact in k125 in k122 */
static void C_ccall f_129(C_word c,C_word *av){
  C_word tmp;
  C_word t0=av[0];              /* the closure itself      */
  C_word t1=av[1];              /* the continuation k      */
  C_word t2=av[2];              /* n                       */
  C_word t3,t4,t5, *a;
  if(c!=3) C_bad_argc_2(c,3,t0);
  C_check_for_interrupt;
  if(C_unlikely(!C_demand(C_calculate_demand(33,c,2)))){
    C_save_and_reclaim((void *)f_129,c,av);}
  a=C_alloc(33);
  if(C_truep(C_i_nequalp(t2,C_fix(0)))){
    t3=t1;{                                   /* return 1 to k: */
      C_word *av2=av;
      av2[0]=t3; av2[1]=C_fix(1);
      ((C_proc)(void*)(*((C_word*)t3+1)))(2,av2);}}
  else{
    /* build the continuation closure {f_143, k, n} */
    t3=(*a=C_CLOSURE_TYPE|3,a[1]=(C_word)f_143,a[2]=t1,a[3]=t2,tmp=(C_word)a,a+=4,tmp);
    t4=C_s_a_i_minus(&a,2,t2,C_fix(1));
    {C_proc tp=(C_proc)C_fast_retrieve_proc(*((C_word*)lf[0]+1));
     C_word *av2=av;
     av2[0]=*((C_word*)lf[0]+1); av2[1]=t3; av2[2]=t4;
     tp(3,av2);}}}                            /* tail call to fact */

/* k141 in fact in k125 in k122 */            /* the continuation of the recursive call */
static void C_ccall f_143(C_word c,C_word *av){
  C_word tmp;
  C_word t0=av[0], t1=av[1], t2, *a;
  C_check_for_interrupt;
  if(C_unlikely(!C_demand(C_calculate_demand(33,c,1)))){
    C_save_and_reclaim((void *)f_143,c,av);}
  a=C_alloc(33);
  t2=((C_word*)t0)[2];                        /* k, from the closure   */
  { C_word *av2=av;
    av2[0]=t2;
    av2[1]=C_s_a_i_times(&a,2,((C_word*)t0)[3],t1);  /* n * result      */
    ((C_proc)(void*)(*((C_word*)t2+1)))(2,av2);}}
```

Read that once and the whole system is visible: recursion depth lives in a chain
of heap-allocated continuation closures, not on the C stack; each of these two C
functions ends in a call it never comes back from. (Function numbers are
program-dependent, and `f_127` in this same file is a *different* function — the
toplevel continuation — so grep by the `/* … */` header, not the number.)

Two details to carry forward. The `C_calculate_demand(33, …)` is not because
`fact` allocates 33 words in the fixnum case — it allocates none. It is the
worst-case budget for generic `*`; see §7.1. And this listing shows path 4 of
§7.3 taking `C_fast_retrieve_proc` even without `-unsafe`, because the callee is
a *known* toplevel binding.

---

## 5. Undoing CPS where it is not needed

Naïve CPS would be catastrophically slow: every loop iteration would cons a
continuation. Two optimizer passes and one backend special case claw the cost
back — §5.1 and §5.4 are passes, §5.2 is a property computed during closure
conversion, and §5.3 is a code-generation case.

### 5.1 Direct lambdas / leaf routines (`optimizer.scm:1516-1748`)

If a procedure's body only ever calls (a) its own continuation `k`, or
(b) itself recursively with the *same* `k`, and its total allocation is
statically bounded, it is a **leaf routine**. `transform-direct-lambdas!`:

* drops the continuation parameter, rewriting the node class to
  `##core#direct_lambda`;
* rewrites `(k v)` calls to `##core#return`;
* rewrites self-calls to `##core#recurse`;
* rewrites all known call sites to `##core#direct_call`, passing the caller's
  allocation pointer `&a` so the callee allocates in the caller's frame;
* hoists nested direct lambdas out of the container when it can.

The result is an ordinary C function that *does* return. **This pass is opt-in**
(`-optimize-leaf-routines`, implied by `-O1` and above); at default settings it
does not run at all.

### 5.2 Customizable procedures (`core.scm:2622-2662`)

If every reference to a variable is a call site, the argument counts always
match, the lambda list is a proper list (no rest parameter), and the procedure
never escapes, it is **customizable**: its arguments are passed as ordinary C
parameters instead of through an argument vector, and no argument-count check is
emitted. Because the runtime may still need to re-enter it after a GC, the
backend emits a small `tr<id>` **trampoline** that unpacks `av[]` back into
positional parameters (`c-backend.scm:701-730`).

### 5.3 Self-tail-call → `goto`

When a looping procedure's recursion is a tail self-call, the backend emits a
`loop:` label and `goto loop` (`c-backend.scm:904` for the label,
`c-backend.scm:334-347` for the jump), assigning through a row of scratch
temporaries first so that simultaneous update is correct.

Putting the pieces together — note the call site, which is load-bearing:

```scheme
(declare (block) (fixnum-arithmetic) (unsafe))
(import (chicken fixnum))
(define (sum-to n)
  (let loop ((i 0) (acc 0))
    (if (fx= i n) acc (loop (fx+ i 1) (fx+ acc i)))))
(print (sum-to 1000000))
```

Without `(print (sum-to 1000000))`, `(block)` mode deletes `sum-to` outright as
an unused side-effect-free binding — the compiler reports `removed side-effect
free assignment to unused variable: sum-to` — and *nothing at all is emitted*.
That single literal call is also what lets constant propagation fold `n` into the
`C_fix(1000000)` below.

**At default settings** this does *not* become a bare C loop. `loop` becomes
merely *customizable* (§5.2), so the backend emits a `trf_144` trampoline and —
because the `loop:` label precedes the prologue checks — both checks stay inside
the loop:

```c
/* default settings: customizable, not direct */
static void f_144(C_word t0,C_word t1,C_word t2,C_word t3){
  ...
loop:
C_check_for_interrupt;
if(C_unlikely(!C_demand(C_calculate_demand(0,0,3)))){
C_save_and_reclaim_args((void *)trf_144,4,t0,t1,t2,t3);}
t4=C_eqp(t2,C_fix(1000000));
  ...
```

Note `C_calculate_demand(0, …)`: the demand is literally zero and the checks are
still in the loop. With `-optimize-leaf-routines` (implied by `-O1` and above),
`loop` becomes a *direct* lambda and the checks disappear entirely — a plain C
loop with no allocation, **no GC check and no interrupt check inside the loop**
(real output, declarations reflowed onto one line):

```c
/* loop in k134 in k131 */
static C_word f_144(C_word t1,C_word t2){
  C_word tmp; C_word t3,t4,t5,t6;
loop:{}
  t3=C_eqp(t1,C_fix(1000000));
  if(C_truep(t3)){ return(t2); }
  else{
    t5=C_u_fixnum_plus(t1,C_fix(1));
    t6=C_u_fixnum_plus(t2,t1);
    t1=t5; t2=t6;
    goto loop;}}
```

This is the shape CHICKEN is trying to reach for hot code. Anything that
prevents it — an escaping continuation, an unknown callee, or *any* allocation
in the loop body — pushes you back onto the CPS path. Measured, this shape lands
within 2.3× of hand-written C (§10.1 A).

*Do not use this exact program as a benchmark*: the recurrence is
SCEV-analyzable, so clang computes its closed form and deletes the loop. A
billion "iterations" finish in 8 ms.

### 5.4 Float unboxing (`lfa2.scm`)

`perform-secondary-flow-analysis` runs a simplified type propagation whose two
jobs are (a) removing type checks that specialization left behind and
(b) recording, for each unassigned `let`-bound flonum variable, a
`(var boxed unboxed)` triple in `floatvars`. `perform-unboxing`
(`lfa2.scm:522`) then filters those (`lfa2.scm:523-527`) and rewrites the tree
with a pair of mutually recursive walkers — `walk` produces boxed results,
`walk/unbox` produces `double`s — inserting `##core#box_float` /
`##core#unbox_float` at the boundaries. `##core#let_float` binds a numbered
`double f<i>` C local (`c-backend.scm:160-165`). `+unboxed-map+`
(`lfa2.scm:205-242`) is the table of operations that have unboxed counterparts;
its three entry kinds (`op`, `acc`, `pred`) are consumed at `lfa2.scm:592-599`,
which matters for §9.2 (C1a).

**A pass that changed since 6.0.0.** In the 6.0.0 release the boolean-predicate
type refinement in this pass was dead code. The `((if ##core#cond))` clause of
`perform-secondary-flow-analysis` closed its `if` after the *then* branch, so the
type-refined merge was computed and thrown away and the unrefined merge was always
the clause's result. Upstream `0f4f5738` ("fix redundant node-traversals in lfa2
pass", 2026-09-05) moves a single close-paren to repair it; the commit message adds
that the bug "could even cause the lfa2 pass to loop endlessly in certain code".
This tree has the fix. The consequence for the rest of this document is that the
check-elimination half of the pass is genuinely weaker on 6.0.0 than here, so the
unboxing *opportunity set* is not the same in the two trees — any re-measurement of
(C1a)/(C1b) has to be taken against master's `lfa2`, not 6.0.0's.

**This pass is opt-in too** — `lfa2` runs only at `-O2` and above, so on a
default compile the `-debug o` line `number of unboxed float variables` never
appears at all.

---

## 6. Closure conversion and preparation

`perform-closure-conversion` (`core.scm:2540`) does the usual free-variable
analysis (`gather`), records `closure-size` and `captured-variables` in the
database, and rewrites:

* each `##core#lambda` into a `##core#closure` construction whose slot 0 is a
  `##core#proc` (the C function's address) and whose remaining slots are the
  captured values;
* each free-variable reference into `##core#ref` on the closure;
* each variable that is both **assigned and captured** into a heap-allocated
  box (`##core#box` / `##core#unbox` / `##core#updatebox`), because flat
  closures copy values.

CHICKEN 6 adds *closure sharing*, as two independent passes:
`merge-shareable` (`core.scm:2682`) and `merge-reusable` (`core.scm:2762`).
A "container" closure can hold the transitive free variables of the nested
closures it dominates, so those nested closures can be smaller or elided.
Variables shared this way that provably don't escape are un-boxed again
(`core.scm:2734-2747`).

The two passes are not enabled at the same optimization levels, and this changed
after 6.0.0. In 6.0.0 `-O1` turned on `merge-reusable-closures` only, `-O2`
`merge-shareable-closures` only, and `-O3` and above both. From upstream `810a1433`
onward — including this tree — `-O2` enables **both** (`chicken.scm:106`). That is a
real code-generation difference, not a bookkeeping one: recompiling real units under
the two option sets gives differing C (568 differing lines on `expand.scm`, 460 on
`optimizer.scm`, 364 on `irregex-core.scm`) with identical `C_CLOSURE_TYPE` counts.
Relatedly, 6.0.0's compiler rejects `-merge-shareable-closures` on the command line
with `Warning: invalid compiler option (ignored)` even though `csc` advertised it;
this tree accepts both flags (`c-platform.scm:109`).

`prepare-for-code-generation` (`core.scm:3108`) is the flattening pass:

* variables become de Bruijn-ish `##core#local` indices into a temporary array;
* globals become `##core#global` / `##core#setglobal` on a literal-frame slot;
* literals are collected into `lf[]` and encoded as strings for
  `C_decode_literal`;
* **allocation demand is accumulated per lambda** (`allocated`) — the exact
  number of words the body can allocate before its next call. This number ends
  up in the `C_alloc(n)` and `C_demand(n)` in the prologue, and is the reason
  CHICKEN needs no allocation checks at individual allocation sites;
* the `lambda-table` of `lambda-literal` records is built — this is what the
  backend consumes.

---

## 7. The C backend

`c-backend.scm:93` — `generate-code`. Two things are worth understanding in
detail.

### 7.1 The procedure prologue (`c-backend.scm:801-953`)

Every non-direct procedure is emitted as:

```c
static void C_ccall f_NNN(C_word c,C_word *av){
  C_word tmp;
  C_word t0=av[0];  ... C_word tK=av[K];   /* unpack the argument vector */
  C_word tK+1; ...                          /* the temporaries           */
  C_word *a;
  if(c!=N) C_bad_argc_2(c,N,t0);            /* if external, safe, argc-checked
                                               and NOT customizable          */
  C_check_for_interrupt;                    /* if timer checks enabled   */
  if(C_unlikely(!C_demand(C_calculate_demand(DEMAND,c,MAXAV)))){
    C_save_and_reclaim((void *)f_NNN,c,av);}   /* → GC, then re-enter    */
  a=C_alloc(DEMAND);                        /* only when DEMAND > 0      */
  ... body ...
}
```

`DEMAND` is the statically computed word count; `MAXAV` is the largest argument
vector any callee needs. `C_calculate_demand(n,c,m)` (`chicken.h:1066`) adds
headroom for the callee's argument vector when the current one is too small.
The crucial property is that the check happens **once, on entry**, and covers
every allocation the body can perform.

Where does `DEMAND` come from? Overwhelmingly, from generic arithmetic. The
rewrite table charges 29 words to a two-argument `+` or `-` and 33 to `*`
(`c-platform.scm:896-898`), because `C_s_a_i_plus` must be able to return a
complex number whose real and imaginary parts are both ratnums of fix-bignums —
the comment at `runtime.c:8437-8441` spells the arithmetic out:
`C_SIZEOF_CPLXNUM + C_SIZEOF_RATNUM * 2 + C_SIZEOF_FIX_BIGNUM * 4 = 29 words!`
That worst case is budgeted at *every* call site, even when both operands are
fixnums. It is why `fact` in §4.3 demands 33 words for a function that in the
fixnum case allocates none.

Note the consequence for the loop case: `a=C_alloc(DEMAND)` is `alloca`
(`chicken.h:1048`), so a `goto loop` back-edge in an *allocating* loop
re-executes the `alloca` and keeps growing the C stack. The backend does not try
to avoid this by moving the checks. The `loop:` label is emitted
**unconditionally**, before the argc, interrupt and demand checks
(`c-backend.scm:904` versus `:906-917`), so in a looping *customizable*
procedure all three sit inside the loop regardless of `DEMAND` — and that is
exactly what caps the stack growth, since the failing `C_demand` routes through
`C_save_and_reclaim_args` to a GC that resets the stack. Keeping the interrupt
check inside is needed independently, so that a non-allocating tight loop still
yields.

The only way to get a loop with no checks in it is for the procedure to become a
**direct** lambda (§5.1), which emits no prologue checks and no `a` at all
(`c-backend.scm:910-919`). That, and not a `DEMAND == 0` special case, is the
shape §5.3 shows.

### 7.2 Argument vectors and their reuse (`push-args`, `c-backend.scm:567-599`)

Calls pass `(argc, C_word *av)` where `av[0]` is the callee itself. Since the
caller never returns, its own `av` is dead the moment its arguments have been
copied into temporaries — so `push-args` reuses it when it is provably big
enough:

```c
C_word *av2;
if(c >= 3) { av2=av; }        /* reuse the caller's vector            */
else       { av2=C_alloc(3); } /* otherwise carve a new one out of the nursery */
av2[0]=callee; av2[1]=k; av2[2]=arg;
tp(3,av2);
```

(That second branch is not a different *place* from the C stack — `C_alloc` is
`alloca` and the C stack *is* the nursery, §8.1. It is a fresh vector, not a
different memory region.)

The three static cases (`C_word av2[N]` as a C array / `C_word *av2=av` /
the dynamic test above) are chosen from `lambda-literal-argument-count`,
`rest-argument-mode`, and whether any `##core#rest-car` in the arguments still
needs the *original* `av`. The commonest trigger for the C-array case is a caller
that has no `av` at all — `caller-has-av?` is
`(not (or (lambda-literal-customizable ll) (lambda-literal-direct ll)))`, so
customizable and direct procedures always build a fresh vector.

### 7.3 Call dispatch

`##core#call` (`c-backend.scm:308-408`) has these paths, cheapest first:

1. `##core#proc` — the callee is a known C function; call it by name.
2. `call-id` + `looping` — the self tail call; `goto loop`.
3. `call-id` + `customizable` — direct C call with positional arguments.
   (A known but *non*-customizable target is also called directly by name, but
   through an `av2` vector rather than positional arguments.)
4. `##core#global` — load the procedure out of the literal frame. The unchecked
   `C_fast_retrieve_proc` is used whenever the binding is known-safe; the
   checked `C_retrieve2_symbol_proc` branch requires `(not unsafe)`,
   `(not no-procedure-checks)` and a non-standard binding, so `-unsafe` /
   `no-procedure-checks` / block mode *disqualify* the checked path rather than
   selecting a level within it. (§4.3's listing shows `C_fast_retrieve_proc`
   without `-unsafe`, because `fact` is a known toplevel binding.)
5. General — `((C_proc)(void*)(*((C_word*)t+1)))(nf,av2)`.

---

## 8. The runtime

### 8.1 Cheney on the M.T.A.

CHICKEN implements Baker's *"CONS Should Not CONS Its Arguments, Part II:
Cheney on the M.T.A."*:

* `C_alloc(n)` is `alloca` (`chicken.h:1048`). **The C stack is the nursery.**
* Generated functions never return, so the C stack only grows.
* `C_demand(n)` (`chicken.h:1126-1143`) compares the current stack pointer
  against `C_stack_limit`. When the nursery is exhausted, the procedure calls
  `C_save_and_reclaim` (or `C_save_and_reclaim_args` when customizable), which
  copies its arguments to the *temporary stack* (a small malloc'd area that is a
  GC root) and calls `C_reclaim`.
* `C_reclaim` (`runtime.c:3404`) performs the collection and then
  `longjmp`s back to `CHICKEN_run` (`runtime.c:1560`), which unwinds the entire
  C stack in one instruction and re-enters the saved continuation via
  `C_restart_trampoline`.

```c
/* CHICKEN_run, runtime.c:1586-1603 (abridged) */
C_sigsetjmp(C_restart, 0);
if(!return_to_host) {
  C_word *p = C_alloc(C_restart_c);
  C_memcpy(p, C_temporary_stack, C_restart_c * sizeof(C_word));
  C_temporary_stack = C_temporary_stack_bottom;
  ((C_proc)C_restart_trampoline)(C_restart_c, p);
}
```

That `setjmp`/`longjmp` pair *is* the trampoline. Note it fires only on GC, not
on every call — CHICKEN is not a "return-to-trampoline-per-call" system.

An important consequence for §9.2 (C1b): `C_save_and_reclaim_args`
(`runtime.c:3373`) is varargs over `C_word` — `C_save(va_arg(v, C_word))` —
pushing onto the temporary stack, which the collector scans as roots. **There is
no way to hand a raw `double` to it.** A live unboxed value cannot cross a GC.

### 8.2 The collector

Two generations, both copying (`C_reclaim`, `runtime.c:3404-3708`):

* **Minor**: roots are the temporary stack, the trace buffer, and the
  *mutation stack*. Live data is evacuated from the C stack (nursery) into
  fromspace. Since the C stack is about to be discarded wholesale by the
  `longjmp`, there is nothing to sweep.
* **Major**: triggered when fromspace fills. A full Cheney copy from fromspace
  into tospace, with roots additionally including literal frames, symbol
  tables, GC roots, collectibles, and finalizers; then the spaces are swapped.
* **Realloc** (`C_rereclaim2`, `runtime.c:3921`): a major GC into a
  freshly-`malloc`ed heap of a different size. Growth/shrink policy is at
  `runtime.c:3598-3639`, with a `heap_shrink_counter` hysteresis to avoid
  grow/shrink thrashing.

The evacuation core is `really_mark` (`runtime.c:3834`) — chase forwarding
pointers, bump-allocate in the target space, `memcpy`, install a forwarding
pointer — and the breadth-first scan is `mark_nested_objects`
(`runtime.c:3801-3832`):

```c
while(heap_scan_top < *tgt_space_top) {
  bp = (C_SCHEME_BLOCK *)heap_scan_top;
  if(*((C_word *)bp) == ALIGNMENT_HOLE_MARKER) bp = (C_SCHEME_BLOCK *)((C_word *)bp + 1);
  n = C_header_size(bp);
  h = bp->header;
  bytes = (h & C_BYTEBLOCK_BIT) ? n : n * sizeof(C_word);
  p = bp->data;
  if(n > 0 && (h & C_BYTEBLOCK_BIT) == 0) {
    if(h & C_SPECIALBLOCK_BIT) { --n; ++p; }
    while(n--) mark(p++);              /* mark() = "if(!C_immediatep(*p)) really_mark(p,…)" */
  }
  heap_scan_top = (C_byte *)bp + C_align(bytes) + sizeof(C_word);
}
```

**Write barrier.** `C_mutate_slot` (`runtime.c:3067`) records old→new pointers:

```c
if(C_in_stackp((C_word)slot) || (!C_in_stackp(val) && !C_in_scratchspacep(val)))
  return *slot = val;                 /* nothing to remember */
*(mutation_stack_top++) = slot;
return *slot = val;
```

Only heap→nursery and heap→scratch edges are remembered. The mutation stack is
cleared at *every* collection, not only minor ones — the clear lives in
`mark_live_objects`, which `C_reclaim` calls unconditionally
(`runtime.c:3493`) and `C_rereclaim2` also calls (`runtime.c:4000`).

**Scratch space** (`runtime.c:3107`ff) is a third area for objects that must be
sized before they can be built (temporary bignums, in particular). It is
malloc'd, is scanned by the GC through recorded back-pointers, and is discarded
entirely on any non-minor collection.

### 8.3 Continuations

`call/cc` (`C_call_cc`, `runtime.c:7688`) is nearly free:

```c
if(C_immediatep(k) || C_block_header(k) != C_VALUES_CONTINUATION_TAG)
  wrapper = C_closure(&a, 2, (C_word)call_cc_wrapper, k);
else
  wrapper = C_closure(&a, 2, (C_word)call_cc_values_wrapper, k);
av2[0]=cont; av2[1]=k; av2[2]=wrapper;
((C_proc)pr)(3, av2);
```

The continuation object is just a closure over the current CPS continuation
`k`, and invoking it is `C_kontinue(k, result)`. Full multi-shot,
re-entrant continuations, at the cost of one 2-slot (3-word —
`C_SIZEOF_CLOSURE(n)` is `n+1`) closure. This is the payoff for the CPS
decision: no stack copying, no segment chains, no `__builtin_setjmp`.

`chicken.continuation` (`continuation.scm`) exposes the same thing through
Feeley's "A Better API for First-Class Continuations", via a one-line foreign
declaration, `#define C_direct_continuation(dummy) t1` — i.e. "the continuation
is whatever is in `t1`", which is true by the calling convention. It is *not* a
one-shot continuation; it is the same multiply-invocable object, reached without
the wrapper closure.

### 8.4 Interrupts and threads

`C_check_for_interrupt` (`chicken.h:1332`) is a decrement-and-test on
`C_timer_interrupt_counter`; the backend emits it in the prologue of every
restartable (non-direct) procedure, *when timer checks are enabled* — under
`-disable-interrupts` or `(declare (disable-interrupts))` no check is emitted at
all, which `continuation.scm` itself relies on. Because an interrupt can only
fire where the runtime knows how to restart, green threads (`scheduler.scm`) get
preemption for free and with no safepoint machinery: an interrupt just makes the
next `C_demand` check fail, which routes through `C_reclaim` →
`handle_interrupt`.

The corollary is worth stating, because §9.2 (C1b) runs into it: a loop that
becomes fully allocation-free also becomes **non-preemptible**, since there is no
longer a demand check to fail.

---

## 9. Where the performance is left on the table

These are ordered by **cost centre**, not by technique, because "SIMD versus
not" turned out to cut across the real distinctions. Each item is tagged
**[measured]** (numbers in §10.1) or **[proposal]** (argued from source only).

The single largest finding is a one-character bug, and it is in §9.2.

### 9.1 Build and compile flags

**(B1) The default build is `-Os`, not `-O0` — and that mostly does not matter.
[measured]**

The portability-sensitive flags are already right: every gcc/clang platform
makefile passes `-fno-strict-aliasing -fwrapv` (`Makefile.linux:35` and
siblings), which the runtime's `C_word*` ↔ `C_SCHEME_BLOCK*` punning needs. The
optimization level is a three-way choice (`Makefile.linux:36-44`):

```make
ifdef DEBUGBUILD
C_COMPILER_OPTIMIZATION_OPTIONS ?= -g -Wall -Wno-unused -O0 -Wno-cpp
else
ifdef OPTIMIZE_FOR_SPEED
C_COMPILER_OPTIMIZATION_OPTIONS ?= -O3 -fomit-frame-pointer
else
C_COMPILER_OPTIMIZATION_OPTIONS ?= -Os -fomit-frame-pointer     # ← the fall-through default
endif
endif
```

`configure` sets neither variable, so a stock build lands on `-Os`; `-O0` is
reachable only under `DEBUGBUILD`. Whichever branch wins is baked into
`C_INSTALL_CFLAGS` at build time (`defaults.make:330`), and that is exactly what
`csc` passes when compiling *user* programs (`csc.scm:130-131`). This tree
confirms it — `chicken-defaults.h:15`:

```c
#define C_INSTALL_CFLAGS "-fno-strict-aliasing -fwrapv -DHAVE_CHICKEN_CONFIG_H -DC_ENABLE_PTABLES -Os -fomit-frame-pointer"
```

and `csc -v hello.scm` really invokes clang with exactly those flags.

Measured (§10.1 F), the consequences are not what a missing-optimizer story
would suggest:

* `-O0` really is catastrophic — up to 8.6× on compute-bound generated C — but
  nobody is standing on it.
* **`-O3` buys nothing over `-Os` for CHICKEN-generated C**: equal or slightly
  worse on all five benchmarks tried. The generated code is a sea of small
  `goto` loops and indirect tail calls that extra inlining and unrolling cannot
  help.
* The level that *does* matter is the one **`libchicken` itself** was built
  with. Its out-of-line byte-scanning kernels are compiled once, at `-Os`, and
  never vectorize: recompiling the unchanged `C_utf_fast_count` source at `-O2`
  is **5.1×** (§10.1 E).

So the actionable form of B1 is: **build the runtime with
`OPTIMIZE_FOR_SPEED=1`, not the user programs.** Beyond that,
`-fno-semantic-interposition` and LTO on `libchicken` are worth measuring —
though note they remove indirection for calls *within* `libchicken`, not the
user-code→`libchicken` hop, so LTO is the one likely to pay.

**`-march=native` is not an option for anything installed.**
`C_COMPILER_OPTIMIZATION_OPTIONS` is compiled into every `libchicken` object
*and* baked verbatim into both `C_INSTALL_CFLAGS` and `C_TARGET_CFLAGS`
(`defaults.make:330,420`), which `csc` reads back and re-passes to the user's C
compiler. Setting it would (a) ship a `libchicken.so` that dies with SIGILL on
any CPU lacking the build machine's ISA extensions, and (b) silently stamp
`-march=native` onto every user program that installation ever compiles — and it
leaks into the cross-compilation flags (`defaults.make:105-106`), where `native`
is not a valid `-march` value. Any AVX2 path must be **runtime-dispatched**
(`__builtin_cpu_supports` plus `__attribute__((target("avx2")))`), not
flag-gated. `-march=native` is fine only for a local, never-installed benchmark
build.

**Source default versus as-built flags.** Everything above is about what
`Makefile.linux` *defaults* to, and that is unchanged in this tree. It is not
necessarily what a given checkout was actually built with, and the distinction
matters whenever a timing is quoted. Read the generated `chicken-defaults.h`: this
tree was configured with `OPTIMIZE_FOR_SPEED`, so its `C_INSTALL_CFLAGS` ends `-O3
-fomit-frame-pointer` and the header opens with
`/* (this build was optimized for speed) */`, whereas the 6.0.0 tree the earlier
revision of these notes was measured on ends `-Os -fomit-frame-pointer` and carries
no marker. So the B1 action item — build the runtime for speed — is already done
here, and the §10.1 tables state which tree each was produced on.

**(B2) FMA is a build-flag question, not a compiler pass. [measured]**

`C_a_i_flonum_multiply_add` and `C_ub_i_flonum_multiply_add` both exist, and the
only thing that generates them is an explicit `fp*+` call (`c-platform.scm:657`).
The trap is that both bottom out in libm's `fma` — `#define C_fma fma`
(`chicken.h:1013`). It is a **function**, not an instruction, and the shipped
`CFLAGS` carry no `-mfma` and no `-march`, so clang emits `call fma@PLT`.
Measured on this build, the same loop written as `(fp*+ a s 1.0)` runs **~1.2×
slower** than `(fp+ (fp* a s) 1.0)` (a pure-C microbenchmark exaggerates this to
~2×). A peephole that rewrote mul+add into `fp*+` today would make exactly the
loops that matter *slower*.

Nor does a peephole help once the flags are right: with `-mfma`, clang already
contracts `a*b+c` into `vfmadd` unaided. What CHICKEN needs is `-mfma` **plus**
`-ffp-contract=fast` — the second is the non-obvious one, because the generated
code splits the multiply and the add across separate C statements and clang's
default `-ffp-contract=on` will not fuse across statements. (FMA changes
rounding, so this should be an opt-in declaration rather than a global default.)

### 9.2 Generated code

**(C0) The SRFI-4 rewrites never fired — a missing `#` in `c-platform.scm`.
[measured; FIXED on this tree]**

This was the largest single defect in the tree and it was a one-character-per-name
typo. It is repaired here, and the repair is the least interesting part of the
entry: waking ~63 rewrite rules that had never executed in this build exposed two
latent upstream bugs that had been sitting behind them. Those are (C0a) and (C0b)
below, and they are the more important result.

**The defect.** `+extended-bindings+` (`c-platform.scm:192-228`, pristine) listed
every `chicken.number-vector` name **without the `#` module separator**:

```scheme
    chicken.number-vectorf32vector-ref chicken.number-vectorf64vector-ref     ; :210
    chicken.number-vectorf32vector-set! chicken.number-vectorf64vector-set!   ; :217
```

Every other module in the same list is spelled correctly —
`chicken.bitwise#arithmetic-shift` (`:186`),
`chicken.bytevector#bytevector-length`. The identifiers the compiler actually
sees are `chicken.number-vector#f64vector-ref`, so `(intrinsic? name)` failed for
all of them and no rewrite keyed on a correct name could ever be applied.

**The typo had two independent halves.** This matters, because repairing only the
one people notice would have left the type predicates out of line:

* **66 names in `+extended-bindings+`** (`:192-228`). This is the intrinsic
  table; without an entry here a rewrite is unreachable no matter how it is
  spelled.
* **10 type-predicate rewrite rules whose own head symbol was misspelled**
  (`:529-538`), e.g. `(rewrite 'chicken.number-vectorf64vector? 2 1
  "C_i_f64vectorp" #t)`. A separate spelling error in a separate table. Fixing
  `+extended-bindings+` alone would have woken the refs, setters and lengths and
  left `f64vector?` still compiling to a CPS call.

76 names across 43 lines, in two tables.

**The consequence was that every SRFI-4 element access compiled to a full CPS
call through the global symbol table.** Confirmed on this tree — a dot-product
loop at `-optimize-level 3` under `(declare (unsafe) (block))` contained *zero*
`C_a_i_f64vector_ref` / `C_ub_i_f64vector_ref` and instead three calls through
`lf[…]=C_h_intern(…,"chicken.number-vector#f64vector-ref")`. Per element: three
`C_check_for_interrupt`, three `C_demand`, two closure allocations, two indirect
calls, and a flonum allocated inside each call. The pristine compiler emits **no**
SRFI-4 intrinsic at any optimization level.

**The fix, and why the old-vs-new comparison is clean.**

```sh
T=~/Developer/working-copies/chicken-core
cd $T && sed -i 's/chicken\.number-vector\([a-zA-Z]\)/chicken.number-vector#\1/g' c-platform.scm
make chicken
```

46 changed lines, 76 corrected names, both tables at once. `make chicken`
recompiles `c-platform.scm` → `c-platform.c` (0.62 s), compiles it at the tree's
stock `-Os` (2.13 s) and relinks the driver (0.10 s) — **~2.9 s** end to end
(median of 3, measured here).

`c-platform` appears in `COMPILER_OBJECTS_1` and nowhere else (`rules.make:46-48`);
`LIBCHICKEN_OBJECTS_1` is `$(LIBCHICKEN_SCHEME_OBJECTS_1) runtime utf`
(`rules.make:41`). **`libchicken.so` is therefore not rebuilt** — on this tree it
still carries its original build stamp while `chicken`, `c-platform.c` and
`c-platform.o` carry the patch stamp. Old and new compilers link the byte-identical
runtime, so every number in §10.1 B, G and H is attributable to the compiler patch
and to nothing else. §10.1 G goes further and includes a configuration whose
generated C is byte-identical between the two compilers, as a control.

**What woke up.** Unpatched master has 73 rewrite rules under these names: 63
already spelled with `#` but unreachable because their `+extended-bindings+`
entries were not, plus the 10 misspelled predicates. After the spelling fix all 73 fired for
the first time in this build. Two of them were unsound and one more was; those
three are deleted, leaving **70** rules — 36 flagged `#t` (apply in safe mode too)
and 34 flagged `#f` (unsafe only), per `(or (third classargs) unsafe)` in the
optimizer's class-2 handler. Firing was verified in emitted C, not assumed: a
polymorphic probe compiled at `-O3` contains 36 distinct inlined intrinsics —
exactly the 36 `#t` targets — where the same probe under the pristine compiler
contains zero.

---

**(C0a) The unsafe `f32/f64vector-set!` rewrites were unsound. [measured; rules
deleted]**

`c-platform.scm:1113` and `:1115` (pristine) rewrote the float setters to
`C_u_i_f32vector_set` / `C_u_i_f64vector_set`:

```c
/* chicken.h:1656-1657 */
#define C_u_i_f64vector_set(v, i, x) \
  ((((double *)C_data_pointer(C_block_item((v), 1)))[ C_unfix(i) ] = C_flonum_magnitude(x)), C_SCHEME_UNDEFINED)
```

`C_flonum_magnitude` is an unchecked field read. But `types.db:2326` and `:2338`
declare the value argument as `(or integer float)`:

```
(chicken.number-vector#f64vector-set! (#(procedure #:clean #:enforce)
   chicken.number-vector#f64vector-set! ((struct f64vector) fixnum (or integer float)) undefined))
```

So a fixnum value dereferences an immediate (segfault) and a bignum value reads
two words out of a bignum's header as a `double` (silent garbage). The `#f` flag
means this applied under `-unsafe`, and `-O4` and `-O5` cons `'unsafe` onto the
options unconditionally (`chicken.scm:121-132` and `:132-147`), so it applied
there too. Measured with a patch-1-only compiler:

```
f32vector-set! x=1        -> Error: segmentation violation
f64vector-set! x=1        -> Error: segmentation violation
f64vector-set! x=2^100    -> 5.0153151251352e-310      (correct: 1.26765060022823e+30)
f32vector-set! x=2^100    -> 0.0                       (correct: 1.26765060022823e+30)
```

The distribution's own test suite trips it: with the spelling fix alone,
`tests/srfi-4-tests.scm` exits 70 with `Error: segmentation violation` at both
`-O4` and `-O5` (it passes at `-O3`, and passes at every level under both the
pristine and the final compiler).

**The asymmetry that bounds the diagnosis.** Only the two float setters are
wrong, and the integer setters are provably fine, because the declaration and the
coercion agree for every one of them:

| rules | `types.db` value | unsafe macro's coercion | agree? |
|---|---|---|---|
| `u8/s8/u16/s16vector-set!` | `fixnum` | `C_unfix(v)` | yes |
| `u32/s32/u64/s64vector-set!` | `integer` | `C_num_to_unsigned_int` / `C_num_to_int` / `C_num_to_uint64` / `C_num_to_int64` | yes |
| `f32/f64vector-set!` | `(or integer float)` | `C_flonum_magnitude(v)` | **no** |

The fix is to delete the two `#f` rules and let both modes use the coercing
`C_i_f32vector_set` / `C_i_f64vector_set` (`runtime.c:6295`, `:6346`), which
accept flonum, fixnum and bignum. That is what `c-platform.scm:1118-1125` now
does. It is not free — see "Residual performance" below and §10.1 G.

---

**(C0b) The `u8vector?` rewrite segfaulted in DEFAULT SAFE MODE. [measured; rule
deleted]**

`c-platform.scm:529` (pristine) was
`(rewrite 'chicken.number-vectoru8vector? 2 1 "C_bytevectorp" #t)`, and

```c
/* chicken.h:1160 */
#define C_bytevectorp(x)  C_mk_bool(C_header_bits(x) == C_BYTEVECTOR_TYPE)
```

`C_header_bits` dereferences its argument. There is no `C_immediatep` guard. The
`#t` flag means the rule applied **in default safe mode, with no `-unsafe`
anywhere**, so `(u8vector? x)` crashed for every immediate — fixnum, `'()`, `#t`,
a character — whenever the argument's type was not statically known.

**The asymmetry that bounds this one too.** The other nine predicates are
one-line wrappers over `C_i_structurep` (`chicken.h:1378`), whose first term is
`!C_immediatep(x) &&`:

```c
/* runtime.c:5023ff */
C_regparm C_word C_i_s8vectorp(C_word x) { return C_i_structurep(x, s8vector_symbol); }
```

so `s8/u16/s16/u32/s32/u64/s64/f32/f64vector?` are immediate-safe and keep their
rewrites. Only `u8vector?` targeted a raw `chicken.h` macro, and the out-of-line
definition it was replacing carries exactly the guard the macro lacks:

```scheme
;; srfi-4.scm:681
(define (u8vector? x) (and (##core#inline "C_blockp" x) (##core#inline "C_bytevectorp" x)))
```

The rewrite dropped the `C_blockp` half. Deleting the rule restores the guarded
out-of-line call, which is what the pristine compiler already produced.

---

**The methodological lesson: probe polymorphically, or find nothing.**

The obvious probe does not expose either bug:

```scheme
(print (u8vector? 42))          ; -> #f, under every compiler, including the broken one
```

The scrutinizer folds the predicate when the argument's type is statically known,
so the rewrite never fires and the emitted C contains **zero** occurrences of
`C_bytevectorp`. Verified directly: under the patch-1-only compiler, that program
prints `#f` and its `.c` has 0 `C_bytevectorp`, while

```scheme
(define (probe x) (u8vector? x))
(define vals (list 42 (u8vector 1 2)))
(for-each (lambda (v) (display (probe v))) vals)
```

has 2 `C_bytevectorp` and dies with `Error: segmentation violation`. This is why
the first sweep over the woken rules reported clean: every probe in it was
monomorphic. **Any rewrite whose defect is a missing type guard is invisible to a
statically-typed call site by construction**, because the guard is exactly what
the scrutinizer discharged. Value-domain bugs like (C0a) need the same treatment
for the same reason — the value must arrive through a runtime-built list whose
union type the scrutinizer cannot narrow.

---

**The exhaustive sweep: nothing else is defective.**

All 70 surviving rules were enumerated and checked against `chicken.h`,
`runtime.c` and `types.db`. **No rule beyond the three above is defective.**

* All 36 `#t` rules resolve to a `runtime.c` function that type-checks its vector
  through an immediate-safe guard (`C_i_<t>vectorp` → `C_i_structurep`, or an
  explicit `C_immediatep`), requires `i & C_FIXNUM_BIT`, rejects `j < 0 || j >=
  size`, and accepts exactly the value domain `types.db` declares. Bounds checks
  demonstrably survive inlining: at `-O3`, index 4 into a 4-element vector raises
  `out of range` for all ten types.
* All 34 `#f` rules resolve to raw unguarded `chicken.h` macros with no immediate
  test and no bounds test — which is precisely what `-unsafe` licenses — and none
  of the eight surviving unsafe setters has a coercion/declaration mismatch (the
  table under (C0a)).
* Exactly one `#t` rule points at a guard that is not immediate-safe:
  `c-platform.scm:1103`, `u8vector-set!` → `C_i_u8vector_set`. That is (C0c)
  below, and the rule must **not** be deleted.

---

**(C0c) A pre-existing runtime bug that is not the compiler's to fix.**

```c
/* chicken.h:1488 */  #define C_i_u8vector_set  C_i_bytevector_set
/* runtime.c:6087 */  C_regparm C_word C_i_bytevector_set(C_word v, C_word i, C_word x) {
                        if(!C_truep(C_bytevectorp(v)))          /* no C_immediatep */
                          barf(C_BAD_ARGUMENT_TYPE_ERROR, "bytevector-set!", v);
```

Structurally this is (C0b). It is **not** a patch regression, because the
out-of-line path is equally exposed — `srfi-4.scm:171` aliases `u8vector-set!`
straight to `bytevector-u8-set!`, and `library.scm:3520-3521` is
`(##core#inline "C_i_bytevector_set" bv i b)` with no prior check. Measured, safe
`-O3`, polymorphic probe, both compilers:

```
(u8vector 9 9) -> ok                       42  -> segmentation violation
"s"            -> bad argument type       1.5  -> bad argument type
```

Byte-identical between pristine and patched. Deleting the rewrite would move the
crash out of line into the same C function. `C_i_bytevector_ref` (`runtime.c:5633`)
has the same hole; `C_i_bytevector_length` (`runtime.c:5911`) does **not** — it
opens `if(C_immediatep(v) || !C_truep(C_bytevectorp(v)))`. That asymmetry is the
whole bug, and the fix belongs in `runtime.c`.

---

**Residual performance left on the table by (C0a) and (C0b). [proposal]**

Both deletions cost something measurable, and both are recoverable without
reintroducing the defect:

* **(C0a) — a type-conditional unsafe float store.** The checked
  `C_i_f64vector_set` costs **1.70×** against the deleted macro on an `axpy`
  kernel at `-O3 -unsafe` (1036 → 1763 ms; the two generated `.c` files differ in
  exactly two instruction lines), and **3.2×** on `fft -D unboxed`, which stores
  as often as it loads (§10.1 G). The information needed to make the unsafe rule
  sound is already available: in every one of these loops the value is the result
  of an `fp*`/`fp+`, so the scrutinizer has already proved it a `float`. What is
  missing is a way for the rewrite to consult that. Two things were established
  experimentally about the route: a `types.db` specialization *does* outrank a
  `c-platform` rewrite when it matches (`f64vector-length` at `types.db:2329`
  emits `C_u_i_64vector_length` under both compilers), but a one-line
  specialization added to `types.db:2334` for the `((struct f64vector) fixnum
  float)` case never matched — `-debug o` printed no `specializations:` line and
  the emitted C kept `C_i_f64vector_set`. And a specialization would be the wrong
  vehicle anyway: the code that would have gated specializations on safe mode is
  commented out (`scrutinizer.scm:545-554`), so a specialization firing in safe
  mode would drop the *bounds* check as well as the type check. The conditional
  therefore has to live in the rewrite layer, as a rewrite class that can consult
  the argument's inferred type. That is the single largest measured performance
  item now outstanding in this document.
* **(C0b) — an immediate-checking `C_i_bytevectorp`.** Adding
  `!C_immediatep(x) &&` to a new `C_i_bytevectorp` (and to `C_i_bytevector_set`
  and `C_i_bytevector_ref`, which fixes (C0c) at the same time) would let
  `u8vector?` be rewritten again. Measured upper bound: **7.15×** on a
  200M-call polymorphic predicate loop (3688 ms out-of-line vs 516 ms for the
  correctly guarded inline `(and C_blockp C_bytevectorp)`). Note this is a
  give-up against a hypothetical, not a regression: the pristine compiler also
  emits `u8vector?` out of line, so (C0b) costs nothing against the shipping
  baseline, and a realistic u8vector loop is still 1.43×/1.82× faster than
  pristine because `u8vector-set!` inlines.

---

**Upstream bug report — the coordinates a maintainer needs.**

All line numbers are in pristine CHICKEN 6.0.0 unless marked.

1. **`c-platform.scm:192-228`** — 66 `chicken.number-vector` names in
   `+extended-bindings+` are missing the `#` module separator, disabling every
   SRFI-4 rewrite. *(Fixed here.)*
2. **`c-platform.scm:529-538`** — 10 type-predicate `rewrite` rules are
   independently misspelled the same way. A separate table; fixing (1) alone does
   not fix these. *(Fixed here.)*
3. **`c-platform.scm:1113` and `:1115`** — the `#f` rewrites for
   `f32/f64vector-set!` emit `C_u_i_f32vector_set` / `C_u_i_f64vector_set`
   (`chicken.h:1656-1657`), which apply `C_flonum_magnitude` unchecked, against a
   `types.db:2326` / `:2338` declaration of `(or integer float)`. Segfault on a
   fixnum value, silent garbage on a bignum, under `-unsafe`, `-O4` and `-O5`.
   `tests/srfi-4-tests.scm` itself fails at `-O4` once the rules are reachable.
   *(Rules deleted here; a type-conditional replacement is the better fix.)*
4. **`c-platform.scm:529`** — the `u8vector?` rewrite targets `C_bytevectorp`
   (`chicken.h:1160`), a raw `C_header_bits` test with no `C_immediatep` guard,
   and it carries the `#t` flag, so it fires in default safe mode. The
   out-of-line definition it replaces guards with `C_blockp` (`srfi-4.scm:681`).
   *(Rule deleted here; the better fix is an immediate-checking `C_i_bytevectorp`.)*
5. **`runtime.c:6087` (`C_i_bytevector_set`) and `runtime.c:5633`
   (`C_i_bytevector_ref`)** lack the `C_immediatep(v) ||` guard that
   `C_i_bytevector_length` (`runtime.c:5911`) has, so `(u8vector-set! 42 0 1)`
   and `(u8vector-ref 42 0)` segfault in safe mode. Reachable with no compiler
   patch at all, via `srfi-4.scm:171` → `library.scm:3520`. *(Not fixed here —
   it is a runtime bug.)*
6. **`c-platform.scm:197`** — `+extended-bindings+` names
   `chicken.number-vector#f128vector?`, a procedure that does not exist anywhere
   in the tree. It should be `c128vector?` (`srfi-4.scm:692`, `types.db:2308`).
   Harmless today because `c128vector?` has no rewrite; latent if one is added.
   *(Not fixed here — outside the scope of the `#` repair.)*
7. **`c-platform.scm:1150`, `:1159`, `:1160`** (patched-tree numbering) — the
   `s8vector->`, `c64vector->` and `c128vector->bytevector/shared` rewrites are
   dead: those three names are absent from `+extended-bindings+`, so only 8 of
   the 11 `C_slot` rules can ever fire. Pre-existing. *(Not fixed here.)*

8. **`c-platform.scm` — the partial fix already attempted, and why it is inert.**
   Upstream `e438ca50` ("correct rewrite rules for all chicken.number-vector
   operations", 2026-07-30, an ancestor of 6.0.0) corrected 79 names in the
   *rewrite rule* table — hunks `@@ -1079,76 @@` and `@@ -1207,18 @@` only. It
   never touched `+extended-bindings+` (`:192-228`) or the ten predicate rules
   (`:529-538`), and `+extended-bindings+` membership is what gates a rewrite
   (`(intrinsic? name)` in the class-2 handler). So the rules have been spelled
   correctly and been unreachable ever since, and the commit produced **no
   observable change**. This is the single most useful thing to lead a bug report
   with, because it explains how the tree came to be in a state where the rewrite
   table looks right and nothing fires. Compounding it, `NEWS:514-515` (in the
   5.1.0 section) still advertises the feature as working: *"SRFI-4 vector
   predicates, reference, set and length procedures should now be faster in tight
   loops as they're inlineable (#757)."*
9. **`c-platform.scm:620`** — `(rewrite '##sys#bytevector? 2 2 "C_bytevectorp" #t)`
   gives a one-argument predicate an arity of 2, so this rewrite never fires
   either. Harmless *today*, but it is a latent second copy of item 4: it targets
   the same unguarded `C_bytevectorp` with the same safe-mode `#t` flag, so
   correcting the arity before `C_bytevectorp` gains a `C_immediatep` guard would
   introduce a fresh safe-mode segfault in internal code. Fix the guard first.
10. **`tests/gobble.scm` and `tests/sgrep.scm` are broken on master**, unrelated to
   any of the above. Both are driven by `tests/runbench.sh` and both segfault under
   the stock compiler: at `-O5 -d0` the missing-variable trap degenerates into a
   SIGSEGV. Recompiled at `-O3` the real cause shows: `gobble.scm:15` calls
   `command-line-arguments` with no import form at all, and `sgrep.scm` uses
   `command-line-arguments` (`:8`) and `fx+` (`:33`, `:35`) while importing only
   `chicken.io chicken.irregex chicken.port` (`:4`). Neither is auto-imported in
   CHICKEN 6. One line each: add `(import (chicken process-context))` to
   `gobble.scm` and `chicken.process-context chicken.fixnum` to `sgrep.scm`'s
   import list. Any `runbench.sh` figure quoted for `grep` or `allocation` without
   this fix is timing a segfault, not a benchmark.

**(C1a) `C_ub_i_f64vector_set` exists but nothing emits it. [proposal]**

With (C0) fixed, a float store still round-trips through a freshly allocated
flonum. No declaration is needed any more — compile at `-O2` or higher with
`(declare (unsafe))`:

```scheme
(define (axpy! a x y n)
  (let loop ((i 0))
    (unless (fx= i n)
      (f64vector-set! y i (fp+ (fp* a (f64vector-ref x i)) (f64vector-ref y i)))
      (loop (fx+ i 1)))))
```

and you get:

```c
double f0;                                        /* ← the *only* unboxed temp */
...
loop:
C_check_for_interrupt;
if(C_unlikely(!C_demand(C_calculate_demand(4,0,2)))){
C_save_and_reclaim_args((void *)trf_152,3,t0,t1,t2);}
a=C_alloc(4);                                     /* ← 4 words = one flonum, every iteration */
...
f0=C_ub_i_flonum_times(C_flonum_magnitude(((C_word*)t0)[3]),C_ub_i_f64vector_ref(((C_word*)t0)[4],t2));
t4=C_flonum(&a,C_ub_i_flonum_plus(f0,C_ub_i_f64vector_ref(((C_word*)t0)[5],t2)));  /* ← heap-allocates … */
t5=C_u_i_f64vector_set(((C_word*)t0)[5],t2,t4);                                    /* … and immediately unboxes */
```

The unboxed macro **already exists** — `chicken.h:1661-1662` define
`C_ub_i_f32vector_set` and `C_ub_i_f64vector_set` in exactly the needed form —
but a whole-tree grep finds no other reference to either name. They are dead
macros. What is missing is the compiler-side half, and it is more than a table
row: none of `+unboxed-map+`'s three kinds fits a setter. In `walk`
(`lfa2.scm:592-599`), `op` unboxes every argument and boxes the result, `acc`
unboxes none and boxes the result, `pred` unboxes every argument and boxes
nothing. A store needs arguments 1–2 left boxed (the macro applies
`C_block_item` and `C_unfix` to them), argument 3 unboxed, and **no** box around
the result. So the uniform `(map (if (eq? type 'acc) walk walk/unbox) subs)` has
to become position-aware and the result-boxing `case` has to learn a fourth kind.

(C0a) adds a constraint that was not visible when this item was written.
`C_ub_i_f64vector_set` (`chicken.h:1662`) writes `(x)` straight into the array
with no coercion at all, so an unboxed-store rewrite is sound only where the
value is *known* to be a float — which, inside `lfa2`, it is: the whole point of
the pass is that it has proved the operand unboxable. So the unboxed store is
safe for exactly the reason the plain `C_u_i_f64vector_set` rewrite was not, and
(C1a) is in fact the well-typed version of the rule (C0a) had to delete. Building
it would also recover most of what (C0a) costs — it is the same recovery, done in
`lfa2.scm` instead of in the rewrite table. Note that the unboxing pass currently
supersedes the allocating unsafe ref entirely: `C_a_u_i_f64vector_ref` appears in
none of the measured units, because `-unsafe` loops go straight to
`C_ub_i_f64vector_ref`.

**(C1b) Loop-carried accumulators are always boxed. [proposal]**

In the dot-product version, `s` is re-boxed every iteration because
`perform-unboxing` only handles `let`-bound variables; a variable that crosses a
`##core#recurse` / `goto loop` back-edge is a *parameter*. Extending unboxing to
loop parameters would make float loops allocation-free, which removes the
per-iteration `C_check_for_interrupt` and `C_demand` (§7.1) and finally lets the
C compiler vectorize the loop. With (C0) fixed this is now measurable rather than
hypothetical, and it is the *whole* remaining gap on a reduction: at `-O3 -unsafe`
the dot kernel emits two `C_ub_i_f64vector_ref` and no out-of-line call at all,
yet still runs 5.7× off hand-written C — 1238 ms vs 216 ms (§10.1 B) — and the
C reference is not vectorized either, because the serial FP reduction blocks it
there too. That 4.9× is boxing and the trampoline, nothing else.

This is the largest expected payoff among the compiler-side items and also the
most invasive — but the hard part is not the file list (`lfa2.scm`, the
`lambda-literal` record, `c-backend.scm`'s prologue and `##core#recurse`
emission). It is a **GC invariant**. As §8.1 notes,
`C_save_and_reclaim_args` is varargs over `C_word`; a `double` has no
representation on the temporary stack, so a loop-carried unboxed accumulator live
across the back edge cannot simply be left in a register. Either it is spilled to
a boxed flonum before every reclaim and re-unboxed on re-entry — giving back most
of what unboxing bought — or the loop is made *entirely* allocation-free, at
which point CHICKEN already emits it as a direct, value-returning function with
no trampoline and no demand check, and the `double` is trivially safe.

That makes this **all-or-nothing per loop**, makes **(C1a) a hard prerequisite**
(without an unboxed store an `axpy!`-shaped loop keeps allocating and stays
restartable), and means the resulting loop is non-preemptible (§8.4).

**(C3) Hoist checks out of allocating loops.** Subsumed by (C1): once a loop is
non-allocating it already emits no checks. The originally proposed
strength-reduction — check once for *k* iterations and decrement a counter —
does not fit `C_demand`, which compares the stack pointer rather than counting.

### 9.3 The runtime

**(R2) Nursery sizing — a real win, but bounded and dangerous. [measured]**

`DEFAULT_STACK_SIZE` is 1 MB on 64-bit (`runtime.c:138`) and `DEFAULT_HEAP_SIZE`
equals it. Measured (§10.1 C), growing the nursery is worth **1.82×** on
allocation-heavy code *with survivors* (1 MB → 8 MB), is non-monotonic beyond
that, and is worth essentially nothing (<2%) when nothing survives — which is
consistent with the theory that minor GC cost is proportional to survivors, not
to nursery size.

Two things the flag hides. **The nursery *is* the C stack**, so `-:s` is capped
by `RLIMIT_STACK`, and nothing in the tree consults `getrlimit`:
`C_stack_hard_limit` is computed directly from the requested size
(`runtime.c:1574`). Under Linux's default `ulimit -s 8192`, `-:s8m` and above do
not warn or error — they **segfault** the moment the nursery fills (`-:s7m` is
fine). That makes a larger nursery unusable as a shipped default and argues that
any change to `DEFAULT_STACK_SIZE` needs an explicit rlimit check and a real
diagnostic. Second, raising `-:s` drags the heap up with it, since a growing heap
must reserve `stack_size * 2`.

**(R4) Character-at-a-time port I/O is 20× off the C baseline. [measured]**

The port layer is a subsystem this document otherwise ignores, and it has the
largest measured gap to C of anything here. Ports are method vectors of Scheme
closures: a port is a 17-word block (`library.scm:4073`) whose slot 2 is a "port
class" vector with `read-char` in slot 0 (`library.scm:4060-4070`). So
`(read-char p)` costs a check, two `##sys#slot`s, an indirect *Scheme* call into
the class closure, and only then `##core#inline "C_read_char"`
(`runtime.c:4768`), which itself loops over `C_getc` to assemble a UTF-8
sequence. There is no Scheme-side buffer: every character crosses the boundary.

Over a 16 MB ASCII file at `-O3`: `read-char` 795 ms (20 MB/s), `read-line`
176 ms, `read-string #f` 154 ms, against a C `getc_unlocked` loop at 35 ms
(457 MB/s). Two observations: "use `read-line`/`read-string`, never `read-char`"
is worth 4.5× and is not in the manual's performance guidance; and even
`read-string` on a whole file runs at 104 MB/s, that gap being the UTF-8
validate/decode pass — which is the one place §9.5 (S1) would pay off on
something other than a microbenchmark.

The fix is a Scheme-visible buffer in `##sys#stream-port-class`, so `read-char`
becomes a bounds test and a bytevector index in the common case. Local to
`library.scm`; touches no compiler code.

**(R1) Pair evacuation. [proposal]** `really_mark` calls
`C_memcpy(p2->data, p->data, bytes)` for every object; for a pair `bytes` is
2 words (the header is copied separately), so a specialized inline two-word store
would avoid the call. Note this is the *same* change as (S3) below, seen from the
other end — they should be done together, not counted twice.

**(R3) Symbol table. [proposal]** `lookup` (`runtime.c:2466`) walks a bucket
chain per probe. Two corrections to the obvious framing: the buckets are weak
*or strong* pairs depending on whether the name is permanent
(`runtime.c:2616-2620`), and the `C_memcmp` per candidate is already
short-circuited on length, so it only runs on same-length names. An
open-addressed table with stored hashes would still avoid the pointer chasing,
but the memcmp saving is smaller than it looks.

### 9.4 The compiler's own speed

The document elsewhere treats the compiler as a thing that produces code, never
as a program with its own performance. `-debug b` prints a per-pass breakdown; on
`library.scm` (8340 lines, 3.89 s wall):

| pass | ms |
|---|---:|
| optimization (13 iterations) | 1167 |
| analysis (14 runs) | 1065 |
| canonicalization | 691 |
| code generation | 316 |
| scrutiny (incl. pre-analysis) | 177 |
| closure conversion | 98 |
| CPS conversion | 58 |
| preparation | 50 |

Two things follow. The scrutinizer is cheap and not worth optimizing. And
canonicalization is third — which it should not be, because it is quadratic.

**(P1) The line-number database is O(N²) in source expressions. [measured]**

`##sys#line-number-database` (`expand.scm:677`) is a 997-bucket hash table
(`expand.scm:769`) keyed on **the head symbol of a call**, whose value is an
association list of *every distinct source expression with that head*:

```scheme
(define (##sys#update-line-number-database! exp ln)   ; expand.scm:812
  ...
  (let* ((name (car x))
         (old (or (hash-table-ref ##sys#line-number-database name) '())))
    (unless (assq x old)                              ; ← linear in |old|
      (hash-table-set! ##sys#line-number-database name (alist-cons x ln old)))
```

A file with N calls whose head is `if` builds one list of length N under the key
`if`, and registering each of them scans it. `get-line-number`
(`expand.scm:780-789`) and `##sys#get-line-2` (`:792-797`) then `assq` the same
lists on every lookup.

Measured canonicalization time for N copies of one small definition:

| N forms | 1000 | 2000 | 4000 |
|---|---:|---:|---:|
| ms | 314 | 1205 | 4444 |

A clean ~4× per doubling. It is not GC (`-:hi512m` changes nothing) and not the
symbol table (`-:t500000` changes nothing), and no compiler flag disables it —
`-no-trace` and `-no-lambda-info` both leave it in place. A statistical profile
(`chicken -:p`, then `chicken-profile`) puts ~20% in `find`'s inner predicate and
a further ~17% across the three line-number procedures.

The fix is a data-structure change, not an algorithm change: key the table on the
expression's own identity (an `eq?` hash table keyed by the pair) rather than on
its head symbol. Nothing outside `expand.scm` depends on the current shape except
`##sys#display-line-number-database`. With (C0) fixed (§9.2), this is now the
cheapest large win left in this document.

### 9.5 SIMD

SIMD comes last deliberately. The measured wins above are larger and cheaper.
Of the two prerequisites this section used to name, **(C0) is now discharged** —
the SRFI-4 rewrites fire on this tree, so float-kernel work can finally be
measured against a sane baseline (§10.1 B). **(B1) is not**: `libchicken.so` is
still the shipped `-Os` build, and that is where most of (S1)'s win lives.

CHICKEN contains no SIMD intrinsics: no `immintrin.h`, no `__m128`, no
`__builtin_ia32`. Some of that is deliberate — the project's portability promise
is a stated goal, though the README's claim is specifically about *generated*
code being portable, not a blanket ban on platform-specific code in the runtime.
Any of the following should be an `#ifdef`-guarded fast path with the current
scalar code as fallback, dispatched at runtime rather than by `-march` (see B1).

**(S1) UTF-8 scanning. [measured]**

The ranking here needed correcting twice over. The function the original notes
led with, `C_utf_fast_count` (`utf.c:3537`), is **dead code** — the only two
references in the entire tree are its definition and its prototype
(`chicken.h:1924`). Vectorising it today buys nothing.

The function actually on the hot path is the *slow* one, `C_utf_count`
(`utf.c:3500`), which `utf8_decode`s every character just to count them. It is
reached through `C_utf_length` / `C_utf_range_length` (`chicken.h:1389-1390`) and
directly from `C_string` / `C_static_string` (`runtime.c:2794`, `:2815`) — so
every string built from bytes pays a full extra pass, including every string
literal at unit-init time, `##sys#symbol->string`, and `get-output-string`.

So step one is not "write SIMD", it is **route the counting paths through a fast
counter at all**; SIMD is step two. The catch is that the two are not
interchangeable on malformed input — the source calls them "slow variant, handles
invalid sequences" versus "fast, unsafe variant", and a stray continuation byte
counts as one character under `C_utf_count` and none under a lead-byte count. The
fast path needs a validated-input precondition or a fused validate-and-count.

The other genuinely hot target is `utf_index1` (`utf.c:3247`), which backs
`string-ref`. Per §2.2 it is guarded by an ASCII short-circuit and a memoised
forward cursor, so the win is confined to one quadrant: **non-ASCII strings
accessed non-sequentially**, where it is worth ~2000× (§10.1 D).

Measured on the counting kernel (§10.1 E), most of the available win is a
build-flag win, not a SIMD win: recompiling the unchanged scalar source at `-O2`
is 5.1× over the shipped `-Os`, while a portable SWAR version adds a further
1.4–1.5× at `-O2`/`-O3` (and 2.6× at `-O3 -march=native`). A pure-C SWAR
rewrite needing no intrinsics is therefore the right first move.

Also worth fusing: `C_utf_validate` (`utf.c:3516`) has exactly one caller,
`utf8->string` (`library.scm:3537`), which then immediately re-scans the same
bytes via `##sys#buffer->string` → `C_utf_range_length`.

**(S2) Bignum arithmetic — use wide multiply first, SIMD second. [proposal]**

```c
/* runtime.c:10485 — schoolbook multiply, decomposing digits into halves */
for (j = 0; j < length_y; ++j) {
  yj = C_uhword_ref(yd, j);
  if (yj == 0) continue;
  carry = 0;
  for (i = 0; i < length_x; ++i) {
    product = (C_uword)C_uhword_ref(xd, i) * yj + (C_uword)C_uhword_ref(rd, i + j) + carry;
    C_uhword_set(rd, i + j, product);
    carry = C_BIGNUM_DIGIT_HI_HALF(product);
  }
  C_uhword_set(rd, j + length_x, carry);
}
```

Two precisions the original framing got wrong. There is no half-digit
*representation* — bignum digits are already full `C_uword`s; only the multiply
*algorithm* decomposes them via `C_uhword_ref`/`C_uhword_set`. And the tree does
not actually state the "portable C has no 64×64→128 multiply" rationale anywhere;
that is inference, however plausible.

On GCC/Clang, `unsigned __int128` gives the wide multiply directly; on MSVC,
`_umul128`. Working in full 64-bit digits quarters the partial-product count —
though since each surviving product is twice as wide, the *instruction*-count win
is ~4× only where 64×64→128 is a single instruction. Then carry chains map onto
ADCX/ADOX, though the commonly cited ~2× for those is a result for
multiply-accumulate inner loops with two independent carry chains, not for plain
addition. AVX-512IFMA with 52-bit limbs is how GMP-class code does it, but that
means changing the limb representation — a much bigger project.

The Karatsuba threshold and its "generates a bit more garbage and GC overhead
dominates" rationale should be re-checked and re-tuned after any of this, since
it interacts with (R2).

**(S3) GC slot scanning. [proposal]** The inner loop of `mark_nested_objects` is
`while(n--) mark(p++)`, one dependent branch per word. A vectorized *filter* —
load 4–8 words, AND with 3, compare to zero, movemask, iterate only over set bits
— turns the common all-immediates case into a handful of instructions per 8
slots. The `&3` test is correct and `really_mark`'s forwarding-pointer mutation
does not invalidate a precomputed mask, since the mask is computed from the slot
*values* before any are updated. But the applicability claim needs defending: it
helps fixnum-vector and structure-heavy heaps and does nothing for pair-heavy
ones, where every slot is a pointer. See (R1) — the pair-copy specialization is
the same change from the other side.

**(S5) Byte scanning in string search. [proposal]** There is no `string-search`
or `string-index` in core CHICKEN 6 — the procedure is `substring-index`
(`chicken.string`, `data-structures.scm:123`), and it is worse than
`memchr`-shaped: `traverse` (`:88`) is a naive O(n·m) Scheme loop over
*codepoint* offsets calling `C_u_i_substring_equal_p` → `C_utf_compare`
(`utf.c:3376`) at each one, which decodes a codepoint at a time. Delegating to
`memmem` is a real win but not free: it returns a byte offset and the caller
needs a codepoint index, so the position must be converted back — free for ASCII,
an extra `C_utf_count` over the prefix otherwise.

Irregex does not fit here at all: it has no literal-prefix scan to delegate.
Literals expand to one NFA state per character and the subject is walked one
position at a time; its `string-scan-char` family runs only on the *pattern*, at
regex-compile time. Adding a first-character `memchr` skip to the search loop
would be a genuine addition — and probably the larger of the two wins.

**(S6) `hash_string` (`runtime.c:2455`). [proposal]** Low priority, and for a
different reason than first assumed. The serial dependency
(`key ^= (key << 6) + (key >> 2) + *(str++)`) does prevent vectorization, but the
real point is that there is **no `string-hash` in core CHICKEN 6** to call it on,
and every in-tree caller feeds it identifier-length input. Nor is the hash
memoized where it would matter: symbols carry no hash slot (`C_SIZEOF_SYMBOL` is
4) and `C_lookup_symbol` recomputes it on every call. What compiled code avoids
is one step up — literal symbols are interned once into the unit's literal frame
at init. A block-parallel hash (xxh3/wyhash) would improve distribution, but the
win is confined to `string->symbol`-heavy code such as the reader, and it changes
hash values.

**(S4) SRFI-4 bulk operations. [measured, and mostly a correction]**

`srfi-4.scm` does not "offer only element-at-a-time accessors": it already
exports `subf64vector`, the `f64vector->bytevector[/shared]` family and
`f64vector->list` / `list->f64vector`, and `subnvector` already runs through a C
memcpy kernel (`C_copy_subvector`, declared in the unit's own `foreign-declare`
at `srfi-4.scm:33-37`, called at `:793`) via exactly the `##core#inline`
mechanism. What is missing is bulk **arithmetic and reduction**: no
`f64vector-fill!`, no `-copy!`, no `-scale!`, no `-sum`, no dot product.

Two corrections to the proposed kernel, both of which matter because it was
presented as ready to paste:

* A `double`-returning C function **cannot** be reached through `##core#inline`,
  which emits a bare `Name(args)` into a `C_word`-valued assignment
  (`c-backend.scm:484-487`); the `double` is silently truncated and handed to the
  runtime as an object pointer. Compiled and run, that segfaults. A
  flonum-returning kernel must return a `C_word` built with `C_flonum(ptr, …)`
  and be bound with `##core#inline_allocate`, which emits `Name(&a,3,…)` and adds
  the words to the frame's demand.
* Measured, the reduction kernel does **not** auto-vectorize at `-O3`, at
  `-O3 -ffp-contract=fast`, or at `-O3 -march=native` — the loop-carried
  dependence blocks it without explicit reassociation. Elementwise ops
  (`fill!`, `scale!`, `axpy!`) do vectorize at `-O2` and up.

So:

```c
C_regparm C_word C_a_i_f64vector_dot(C_word **ptr, C_word c,
                                     C_word x, C_word y, C_word n) {
  double *a = (double *)C_data_pointer(C_block_item(x,1));
  double *b = (double *)C_data_pointer(C_block_item(y,1));
  double s = 0.0;
  C_word i, len = C_unfix(n);
  for(i = 0; i < len; ++i) s += a[i] * b[i];
  return C_flonum(ptr, s);
}
```

bound the way `srfi-4.scm:270` already binds `C_a_i_f64vector_ref`:

```scheme
(define (f64vector-dot x y n)
  (##core#inline_allocate ("C_a_i_f64vector_dot" 4) x y n))
```

(The `4` is `words-per-flonum`, `c-platform.scm:84`.) The `C_block_item(v,1)` /
`C_data_pointer` field access is correct as written — compare `chicken.h:1657`.
In-place kernels return no flonum and can use plain `##core#inline`; only the
reductions need the allocating form, and they need a documented reassociation
policy (pairwise or Kahan) rather than relying on `-ffast-math`.

(C0) also moves this item's target. The baseline a bulk kernel now has to beat is
no longer a CPS call per element but an inlined, unboxed loop: 1041 ms for a
200M-element dot product at `-O3 -unsafe`, against 213 ms for the hand-written C
that a `C_a_i_f64vector_dot` would essentially *be* (§10.1 B). So the kernel is
still worth roughly 4.9× on reductions — but it is now a 4.9× over working
inlined code, not a 34× over a symbol-table call, and the elementwise kernels
(`fill!`, `scale!`, `axpy!`) claim their win mainly through vectorization that
CHICKEN cannot reach at all: clang auto-vectorizes `scale` to 65 ms where the
best CHICKEN gets is 1803 ms.

---

## 10. How to actually verify any of this

The tree **is** built: `chicken`, `csi`, `csc` and `libchicken.so` sit at the
tree root and report `6.0.1pre1 (rev d6442142)`,
`linux-unix-clang-x86-64 [ 64bit dload ptables ]`. (Note that `chicken -version`
prints this woven through an ASCII-art banner in this tree; 6.0.0 printed it as
plain lines.) Because this is a git checkout you can also pin the exact source
state with `git describe --tags`, which gives `6.0.1pre1-68-gd6442142`. Step 1 below is therefore
already done, and §10.1 holds real numbers for the items tagged **[measured]**
in §9. The items tagged **[proposal]** are still arguments from source.

1. **Rebuilding.** The top-level `Makefile` is only a stub that errors out for
   non-GNU make; `GNUmakefile` is the real one, and it includes `config.make`,
   which this tree already has (`PLATFORM = linux`, `C_COMPILER = clang`). So a
   bare `make` rebuilds. CHICKEN 6 replaced the bare `make PLATFORM=…` workflow
   with a `configure` script (`NEWS:181`, `README:70`), though the old form still
   works.

   The ordinary build does **not** bootstrap through `chicken-boot`: a
   distribution build compiles the pre-generated `.c` files that ship in the tree
   (`rules.make:66-67`). A boot compiler is needed only when building from git
   sources, and then it is an explicit separate step
   (`./configure --chicken <path>` then `make boot-chicken`,
   `rules.make:1044-1049`). Changing a compiler `.scm` does mean regenerating and
   recompiling every `.c`, so keeping a known-good compiler around is still good
   advice.

   **Optimization level is a make variable, not a `configure` flag:**

   | invocation | C flags used |
   |---|---|
   | `make` (default) | `-Os -fomit-frame-pointer` |
   | `make OPTIMIZE_FOR_SPEED=1` | `-O3 -fomit-frame-pointer` |
   | `make DEBUGBUILD=1` | `-g -Wall -Wno-unused -O0 -Wno-cpp` |

   **This tree was built at `-Os`** (`chicken-defaults.h:15`); the
   `/* (this build was optimized for speed) */` marker that `OPTIMIZE_FOR_SPEED`
   emits is absent. That settles (B1).

2. **Look at the C.** `chicken foo.scm -output-file foo.c` and read it. Note that
   `chicken` itself does not accept `-O3` (`Warning: invalid compiler option
   (ignored)`); that is a `csc` spelling which `csc` rewrites to
   `-optimize-level 3`.

   Add `-debug o` to see the optimizer's decisions. The messages worth watching,
   with their real source strings:

   | message | emitted at | meaning |
   |---|---|---|
   | `direct leaf routine/allocation`, `… with hoistable closures/allocation` | optimizer.scm:1639-1640 | a procedure became a direct (non-CPS) C function |
   | `number of unboxed float variables`, `number of inline operations replaced with unboxed ones` | lfa2.scm:607, 609 | flonum unboxing (§9.2 C1) |
   | `customizable procedures` | core.scm:3068 | closures whose calling convention can be specialized |
   | `calls to known targets` | core.scm:3082 | call sites that became direct C calls |
   | `identified direct recursive calls` | core.scm:3274 | self-calls the backend can turn into a C loop |
   | `fast box initializations` / `fast global references` / `fast global assignments` | core.scm:3458/3460/3462 | avoided runtime checks |

   Two caveats. `direct leaf routine` alone is never printed — only the two
   longer forms — and a toy example usually inlines the candidate away before the
   leaf pass sees it. And the unboxing counters require `lfa2`, which is only
   added from `-optimize-level 2` upward, so on a default compile the line never
   appears at all.

3. **Look at the passes.** `-debug 3` prints the CPS node tree, `-debug 7` the
   optimized tree, `-debug 9` the closure-converted tree. `-debug b` prints the
   per-pass timing breakdown used in §9.4; `-debug n` dumps the line-number
   database.

4. **Measure GC separately from mutator.** These are *runtime* options, parsed by
   `CHICKEN_parse_command_line` (`runtime.c:1352`); parsing stops at the first
   argument that is not `-:...`. Run `<program> -:?` for the built-in list
   (`runtime.c:1375-1405`).

   | option | effect |
   |---|---|
   | `-:g` | show GC information — per-collection `level`, `gcs(minor)`, `gcs(major)`, space bounds, heap resizes. **This is the collection-count report — and it prints only *major* GCs.** |
   | `-:d` | debug output — startup/shutdown trace, `heap resized`, one `entering <unit>` per unit. *Not* GC accounting. |
   | `-:hSIZE` | fixed heap size (`-:hi` initial, `-:hm` maximal, `-:hg`/`-:hs` growth/shrink percentages). Bare `-:h` also sets `C_heap_size_is_fixed`, turning heap exhaustion into a panic — use `-:hi` to set the initial size without pinning it. |
   | `-:sSIZE` | nursery (stack) size — the minor-GC knob, and hard-capped by `RLIMIT_STACK` (§9.3 R2) |
   | `-:RSEED` | seed `rand()` deterministically — "helpful for benchmark stability" |
   | `-:p` / `-:PFREQ` | statistical profile, written at exit; read with `chicken-profile` |
   | `-:aSIZE`, `-:tSIZE` | trace-buffer and symbol-table sizes |

   `SIZE` accepts `k`/`m`/`g` suffixes.

5. **Benchmarks.** `tests/` is primarily the *correctness* suite (156 files,
   driven by `runtests.sh` / `make check`). The benchmarks are a separate fixed
   set of nine driven by `tests/runbench.sh` / `make bench` — and there is no
   string benchmark among them. For SIMD work specifically, the honest comparison
   is against a hand-written C loop doing the same thing; that gap is the real
   headroom, and §10.1 B measures it.

### 10.1 What it actually costs (measured)

Machine: Intel Xeon Gold 6238R @ 2.20 GHz, Linux 6.8.0-137. Compiler under test: `chicken-core` master at `d6442142`
(`git describe`: 6.0.1pre1-68-gd6442142), clang 18.1.3. **This tree is built
with `OPTIMIZE_FOR_SPEED`**, so its `C_INSTALL_CFLAGS` ends `-O3
-fomit-frame-pointer` and `chicken-defaults.h` carries the
`/* (this build was optimized for speed) */` marker — unlike the 6.0.0 tree the
earlier revision of these notes was measured on, which was a stock `-Os` build
(§9.1 B1). `Makefile.linux` is byte-identical between the two trees; the
difference is the make invocation, not the source. Both compilers link the
byte-identical
`libchicken.so` from that tree, which was built by the *unpatched* compiler
(`make chicken` only), so every difference below is the compiler patch alone.
Ratios are not comparable with the 6.0.0 measurements: master's runtime differs
from 6.0.0's by −13% to +23% on the minor-GC path these kernels stress. Wall-clock milliseconds, best of 5 whole-process runs;
spread under 5%. Process startup (~8 ms) is included everywhere.

#### A. The `goto loop` shape (§5.3) is within 2.3× of C

2×10⁹ iterations of `acc ← acc xor (i·3)` in fixnums:

| | ms | vs C |
|---|---:|---:|
| CHICKEN 6.0.0, `csc -O3` | 902 | 2.34× |
| hand-written C, `clang -O3` | 385 | 1.00× |

Both print the same answer. The remaining 2.3× is fixnum tagging plus the loss of
vectorization.

#### B. f64vector loops (§9.2 C0/C1a/C1b) — before and after the fix

Four kernels over `f64vector`s, 200M element-operations each (n = 200 000 × 1000
reps; 3.2 MB working set, so cache-resident and *not* bandwidth-bound). "old" is
the pristine compiler, "new" is the patched one; both link the same
`libchicken.so`. CPU milliseconds via `current-process-milliseconds`, **median of
5**; every spread is ≤ 7.4%. Numeric results are identical in all 16 CHICKEN
cells and match the C reference exactly.

| | dot | axpy! | sum | scale! |
|---|---:|---:|---:|---:|
| old, `-O3` (safe) | 10549 | 13623 | 6950 | 9622 |
| **new, `-O3` (safe)** | **5425** | **5594** | **4821** | **4965** |
| *win* | *1.94×* | *2.44×* | *1.44×* | *1.94×* |
| old, `-O3 -unsafe` | 7254 | 9652 | 4124 | 6550 |
| **new, `-O3 -unsafe`** | **1238** | **1731** | **1222** | **1962** |
| *win* | *5.86×* | *5.58×* | *3.37×* | *3.34×* |
| hand-written C, `clang -O3` | 216 | 124 | 216 | 60 |
| *new `-unsafe` vs C* | *5.7×* | *14.0×* | *5.7×* | *32.7×* |

(The earlier `-ffast-math` figures for dot and axpy — 125 and 123 ms — are
unaffected by the patch and are omitted only to keep the table narrow.)

What the emitted C shows, which is the mechanism behind every row:

| unit | `C_ub_i_..._ref` | `C_a_i_..._ref` | `C_i_..._set` | `C_u_i_..._set` | out-of-line `chicken.number-vector#` |
|---|---:|---:|---:|---:|---|
| old, any level | 0 | 0 | 0 | 0 | every ref, every set!, `make-f64vector` |
| new, `-O3` safe | 0 | 1–3 | 1–2 | 0 | `make-f64vector` only |
| new, `-O3 -unsafe` | 1–3 | 0 | 1–2 | **0** | `make-f64vector` only |

Three readings:

* **The old compiler emits zero inlines at any optimization level.** That is (C0)
  in its purest form.
* **`C_u_i_f64vector_set` is absent from every new unit, including at `-unsafe`.**
  That is (C0a) in force. It is also where the safe/unsafe asymmetry in the axpy
  column comes from: the store is checked in both modes now.
* **`C_a_u_i_f64vector_ref` never appears.** At `-unsafe` the unboxing pass goes
  straight past the allocating unsafe ref to `C_ub_i_f64vector_ref`, which
  returns a raw `double`. That, not inlining alone, is where the 4–7× unsafe-mode
  win comes from.

Two separate gaps remain, and they are not the same size:

* **The gap the fix closed** is 1.4–2.4× in safe mode and 3.3–5.9× at `-unsafe`.
* **The gap to hand-written C is 5.7× on the reductions** (`dot`, `sum`) and
  14.0×/32.7× on the elementwise kernels. The reduction figure is the honest
  like-for-like number: clang does not vectorize a serial FP reduction either, so
  that 4.9× is pure boxing and trampoline overhead, and it is what (C1a) and
  (C1b) are aimed at. The elementwise figures include SIMD that CHICKEN has no
  way to reach, which is what (S4) is aimed at.

An older revision of this table reported an `axpy` figure of 907 ms for the
"fixed" configuration, obtained with a `(declare (extended-bindings …))`
workaround. That number was measured with the unchecked store that (C0a) had to
delete; the honest figure for the shipping compiler is 2107 ms. See §10.1 H.

#### C. Allocation and nursery size (§9.3 R2)

100M `cons`es, `ulimit -s unlimited`. "long-lived" builds 100 000-element lists
(pairs survive minor collections); "short-lived" builds 1000-element lists
(nothing survives).

| nursery | long-lived (ms) | major GCs | minor GCs | short-lived (ms) |
|---|---:|---:|---:|---:|
| `-:s1m` (default) | 1767 | 200 | 2848 | 691 |
| `-:s8m` | **970** | 58 | 322 | **681** |
| `-:s64m` | 1189 | 1 | – | 832 |
| `-:s256m` | 1263 | 1 | – | – |

1.82× from 1 MB → 8 MB when there are survivors, non-monotonic beyond that, and
under 2% when there are none. With Linux's default `ulimit -s 8192`, `-:s8m` and
larger die with a bare `Segmentation fault` (`-:s7m` is fine).

A benchmarking trap: clang hoists CHICKEN's fixed-size `C_alloc` and deletes
allocations whose result never escapes the iteration. A "discard every pair"
microbenchmark compiles to a loop with no `alloca` at all and zero GCs.

#### D. UTF-8 `string-ref` (§9.5 S1)

`string-ref` in a loop over a 100 000-character string:

| access pattern | ASCII | all U+03BB (2-byte) |
|---|---:|---:|
| sequential, 10M refs | 110 ms | 178 ms |
| strided by 4099 | 12.7 ns/ref | 26.0 µs/ref |

Sequential non-ASCII costs only **1.6×** (the memoised cursor); non-sequential
non-ASCII costs about **2000×**. A string that is ASCII except for a *single*
non-ASCII character anywhere is as slow as a fully non-ASCII one — the
`len == codepoints` fast path is all-or-nothing.

#### E. The counting kernel: optimization level first, SWAR second

200 passes over 1 MB. "scalar" is `C_utf_fast_count` verbatim from `utf.c:3537`;
"SWAR" is an 8-byte-word version using
`popcount(w & 0x8080… & ((~w & 0x4040…) << 1))`.

| clang flags | scalar (ms) | SWAR (ms) | SWAR / scalar |
|---|---:|---:|---:|
| `-O0` | 297.2 | 105.7 | 2.8× |
| `-Os` *(what `libchicken.so` ships)* | 177.0 | 47.5 | 3.7× |
| `-O2` | 34.6 | 23.5 | 1.5× |
| `-O3` | 31.7 | 22.4 | 1.4× |
| `-O3 -march=native` | 18.9 | 7.2 | 2.6× |

`objdump -d libchicken.so --disassemble=C_utf_fast_count` confirms the shipped
code is a scalar loop. Recompiling the *unchanged* source at `-O2` is **5.1×**;
SWAR at `-O3 -march=native` is 24.6× over the shipped build. Most of the "SIMD"
win here is really a build-flag win.

#### F. B1: the same generated `.c` at different `-O` levels

Each benchmark's `chicken`-generated `.c` compiled by hand and linked against the
same `libchicken.so`:

| benchmark | `-O0` | `-O1` | `-Os` | `-O2` | `-O3` |
|---|---:|---:|---:|---:|---:|
| fixnum loop, 2×10⁹ | 7815 | 1056 | **907** | 1059 | 1033 |
| f64 dot, 200M ops | 2283 | 1045 | **1039** | 1074 | 1184 |
| f64 axpy, 200M ops | 2340 | 899 | 945 | **893** | 1009 |
| cons, 100M pairs | 2248 | 1782 | **1756** | 1779 | 1775 |
| `string-ref`, 10M ASCII | 139 | 120 | **115** | 119 | 122 |

`-O0` costs up to 8.6× on compute-bound code and only ~1.2× on runtime-bound code
(where the work happens inside the prebuilt `libchicken`). But **`-O3` buys
nothing over `-Os` for CHICKEN-generated C.** The level that matters is the one
`libchicken` itself was built with.

#### G. The distribution's own fft benchmark — and the price of (C0a)

`tests/fft.scm`, compiled the way `tests/runbench.sh` does
(`-O5 -d0 -disable-interrupts -b`). Wall-clock ms, median of 5.

| configuration | `2000 11` | `2000 14` |
|---|---:|---:|
| default build — `f64vector` aliased to Scheme `vector`, old | 1217 | 14239 |
| default build — same, **new** | 1226 | 14340 |
| `-D unboxed` — real `f64vector`s, old | 3431 | 31980 |
| `-D unboxed` — real `f64vector`s, **new** | **572** | **5206** |
| `-D unboxed`, unchecked store (the deleted (C0a) rule) — *unsound, reference only* | *177* | *1567* |

**The default rows are a control, and a strict one: the generated C is
byte-identical between the two compilers.** `fft.scm`'s `cond-expand` aliases
every `f64vector` operation to a plain `vector` operation in that configuration,
so no SRFI-4 rewrite is reachable and none fires. The sub-1% deltas are run-to-run
noise. Anything that moved in the unboxed rows is therefore the patch and nothing
else.

**The headline is an inversion.** Under the pristine compiler, using real
`f64vector`s made fft **2.25× slower** than using plain Scheme vectors (31980 vs
14239 at `2000 14`) — the specialized numeric type was a pessimization, because
every access became a CPS call while `vector-ref` inlined. Under the patched
compiler it is **2.75× faster** (5206 vs 14340), which is what the type was
always supposed to buy. Against unpatched master, `-D unboxed` improves 6.00× and
6.14×.
Output is identical in all four cells (verified with a checksummed variant built
with identical flags and run at finite iteration counts; stock `fft.scm` prints
nothing and its 2000-iteration runs overflow to NaN by design).

**The third row is the price of (C0a), and it is the largest single cost the
correctness patches carry.** It is the old `(declare (extended-bindings …))`
workaround, which made the *unsafe* setter rule fire. Its generated C and the
patched compiler's differ in exactly one thing: 40 occurrences of
`C_u_i_f64vector_set` versus 40 of `C_i_f64vector_set` (after normalizing the
filename and an off-by-one in line comments, `diff` on the two `.c` bodies is
empty). Both contain the same 50 `C_ub_i_f64vector_ref` and the same 4
`C_u_i_f64vector_length`. So on a kernel that stores as often as it loads, the
checked store costs **3.2×** — and the unchecked one segfaults on
`(f64vector-set! v 0 7)`. This is the measurement that makes the type-conditional
unsafe rewrite proposed in §9.2 worth building rather than merely worth
mentioning.

#### H. Correctness evidence for the (C0)/(C0a)/(C0b) patch

The patch changes what code the compiler emits for ten data types in two safety
modes, so it was gated on behaviour, not only on benchmarks.

**Full test suite.** `tests/runtests.sh`, run against symlink-farm roots so the
upstream tree was never written to. Both compilers exit 0, emit the same 81
section banners in the same order, reach `======================================== done. All tests passed.`,
and contain zero occurrences of `Segmentation` / `segfault` / `Aborted` /
`core dumped`. The suite runs under `set -e`, so reaching that identical final
banner is the pass proof. The 206 pass/fail report lines are **byte-identical**
between the two runs: **19003 assertions passed, 0 failed, on each side**. The
pass/fail delta is empty — no test passes with the old compiler and fails with
the new one.

**`tests/srfi-4-tests.scm`** — exit 0 at `-O2`, `-O3`, `-O4` and `-O5` under both
compilers, output byte-identical. It genuinely exercises the patch: under the new
compiler it compiles with 20+ inlined intrinsics, under the old one with only the
five already-correctly-spelled `C_u_i_*vector_length` entries. Under a
**patch-1-only** compiler it exits 70 with `Error: segmentation violation` at
`-O4` and `-O5` — which is how (C0a) was caught.

**Semantic differentials.** 7975 isolated program invocations across 6 builds,
each case in its own process so a crash is contained and its exit status
recorded. Every probe is polymorphic, per the lesson in §9.2.

| axis | shape | old vs new, safe `-O3` |
|---|---|---|
| operation × value-type matrix | 51 ops × 23 value types | **0 / 1173 differ** |
| index and value domain sweep | 20 ops × 12 indices, 10 setters × 25 values | **0 / 490 differ** |
| monomorphic (specialization path live) | 78 index/value configs | **0 / 2652 result lines differ** |
| non-zero exit codes | — | **0** |

At `-O5 -unsafe`, 1635 cells differ and **none of them is on a legal input**:
every one falls on a wrong-type argument, an out-of-range or non-fixnum index, or
an out-of-element-range value — undefined behaviour the `#f` rules explicitly
claim, and the same treatment pristine CHICKEN already gives `vector-ref` under
`-unsafe`. Zero differences on any type predicate, on any correct-type vector, on
any in-range fixnum index, or on any in-range value. `f32vector-set!` and
`f64vector-set!` do not appear in the unsafe diff for any of the 25 test values —
direct confirmation that (C0a) removed the divergence.

**Safe-mode error behaviour is unchanged.** Six cases (out-of-bounds ref,
out-of-bounds set!, negative index, non-fixnum index, wrong-type vector,
wrong-type value) × `-O2` and `-O3` × both compilers: all 12 pairs exit 70 with
byte-identical `Error:` lines and byte-identical culprit values. The one textual
difference is cosmetic and inherent to inlining — the new compiler's call history
loses the trailing frame naming the now-inlined intrinsic:

```
old:  … e_oob_ref.scm:5: g34
      e_oob_ref.scm:2: chicken.number-vector#f64vector-ref     <-- frame gone
new:  … e_oob_ref.scm:5: g34
```

**Positive controls.** The probe methodology was validated against both known
defects using a purpose-built patch-1-only compiler. It reproduces the `u8vector?`
segfault on fixnum, `'()`, `#t` and character, and both halves of the float-setter
bug (segfault on a fixnum value, `0.0` / `5.0153151251352e-310` on a bignum). The
same probes report clean on the patched compiler, so the negative result on the
other 67 rules is a real negative rather than a blind spot.

**What could not be verified.**

* Only `linux-unix-clang-x86-64`, 64-bit, clang 18.1.3. No 32-bit build, no other
  C compiler, no other platform. The `C_8ALIGN_BIT` paths of §2.2 are 32-bit-only
  and are untouched by any probe here.
* `c64vector` and `c128vector` element accessors have **no** rewrite rules at all,
  so they were exercised only through `->bytevector/shared`. Likewise
  `u8vector-ref`, `u64vector-ref` and `s64vector-ref`, which upstream simply does
  not rewrite (`u8vector-set!` is rewritten but `u8vector-ref` is not — see
  upstream item 7 in §9.2).
* Suite wall-clock time is not reported. The two suite runs shared the machine, so
  any figure would be meaningless; correctness, not speed, is what that run
  establishes.
* One log-only difference appeared in the normalized full-suite diff — the
  `apply-test.scm` section captured a call-history block in one run and not the
  other — and was chased to ground as *not* compiler-caused: the generated C for
  that file under the exact suite options is byte-identical between the two
  compilers (body md5 `f2e708d0297816433e53b800b07fbd1a`), the file contains no
  SRFI-4 identifier, both runs panic identically in the way the test intends, and
  12 interleaved reruns plus 25 loaded runs each showed zero disagreement. It is
  stdout-flush nondeterminism in a deliberately panicking process.

**One intended behaviour change worth a release note.** `-O4` and `-O5` cons
`'unsafe` onto the options unconditionally (`chicken.scm:121-132`, `:132-147`),
so now that the ref rewrites fire, bounds checking on SRFI-4 accessors is
genuinely gone at those levels: reading element 100 of a 4-element `f64vector`
raises `Error: out of range` under the old compiler at `-O5` and silently returns
garbage under the new one, and a negative index at `-O5 -unsafe` can end in
`[panic] unrecoverable segmentation violation`. `-O1` through `-O3` remain
checked. This is upstream-intended semantics that the spelling bug had been
accidentally masking — pristine CHICKEN already gives
`Error: segmentation violation` for `(vector-ref (vector 1 2 3 4) 9)` at
`-O5 -unsafe`. Code that was relying on the accidental safety should move to
`-O3`.

#### Reproducing these against an uninstalled tree

```sh
CH=/path/to/chicken-6.0.0
export LD_LIBRARY_PATH=$CH          # the binaries' RUNPATH points at the *installed*
                                    # prefix; without this you may measure a different
                                    # libchicken. Check with `ldd`.

# .c only
$CH/chicken foo.scm -output-file foo.c -optimize-level 3

# compile + link (the form tests/runbench.sh uses)
$CH/csc -compiler $CH/chicken -I$CH -L$CH -include-path $CH -O3 foo.scm -o foo

# hand-compile the generated .c at a chosen level, to reproduce table F
clang -O3 -fno-strict-aliasing -fwrapv -DHAVE_CHICKEN_CONFIG_H -DC_ENABLE_PTABLES \
      -I$CH -c foo.c -o foo.o
clang foo.o -o foo -L$CH -lchicken -lm -ldl

# nursery sweep (table C) — raise the rlimit first, or -:s8m and up segfault
( ulimit -s unlimited; ./foo -:s8m -:g ARGS )
```

`csc` deletes the intermediate `.c`; generate it separately if you want both the
executable and the C to read.

### A sensible order of attack

Ranked by measured payoff per unit of effort, not by technique.

**Done on this tree: (C0), the `+extended-bindings+` typo.** One missing `#` per
name, 76 names across 43 lines in two tables, disabled every SRFI-4 rewrite.
Fixed; measured at 1.4–2.4× safe and 3.3–5.9× at `-unsafe` on f64 kernels, and
6.0–6.1× on `tests/fft.scm -D unboxed`, with identical output everywhere and a
byte-identical-C control cell proving the attribution (§10.1 B, G). Repairing it
also exposed and fixed two latent upstream bugs — the unsound unsafe float
setters (C0a) and the safe-mode `u8vector?` segfault (C0b) — and left three items
in the queue below.

1. **(C0a′) a type-conditional unsafe float store** — the correctness fix for
   (C0a) costs 2.21× on an `axpy` kernel at `-O3 -unsafe` and **4.0× on
   `fft -D unboxed`** (§10.1 G), and the type information needed to make the fast
   store sound is already computed by the scrutinizer. Needs a rewrite class that
   can consult an argument's inferred type; a `types.db` specialization is the
   wrong vehicle (`scrutinizer.scm:545-554`). The largest measured item now
   outstanding, and it converges with (C1a).
2. **(P1) the line-number database** — quadratic canonicalization, a contained
   data-structure change in `expand.scm`, and the largest compile-time win.
3. **(B1) build the runtime with `OPTIMIZE_FOR_SPEED=1`** — the question is
   *answered* (the default is `-Os`, not `-O0`), and what remains actionable is
   the runtime's own `-O` level, which is where most of (S1)'s win lives. Settle
   `-mfma -ffp-contract=fast` here too, which subsumes **(B2)**; and settle the
   AVX2 runtime-dispatch strategy before writing any intrinsic.
4. **(R4) buffered `read-char`** — 4.5× available to users today by advice alone,
   ~20× against C for a change local to `library.scm`.
5. **(C0b′)/(C0c) an immediate-checking `C_i_bytevectorp`** — add
   `C_immediatep` guards to `C_i_bytevector_set` (`runtime.c:6087`) and
   `C_i_bytevector_ref` (`:5659`), mirroring `C_i_bytevector_length` (`:5937`).
   This fixes a live safe-mode segfault reachable with no compiler patch at all,
   and it lets `u8vector?` be inlined again (bounded at 7.15× on a pure-predicate
   loop). Small, local, and a genuine correctness fix rather than only a speed
   one.
6. **(R2) nursery sizing** — a real 1.82× on survivor-heavy allocation, one flag,
   but bounded, non-monotonic, and `RLIMIT_STACK`-capped.
7. **(C1a)** unboxed `f64vector-set!` — needs a new `+unboxed-map+` kind, not an
   `acc` entry; and it is the well-typed form of the rule (C0a) deleted, so it
   subsumes much of item 1.
8. **(S4)** SRFI-4 elementwise kernels via `##core#inline_allocate`; reductions
   separately, with an explicit reassociation policy. Its target moved with (C0):
   4.9× over inlined code, not 34× over a symbol-table call.
9. **(S1)** UTF-8 scanning, aimed at `C_utf_count` and `utf_index1` — and as a
   portable SWAR rewrite first, since most of the win is the `-O` level.
10. **(C1b)** loop-carried float unboxing — largest compiler-side payoff, most
    invasive, blocked behind (C1a) and the GC trampoline's inability to save a
    `double`. Now quantified: it is the whole of the remaining 4.9× on reductions.
11. **(S2)** wide-multiply bignums; **(S3)+(R1)** GC scan and pair copy, which are
    one change seen from two sides.

Deliberately not queued: **(S5)**, **(S6)**, **(R3)** and **(C3)** — (C3) is
subsumed by (C1), and the other three are low-payoff or aimed at procedures that
do not exist in this tree. Also not queued, but worth an upstream report:
`c-platform.scm:197` names a nonexistent `f128vector?` where it means
`c128vector?`, and three `->bytevector/shared` rewrites are dead for want of an
`+extended-bindings+` entry (§9.2, upstream items 6 and 7).

---

## Appendix: file map

| File | Role |
|---|---|
| `chicken.h` | Object representation, allocation macros, ~700 `C_*` inline primitives |
| `runtime.c` | GC, trampoline, numeric tower, symbol tables, I/O, process control |
| `utf.c` | UTF-8 codec, Unicode case/property tables |
| `core.scm` | Canonicalization, CPS conversion, analysis, closure conversion, preparation |
| `optimizer.scm` | Inlining, contraction, rewriting, direct-lambda/leaf transform |
| `lfa2.scm` | Secondary flow analysis; flonum unboxing |
| `scrutinizer.scm` | Type checking and specialization |
| `c-backend.scm` | C code generation |
| `c-platform.scm` | Rewrite rules and intrinsic tables mapping Scheme ops to `C_*` |
| `batch-driver.scm` | Pass sequencing, command-line handling |
| `support.scm` | Node representation, the analysis database, utilities |
| `library.scm` | The Scheme-level core library, including the port layer |
| `expand.scm`, `modules.scm`, `synrules.scm` | Macro expander, module system, `syntax-rules` |
| `eval.scm` | The interpreter — a separate execution path this document does not cover |
| `srfi-4.scm` | Homogeneous numeric vectors (`chicken.number-vector`) |
| `r7lib.scm` | R7RS library support |
| `data-structures.scm` | `chicken.string`, `substring-index`, sorting |
| `irregex-core.scm` | Regular expressions |
| `scheduler.scm` | Green threads, built on the interrupt mechanism |
| `egg-compile.scm`, `chicken-install.scm` | The egg build and package system |
| `types.db` | Type signatures consumed by the scrutinizer |
| `dbg-stub.c` | Lowlevel client-side C for the debugger; one of only four hand-written `.c` files at the tree root (with `runtime.c`, `utf.c`, `chicken-do.c`) |

Every other `.c` at the tree root is generated — each begins
`/* Generated from <name>.scm by the CHICKEN compiler`.
