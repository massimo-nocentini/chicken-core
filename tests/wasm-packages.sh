#!/bin/sh
# wasm-packages.sh - tests of packages of compiled extensions (make wasm-package)
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
# Run by "make wasm-check" (with WASM_DYLINK=1) from an empty scratch
# directory, after it has made PKG with "make wasm-package" from the
# eggs wasm-egg-a and wasm-egg-b of tests/wasm/eggs.
#
# Environment:
#   BUILD      the build directory (node/csi, the page, the SDK)
#   PKG        the package directory, holding manifest.json
#   TEST_DIR   the source tests directory (read only)
#   HOST_CSI   the host csi command that runs emscripten/wasm-eggs.scm
#   NODE       the node binary
#
# Every check compares stdout, or stderr for a failure.  The page's
# harnesses (worker-harness.js and notebook-harness.js with --package)
# are run by make.

set -e

: "${BUILD:?BUILD must name the build directory}"
: "${PKG:?PKG must name the package directory}"
: "${TEST_DIR:?TEST_DIR must name the source tests directory}"
: "${HOST_CSI:?HOST_CSI must name the host csi command}"
BUILD=$(cd "$BUILD" && pwd)
PKG=$(cd "$PKG" && pwd)
TEST_DIR=$(cd "$TEST_DIR" && pwd)
NODE=${NODE:-node}
TOOL=$TEST_DIR/../emscripten/wasm-package.js
SDK=$BUILD/stage/chicken
ABI=$(cat "$BUILD/wasm-abi")
ARCH=$(sed -n 's/^WASM_ARCH *= *//p' "$BUILD/config.make")
ARCH=${ARCH:-wasm64}

failures=0
checks=0

fail() {
    failures=$((failures + 1))
    echo "FAIL $1: $2"
    for f in pkg.out pkg.err; do
	if test -s $f; then echo "  --- $f:"; head -20 $f | sed 's/^/  | /'; fi
    done
}

# run COMMAND ...: run a command, capturing output and status
run() {
    checks=$((checks + 1))
    if "$@" >pkg.out 2>pkg.err; then status=0; else status=$?; fi
}

# expect NAME EXPECTED COMMAND ...: stdout must equal EXPECTED, status 0
expect() {
    name=$1; expected=$2; shift 2
    run "$@"
    out=$(cat pkg.out)
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
    elif ! grep -Eq "$regex" pkg.err; then
	fail "$name" "stderr does not match '$regex'"
    else
	echo "ok   $name"
    fi
}

# the node csi, with the unpacked package on its repository and
# include paths (after the staged repository: see the node wrappers)
csi() {
    CHICKEN_REPOSITORY_PATH="$PWD/unpacked/repo" CHICKEN_INCLUDE_PATH="$PWD/unpacked/share" \
	"$BUILD/node/csi" -n "$@"
}

# the manifest has a build for each of the page's (chicken-wasm-builds:
# ARCH:EH:ABI each), with the same ABI, and the bundles it names
builds() {
    "$NODE" -e '
      const fs = require("fs"), path = require("path");
      const [pkg, page] = process.argv.slice(1);
      const m = JSON.parse(fs.readFileSync(path.join(pkg, "manifest.json"), "utf8"));
      const html = fs.readFileSync(page, "utf8");
      const builds = /<meta name="chicken-wasm-builds" content="([^"]*)">/.exec(html)[1].split(" ");
      for (const b of builds) {
        const [arch, eh, abi] = b.split(":");
        const x = m.builds[abi];
        if (!x || x.arch !== arch || x.eh !== eh) throw new Error("no build " + b);
        const raw = fs.readFileSync(path.join(pkg, x.rawBundle));
        const gz = fs.readFileSync(path.join(pkg, x.bundle));
        if (raw.length !== x.size || gz.length !== x.gzSize) throw new Error("sizes of " + b);
        console.log(arch + " " + (x.files.length > 0));
      }
      console.log(m.format, m.formatVersion, m.name, m.eggs.map(e => e.name + ":" + e.origin).join(" "));
    ' "$PKG" "$BUILD/web/index.html"
}
pagebuilds=$(sed -n 's/.*<meta name="chicken-wasm-builds" content="\([^"]*\)">.*/\1/p' "$BUILD/web/index.html" |
    tr ' ' '\n' | sed 's/:.*/ true/')
