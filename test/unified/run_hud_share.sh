#!/bin/sh
# Edge-case tests for common/hud_share.h (bad file contents, symlinks, clock
# jumps, unprivileged writer, full /tmp). Throwaway containers only.
#   test/unified/run_hud_share.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/test/unified/.work/bin
mkdir -p "$OUT"
rc=0
# ASan needs ASLR off (setarch -R) on current kernels, hence seccomp=unconfined.
docker run --rm --platform linux/amd64 --security-opt seccomp=unconfined \
    -v "$ROOT":/src:ro -v "$OUT":/out debian:bookworm-slim sh -ec '
  apt-get update -qq >/dev/null && apt-get install -y -qq g++ >/dev/null 2>&1
  mkdir -p /b
  g++ -std=c++11 -O1 -g -Wall -Wextra -fsanitize=address,undefined -I/src/mazda/patches \
      /src/test/unified/hud_share_test.cpp -o /b/hud_share_test
  g++ -std=c++11 -O1 -g -Wall -Wextra -static -I/src/mazda/patches \
      /src/test/unified/hud_share_test.cpp -o /out/hud_share_test_static
  chmod 755 /b /b/hud_share_test
  setarch x86_64 -R /b/hud_share_test
  echo "50 3" > /tmp/hud_oem_speed; echo 1790000000 > /tmp/hud_carplay_active
  chmod 644 /tmp/hud_oem_speed /tmp/hud_carplay_active; chmod 1777 /tmp
  su nobody -s /bin/sh -c "setarch x86_64 -R /b/hud_share_test nonroot"' || rc=1
docker run --rm --platform linux/amd64 --tmpfs /tmp:size=64k -v "$OUT":/out:ro debian:bookworm-slim sh -ec '
  dd if=/dev/zero of=/tmp/fill bs=1k count=1000 2>/dev/null || true
  /out/hud_share_test_static full' || rc=1
exit $rc
