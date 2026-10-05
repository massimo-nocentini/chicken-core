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
# include files installed by an egg are in the SDK, for programs (C
# headers on emcc's include path, Scheme files on the compiler's), and
# on the include path of the node csi
expect E17 'ok' sh -c "ls '$SDK/share/chicken/wasm-egg-a-shared.scm' \
    '$SDK/include/chicken/wasm-egg-a.h' >/dev/null && echo ok"
cat >incprog.scm <<'EOF'
(import (chicken foreign))
(include "wasm-egg-a-shared.scm")
(foreign-declare "#include \"wasm-egg-a.h\"")
(print (list egg-a-shared-value (foreign-value "WASM_EGG_A_HEADER_VALUE" int)))
EOF
expect E18 '(7 11)' sh -c "'$SDK/bin/csc-wasm' -node incprog.scm -o incprog.js && '$NODE' incprog.js"
expect E19 '7' csi -e '(include "wasm-egg-a-shared.scm") (print egg-a-shared-value)'
# a file in a subdirectory is installed at the same path below the
# destination, as chicken-install does; Scheme files on the include
# path are listed for the web image
include_plan() {
    plan "$PWD/inc" >/dev/null && grep -E '^WASM_EGG_(WEB_INCLUDES|INCLUDE_LISTS) =' plan.mk &&
	grep -o 'echo [^;]*;' plan.mk
}
rm -rf inc && mkdir -p inc/sub
echo '((components (scheme-include inc-s (files "top.scm" "sub/inc.scm"))
  (c-include inc-c (files "sub/inc.h") (destination "include/inc"))))' >inc/inc.egg
: >inc/top.scm; : >inc/sub/inc.scm; : >inc/sub/inc.h
expect E20 'WASM_EGG_INCLUDE_LISTS = $(WASM_EGG_DIR)/inc/includes.list
WASM_EGG_WEB_INCLUDES = top.scm sub/inc.scm
echo share/chicken/top.scm;
echo share/chicken/sub/inc.scm;
echo include/inc/sub/inc.h;' include_plan
echo '((components (scheme-include bad (files "../x.scm"))))' >inc/inc.egg
expect_error E21 "egg .inc.: file of .bad. must be inside the egg" plan "$PWD/inc"
# a build-dependency is used on the host, at build time, where it must
# be installed (HOST_REPO holds the compiled import library of
# wasm-egg-tool, whose import needs its unit); found in the egg cache,
# it is built for the target too
HOST_REPO=$EGG_BUILD/host-repository
expect E22 '42' csi -e '(import wasm-egg-c) (print (egg-c-answer))'
expect E32 '42' csi -e '(import wasm-egg-tool) (print (tool-double 21))'
printf '(import wasm-egg-c)\n(print (egg-c-answer))\n' >toolprog.scm
expect E33 '42' sh -c "'$SDK/bin/csc-wasm' -node toolprog.scm \
    '$SDK/lib/libchicken-eggs.a' -o toolprog.js && '$NODE' toolprog.js"
# plan_in CACHE REPOSITORY EGG ...: plan with that egg cache and host
# repository, offline; plan_host REPOSITORY EGG ...: with no egg cache
plan_in() {
    c=$1; r=$2; shift 2
    WASM_EGGS_HOST_REPOSITORY="$r" CHICKEN_EGG_CACHE="$c" WASM_EGGS_CHICKEN_INSTALL= \
	plan "$@" >/dev/null && grep '^WASM_EGG_NAMES =' plan.mk
}
plan_host() { plan_in "$PWD/no-cache" "$@"; }
expect E34 'WASM_EGG_NAMES = wasm-egg-tool wasm-egg-c' plan_in "$EGG_BUILD/egg-cache" "$HOST_REPO" \
    "$EGGS/wasm-egg-c"
# one that cannot be built for the target (not in the cache) is only
# used on the host, with a warning
expect E23 'WASM_EGG_NAMES = wasm-egg-c' plan_host "$PWD/no-repo:$HOST_REPO" \
    "$EGGS/wasm-egg-c"
