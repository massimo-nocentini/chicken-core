#!/bin/sh

set -e

# When cd is given as argument a directory that cannot be found in the
# paths yielded by CDPATH on OpenBSD's ksh (same binary as sh), it
# fails with
#     `sh: cd: <the dir>: bad directory'
# So, we unset CDPATH to avoid such problems.
unset CDPATH

BOOTVERSION=6.0.0rc3
BOOTURL=2026/05/12/chicken-${BOOTVERSION}.tar.gz

getcmd="wget -c"
mkcmd=make
case "$(uname)" in
    FreeBSD)
        mkcmd=gmake
	# FreeBSD's ftp doesn't support HTTPS (only HTTP)
        getcmd=fetch;;
    *BSD)
	# Counter-intuitively, the ftp(1) program on many
	# BSDs supports both HTTP(S) and FTP
        getcmd=ftp
        mkcmd=gmake;;
esac

mkdir -p boot/snapshot
cd boot
$getcmd https://code.call-cc.org/dev-snapshots/$BOOTURL
tar -xzf chicken-${BOOTVERSION}.tar.gz
cd chicken-${BOOTVERSION}
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
rm -fr boot/chicken-${BOOTVERSION}
rm -f  boot/chicken-${BOOTVERSION}.tar.gz

echo
echo 'Now, build chicken by passing "--chicken ./chicken-boot" to "configure",'
echo 'in addition to "--prefix ..." and additional parameters.'
echo
