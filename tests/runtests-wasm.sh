#!/bin/sh
# runtests-wasm.sh - run the CHICKEN test suite against the WebAssembly build
#
# Copyright (c) 2026, The CHICKEN Team
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following
# conditions are met:
#
#   Redistributions of source code must retain the above copyright notice, this list of conditions and the following
#     disclaimer.
#   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
#     disclaimer in the documentation and/or other materials provided with the distribution.
#   Neither the name of the author nor the names of its contributors may be used to endorse or promote
#     products derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
# Run from an empty scratch directory (make wasm-check uses
# build-wasm/tests-run).  The source tests directory is copied to ./tests
# and the tests run there, with the same relative file names as in
# runtests.sh; nothing is written to the source tree.  The runtests.sh
# line each test mirrors is given as "rt:LINE".
#
# Lanes:
#   A  interpreted with the wasm csi
#   B  interpreted, after the wasm chicken emitted an import library
#   C  the wasm chicken as a compiler (nursery stress, messages,
#      differential test against the host chicken)
#   D  compiled with the SDK's csc-wasm and run under node
#
# Environment:
#   WASM_DIR     directory holding the node wrappers (build-wasm/node)
#   TEST_DIR     the source tests directory (read only)
#   WASM_SDK     the staged SDK prefix (build-wasm/stage/chicken); lane D
#   HOSTCHICKEN  command running the host chicken; lane C differential
#   WASM_LANES   lanes to run (default "A B C D")
#
# Every test must succeed (or fail, where that is expected) without any
# engine-level failure (RangeError, RuntimeError, Aborted) in its output.

set -e

: "${WASM_DIR:?WASM_DIR must name the directory with the node wrappers}"
: "${TEST_DIR:?TEST_DIR must name the source tests directory}"
WASM_DIR=$(cd "$WASM_DIR" && pwd)
TEST_DIR=$(cd "$TEST_DIR" && pwd)
SRC_DIR=$(cd "$TEST_DIR/.." && pwd)
if test -n "$WASM_SDK"; then WASM_SDK=$(cd "$WASM_SDK" && pwd); fi
NODE=${NODE:-node}
WASM_LANES=${WASM_LANES:-A B C D}
DIFF_OPTS=-bu

# The repository the node wrappers use by default: the staged import
# libraries and types.db.
unset CHICKEN_REPOSITORY_PATH
WASM_REPO=$("$WASM_DIR/csi" -n -e '(import (chicken platform)) (display (car (repository-path)))')
WASM_REPO=$(cd "$WASM_REPO" && pwd)
CHICKEN_REPOSITORY_PATH=$WASM_REPO
export CHICKEN_REPOSITORY_PATH

interpret="timeout 600 $WASM_DIR/csi -n -include-path $SRC_DIR"
wchicken="timeout 600 $WASM_DIR/chicken"
engine_errors='RangeError|RuntimeError|Aborted\('

# Some tests look at "../tests" and copy "../csi", as in the source tree.
rm -rf tests csi
mkdir tests
cp -R "$TEST_DIR"/. tests/
cp "$WASM_DIR/csi.wasm" csi
cd tests
# as runtests.sh does before starting (rt:63), in case the source tree
# holds artefacts of a host test run
rm -fr *.exe *.so *.o *.out *.import.* a.out test-repository

failures=
total_pass=0
total_fail=0
total_skip=0

lane_begin() {
    lane=$1; pass=0; fail=0; skip=0
    echo "======================================== lane $lane: $2"
}

lane_end() {
    echo "---- lane $lane: $pass passed, $fail failed, $skip skipped"
    total_pass=$((total_pass + pass))
    total_fail=$((total_fail + fail))
    total_skip=$((total_skip + skip))
    eval "result_$lane=\"$pass passed, $fail failed, $skip skipped\""
}

log_name() {
    echo "$1" | tr -c 'A-Za-z0-9_.\n-' '_'
}

ok() {
    pass=$((pass + 1))
    echo "ok   [$lane] $1"
}

bad() {
    fail=$((fail + 1))
    failures="$failures
  [$lane] $1: $2"
    echo "FAIL [$lane] $1: $2"
    if test -s "$3"; then tail -25 "$3" | sed 's/^/  | /'; fi
}

skip() {
    skip=$((skip + 1))
    echo "skip [$lane] $1: $2"
}

