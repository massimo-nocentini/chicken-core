#!/bin/sh
# wasm-smoke.sh - smoke tests for the WebAssembly (node) build of CHICKEN
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
# build-wasm/tests-run); nothing is written elsewhere.
#
# Environment:
#   WASM_DIR   directory holding the node wrappers (build-wasm/node)
#   TEST_DIR   the source tests directory (read only)
#   WASM_SMOKE_ALLOW_UNSUPPORTED=1  tolerate "unsupported syscall"
#              diagnostics (DEBUGBUILD lane only)
#   WASM_SMOKE_LANE_W=0  skip lane W (worst-case engine stack)
#
# Every check compares stdout and/or the exit status.  Any engine-level
# failure on stderr (RangeError, RuntimeError, Aborted) fails the check.

set -e

: "${WASM_DIR:?WASM_DIR must name the directory with the node wrappers}"
: "${TEST_DIR:?TEST_DIR must name the source tests directory}"
WASM_DIR=$(cd "$WASM_DIR" && pwd)
TEST_DIR=$(cd "$TEST_DIR" && pwd)
NODE=${NODE:-node}

if test "${WASM_SMOKE_ALLOW_UNSUPPORTED:-0}" = 1; then
    engine_errors='RangeError|RuntimeError|Aborted'
else
    engine_errors='RangeError|RuntimeError|Aborted|unsupported syscall'
fi

failures=0
checks=0

# How csi is started; lane W replaces these.
lane=default
csi_run() { "$WASM_DIR/csi" "$@"; }

fail() {
    failures=$((failures + 1))
    echo "FAIL [$lane] $1: $2"
    for f in smoke.out smoke.err; do
	if test -s $f; then echo "  --- $f:"; head -20 $f | sed 's/^/  | /'; fi
    done
}

# run NAME COMMAND ...: run a command, capturing output and status
run() {
    name=$1; shift
    checks=$((checks + 1))
    if "$@" >smoke.out 2>smoke.err; then status=0; else status=$?; fi
    if grep -Eq "$engine_errors" smoke.err; then
	fail "$name" "engine error on stderr"
	return 1
    fi
    return 0
}

# expect NAME EXPECTED COMMAND ...: stdout must equal EXPECTED, status 0
expect() {
    name=$1; expected=$2; shift 2
    run "$name" "$@" || return 0
    out=$(cat smoke.out)
    if test "$status" -ne 0; then
	fail "$name" "exit status $status"
    elif test "x$out" != "x$expected"; then
	fail "$name" "expected '$expected', got '$out'"
    else
	echo "ok   [$lane] $name"
    fi
}

# expect_status NAME STATUS COMMAND ...: exit status must be STATUS
# ("nonzero" accepts any failure)
expect_status() {
    name=$1; expected=$2; shift 2
    run "$name" "$@" || return 0
    if test "$expected" = nonzero && test "$status" -ne 0; then
	echo "ok   [$lane] $name"
    elif test "$expected" = "$status"; then
	echo "ok   [$lane] $name"
    else
	fail "$name" "exit status $status, expected $expected"
    fi
}

# expect_error NAME REGEX COMMAND ...: must fail with REGEX on stderr
expect_error() {
    name=$1; regex=$2; shift 2
    run "$name" "$@" || return 0
    if test "$status" -eq 0; then
	fail "$name" "unexpected success"
    elif ! grep -Eq "$regex" smoke.err; then
	fail "$name" "stderr does not match '$regex'"
    else
	echo "ok   [$lane] $name"
    fi
}

# The checks that stress stack depth and GC restarts; lane W reruns them.
S23_ITERATIONS=20000000

stack_checks() {
    expect S8 gc-ok csi_run -n -e \
	'(let loop ((i 0)) (when (< i 3000000) (make-vector 10) (loop (+ i 1)))) (print "gc-ok")'
    expect S9 1000000 csi_run -n -e \
	'(define (f n) (if (= n 0) 0 (+ 1 (f (- n 1))))) (print (f 1000000))'
    expect S17 1000000 csi_run -n -e \
	'(import (chicken fixnum)) (define (f n) (if (fx= n 0) 0 (fx+ 1 (f (fx- n 1))))) (print (f 1000000))'
    expect_error S18 'recursion too deep or circular data' csi_run -n -e \
	'(define (mk) (let loop ((i 0) (l (quote ()))) (if (< i 1000000) (loop (+ i 1) (list l)) l))) (print (equal? (mk) (mk)))'
    # the same two at the largest nursery the runtime accepts (320k at
    # the default frame pad: C_WASM_MAX_NURSERY in runtime.c)
    expect S9m 1000000 csi_run -:s320k -n -e \
	'(define (f n) (if (= n 0) 0 (+ 1 (f (- n 1))))) (print (f 1000000))'
    expect_error S18m 'recursion too deep or circular data' csi_run -:s320k -n -e \
	'(define (mk) (let loop ((i 0) (l (quote ()))) (if (< i 1000000) (loop (+ i 1) (list l)) l))) (print (equal? (mk) (mk)))'
    # -: options must come first; more than 30000 minor GCs (drift regression)
    expect S23 ok csi_run -:s64k -n -e \
	"(let l ((i 0)) (if (< i $S23_ITERATIONS) (l (+ i 1)))) (print (quote ok))"
}

C="csi_run -n"