expect_error E24 "egg .wasm-egg-c.: build-dependency .wasm-egg-tool. is not installed in the host repository \\($PWD/no-repo\\)" \
    plan_host "$PWD/no-repo" "$EGGS/wasm-egg-c"
rm -rf newer && mkdir newer
echo '((build-dependencies (wasm-egg-tool "2.0")) (components (extension newer)))' >newer/newer.egg
plan_warnings() {
    plan_host "$@" 2>&1 >/dev/null | sed -n 's/^wasm-eggs: warning: //p'
}
expect E25 "build-dependency \`wasm-egg-tool' of \`newer' is not built for WebAssembly, only used from the host repository: egg \`wasm-egg-tool' is not in the cache $PWD/no-cache (needed by newer)
egg \`newer' needs version 2.0 of \`wasm-egg-tool' on the host, but $HOST_REPO/wasm-egg-tool.egg-info has version 1.1" \
    plan_warnings "$HOST_REPO" "$PWD/newer"
rm -rf both && mkdir both
echo '((dependencies wasm-egg-a) (build-dependencies wasm-egg-a) (components (extension both)))' \
    >both/both.egg
expect E26 'WASM_EGG_NAMES = wasm-egg-a both' plan_host '' "$EGGS/wasm-egg-a" "$PWD/both"
# the planner runs again when the egg cache changes (it is recorded
# with the host settings), and only then
replan() {
    MAKEFLAGS= ${MAKE:-make} --no-print-directory -C "$EGG_BUILD" -f "$TEST_DIR/../GNUmakefile" \
	wasm-eggs.mk | grep -c 'wasm-eggs: egg' || :
}
cp "$EGG_BUILD/config-host.make" config-host.save
expect E27 '0' replan
rm -rf other-cache && cp -R "$EGG_BUILD/egg-cache" other-cache
echo "WASM_EGG_CACHE = $PWD/other-cache" >>"$EGG_BUILD/config-host.make"
expect E28 '4' replan
expect E29 '0' replan
cp config-host.save "$EGG_BUILD/config-host.make"
replan >/dev/null
# the web REPL
expect E30 '(shared 7)' sh -c "'$NODE' '$TEST_DIR/wasm/egg-harness.js' '$EGG_BUILD/web' \
    '(include \"wasm-egg-a-shared.scm\") (list (quote shared) egg-a-shared-value)' '(shared 7)' \
    >harness.out && echo '(shared 7)' || { cat harness.out; exit 1; }"
expect E9 'ok' sh -c "'$NODE' '$TEST_DIR/wasm/egg-harness.js' '$EGG_BUILD/web' >harness.out \
    && echo ok || { cat harness.out; exit 1; }"
# the web notebook kernel
expect E16 'ok' sh -c "'$NODE' '$TEST_DIR/wasm/notebook-harness.js' '$EGG_BUILD/web' --eggs \
    >harness.out && echo ok || { cat harness.out; exit 1; }"
# a build directory without the list of an egg's include files (made
# before the lists were) installs them again, into the SDK too
reinstall_includes() {
    rm -f "$EGG_BUILD/eggs/wasm-egg-a/includes.list" "$SDK/include/chicken/wasm-egg-a.h" \
	"$SDK/share/chicken/wasm-egg-a-shared.scm"
    MAKEFLAGS= ${MAKE:-make} --no-print-directory -C "$EGG_BUILD" -f "$TEST_DIR/../GNUmakefile" \
	wasm-eggs-repo.stamp >reinstall.log 2>&1 || { cat reinstall.log; exit 1; }
    ls "$SDK/include/chicken/wasm-egg-a.h" "$SDK/share/chicken/wasm-egg-a-shared.scm" >/dev/null &&
	cat "$EGG_BUILD/eggs/wasm-egg-a/includes.list"
}
expect E31 'share/chicken/wasm-egg-a-shared.scm
include/chicken/wasm-egg-a.h' reinstall_includes

rm -f eggs.out eggs.err
echo
if test $failures -ne 0; then
    echo "wasm-eggs: $failures of $checks checks FAILED"
    exit 1
fi
echo "wasm-eggs: all $checks checks passed"