# check NAME COMMAND ...: COMMAND must succeed; its output goes to
# NAME.wasm.out
check() {
    name=$1; shift
    log=$(log_name "$name").wasm.out
    if "$@" >"$log" 2>&1; then status=0; else status=$?; fi
    if grep -Eq "$engine_errors" "$log"; then
	bad "$name" "engine error (status $status)" "$log"
    elif test $status -ne 0; then
	bad "$name" "exit status $status" "$log"
    else
	ok "$name"
    fi
}

# check_fail NAME REGEX COMMAND ...: COMMAND must fail with REGEX in
# its output, but not in the engine, by a timeout or by a signal
check_fail() {
    name=$1; regex=$2; shift 2
    log=$(log_name "$name").wasm.out
    if "$@" >"$log" 2>&1; then status=0; else status=$?; fi
    if grep -Eq "$engine_errors" "$log"; then
	bad "$name" "engine error (status $status)" "$log"
    elif test $status -eq 0; then
	bad "$name" "succeeded, but should have failed" "$log"
    elif test $status -eq 124 || test $status -ge 128; then
	bad "$name" "timed out or killed (status $status)" "$log"
    elif ! grep -Eq "$regex" "$log"; then
	bad "$name" "failed (status $status) without '$regex'" "$log"
    else
	ok "$name"
    fi
}

# check_diff NAME EXPECTED COMMAND ...: COMMAND must succeed and its
# standard output must match the file EXPECTED
check_diff() {
    name=$1; expected=$2; shift 2
    base=$(log_name "$name")
    log=$base.wasm.out
    if "$@" >"$log" 2>"$base.wasm.err"; then status=0; else status=$?; fi
    if grep -Eq "$engine_errors" "$log" "$base.wasm.err"; then
	bad "$name" "engine error (status $status)" "$base.wasm.err"
    elif test $status -ne 0; then
	bad "$name" "exit status $status" "$base.wasm.err"
    elif ! diff $DIFF_OPTS "$expected" "$log" >"$base.wasm.diff"; then
	bad "$name" "output differs from $expected" "$base.wasm.diff"
    else
	ok "$name"
    fi
}

want() {
    case " $WASM_LANES " in *" $1 "*) return 0 ;; esac
    return 1
}

# the import libraries lanes B and D need, made by the wasm chicken
# (runtests.sh makes them with csc -s/-J, which also builds a .so)
emit_import_libraries() {
    $wchicken reexport-m1.scm -emit-all-import-libraries -output-file reexport-m1.wasm.c &&
    $wchicken square-functor.scm -emit-all-import-libraries -output-file square-functor.wasm.c &&
    $wchicken import-library-test1.scm -emit-import-library foo \
	-output-file import-library-test1.wasm.c
}


### Lane A: interpreted

if want A; then
lane_begin A "interpreted (wasm csi)"

# rt:67-75: the wrapper's default repository, i.e. the staged one
repository_path_default() {
    (unset CHICKEN_REPOSITORY_PATH; $interpret -s repository-path-default.scm)
}
check repository-path-default repository_path_default
skip repository-path "needs sample-module.so in a test repository (rt:76-79); no dynamic loading"
check types-db-consistency $interpret -s types-db-consistency.scm "$WASM_REPO/types.db"
skip csc-tests "needs csc and a C compiler for the target (rt:99)"
check apply-test $interpret -s apply-test.scm
check library-tests $interpret -s library-tests.scm
check records-and-setters-test $interpret -s records-and-setters-test.scm
check record-printer-test $interpret -s record-printer-test.scm
check unicode-tests $interpret -s unicode-tests.scm
check invalid-utf-test $interpret -s invalid-utf-test.scm
check file-encoding-test $interpret -s file-encoding-test.scm
check reader-tests $interpret -s reader-tests.scm
check_diff dwindtst dwindtst.expected $interpret -s dwindtst.scm
check delimited-continuation-tests $interpret -s delimited-continuation-tests.scm
check lolevel-tests $interpret -s lolevel-tests.scm

# rt:262.  A fatal gate: wasm32 compares against arithmetic-test.32.expected.
check arithmetic-test $interpret -D check -s arithmetic-test.scm
if test $status -ne 0; then
    echo "runtests-wasm: arithmetic-test failed, which is fatal"
    exit 1
fi

