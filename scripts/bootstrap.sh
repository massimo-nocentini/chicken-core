#!/bin/sh

set -e

# build 6.0.0-bootstrap tarball

getcmd="wget -c"
mkcmd=make
case "$(uname)" in
    FreeBSD)
        mkcmd=gmake
        getcmd=fetch;;
    *BSD)
        mkcmd=gmake;;
esac

mkdir -p boot/snapshot
cd boot
$getcmd https://code.call-cc.org/dev-snapshots/2024/07/01/chicken-6.0.0-bootstrap.tar.gz
tar -xzf chicken-6.0.0-bootstrap.tar.gz
cd chicken-6.0.0
$mkcmd "$@" PREFIX="$(pwd)"/../snapshot
$mkcmd "$@" PREFIX="$(pwd)"/../snapshot install
cd ../..

# build a boot-chicken from git head using the snapshot
# chicken and then use that to build the real thing

./configure --chicken "$(pwd)"/boot/snapshot/bin/chicken
$mkcmd boot-chicken

# remove snapshot installation and tarball
rm -fr boot/snapshot
rm -fr boot/chicken-6.0.0
rm -f  boot/chicken-6.0.0-bootstrap.tar.gz

echo
echo 'Now, build chicken by passing "--chicken ./chicken-boot" to "configure",'
echo 'in addition to PREFIX, PLATFORM, and other parameters.'
echo