expect K1 "$pagebuilds
chicken-wasm-package 1 wasm-test-eggs wasm-egg-a:local wasm-egg-b:local" builds
expect K2 'wasm-egg-a-extra.import.so wasm-egg-a.import.so wasm-egg-a.so wasm-egg-a.types wasm-egg-b-core.import.so wasm-egg-b-core.so wasm-egg-b.import.so wasm-egg-b.so
wasm-egg-a-shared.scm' sh -c "rm -rf unpacked && '$NODE' '$TOOL' unpack '$PKG' --abi $ABI unpacked >/dev/null &&
  ls unpacked/repo | tr '\n' ' ' | sed 's/ \$//' && echo && ls unpacked/share"
# node csi loads the extensions, their compiled import libraries and
# the include files
expect K3 '(10 18 42 42 2 1)' csi -e '(import wasm-egg-b) (print (egg-b-report))'
expect K4 '(42 15 8)' csi -e \
    '(import wasm-egg-a) (print (list (egg-a-add 40 2) (egg-a-scale 5) (egg-a-twice 4)))'
expect K5 '(7 11)' csi -e '(import wasm-egg-b) (print (egg-b-included))'
expect K6 '7' csi -e '(include "wasm-egg-a-shared.scm") (print egg-a-shared-value)'
# garbage collections and continuations through the frames of a side
# module: a major GC in a callback, an escape, re-entries
expect K7 '100000' csi -e '(import wasm-egg-a (chicken gc))
  (print (length (egg-a-walk (lambda (i v) (when (= i 500) (gc #t)) (make-string 100 #\x)) 100000)))'
expect K8 'escaped' csi -e '(import wasm-egg-a)
  (print (call-with-current-continuation
          (lambda (k) (egg-a-walk (lambda (i v) (if (= i 500) (k (quote escaped)) i)) 1000))))'
expect K9 '((0 1 2 20 4) 3)' csi -e '(import wasm-egg-a)
  (let* ((r #f) (n 0)
         (res (egg-a-walk (lambda (i v) (if (= i 3) (call-with-current-continuation (lambda (k) (set! r k) i)) i)) 5)))
    (set! n (+ n 1))
    (if (< n 3) (r (* 10 n)) (print (list res n))))'
# the import library of a module the extension defines besides its
# own is found, but (as natively) its extension is that of the module's
# name: import the first module first
expect K10 'extra' csi -e '(import wasm-egg-a wasm-egg-a-extra) (print (egg-a-extra))'
# a file whose SHA-256 is not the manifest's is refused
corrupt() {
    rm -rf bad-pkg unpacked-bad && cp -R "$PKG" bad-pkg &&
	"$NODE" -e '
          const fs = require("fs");
          const m = JSON.parse(fs.readFileSync("bad-pkg/manifest.json", "utf8"));
          const b = m.builds[process.argv[1]], f = b.files.find(f => f.path === "repo/wasm-egg-a.so");
          const raw = fs.readFileSync("bad-pkg/" + b.rawBundle);
          raw[f.offset + f.size - 1] ^= 1;
          fs.writeFileSync("bad-pkg/" + b.rawBundle, raw);' "$ABI" &&
	"$NODE" "$TOOL" unpack bad-pkg --abi "$ABI" unpacked-bad
}
expect_error K11 'repo/wasm-egg-a.so: bad size or SHA-256' corrupt
expect_error K12 'no build for the ABI 0123456789abcdef' "$NODE" "$TOOL" unpack "$PKG" --abi 0123456789abcdef x
# a side module that the page's csi could not load is refused, with the
# symbols it lacks (a function and data that neither libchicken nor the
# C library exports): by csc-wasm -shared, which leaves no output, and
# by the package's check (of a module linked without csc-wasm's)
cat >noexport.scm <<'EOF'
(import scheme (chicken foreign))
(foreign-declare "extern int wasm_no_such_function(int);\nextern int wasm_no_such_data;")
(define f (foreign-lambda int "wasm_no_such_function" int))
(define g (foreign-value "wasm_no_such_data" int))
EOF
EMCC=$(sed -n "s/^EMCC='\(.*\)'\$/\1/p" "$SDK/bin/csc-wasm")
expect_error K13 'noexport.so: unresolved: GOT.mem.wasm_no_such_data env.wasm_no_such_function' \
    "$SDK/bin/csc-wasm" -shared noexport.scm -o noexport.so
expect K13b 'none' sh -c 'test -f noexport.so || echo none'
# (as csc-wasm -shared links)
"$SDK/bin/csc-wasm" -shared -c noexport.scm -o noexport.o
$EMCC $(cat "$SDK/share/chicken/emsideflags") -sSIDE_MODULE=2 -sEXPORTED_FUNCTIONS=_C_toplevel \
    -Wl,-Bsymbolic noexport.o -o noexport.so
bundle_one() {
    rm -rf one && mkdir -p one/repo && cp "$1" one/repo/ && basename "$1" | sed 's|^|repo/|' >one/files.list &&
	echo "one 1 local" >one/eggs.list &&
	"$NODE" "$TOOL" bundle --name one --root one --files one/files.list --eggs one/eggs.list \
	    --exports "$BUILD/runtime-exports" --main "$BUILD/web/chicken-repl.wasm" --arch "$ARCH" \
	    --eh x --abi "$ABI" --chicken 0 --binary-version 0 --out one/out --info one/info.json
}
expect_error K13c 'noexport.so: unresolved: GOT.mem.wasm_no_such_data env.wasm_no_such_function' \
    bundle_one noexport.so
# csi refuses to load it, saying why, and loads others after it (the
# entries of the global offset table that it would leave undefined
# would make every later load fail)
expect K13d 'unable to load compiled module - symbols missing from this program: GOT.mem.wasm_no_such_data wasm_no_such_function
(42 15 8)' csi -e '(import (chicken condition))
  (handle-exceptions e (print ((condition-property-accessor (quote exn) (quote message)) e)) (load "noexport.so"))
  (import wasm-egg-a) (print (list (egg-a-add 40 2) (egg-a-scale 5) (egg-a-twice 4)))'
# what clang calls in place of what C code names (siprintf for sprintf
# of %d, strcpy ...), setjmp and longjmp, long double and 128-bit
# integer arithmetic: csi exports all of it
cat >libc.scm <<'EOF'
(module libc (fmt)
(import scheme (chicken base) (chicken foreign))
(foreign-declare #<<C
#include <stdio.h>
#include <string.h>
#include <setjmp.h>
static char buf[256];
static jmp_buf jb;
static int jump(int n) { if (setjmp(jb) == 0) { if (n) longjmp(jb, n); return 0; } return 100 + n; }
static char *fmt(int n, double d, char *s)
{
  long double x = d;
  __int128 i = (__int128)n * n * 1000000007LL;
  char t[64];
  strcpy(t, s);
  x = x * 14 / 5;
  sprintf(buf, "%d %.2f %s %d %d %d", n, d, t, jump(n), (int)x, (int)(i % 1000));
  return buf;
}
C
)
(define fmt (foreign-lambda c-string "fmt" int double c-string)))
EOF
"$SDK/bin/csc-wasm" -shared -J libc.scm -o libc.so
"$SDK/bin/csc-wasm" -shared -setup-mode libc.import.scm -o libc.import.so
expect K18 '5 2.50 abc 105 7 175' csi -e '(import libc) (print (fmt 5 2.5 "abc"))'
# a file that is not WebAssembly is not taken for compiled code (nor
# read as source code)
printf '\177ELF' >elf.so
expect_error K19 'unable to load compiled module - not a WebAssembly module' csi -e '(load "elf.so")'

# a side module of the other architecture of the page is refused
other=$(sed -n 's/^WASM_WEB_ARCHS *= *//p' "$BUILD/config-web.make" | tr ' ' '\n' | grep -v "^$ARCH\$" | head -1)
if test -n "$other"; then
    "$NODE" "$TOOL" unpack "$PKG" --arch "$other" unpacked-other >/dev/null
    expect_error K14 "wasm-egg-a.so: built for $other, not $ARCH" bundle_one unpacked-other/repo/wasm-egg-a.so
fi
# the builds of a package may list its eggs in another order (an egg
# that one architecture only depends on), and the version of the
# package is that of the first egg directory given
info() {
    printf '{"abi": "%s", "eggs": %s, "build": {"arch": "%s", "eh": "x", "bundle": "b%s", "rawBundle": "r%s", "files": []}}' \
	"$1" "$2" "$3" "$1" "$1" >"$1.json"
}
manifest_two() {
    mkdir -p mf &&
	info 0000000000000001 '[{"name": "e1", "version": "1.0", "origin": "local"}, {"name": "e2", "version": "2.0", "origin": "local"}]' wasm64 &&
	info 0000000000000002 '[{"name": "e2", "version": "2.0", "origin": "local"}, {"name": "e1", "version": "1.0", "origin": "local"}]' wasm32 &&
	"$NODE" "$TOOL" manifest --out mf --name pk "$@" 0000000000000001.json 0000000000000002.json >/dev/null &&
	"$NODE" -e 'const m = require("./mf/manifest.json");
	  console.log(m.version, m.eggs.map(e => e.name).join(" "), Object.keys(m.builds).length)'
}
expect K20 '2.0 e1 e2 2' manifest_two --first e2
expect K21 '1.0 e1 e2 2' manifest_two
expect K22 'wasm-test-eggs 0.3' "$NODE" -e 'const m = require(process.argv[1]); console.log(m.name, m.version)' \
    "$PKG/manifest.json"
# the planner's shared mode: the conditions "dynamic" and "dload" hold,
# not "static", and the target's version is the build's
PLANNER=$TEST_DIR/../emscripten/wasm-eggs.scm
plan() {
    WASM_EGGS_DEFAULTS="$TEST_DIR/../setup.defaults" WASM_EGG_DIR=plan-eggs WASM_EGGS_VERSION=6.1.0 \
	CHICKEN_EGG_CACHE="$PWD/no-cache" WASM_EGGS_CHICKEN_INSTALL= $HOST_CSI -s "$PLANNER" plan.mk "$@"
}
rm -rf dyn && mkdir dyn
echo '((components (extension dyn
   (cond-expand ((and dynamic dload chicken-6.1 (not static)) (csc-options "-D" "dyn-ok"))
                (else (error "dyn: wrong conditions"))))))' >dyn/dyn.egg
shared_plan() { (WASM_EGGS_MODE=shared; export WASM_EGGS_MODE; plan "$@"); }
rm -f plan.mk; shared_plan "$PWD/dyn" >/dev/null 2>&1 || :
expect K15 '1' grep -c -- ' -D dyn-ok ' plan.mk
expect_error K16 'dyn: wrong conditions' plan "$PWD/dyn"
echo '((components (extension st (linkage static))))' >dyn/dyn.egg
expect_error K17 "component .st. has no dynamic linkage, which a package needs" shared_plan "$PWD/dyn"
rm -f pkg.out pkg.err
echo
if test $failures -ne 0; then
    echo "wasm-packages: $failures of $checks checks FAILED"
    exit 1
fi
echo "wasm-packages: all $checks checks passed"
