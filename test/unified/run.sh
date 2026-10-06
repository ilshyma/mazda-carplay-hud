#!/bin/sh
# Host integration test for the CarPlay <-> svcjcinavi hand-off (see harness.cpp).
# Runs in an x86_64 Debian container: it needs to create /jci/navi/svcjcinavi.so
# (the merge shim's self-gate path) and /data_persist, which a host must not.
#   test/unified/run.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec docker run --rm --platform linux/amd64 -v "$ROOT":/src:ro debian:bookworm-slim sh -ec '
  apt-get update -qq >/dev/null && apt-get install -y -qq g++ >/dev/null 2>&1
  P=/src/mazda/patches; T=/src/test/unified; B=/tmp/b; mkdir -p $B /jci/navi
  F="-O1 -g -Wall -Wextra -Wno-unused-parameter -DLOG_LEVEL=2"
  gcc $F -shared -fPIC $T/fake_vbs.c        -o $B/libjcivbsnaviclient.so -lpthread
  gcc $F -shared -fPIC $T/fake_jcidbus.c    -o $B/libjcidbus.so
  gcc $F -shared -fPIC $T/fake_svcjcinavi.c -o /jci/navi/svcjcinavi.so \
      -Wl,--section-start=.anchor=0x19008 -Wl,--section-start=.streetbuf=0xaab98
  g++ $F -std=c++11 -shared -fPIC -I$P $P/svcjcinavi/merge.cpp -o $B/libpatch-svcjcinavi.so -ldl
  g++ $F -std=c++11 -I$P -DCARPLAY_NO_UDPD_LAUNCH -DCARPLAY_VN_NORMALIZE=1 \
      $T/harness.cpp $P/blmjcicarplay/hud/hud_send.cpp \
      $P/blmjcicarplay/oem/libjcidbus.cpp $P/blmjcicarplay/oem/libjcivbsnaviclient.cpp \
      -L$B -Wl,--no-as-needed -lpatch-svcjcinavi -ljcivbsnaviclient -ldl -lpthread -o $B/harness
  cd $B
  nm -D /jci/navi/svcjcinavi.so | grep -E "GetServiceInterfaces|current_StreetName"
  rc=0
  # the merge shim reads libpatch.conf next to itself, once per process
  LD_LIBRARY_PATH=$B ./harness coop   || rc=1
  echo
  LD_LIBRARY_PATH=$B ./harness legacy || rc=1
  echo
  printf "force_street_name = true\nforce_street_name_native = true\n" > $B/libpatch.conf
  LD_LIBRARY_PATH=$B ./harness street || rc=1
  echo
  printf "force_street_name = false\nforce_street_name_native = false\n" > $B/libpatch.conf
  LD_LIBRARY_PATH=$B ./harness street_off || rc=1
  exit $rc
'
