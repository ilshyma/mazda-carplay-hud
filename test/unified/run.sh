#!/bin/sh
# Host integration test for the CarPlay <-> svcjcinavi hand-off (see harness.cpp).
# Runs in an x86_64 Debian container: it needs to create /jci/navi/svcjcinavi.so
# (the merge shim's self-gate path) and /data_persist, which a host must not.
#   test/unified/run.sh
#   SAN=thread  test/unified/run.sh     ThreadSanitizer (sender / producer / HMI-callback threads)
#   SAN=address test/unified/run.sh     AddressSanitizer + UBSan
#   DIAG=1      test/unified/run.sh     diag build: also checks the merge shim's capture log
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
case "${SAN:-}" in
    "")      SANFLAGS="" ;;
    thread)  SANFLAGS="-fsanitize=thread" ;;
    address) SANFLAGS="-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer" ;;
    *) echo "SAN must be thread or address"; exit 2 ;;
esac
# TSan needs ASLR off (setarch -R) on current kernels; personality() needs seccomp relaxed.
[ -n "${DIAG:-}" ] && SANFLAGS="$SANFLAGS -DHUD_NAV_DIAG"
exec docker run --rm --platform linux/amd64 -e SANFLAGS="$SANFLAGS" -e DIAG="${DIAG:-}" \
    --security-opt seccomp=unconfined -e RUNNER="${SAN:+setarch x86_64 -R}" \
    -e TSAN_OPTIONS="halt_on_error=0 second_deadlock_stack=1 suppressions=/src/test/unified/tsan.supp" \
    -e ASAN_OPTIONS="detect_leaks=0" \
    -v "$ROOT":/src:ro debian:bookworm-slim sh -ec '
  apt-get update -qq >/dev/null && apt-get install -y -qq g++ >/dev/null 2>&1
  P=/src/mazda/patches; T=/src/test/unified; B=/tmp/b; mkdir -p $B /jci/navi
  F="-O1 -g -Wall -Wextra -Wno-unused-parameter -DLOG_LEVEL=2 $SANFLAGS"
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
  if [ -n "$DIAG" ]; then
    LD_LIBRARY_PATH=$B $RUNNER ./harness coop > /dev/null 2>&1   # no live/ dir: must write nothing
    [ ! -e /data_persist/hud-probe ] && echo "diag: nothing written without the probe dir" || { echo "diag: FAIL wrote without probe dir"; rc=1; }
    mkdir -p /data_persist/hud-probe/live
  fi
  # the merge shim reads libpatch.conf next to itself, once per process
  LD_LIBRARY_PATH=$B $RUNNER ./harness coop   || rc=1
  echo
  LD_LIBRARY_PATH=$B $RUNNER ./harness legacy || rc=1
  echo
  printf "force_street_name = true\nforce_street_name_native = true\n" > $B/libpatch.conf
  LD_LIBRARY_PATH=$B $RUNNER ./harness street || rc=1
  echo
  printf "force_street_name = false\nforce_street_name_native = false\n" > $B/libpatch.conf
  LD_LIBRARY_PATH=$B $RUNNER ./harness street_off || rc=1
  if [ -n "$DIAG" ]; then
    L=/data_persist/hud-probe/live/merge.log
    echo; echo "diag capture ($(wc -l < $L) lines):"
    for a in oem-dropped oem-native-unblank aa-frame oem-spliced-aa pass; do
      n=$(grep -c " $a - " $L); echo "  $a: $n"; [ "$n" -gt 0 ] || rc=1
    done
    grep -m1 " oem-native-unblank - " $L | sed "s/^/  e.g. /"
  fi
  exit $rc
'
