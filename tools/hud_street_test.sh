#!/bin/sh
# One-shot HUD street-line test (engine running, SSH up). ~25 s.
#
# For Hud_Type 2 (windshield HUD of the CX-9) the HUD's navigation display
# mode is pushed from /com/jci/blm/settings/HUD/StreetInformation
# (svcjciblmsettings: 1 Always -> HEC 0xb=0x21, 2 On demand -> 0x22,
# 3 Off -> 0x23). This cycles the three values, each with a "turn in 20 m"
# frame whose street reads "MODE <n> ...", then restores the original value.
# CHudNavigation (unused for Hud_Type 2) is put back to its EU default 3.
#
#   tools/hud_street_test.sh            # watch the HUD, note which MODE shows a street
#   KEEP=1 tools/hud_street_test.sh     # keep StreetInformation=1 afterwards
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEY=${CMU_KEY:-$HOME/Documents/mazda-hud-install/mazda-hud-toolkit/id_rsa_cmu}
OPTS="-i $KEY -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o ConnectTimeout=15"
CMU=${CMU:-cmu@192.168.53.1}
nc -z -G 3 192.168.53.1 36000 >/dev/null 2>&1 || { echo "CMU SSH недоступен (флешка, Wi-Fi машины?)"; exit 1; }
# shellcheck disable=SC2086
scp -q $OPTS -P 36000 "$ROOT/test/build/hud_setting" "$CMU:/tmp/hud_setting"
# shellcheck disable=SC2086
ssh $OPTS -p 36000 "$CMU" "KEEP=${KEEP:-}" sh -s <<'REMOTE'
chmod +x /tmp/hud_setting
S=/tmp/hud_setting
BUS=unix:path=/tmp/dbus_service_socket
get() { $S "$1" 2>/dev/null | awk -v k="$1" '$1 == k {print $3}'; }
frame() {  # AA-tagged so it shows even while Android Auto owns the HUD
  dbus-send --address=$BUS --type=signal /com/NNG/Api/Server com.NNG.Api.Server.Guidance.GuidanceChangedForHUD \
    int32:$1 int32:$2 int32:$3 string:"$4" int32:65535 int32:0 \
    int32:0 int32:0 int32:0 int32:0 int32:0 int32:0 int32:0 int32:0
}
orig=$(get StreetInformation)
echo "StreetInformation was ${orig:-?}; Hud_Type=$(get Hud_Type) NavigationSignal=$(get NavigationSignal) CHudNavigation=$(get CHudNavigation)"
$S CHudNavigation 3 > /dev/null 2>&1
for m in "1 ALWAYS" "2 ON DEMAND" "3 OFF"; do
  v=${m%% *}
  $S StreetInformation "$v" > /dev/null 2>&1
  echo "MODE $m  (StreetInformation=$(get StreetInformation))"
  sleep 2
  i=0; while [ $i -lt 24 ]; do frame 3 200 1 "MODE $m"; usleep 250000; i=$((i+1)); done
done
frame 0 0 0 ""
final=${orig:-2}; [ -n "$KEEP" ] && final=1
$S StreetInformation "$final" > /dev/null 2>&1
echo "restored: StreetInformation=$(get StreetInformation) CHudNavigation=$(get CHudNavigation)"
REMOTE