check pp-test $interpret -s pp-test.scm
check environment-tests $interpret -s environment-tests.scm
check syntax-tests $interpret -s syntax-tests.scm
check meta-syntax-test $interpret -bnq meta-syntax-test.scm -e '(import foo)' \
    -e '(assert (equal? (quote ((1))) (bar 1 2)))' -e '(assert (equal? (quote (list 1 2 3)) (listify)))' \
    -e '(import test-import-syntax-for-syntax)' -e '(assert (equal? (quote (1)) (test)))' \
    -e '(import test-begin-for-syntax)' -e '(assert (equal? (quote (1)) (test)))'
skip "meta-syntax-test (foo.import.so)" "needs the compiled import library foo.import.so (rt:283-285); no dynamic loading"
check reexport-tests $interpret -bnq reexport-tests.scm
check simple-functors-test $interpret -bnq simple-functors-test.scm
check functor-tests $interpret -bnq functor-tests.scm
check import-tests $interpret -bnq import-tests.scm
check test-optional $interpret -s test-optional.scm
check matchable $interpret matchable.scm -s match-test.scm
check loopy-test $interpret -s loopy-test.scm

# rt:352-357: r4rstest is not in the plan's list, but costs nothing
r4rstest() {
    $interpret -e '(set! ##sys#procedure->string (constantly "#<procedure>"))' \
	-i -s r4rstest.scm
}
check_diff r4rstest r4rstest.expected r4rstest

# rt:359-361.  runtests.sh says "expect two failures", but the host csi
# passes all 22 cases today; the wasm csi must match the host exactly.
r5rs_pitfalls() {
    $interpret -i -s r5rs_pitfalls.scm >r5rs_pitfalls.wasm.txt || return 1
    passed=$(grep -c '^Passed: ' r5rs_pitfalls.wasm.txt || true)
    failed=$(grep -c '^Failure: ' r5rs_pitfalls.wasm.txt || true)
    echo "r5rs_pitfalls: $passed passed, $failed failed (expected 22 and 0)"
    grep '^Failure: ' r5rs_pitfalls.wasm.txt || true
    test "$passed" -eq 22 && test "$failed" -eq 0
}
check r5rs_pitfalls r5rs_pitfalls

check r7rs-tests $interpret -s r7rs-tests.scm
check r7rs-tests-2 $interpret -s r7rs-tests-2.scm
check r7rs-library-tests $interpret -s r7rs-library-tests.scm
check life $interpret -s life.scm
check module-tests $interpret -include-path "$SRC_DIR" -s module-tests.scm
check module-tests-2 $interpret -include-path "$SRC_DIR" -s module-tests-2.scm
check test-chained-modules $interpret -bnq test-chained-modules.scm
skip "test-chained-modules.so" "needs test-chained-modules.so and m3.import.so (rt:390-393); no dynamic loading"
check ec $interpret -bqn ec.scm ec-tests.scm
skip "ec.so" "needs ec.so and ec.import.so (rt:398-400); no dynamic loading"
skip port-tests "runs a subprocess and pipes (rt:411); process creation is not available"
check read-lines-tests $interpret -s read-lines-tests.scm
check random-tests $interpret -s random-tests.scm
check numbers-string-conversion-tests $interpret -s numbers-string-conversion-tests.scm
check numbers-test $interpret -s numbers-test.scm
check numbers-test-ashinn $interpret -s numbers-test-ashinn.scm
check numbers-test-gauche $interpret -s numbers-test-gauche.scm
check bignum-division-test $interpret -s bignum-division-test.scm
check srfi-4-tests $interpret -s srfi-4-tests.scm
check bytevector-guard-tests $interpret -s bytevector-guard-tests.scm
check utf-compare-tests $interpret -s utf-compare-tests.scm
check utf-string-set-tests $interpret -s utf-string-set-tests.scm
check condition-tests $interpret -s condition-tests.scm
check data-structures-tests $interpret -s data-structures-tests.scm
check path-tests $interpret -bnq path-tests.scm
check srfi-45-tests $interpret -s srfi-45-tests.scm
check file-access-tests $interpret -s file-access-tests.scm
check test-copy-file $interpret -s test-copy-file.scm
check test-find-files $interpret -bnq test-find-files.scm
check test-create-temporary-file $interpret -bnq test-create-temporary-file.scm
check record-rename-test $interpret -bnq record-rename-test.scm
check test-irregex $interpret -bnq test-irregex.scm
check test-glob $interpret -bnq test-glob.scm
check test-finalizers $interpret -s test-finalizers.scm
check syntax-rule-stress-test $interpret -bnq syntax-rule-stress-test.scm
check multiple-values $interpret -s multiple-values.scm
check version-module-tests $interpret -bnq version-module-tests.scm

