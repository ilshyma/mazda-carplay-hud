#!/bin/bash
# Runs inside the container started by run.sh. Real dbus-daemon/dbus-monitor,
# busybox for everything else (like the CMU).
set -u
FAILS=0
check() { if eval "$1"; then echo "  ok   $2"; else echo "  FAIL $2"; FAILS=$((FAILS+1)); fi; }

mkdir -p /bb && busybox --install -s /bb
P="env PATH=/bb:/usr/bin:/bin busybox sh /src/install/hud_probe.sh"
mkdir -p /data_persist/oem-aa-mod /jci/sm /jci/navi
echo 'JCI_SW_VER="MAZ_CMU-150_74.00.324"' > /jci/version.ini
echo '<service name="jciAAPA"><environ_var env_name="LD_PRELOAD" env_value="/data_persist/oem-aa-mod/libpatch-blmjciaapa.so"/>' > /jci/sm/sm.conf
echo "force_street_name = true" > /data_persist/oem-aa-mod/libpatch.conf
echo "50 3" > /tmp/hud_oem_speed

for b in service hmi; do
  dbus-daemon --session --address=unix:path=/tmp/dbus_${b}_socket --fork --nopidfile >/dev/null
done
sleep 0.5
# stand-ins for the OEM service processes the sampler looks for
for n in L_jciCARPLAY L_jciAAPA L_jcinavi /usr/bin/aap_service; do (exec -a "$n" sleep 600) & done

sig() { dbus-send --address=unix:path=/tmp/dbus_service_socket --type=signal /com/NNG/Api/Server \
          com.NNG.Api.Server.Guidance.GuidanceChangedForHUD int32:3 int32:200 int32:1 string:"$1" \
          int32:50 int32:1 int32:0 int32:0 int32:0 int32:0 int32:0 int32:0 int32:0 int32:0; }
hud() { dbus-send --address=unix:path=/tmp/dbus_service_socket --type=method_call --dest=org.freedesktop.DBus \
          /com/jci/vbs/navi com.jci.vbs.navi.SetHUDDisplayMsgReq uint32:3 2>/dev/null; }
cpsig() { dbus-send --address=unix:path=/tmp/dbus_hmi_socket --type=signal /com/jci/carplay \
          com.jci.carplay.TurnByTurnEntitySignal uint32:$1; }

echo "[P1] start from a shell that exits right away (SSH session ending)"
sh -c "$P start 'test drive'" ; sleep 1
S=$(cat /tmp/hud-probe.session)
check '[ -d "$S" ]' "session dir $S"
check '[ $(pgrep -c dbus-monitor) = 4 ]' "4 dbus-monitor running after the starter exited"
sig "Oboronna"; hud; cpsig 1; sleep 0.3
mkdir -p /data_persist/hud-probe/live
echo "1.0 aa16 4 deadbeef" >> /data_persist/hud-probe/live/aa_nav.log   # what a diag shim writes
$P mark "AA Google Maps" >/dev/null
sleep 5
$P status | head -20

echo "[P2] stop -> one tar.gz with everything"
$P stop
T=$(ls /data_persist/hud-probe/session-*.tar.gz | head -1)
check '[ -f "$T" ]' "archive $T"
mkdir -p /x && tar xzf "$T" -C /x && D=/x/$(basename "$T" .tar.gz)
check 'grep -q "GuidanceChangedForHUD" $D/dbus_service.log && grep -q Oboronna $D/dbus_service.log' "NNG signal captured with street"
check 'grep -q "SetHUDDisplayMsgReq" $D/dbus_service.log' "HUD method call captured"
check 'grep -q "TurnByTurnEntitySignal" $D/dbus_hmi.log' "CarPlay TBT signal captured on HMI bus"
check '[ -s $D/dbus_service.profile ] || grep -q "profile" $D/errors.log' "profile (timestamps) captured or its absence logged"
check '[ $(wc -l < $D/state.log) -ge 2 ] && grep -q "speed=\[50 3\]" $D/state.log' "state samples with OEM speed"
check 'grep -q "PIDS cp/aa/nav/aas: [0-9]* [0-9]* [0-9]* [0-9]*" $D/events.log' "all 4 service PIDs found"
check 'grep -q "AA Google Maps" $D/marks.log && grep -q STOP $D/marks.log' "marks recorded"
check 'grep -q deadbeef $D/aa_nav.log' "diag shim log collected"
check '[ ! -d /data_persist/hud-probe/live ]' "live/ removed (diag shims stop writing)"
check 'grep -q "force_street_name = true" $D/meta.txt && grep -q LD_PRELOAD $D/meta.txt' "meta: config + preloads"
check '[ $(pgrep -c dbus-monitor) = 0 ] && ! pgrep -f "_sampler" >/dev/null' "no probe processes left"

echo "[P3] reboot mid-session -> packed on the next start"
$P start >/dev/null; sleep 3
S=$(cat /tmp/hud-probe.session)
pkill dbus-monitor; pkill -f _sampler; rm -f /tmp/hud-probe.session    # what a reboot does
$P start >/dev/null; sleep 1
check '[ -f "$S.tar.gz" ] && [ ! -d "$S" ]' "interrupted session packed"
check '[ -n "$(cat /tmp/hud-probe.session)" ]' "new session running"
$P stop >/dev/null

echo "[P4] clean refuses while running, works when stopped"
$P start >/dev/null
check '! $P clean >/dev/null' "clean refused while running"
$P stop >/dev/null; $P clean >/dev/null
check '[ -z "$(ls /data_persist/hud-probe/ 2>/dev/null | grep session)" ]' "sessions removed"

echo
[ $FAILS = 0 ] && echo "probe: all passed" || echo "probe: $FAILS FAILED"
exit $FAILS