expect S1 3 $C -e '(print (+ 1 2))'
expect S2 '#f #t wasm32 1073741823 #t emscripten unix #f' $C -e \
    '(import (chicken platform) (chicken fixnum)) (print (feature? #:64bit) " " (feature? #:32bit) " " (machine-type) " " most-positive-fixnum " " (feature? #:emscripten) " " (software-version) " " (software-type) " " (feature? #:dload))'
expect_status S3 3 $C -e '(exit 3)'
expect_status S3b nonzero $C -e '(car 1)'
expect S4 bar env FOO=bar "$WASM_DIR/csi" -n -e \
    '(import (chicken process-context)) (print (get-environment-variable "FOO"))'
expect S5 a,b $C -e \
    '(import (chicken string)) (print (string-intersperse (quote ("a" "b")) ","))'
expect S5b ok $C -e \
    '(import (chicken tcp) (chicken process) (chicken file posix) (srfi 4)) (print (quote ok))'
expect S6 1267650600228229401496703205376 $C -e '(print (expt 2 100))'
expect S7 '0.333333333333333 0.333333333333333' $C -e \
    '(print (/ 1. 3) " " (exact->inexact 1/3))'
expect S10 major-ok $C -e '(import (chicken gc)) (gc #t) (print "major-ok")'
expect S11 42 $C -e \
    '(print (call-with-current-continuation (lambda (k) (dynamic-wind (lambda () #f) (lambda () (k 42)) (lambda () #f)))))'
rm -f smoke.tmp
expect S12 7 $C -e \
    '(with-output-to-file "smoke.tmp" (lambda () (write 7))) (print (with-input-from-file "smoke.tmp" read))'
rm -f smoke.tmp

s13() { printf '(define x 41)\n(+ x 1)\n' | csi_run -n -q; }
run S13 s13 && if test "$status" -eq 0 && grep -q 42 smoke.out; then
    echo "ok   [$lane] S13"
else
    fail S13 "no 42 in the REPL output (status $status)"
fi

expect S14 3 $C -e '(print (string-length "λ€x"))'
expect S15 aλa $C -e \
    '(let ((s (make-string 3 #\a))) (string-set! s 1 #\λ) (print s))'

s16() { "$WASM_DIR/chicken" "$TEST_DIR/null.scm" -output-file smoke-null.c && grep -q C_toplevel smoke-null.c; }
expect_status S16 0 s16
rm -f smoke-null.c

stack_checks

expect S19 '#t' $C -e \
    '(import (chicken time)) (let-values (((u0 s0) (cpu-time))) (let l ((i 0)) (if (< i 3000000) (l (+ i 1)))) (let-values (((u1 s1) (cpu-time))) (print (> u1 u0))))'
expect S20 '1000 #t' $C -e \
    '(import (scheme time)) (print (jiffies-per-second) " " (< 0 (current-jiffy)))'

# S20b: 37 minutes after startup, microsecond jiffies would have wrapped
s20b() {
    "$NODE" -e '
const csi = process.argv[1];
const orig = performance.now.bind(performance);
performance.now = () => orig() + 2.2e6;
process.argv = [process.execPath, csi, "-n", "-e",
  "(import (scheme time) (chicken time))" +
  "(let ((a (current-jiffy)))" +
  "  (let w ((t0 (current-process-milliseconds)))" +
  "    (if (< (- (current-process-milliseconds) t0) 50) (w t0)))" +
  "  (let ((b (current-jiffy))) (print (> a 0) \" \" (- b a))))"];
require(csi);' "$WASM_DIR/csi.js"
}
run S20b s20b && {
    set -- $(cat smoke.out)
    if test "$status" -eq 0 && test "x$1" = 'x#t' && test "${2:-0}" -ge 40 && test "${2:-0}" -le 200; then
	echo "ok   [$lane] S20b"
    else
	fail S20b "expected '#t <40..200>', got '$(cat smoke.out)'"
    fi
}

expect_error S21 'exceeds the WebAssembly stack' csi_run -:s8m -n -e 1
expect_error S21b 'exceeds the WebAssembly maximum' csi_run -:s321k -n -e 1
expect S22 '#f' $C -e '(import (chicken process-context)) (print (executable-pathname))'
expect_status S24 0 "$WASM_DIR/chicken-status" -h
# chicken-profile exits 64 after -help (as natively), so ask for its version
expect_status S24b 0 "$WASM_DIR/chicken-profile" -version

# Lane W: worst-case engine stack.  Liftoff frames are the largest; a
# browser worker gets about 1 MB of native stack.
if test "${WASM_SMOKE_LANE_W:-1}" != 0; then
    S23_ITERATIONS=5000000	# still well over 30000 minor GCs

    lane=W-liftoff
    csi_run() {
	NODE_OPTIONS_WASM="--liftoff --no-wasm-tier-up --stack-size=900" "$WASM_DIR/csi" "$@"
    }
    stack_checks

    lane=W-worker
    csi_run() {
	"$NODE" --liftoff --no-wasm-tier-up "$TEST_DIR/wasm/in-worker.js" 1 "$WASM_DIR/csi.js" "$@"
    }
    stack_checks
fi

rm -f smoke.out smoke.err
echo
if test $failures -ne 0; then
    echo "wasm-smoke: $failures of $checks checks FAILED"
    exit 1
fi
echo "wasm-smoke: all $checks checks passed"
