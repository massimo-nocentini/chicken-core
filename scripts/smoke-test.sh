#! /bin/sh

set -e

ALL_GOOD="========== ALL GOOD! =========="

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|-help|--help]

This script runs basic tests on the chicken-core repository:

* Creates a distribution tarball with the Scheme code compiled to C.
* Extracts, builds, installs and tests the code from the distribution
  tarball.
* Uses CHICKEN installed out of the distribution tarball to install
  salmonella, and uses it to test an egg with dependencies.

If everything goes well, you should see

$ALL_GOOD

printed to stdout and the script will exit 0.

The following environment variables are considered by this script:

* CHICKEN: path to the chicken executable to be used to compile Scheme
  code to C.  By default, chicken will be used from \$PATH.

* MAKE_JOBS: the maximum number of make jobs to use.  On systems where
  the nproc program is available, its output will be used by default,
  otherwise 1 will be used.

* C_COMPILER: the C compiler to use.  The default is gcc on Linux and
  cc on BSDs.

* EGGS: eggs to be used as input for salmonella (space-separated, in
  case of multiple eggs).  By default, the base64 egg will be used.
  Note that, unless you tweak setup.defaults to configure
  chicken-install to use egg sources from a local filesystem, testing
  the installation of eggs requires Internet access.  If you want to
  skip the egg installation test, set this variable to ":".
EOF
}

[ "$1" = "-h" ] || [ "$1" = "-help" ] || [ "$1" = "--help" ] && {
    usage
    exit 0
}

set -x

chicken=${CHICKEN:-chicken}
c_compiler=${C_COMPILER:-gcc}
make="make"

if command -v nproc >/dev/null; then
    make_jobs=${MAKE_JOBS:-$(nproc)}
else
    make_jobs=${MAKE_JOBS:-1}
fi

case "$(uname)" in
    *BSD)
        c_compiler=${C_COMPILER:-cc}
        make=gmake
        ;;
esac

# manual-labor is needed by make dist to generate the HTML files of
# the manual
command -v manual-labor >/dev/null || {
    set +x
    echo "[ERROR] manual-labor could not be found. \
Install it with chicken-install and/or make sure its location is in \$PATH." >&2
    exit 1
}

# Using a directory in the current directory as /tmp might be mounted
# on a filesystem that disallows execution
tmpdir=$(mktemp -p "$PWD" -d smoke-test-XXXXXX)

./configure --chicken "$chicken"
"$make" dist -j "$make_jobs"

tarball_basename=chicken-$(cat buildversion)
tarball=${tarball_basename}.tar.gz

mv "$tarball" "$tmpdir"
cd "$tmpdir"
tar xzf "$tarball"
cd "$tarball_basename"
./configure --prefix "$PWD/../chicken" --chicken "$chicken" --c-compiler "$c_compiler"
"$make" -j "$make_jobs"
"$make" install
"$make" check

eggs=${EGGS:-base64}
# : is not a valid egg name
if [ "$eggs" != ":" ]; then
    ../chicken/bin/chicken-install -v salmonella
    # shellcheck disable=SC2086
    ../chicken/bin/salmonella $eggs
fi

set +x
echo "$ALL_GOOD"
