#!/bin/sh
# Assemble the on-CMU install folder from a release build:
#   tools/docker-build.sh release && tools/package.sh
# -> dist/hud-mod/ (copy to the unit or a USB stick and run install.sh) + dist/hud-mod.zip
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/dist/hud-mod
rm -rf "$OUT" && mkdir -p "$OUT"
for s in blmjcicarplay blmjciaapa svcjcinavi aap_service; do
    cp "$ROOT/mazda/build/release/libpatch-$s.so" "$OUT/"
done
cp "$ROOT/install/install.sh" "$ROOT/install/uninstall.sh" "$ROOT/install/libpatch.conf" \
   "$ROOT/resources/aap_system_attributes.xml" "$ROOT/resources/aap_system_attributes_UCP.xml" "$OUT/"
chmod 0755 "$OUT/install.sh" "$OUT/uninstall.sh"
( cd "$OUT" && md5 -r *.so 2>/dev/null || md5sum *.so ) > "$OUT/MD5SUMS"
( cd "$ROOT/dist" && rm -f hud-mod.zip && zip -qr hud-mod.zip hud-mod )
echo "packaged -> $OUT"
cat "$OUT/MD5SUMS"
