#!/bin/sh
# wasm-eggs.sh - tests of eggs linked into the WebAssembly build (WASM_EGGS)
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
# Run by "make wasm-check" from an empty scratch directory, after it has
# built EGG_BUILD with WASM_EGGS naming the eggs in tests/wasm/eggs.
#
# Environment:
#   EGG_BUILD  the build directory with the eggs linked in
#   TEST_DIR   the source tests directory (read only)
#   HOST_CSI   the host csi command that runs emscripten/wasm-eggs.scm
#   NODE       the node binary
#
# Every check compares stdout, or stderr for a failure.

set -e

: "${EGG_BUILD:?EGG_BUILD must name the build directory with the eggs}"
: "${TEST_DIR:?TEST_DIR must name the source tests directory}"
: "${HOST_CSI:?HOST_CSI must name the host csi command}"
EGG_BUILD=$(cd "$EGG_BUILD" && pwd)
TEST_DIR=$(cd "$TEST_DIR" && pwd)
NODE=${NODE:-node}
export NODE
EGGS=$TEST_DIR/wasm/eggs
SDK=$EGG_BUILD/stage/chicken

failures=0
checks=0

fail() {
    failures=$((failures + 1))
    echo "FAIL $1: $2"
    for f in eggs.out eggs.err; do
	if test -s $f; then echo "  --- $f:"; head -20 $f | sed 's/^/  | /'; fi
    done
}

# run COMMAND ...: run a command, capturing output and status
run() {
    checks=$((checks + 1))
    if "$@" >eggs.out 2>eggs.err; then status=0; else status=$?; fi
}

# expect NAME EXPECTED COMMAND ...: stdout must equal EXPECTED, status 0
expect() {
    name=$1; expected=$2; shift 2
    run "$@"
    out=$(cat eggs.out)
    if test "$status" -ne 0; then
	fail "$name" "exit status $status"
    elif test "x$out" != "x$expected"; then
	fail "$name" "expected '$expected', got '$out'"
    else
	echo "ok   $name"
    fi
}

# expect_error NAME REGEX COMMAND ...: must fail with REGEX on stderr
expect_error() {
    name=$1; regex=$2; shift 2
    run "$@"
    if test "$status" -eq 0; then
	fail "$name" "unexpected success"
    elif ! grep -Eq "$regex" eggs.err; then
	fail "$name" "stderr does not match '$regex'"
    else
	echo "ok   $name"
    fi
}

csi() { "$EGG_BUILD/node/csi" -n "$@"; }
PLANNER=$TEST_DIR/../emscripten/wasm-eggs.scm
plan() {
    WASM_EGGS_DEFAULTS="$TEST_DIR/../setup.defaults" WASM_EGG_DIR=plan-eggs \
	$HOST_CSI -s "$PLANNER" plan.mk "$@"
}

# node csi: an egg unit is initialised when first imported, not before
expect E0 '#f #t #t' csi -e \
    "(define before (##sys#provided? 'wasm-egg-a)) (import wasm-egg-b) \
     (print before \" \" (##sys#provided? 'wasm-egg-a) \" \" (##sys#provided? 'wasm-egg-b))"
expect E1 '(10 18 42 42 2 1)' csi -e '(import wasm-egg-b) (print (egg-b-report))'
expect E2 '#t' csi -e '(import wasm-egg-b) (print (egg-b-target?))'
expect E3 '2 1' csi -e \
    '(import wasm-egg-b) (define x 1) (define y 2) (egg-a-swap! x y) (print x " " y)'
expect E4 '42 15 8' csi -e \
    '(import wasm-egg-a) (print (egg-a-add 40 2) " " (egg-a-scale 5) " " (egg-a-twice 4))'
# the import libraries (and a types file) are in the staged repository
expect E5 'ok' sh -c "cd '$SDK'/lib/chicken/* && ls wasm-egg-a.import.scm wasm-egg-a.types \
    wasm-egg-b-core.import.scm wasm-egg-b.import.scm >/dev/null && echo ok"
