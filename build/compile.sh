#!/usr/bin/env bash
# Configure + compile one copy of the nginx source.
# usage: compile.sh <build-name> [extra ./configure args...]
# env:   MAKE_TARGET=modules  -> only build the dynamic modules
set -euo pipefail

name=$1; shift
mapfile -t args < /build/configure-args     # the original's ./configure args, one per line

cp -a /src/nginx "/build/$name"             # fresh copy, so builds don't share object files
cd "/build/$name"
./configure "${args[@]}" "$@"

# OpenSSL was already built once in the Dockerfile. nginx's makefile rebuilds it
# whenever ssl.h is older than the freshly generated objs/Makefile, so mark it
# as newer to make nginx reuse the existing build.
ssl_h=/src/openssl/.openssl/include/openssl/ssl.h
[ -f "$ssl_h" ] && touch "$ssl_h"

make -j"$(nproc)" ${MAKE_TARGET:-}
