# syntax=docker/dockerfile:1
#
# CHICKEN Scheme built from a git checkout, installed in /usr/local.
#
# The build context is the root of a chicken-core checkout, including
# .git (identify.sh records the revision and branch from it); this
# file need not be inside it:
#
#     docker build -f .github/docker/Dockerfile -t chicken .
#
# A checkout has no C translations of the Scheme sources, so the build
# bootstraps as scripts/bootstrap.sh does: the release snapshot named
# there builds a chicken-boot from the checkout, which builds the rest.
#
# Everything is compiled and linked with clang.  configure records only
# the C compiler and the linker in config.make, and the boot-chicken
# stages run make with CONFIG= (no config.make), so the compilers and
# the linker are also given on every make command line, from which they
# reach the sub-makes through MAKEFLAGS.

# ubuntu:latest is multi-platform: each build pulls its own platform's image
ARG BASE=ubuntu:latest

FROM ${BASE} AS snapshot
ENV CC=clang CXX=clang++
ENV CLANG_MAKE="C_COMPILER=clang CXX_COMPILER=clang++ LINKER=clang"
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates clang libc6-dev make wget \
 && rm -rf /var/lib/apt/lists/*
# Only this file, so the snapshot layer is reused until it changes
COPY scripts/bootstrap.sh /tmp/bootstrap.sh
RUN set -eu; \
    version=$(sed -n 's/^BOOTVERSION=//p' /tmp/bootstrap.sh); \
    url=$(sed -n 's/^BOOTURL=//p' /tmp/bootstrap.sh | sed "s/\${BOOTVERSION}/$version/"); \
    mkdir -p /boot && cd /boot; \
    wget -qO- "https://code.call-cc.org/dev-snapshots/$url" | tar -xz; \
    cd "chicken-$version"; \
    ./configure --prefix /boot/snapshot --c-compiler clang --linker clang; \
    make -j"$(nproc)" $CLANG_MAKE; \
    make $CLANG_MAKE install

FROM snapshot AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN set -eu; \
    git config --global --add safe.directory /src; \
    ./configure --chicken /boot/snapshot/bin/chicken --c-compiler clang --linker clang; \
    make -j"$(nproc)" $CLANG_MAKE boot-chicken; \
    make $CLANG_MAKE spotless; \
    ./configure --chicken ./chicken-boot --prefix /usr/local --c-compiler clang --linker clang; \
    make -j"$(nproc)" $CLANG_MAKE; \
    make $CLANG_MAKE DESTDIR=/out install

FROM ${BASE}
# csc and chicken-install need a C compiler at run time: the clang the
# installed CHICKEN was configured with
ENV CC=clang CXX=clang++
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates clang libc6-dev make \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/usr/local/ /usr/local/
RUN ldconfig \
 && csi -version \
 && grep -q '# define C_INSTALL_CC "clang"' /usr/local/include/chicken/chicken-config.h \
 && grep -q '# define C_INSTALL_CXX "clang++"' /usr/local/include/chicken/chicken-config.h \
 && printf '(import (chicken format))\n(printf "~a~%%" (+ 1 2))\n' >/tmp/t.scm \
 && csc /tmp/t.scm -o /tmp/t && test "$(/tmp/t)" = 3 \
 && rm -f /tmp/t /tmp/t.scm
CMD ["csi"]
