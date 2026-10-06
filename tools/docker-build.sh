#!/bin/sh
# Cross-compile every shim inside an x86_64 Debian container (the
# m3-toolchain binaries are x86_64 Linux ELF, so they cannot run on macOS).
#
#   tools/docker-build.sh                 # make -C mazda release
#   tools/docker-build.sh all             # any make target(s)
#   M3TOOLCHAIN_DIR=/path tools/docker-build.sh
#
# M3TOOLCHAIN_DIR defaults to the initialised submodule (mazda/m3-toolchain);
# point it at any other checkout of lmagder/m3-toolchain to skip the
# submodule download. It is bind-mounted read-only over mazda/m3-toolchain.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TC=${M3TOOLCHAIN_DIR:-$ROOT/mazda/m3-toolchain}
if [ ! -x "$TC/bin/arm-cortexa9_neon-linux-gnueabi-g++" ]; then
    echo "m3-toolchain not found at $TC" >&2
    echo "run: git submodule update --init mazda/m3-toolchain   (or set M3TOOLCHAIN_DIR)" >&2
    exit 1
fi

[ $# -gt 0 ] || set -- release

exec docker run --rm --platform linux/amd64 \
    -v "$ROOT":/src \
    -v "$TC":/src/mazda/m3-toolchain:ro \
    -w /src \
    debian:bookworm-slim \
    sh -c 'command -v make >/dev/null || { apt-get update -qq && apt-get install -y -qq make >/dev/null; }; make -C mazda "$@"' sh "$@"
