#!/bin/sh
# Installer/uninstaller scenarios against a real CMU config dump, in busybox.
#   test/install/run.sh [CMU_DUMP_DIR]
# CMU_DUMP_DIR must contain jci/sm/sm.conf, jci/sm/sm_WCP.conf, jci/version.ini,
# jci/navi/svcjcinavi.so and etc/devmgr_config_master.xml (OEM files are not
# part of this repo). Build the package first: tools/package.sh.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DUMP=${1:-${CMU_DUMP:-$HOME/Documents/mazda-hud-install/analysis/cmu}}
[ -f "$DUMP/jci/sm/sm.conf" ] || { echo "no CMU dump at $DUMP"; exit 2; }
[ -f "$ROOT/dist/hud-mod/install.sh" ] || { echo "no package: run tools/package.sh"; exit 2; }
W=$ROOT/test/install/.work
rm -rf "$W" && mkdir -p "$W/aapxml/stock" "$W/aapxml/patched"
# Stock AA attribute XMLs = upstream's first commit of them (before any patch).
for x in aap_system_attributes.xml aap_system_attributes_UCP.xml; do
    git -C "$ROOT" show 9ab4b01:resources/$x > "$W/aapxml/stock/$x"
    cp "$ROOT/resources/$x" "$W/aapxml/patched/$x"
done
exec docker run --rm -v "$DUMP":/dump:ro -v "$ROOT/dist/hud-mod":/pkg:ro -v "$W/aapxml":/aapxml:ro \
    -v "$ROOT/test/install/scenarios.sh":/scenarios.sh:ro busybox:latest sh /scenarios.sh