lane_end
fi


### Lane B: interpreted, with import libraries emitted by the wasm chicken

if want B; then
lane_begin B "import libraries from the wasm chicken"

rm -f reexport-m*.import* foo.import.* square-functor.import.* sf1.import.* sf2.import.*
check "emit import libraries" emit_import_libraries
check reexport-m2 $interpret -s reexport-m2.scm
check use-square-functor $interpret -bnq use-square-functor.scm
skip "use-square-functor (require-library)" "loads use-square-functor.so (rt:320-321); no dynamic loading"
check import-library-test2 $interpret -s import-library-test2.scm
skip "import-library-test2 (foo.import.so)" "needs foo.import.so (rt:335-336); no dynamic loading"

lane_end
fi


### Lane C: the wasm chicken as a compiler

if want C; then
lane_begin C "wasm chicken"

# rt:503-507.  Runtime options must come first: runtests.sh passes
# -:s after the file name, where the runtime never sees it.  300000
# instead of 500000: the wasm runtime refuses a nursery over 320k.
for s in 100000 250000 300000; do
    check "nursery stress -:s$s" $wchicken -:s$s -ignore-repository "$SRC_DIR/port.scm" \
	-output-file tmp.wasm.c -include-path "$SRC_DIR"
done

# rt:108-110
messages_test() {
    $wchicken messages-test.scm -consult-types-file "$WASM_REPO/types.db" \
	-ignore-repository -analyze-only 2>messages.wasm.txt &&
    diff $DIFF_OPTS messages.expected messages.wasm.txt
}
check messages-test messages_test

# The generated C must not depend on the compiler's platform.  First
# make sure the host output does not depend on the symbol table's hash
# seed, then compare the host and the wasm output bodies (the header
# holds the version and date).
translate() {		# translate CHICKEN SEED OUTPUT
    $1 -:R$2 "$SRC_DIR/port.scm" -ignore-repository -include-path "$SRC_DIR" \
	-output-file "$3.full" &&
    sed '1,/^#include/d' "$3.full" >"$3"
}
if test -z "$HOSTCHICKEN"; then
    skip differential "HOSTCHICKEN is not set"
else
    host_deterministic() {
	translate "$HOSTCHICKEN" 1 port-host-1.wasm.c &&
	translate "$HOSTCHICKEN" 2 port-host-2.wasm.c &&
	cmp port-host-1.wasm.c port-host-2.wasm.c
    }
    differential() {
	translate "$wchicken" 1 port-wasm-1.wasm.c &&
	diff $DIFF_OPTS port-host-1.wasm.c port-wasm-1.wasm.c
    }
    check "host determinism (-:R1 vs -:R2)" host_deterministic
    if test $status -eq 0; then
	check "differential (host vs wasm chicken)" differential
    else
	skip "differential (host vs wasm chicken)" "the host output depends on the hash seed"
    fi
fi

lane_end
fi


### Lane D: compiled with csc-wasm, run under node

if want D; then
lane_begin D "compiled (csc-wasm, node)"

if test -z "$WASM_SDK"; then
    skip "lane D" "WASM_SDK is not set"
else
compile="timeout 600 $WASM_SDK/bin/csc-wasm -node -o a.js -types $WASM_REPO/types.db -ignore-repository -include-path $SRC_DIR"
run="timeout 600 $NODE a.js"

# cr NAME [CSC-OPTION ...] FILE: compile and run a.js
cr() {
    name=$1; shift
    rm -f a.js a.wasm
    check "$name" sh -c "$compile $* && $run"
}

cr version-tests version-tests.scm
cr compiler-tests compiler-tests.scm
cr ffi-tests ffi-tests.scm
cr "ffi-tests-2 -d3" -d3 ffi-tests-2.scm

