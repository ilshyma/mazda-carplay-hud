#!/bin/sh
# Assemble the on-CMU install folder from a release build:
#   tools/docker-build.sh release && tools/package.sh
# -> dist/hud-mod/ (copy to the unit or a USB stick and run install.sh) + dist/hud-mod.zip
#
#   tools/docker-build.sh BUILD_DIR=build-diag EXTRA_CXXFLAGS='-DHUD_NAV_DIAG -DLOG_LEVEL=1' release
#   tools/package.sh diag
# -> dist/hud-mod-diag/: ship code plus raw nav capture for the probe
#    (install/hud_probe.sh; nothing is written until the probe is started).
#
#   tools/docker-build.sh release blmjcicarplay-debug && tools/package.sh debug
# -> dist/hud-mod-debug/: same, but the CarPlay shim is the -O0 verbose build that
#    logs every decoded maneuver (incl. road="...") to /tmp/carplay_bridge.log.
#    In that build a maneuver with no HUD glyph shows "EV=.. S=.. A=.." in the
#    street line instead of a blank (on purpose, to extend the icon table).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=hud-mod
[ "${1:-}" = debug ] && NAME=hud-mod-debug
[ "${1:-}" = diag ] && NAME=hud-mod-diag
OUT=$ROOT/dist/$NAME
rm -rf "$OUT" && mkdir -p "$OUT"
for s in blmjcicarplay blmjciaapa svcjcinavi aap_service; do
    dir=build/release
    [ "$NAME" = hud-mod-debug ] && [ "$s" = blmjcicarplay ] && dir=build/debug
    [ "$NAME" = hud-mod-diag ] && dir=build-diag/release
    cp "$ROOT/mazda/$dir/libpatch-$s.so" "$OUT/"
done
cp "$ROOT/install/install.sh" "$ROOT/install/uninstall.sh" "$ROOT/install/hud_probe.sh" "$ROOT/install/libpatch.conf" \
   "$ROOT/resources/aap_system_attributes.xml" "$ROOT/resources/aap_system_attributes_UCP.xml" "$OUT/"
chmod 0755 "$OUT/install.sh" "$OUT/uninstall.sh" "$OUT/hud_probe.sh"
( cd "$OUT" && md5 -r *.so 2>/dev/null || md5sum *.so ) > "$OUT/MD5SUMS"
( cd "$ROOT/dist" && rm -f "$NAME.zip" && zip -qr "$NAME.zip" "$NAME" )
echo "packaged -> $OUT"
cat "$OUT/MD5SUMS"
