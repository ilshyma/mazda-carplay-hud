#!/bin/sh
# Does the HUD module accept the street-name display mode? (~20 s, engine on)
#
# svcjciblmsettings turns StreetInformation into HEC customize item 0xb
# (com.jci.vbs.settings SetHECCustomizeRequest1); the HUD ECU reports its
# settings back in HECCustomizeRespPart, whose Nav_GPD_Timg field is the
# guidance-point (street) display timing. This toggles StreetInformation
# 1 -> 3 -> original while recording that interface, then prints what the
# CMU sent and what the HUD answered.
#
#   tools/hud_hec_probe.sh
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEY=${CMU_KEY:-$HOME/Documents/mazda-hud-install/mazda-hud-toolkit/id_rsa_cmu}
OPTS="-i $KEY -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o ConnectTimeout=15"
CMU=${CMU:-cmu@192.168.53.1}
OUT=${PROBE_OUT:-$HOME/Documents/mazda-hud-install/logs/hud-probe}/hec_$(date +%Y%m%d-%H%M%S).log
mkdir -p "$(dirname "$OUT")"
nc -z -G 3 192.168.53.1 36000 >/dev/null 2>&1 || { echo "CMU SSH недоступен (флешка, Wi-Fi машины?)"; exit 1; }
# shellcheck disable=SC2086
scp -q $OPTS -P 36000 "$ROOT/test/build/hud_setting" "$CMU:/tmp/hud_setting"
echo "запись ~20 с, мотор должен быть заведён…"
# shellcheck disable=SC2086
ssh $OPTS -p 36000 "$CMU" sh -s > "$OUT" 2>&1 <<'REMOTE'
chmod +x /tmp/hud_setting
S=/tmp/hud_setting
get() { $S "$1" 2>/dev/null | awk -v k="$1" '$1 == k {print $3}'; }
orig=$(get StreetInformation); orig=${orig:-2}
dbus-monitor --address unix:path=/tmp/dbus_service_socket "interface='com.jci.vbs.settings'" > /tmp/hec.mon 2>&1 &
MON=$!
sleep 2
for v in 1 3 "$orig"; do
  echo "@@MARK set StreetInformation=$v at $(cut -d' ' -f1 /proc/uptime)" >> /tmp/hec.mon
  $S StreetInformation "$v" > /dev/null 2>&1
  sleep 5
done
kill $MON
cat /tmp/hec.mon
echo "@@FINAL StreetInformation=$(get StreetInformation)"
REMOTE
echo "сырая запись: $OUT"
python3 - "$OUT" <<'EOF'
import re, sys
FIELDS = {
  'HECCustomizeRespPart': 'contents status Afs_OnOff SpLmt_OnOff SpLmt_Caution SpLmt_SpLvl Nav_GPD_Timg HUD_TA_OnOff HUD_Gsi_OnOff SpeedAlarm BSM_OnOff'.split(),
}
lines = open(sys.argv[1], errors='replace').read().splitlines()
msgs, cur = [], None
for l in lines:
    if l.startswith('@@'):
        msgs.append(('MARK', l[2:], [])); cur = None; continue
    m = re.match(r'(signal|method call|method return|error).*?member=(\w+)', l)
    if m:
        cur = (m.group(1), m.group(2), []); msgs.append(cur); continue
    if l.startswith('method return'):
        cur = ('return', '', []); msgs.append(cur); continue
    v = re.match(r'\s+(byte|uint\d+|int\d+|boolean)\s+(\S+)', l)
    if v and cur is not None:
        cur[2].append(int(v.group(2)) if v.group(2).lstrip('-').isdigit() else v.group(2))
seen = False
for kind, member, vals in msgs:
    if kind == 'MARK':
        print('\n>>', member); continue
    if not member or member in ('NameAcquired', 'NameLost'):
        continue
    seen = True
    names = FIELDS.get(member)
    if names and len(vals) >= len(names):
        pairs = ', '.join(f'{n}={vals[i]}' for i, n in enumerate(names))
        print(f'   HUD  {member}: {pairs}')
    else:
        who = 'CMU ' if kind == 'method call' else 'HUD ' if kind == 'signal' else '    '
        print(f'   {who} {member} {vals}')
if not seen:
    print('\n(ни одного сообщения com.jci.vbs.settings — HUD/VBS не ответил)')
EOF