# rt:102 uses $compile_r (no -ignore-repository): chicken.foreign is only
# found in the repository.  The native test loads inline-me.so when
# inlining-tests imports it; statically, the unit is linked instead.
inline_me() {
    $WASM_SDK/bin/csc-wasm -c -unit inline-me -J -oi inline-me.inline inline-me.scm \
	-o inline-me.o
}
check "inline-me (-oi)" inline_me
cr "inlining-tests -O3" inlining-tests.scm -optimize-level 3 -uses inline-me inline-me.o
cr "inline-unroll -O3" inline-unroll.scm -optimize-level 3
cr "rest-arg-tests -specialize" rest-arg-tests.scm -specialize

profiler() {
    rm -f TEST.profile
    $compile null.scm -profile -profile-name TEST.profile && $run &&
    $WASM_DIR/chicken-profile TEST.profile
}
check "profiler + chicken-profile" profiler

cr "typematch-tests -specialize" typematch-tests.scm -specialize -no-warnings
cr "scrutiny-tests-3 -specialize -block" scrutiny-tests-3.scm -specialize -block
cr "scrutiny-tests-strict" scrutiny-tests-strict.scm -strict-types -specialize

line_numbers() {
    $compile -O3 test-line-numbers.scm 2>test-line-numbers.wasm.txt &&
    diff $DIFF_OPTS test-line-numbers.expected test-line-numbers.wasm.txt && $run
}
check "test-line-numbers -O3" line_numbers

specialization() {
    rm -f foo.types foo.import.*
    $compile specialization-test-1.scm -emit-types-file foo.types -specialize \
	-debug ox -emit-import-library foo && $run &&
    $compile specialization-test-2.scm -types foo.types -types specialization-test-2.types \
	-specialize -debug ox && $run
    s=$?; rm -f foo.types foo.import.*; return $s
}
check specialization specialization

fft() {
    $compile fft.scm -O2 -local -d0 -disable-interrupts -b && $run 1000 7 &&
    $compile fft.scm -O4 -debug x -d0 -disable-interrupts -b && $run 1000 7
}
check "fft -O2/-O4" fft

cr "callback-tests" -extend c-id-valid.scm callback-tests.scm
check_fail "callback-tests twice" '\[panic\] callback returned twice' $run twice

cr apply-test apply-test.scm
check_fail "apply-test -:A10k" '\[panic\] fixed temporary stack overflow' $run -:A10k
cr test-gc-hooks test-gc-hooks.scm
cr "library-tests -specialize" -specialize library-tests.scm
cr records-and-setters-test records-and-setters-test.scm
cr record-printer-test record-printer-test.scm
cr "unicode-tests -specialize" -specialize unicode-tests.scm

dwind() { $compile dwindtst.scm && $run; }
check_diff "dwindtst" dwindtst.expected dwind

delimcc() {
    $interpret -s delimited-continuation-tests.scm >delimcc.wasm.txt &&
    $compile delimited-continuation-tests.scm && $run >delimcc-compiled.wasm.txt &&
    diff $DIFF_OPTS delimcc.wasm.txt delimcc-compiled.wasm.txt &&
    $compile -O3 delimited-continuation-tests.scm && $run >delimcc-compiled.wasm.txt &&
    diff $DIFF_OPTS delimcc.wasm.txt delimcc-compiled.wasm.txt
}
check "delimited-continuation-tests (+ -O3)" delimcc
cr delimcc-retention delimcc-retention.scm
cr "delimcc-retention -O3" -O3 delimcc-retention.scm
cr "closure-sharing-reentry-tests -O2" -O2 closure-sharing-reentry-tests.scm
cr "closure-sharing-reentry-tests -O3" -O3 closure-sharing-reentry-tests.scm
cr "lolevel-tests -specialize" -specialize lolevel-tests.scm
cr syntax-tests syntax-tests.scm
cr syntax-tests-2 syntax-tests-2.scm
cr reexport-tests reexport-tests.scm
rm -f reexport-m*.import* foo.import.* square-functor.import.* sf1.import.* sf2.import.*
check "emit import libraries" emit_import_libraries
cr reexport-m2 reexport-m2.scm
skip reexport-tests-2 "needs reexport-m3 ... m10 as .so extensions (rt:297-306); no dynamic loading"
cr simple-functors-test simple-functors-test.scm
cr functor-tests functor-tests.scm
cr use-square-functor use-square-functor.scm
cr compiler-syntax-tests compiler-syntax-tests.scm
# rt:337.  Statically, (require-library import-library-test1) links the unit.
import_library_test2() {
    $WASM_SDK/bin/csc-wasm -c -unit import-library-test1 -emit-import-library foo \
	import-library-test1.scm -o import-library-test1.o -ignore-repository &&
    $compile import-library-test2.scm import-library-test1.o && $run
}
check import-library-test2 import_library_test2
rm -f foo.import.*
cr test-optional test-optional.scm
cr module-tests-compiled module-tests-compiled.scm
cr module-static-eval-compiled module-static-eval-compiled.scm

