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

ARG DEBIAN=debian:trixie-slim

FROM ${DEBIAN} AS snapshot
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates gcc libc6-dev make wget \
 && rm -rf /var/lib/apt/lists/*
# Only this file, so the snapshot layer is reused until it changes
COPY scripts/bootstrap.sh /tmp/bootstrap.sh
RUN set -eu; \
    version=$(sed -n 's/^BOOTVERSION=//p' /tmp/bootstrap.sh); \
    url=$(sed -n 's/^BOOTURL=//p' /tmp/bootstrap.sh | sed "s/\${BOOTVERSION}/$version/"); \
    mkdir -p /boot && cd /boot; \
    wget -qO- "https://code.call-cc.org/dev-snapshots/$url" | tar -xz; \
    cd "chicken-$version"; \
    ./configure --prefix /boot/snapshot; \
    make -j"$(nproc)"; \
    make install

FROM snapshot AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN set -eu; \
    git config --global --add safe.directory /src; \
    ./configure --chicken /boot/snapshot/bin/chicken; \
    make -j"$(nproc)" boot-chicken; \
    make spotless; \
    ./configure --chicken ./chicken-boot --prefix /usr/local; \
    make -j"$(nproc)"; \
    make DESTDIR=/out install

FROM ${DEBIAN}
# csc and chicken-install need a C compiler at run time
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates gcc libc6-dev make \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/usr/local/ /usr/local/
RUN ldconfig \
 && csi -version \
 && printf '(import (chicken format))\n(printf "~a~%%" (+ 1 2))\n' >/tmp/t.scm \
 && csc /tmp/t.scm -o /tmp/t && test "$(/tmp/t)" = 3 \
 && rm -f /tmp/t /tmp/t.scm
CMD ["csi"]