# a compiled program imports an egg: its units come from libchicken-eggs.a
printf '(import wasm-egg-b)\n(print (egg-b-report))\n' >eggprog.scm
expect E6 '(10 18 42 42 2 1)' sh -c "'$SDK/bin/csc-wasm' -node eggprog.scm \
    '$SDK/lib/libchicken-eggs.a' -o eggprog.js && '$NODE' eggprog.js"
# planning fails, naming the egg and the reason, for an egg that
# cannot be built statically, and for a dependency that is missing
expect_error E7 "egg .wasm-egg-custom.: component .wasm-egg-custom. has a custom build script" \
    plan "$EGGS/wasm-egg-custom"
plan_uncached() {
    CHICKEN_EGG_CACHE="$PWD/no-cache" WASM_EGGS_CHICKEN_INSTALL= plan "$@"
}
expect_error E8 "egg .wasm-egg-a. is not in the cache" plan_uncached "$EGGS/wasm-egg-b"
# every module an extension defines has its import library installed
expect E10 'extra' csi -e '(import wasm-egg-a-extra) (print (egg-a-extra))'
# include files installed by wasm-egg-a (scheme-include and c-include)
expect E11 '(7 11)' csi -e '(import wasm-egg-b) (print (egg-b-included))'
# the staged repository comes before one in CHICKEN_REPOSITORY_PATH
expect E12 '3' env CHICKEN_REPOSITORY_PATH="$PWD/no-repo" "$EGG_BUILD/node/csi" -n -e \
    '(import wasm-egg-a) (print (egg-a-add 1 2))'
# an egg's sources are copied again when they come from elsewhere:
# its origin is recorded, and the copy depends on it
origin() {
    plan "$1" >/dev/null && cat plan-eggs/wasm-egg-a/origin &&
	grep -F '$(WASM_EGG_DIR)/wasm-egg-a/src.stamp: $(WASM_EGG_DIR)/wasm-egg-a/origin ' plan.mk |
	    sed 's/:.*//'
}
rm -rf moved && mkdir moved && cp -Rp "$EGGS/wasm-egg-a" moved/
expect E13 "$EGGS/wasm-egg-a
\$(WASM_EGG_DIR)/wasm-egg-a/src.stamp" origin "$EGGS/wasm-egg-a"
expect E14 "$PWD/moved/wasm-egg-a
\$(WASM_EGG_DIR)/wasm-egg-a/src.stamp" origin "$PWD/moved/wasm-egg-a"
# an egg without extensions for the target (host-only) is planned,
# with a warning; its done.stamp follows its sources' copy
host_only() {
    plan "$PWD/host-only" 2>&1 >/dev/null | grep -o 'no extension for the target' &&
	grep -F '$(WASM_EGG_DIR)/host-only/done.stamp:' plan.mk | sed 's/.*: //'
}
rm -rf host-only && mkdir host-only
echo '((components (host (extension host-only))))' >host-only/host-only.egg
expect E15 'no extension for the target
$(WASM_EGG_DIR)/host-only/src.stamp' host_only
# the web REPL
expect E9 'ok' sh -c "'$NODE' '$TEST_DIR/wasm/egg-harness.js' '$EGG_BUILD/web' >harness.out \
    && echo ok || { cat harness.out; exit 1; }"
# the web notebook kernel
expect E16 'ok' sh -c "'$NODE' '$TEST_DIR/wasm/notebook-harness.js' '$EGG_BUILD/web' --eggs \
    >harness.out && echo ok || { cat harness.out; exit 1; }"

rm -f eggs.out eggs.err
echo
if test $failures -ne 0; then
    echo "wasm-eggs: $failures of $checks checks FAILED"
    exit 1
fi
echo "wasm-eggs: all $checks checks passed"