# rt:404-408: a statically linked extension, found via its .link file
static_link() {
    rm -rf test-repository && mkdir test-repository &&
    $WASM_SDK/bin/csc-wasm -c -unit sample-module -J sample-module.scm \
	-o sample-module.o -ignore-repository &&
    $compile -uses sample-module module-static-link.scm sample-module.o && $run
}
check "module-static-link" static_link

cr fixnum-tests fixnum-tests.scm
cr "fixnum-tests -unsafe" -unsafe fixnum-tests.scm
# Translated by the host chicken, this fails: the compiler folds
# (string->number "+1@i" 19) with the host's libm (glibc sin(18.0) is
# -0.75098724677167605), while make-polar runs with musl's at run time
# (-0.75098724677167616).  Translate it with the wasm chicken instead, so
# that folding uses the target's libm, and let csc-wasm compile the C.
numbers_string_conversion() {
    rm -f a.js a.wasm
    $wchicken numbers-string-conversion-tests.scm -static -specialize \
	-consult-types-file "$WASM_REPO/types.db" -ignore-repository -include-path "$SRC_DIR" \
	-output-file numbers-string-conversion-tests.wasm.c &&
    $WASM_SDK/bin/csc-wasm -node numbers-string-conversion-tests.wasm.c -o a.js && $run
}
check "numbers-string-conversion-tests -specialize (wasm chicken)" numbers_string_conversion
cr "numbers-test -specialize" -specialize numbers-test.scm
cr "numbers-test-ashinn -specialize" -specialize numbers-test-ashinn.scm
cr "numbers-test-gauche -specialize" -specialize numbers-test-gauche.scm
cr bignum-division-test bignum-division-test.scm
# not compiled by runtests.sh: guards the FP-contraction guarantee
cr srfi-4-tests srfi-4-tests.scm
cr bytevector-guard-tests bytevector-guard-tests.scm
cr utf-compare-tests utf-compare-tests.scm
cr utf-string-set-tests utf-string-set-tests.scm
skip posix-tests "starts a csi subprocess with process (rt:481); process creation is not available"

heap_literal() {
    $compile heap-literal-stress-test.scm || return 1
    for s in 100000 250000 500000; do
	$run -:d -:g -:hi$s || return 1
    done
}
check heap-literal-stress-test heap_literal
cr weak-pointer-test weak-pointer-test.scm
cr symbolgc-tests symbolgc-tests.scm
cr test-finalizers test-finalizers.scm
finalizer_error() {
    $compile finalizer-error-test.scm && $run -:hg101 2>finalizer-error.wasm.txt &&
    cat finalizer-error.wasm.txt && grep -q 'Warning: in finalizer' finalizer-error.wasm.txt
}
check "finalizer-error-test (error message expected)" finalizer_error
cr test-finalizers-2 test-finalizers-2.scm
cr locative-stress-test locative-stress-test.scm
skip executable-tests "checks executable-pathname, which is #f on wasm (rt:566-567)"
skip "embedding (1-3)" "csc-wasm links Scheme programs; the embedding tests need csc's C-main handling (rt:572-582)"

linking() {
    $WASM_SDK/bin/csc-wasm -c -unit reverser -J reverser/tags/1.0/reverser.scm \
	-o reverser.o -ignore-repository &&
    $compile -uses reverser linking-tests.scm reverser.o && $run
}
check "linking-tests (static)" linking
skip private-repository-test "relies on the executable's location (rt:597-602)"
cr multiple-values multiple-values.scm
fi

lane_end
fi

echo
for l in A B C D; do
    if want $l; then eval "echo \"lane $l: \$result_$l\""; fi
done
if test $total_fail -ne 0; then
    echo "runtests-wasm: $total_fail FAILED ($total_pass passed, $total_skip skipped):$failures"
    exit 1
fi
echo "runtests-wasm: all $total_pass tests passed ($total_skip skipped)"
