#!/bin/sh
# hud_probe.sh against real dbus-daemon/dbus-monitor, busybox userland.
#   test/probe/run.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec docker run --rm --platform linux/amd64 -v "$ROOT":/src:ro debian:bookworm-slim sh -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq dbus busybox procps >/dev/null 2>&1
  bash /src/test/probe/scenario.sh'
