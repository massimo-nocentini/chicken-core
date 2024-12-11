#!/bin/sh

set -e

# build 6.0.0pre1 tarball

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
$getcmd https://code.call-cc.org/dev-snapshots/2024/12/09/chicken-6.0.0pre1.tar.gz
tar -xzf chicken-6.0.0pre1.tar.gz
cd chicken-6.0.0pre1
./configure --prefix "$(pwd)"/../snapshot
$mkcmd "$@"
$mkcmd "$@" install
cd ../..

# build a boot-chicken from git head using the snapshot
# chicken and then use that to build the real thing

./configure --chicken "$(pwd)"/boot/snapshot/bin/chicken
$mkcmd boot-chicken

# remove snapshot installation and tarball
rm -fr boot/snapshot
rm -fr boot/chicken-6.0.0pre1
rm -f  boot/chicken-6.0.0pre1.tar.gz

echo
echo 'Now, build chicken by passing "--chicken ./chicken-boot" to "configure",'
echo 'in addition to PREFIX, PLATFORM, and other parameters.'
echo
