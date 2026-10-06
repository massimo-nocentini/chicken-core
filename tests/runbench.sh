#!/bin/sh
# runbench.sh - run benchmarks
#
# - Upstream dropped the core benchmark suite (slatex, grep, allocation)
#   and the `make bench' target; this fork keeps the remaining benchmarks,
#   including the delimited-continuation ones.  Run it from tests/ after
#   building: `cd tests; sh runbench.sh'.
#
# - Note: this needs a proper shell, so it will not work with plain mingw
#   (just the compiler and the Windows shell, without MSYS)

set -e
TEST_DIR=`pwd`
export DYLD_LIBRARY_PATH=${TEST_DIR}/..
export LD_LIBRARY_PATH=${TEST_DIR}/..

echo 

CHICKEN=../chicken
COMPILE_OPTIONS="-O5 -d0 -disable-interrupts -b"

if test -n "$MSYSTEM"; then
    CHICKEN="..\\chicken.exe"
    # make compiled tests use proper library on Windows
    cp ../lib*chicken*.dll .
fi

case `uname -s` in
    *BSD*|*bsd*) timeopts="-c";;
    Darwin) timeopts="";;
    *) timeopts='-f "%E elapsed, %U user, %S system"'
esac

run()
{
    /usr/bin/time "$timeopts" ./a.out "$1" "$2" "$3"
}

echo "****************************************"

compiler_options="-C -Wa,-W"
compile="../csc -w -compiler $CHICKEN -I.. -L.. -include-path .. -o a.out $COMPILE_OPTIONS"
interpret="../csi -n -include-path .."

echo "======================================== null ... "
$compile null.scm -O5
run -:Hd

echo "======================================== compilation ... "
/usr/bin/time "$timeopts" $compile compiler.scm

echo "======================================== compiler ... "
run -:Hd

echo "======================================== fft/boxed ... "
$compile fft.scm
run 2000 11
echo "======================================== fft/unboxed ... "
$compile fft.scm -D unboxed
run 2000 11

echo "======================================== irregex ... "
/usr/bin/time "$timeopts" $interpret -bnq test-irregex.scm >/dev/null

echo "======================================== delimited continuations ... "
$compile delimcc-bench.scm
./a.out

echo "======================================== delimited continuations, paper workloads ... "
# The same workloads twice: native shift/reset, then Filinski's
# meta-continuation cell over call/cc (the indirect implementation).
$compile delimcc-paper-bench.scm
./a.out
$compile -D filinski delimcc-paper-bench.scm
./a.out
