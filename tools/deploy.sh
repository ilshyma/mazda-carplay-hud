#!/bin/sh
# Push the packaged mod to the CMU over the toolkit's SSH link and run it.
# Prerequisite: SSH up on the unit (USB unlock stick -> SSH, toolkit menu 1/9).
#
#   tools/deploy.sh install     copy dist/hud-mod, run install.sh, reboot
#   tools/deploy.sh uninstall   run uninstall.sh, reboot
#   tools/deploy.sh status      what is loaded where + live hand-off state
#
#   tools/deploy.sh roads       follow CarPlay road names live (debug CarPlay build)
#
#   tools/deploy.sh probe start [label]   record a drive (install/hud_probe.sh)
#   tools/deploy.sh probe mark <text>     timestamped note during the drive
#   tools/deploy.sh probe status|stop|list|clean
#   tools/deploy.sh probe fetch           copy finished sessions to $PROBE_OUT
#   tools/deploy.sh sysdump               CMU libraries/binaries for QEMU tests
#
# HUD_PKG  package folder to install (default dist/hud-mod; e.g. dist/hud-mod-debug)
# CMU_KEY  ssh key for the cmu account (default: the toolkit's id_rsa_cmu)
# CMU      user@host  (default cmu@192.168.53.1, the unit's Wi-Fi AP)
# PROBE_OUT  where fetched sessions / sysdumps go (default ~/Documents/mazda-hud-install/logs/hud-probe)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEY=${CMU_KEY:-$HOME/Documents/mazda-hud-install/mazda-hud-toolkit/id_rsa_cmu}
CMU=${CMU:-cmu@192.168.53.1}
PORT=36000
PKG=${HUD_PKG:-$ROOT/dist/hud-mod}
PROBE_OUT=${PROBE_OUT:-$HOME/Documents/mazda-hud-install/logs/hud-probe}
PROBE=/data_persist/hud-probe/hud_probe.sh
[ -f "$KEY" ] || { echo "ssh key not found: $KEY (set CMU_KEY)"; exit 1; }
chmod 600 "$KEY" 2>/dev/null || true
OPTS="-i $KEY -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o ConnectTimeout=15"
ssh_cmu() { ssh $OPTS -p $PORT "$CMU" "$@"; }

case "${1:-}" in
install)
    [ -f "$PKG/install.sh" ] || { echo "no package — run tools/docker-build.sh release && tools/package.sh"; exit 1; }
    ssh_cmu 'rm -rf /tmp/hud-mod && mkdir -p /tmp/hud-mod'
    scp $OPTS -P $PORT "$PKG"/* "$CMU:/tmp/hud-mod/"
    # Verify every shim landed intact before touching the sm config.
    ssh_cmu 'cd /tmp/hud-mod && md5sum *.so' | awk '{print $1, $2}' | sort > /tmp/hud-mod.remote.$$
    sort "$PKG/MD5SUMS" | awk '{print $1, $2}' > /tmp/hud-mod.local.$$
    if ! cmp -s /tmp/hud-mod.local.$$ /tmp/hud-mod.remote.$$; then
        echo "md5 mismatch after copy:"; diff /tmp/hud-mod.local.$$ /tmp/hud-mod.remote.$$ || true
        rm -f /tmp/hud-mod.*.$$; exit 1
    fi
    rm -f /tmp/hud-mod.*.$$
    ssh_cmu 'cd /tmp/hud-mod && sh install.sh'
    printf "reboot the unit now? [y/N] "; read a
    [ "$a" = y ] && ssh_cmu 'sync; reboot' || true
    ;;
uninstall)
    scp $OPTS -P $PORT "$ROOT/install/uninstall.sh" "$CMU:/tmp/hud-mod-uninstall.sh"
    ssh_cmu 'sh /tmp/hud-mod-uninstall.sh'
    printf "reboot the unit now? [y/N] "; read a
    [ "$a" = y ] && ssh_cmu 'sync; reboot' || true
    ;;
status)
    ssh_cmu sh -s <<'REMOTE'
pid_of() { ps | awk -v p="$1" 'index($0, p) && !/awk/ { print $1; exit }'; }
for svc in L_jciCARPLAY L_jciAAPA L_jcinavi /usr/bin/aap_service; do
  pid=$(pid_of "$svc")
  so=$(grep -o 'libpatch-[a-z_]*\.so' "/proc/$pid/maps" 2>/dev/null | sort -u | tr '\n' ' ')
  echo "$svc pid=${pid:-none} shim=${so:-NOT LOADED}"
done
echo "OEM speed (svcjcinavi -> CarPlay): $(cat /tmp/hud_oem_speed 2>/dev/null || echo 'none yet')"
if [ -f /tmp/hud_carplay_active ]; then
  echo "CarPlay owns HUD: marker ts=$(cat /tmp/hud_carplay_active) now=$(date +%s)"
else
  echo "CarPlay owns HUD: no"
fi
echo "--- /tmp/carplay_bridge.log (tail)"
tail -n 15 /tmp/carplay_bridge.log 2>/dev/null
REMOTE
    ;;
roads)
    # Debug CarPlay build only: decoded maneuvers + the street sent to the HUD.
    # busybox grep has no --line-buffered; awk fflush keeps it live over ssh.
    ssh_cmu "tail -f /tmp/carplay_bridge.log | awk '/nav HUD|road=/ { print; fflush() }'"
    ;;
probe)
    shift
    case "${1:-}" in
    fetch)
        mkdir -p "$PROBE_OUT"
        files=$(ssh_cmu 'ls /data_persist/hud-probe/*.tar.gz 2>/dev/null' || true)
        [ -n "$files" ] || { echo "no finished sessions on the unit (probe stop first)"; exit 1; }
        for f in $files; do
            scp $OPTS -P $PORT "$CMU:$f" "$PROBE_OUT/" && echo "fetched $PROBE_OUT/$(basename "$f")"
        done
        echo "delete them on the unit with: tools/deploy.sh probe clean"
        ;;
    start)
        # always run the probe version from this checkout
        ssh_cmu 'mkdir -p /data_persist/hud-probe'
        scp $OPTS -P $PORT "$ROOT/install/hud_probe.sh" "$CMU:$PROBE"
        shift; ssh_cmu "sh $PROBE start '$*'"
        ;;
    mark)
        shift; ssh_cmu "[ -f $PROBE ] && sh $PROBE mark '$*' || echo 'пробник не запущен: tools/deploy.sh probe start'" ;;
    status|stop|list|clean)
        ssh_cmu "[ -f $PROBE ] && sh $PROBE $1 || echo 'пробник ещё ни разу не запускали на этом блоке: tools/deploy.sh probe start'" ;;
    *)
        sed -n '2,24p' "$0"; exit 1 ;;
    esac
    ;;
sysdump)
    # Everything the shims link or interpose, for QEMU-based tests at home.
    # Fetched in parts with live progress; a re-run resumes at the first
    # missing/broken part. Result: $PROBE_OUT/cmu_sysdump_<date>/NN-<part>.tar.gz
    PARTS='lib|lib
usr-lib|usr/lib/libstdc++* usr/lib/libdbus* usr/lib/libdevmgr* usr/lib/libaap*
jci-lib|jci/lib
jci-apps|jci/aapa jci/carplay jci/navi jci/sm jci/version.ini
bin-etc|usr/bin/aap_service usr/bin/carplayd etc/aap_system_attributes*.xml etc/devmgr_config_master.xml'
    WORK=$PROBE_OUT/cmu_sysdump.part
    mkdir -p "$WORK"
    ssh_cmu true 2>/dev/null || { echo "✗ CMU не отвечает по SSH (подними SSH флешкой, Mac на Wi-Fi машины?)"; exit 1; }

    echo "Считаю размеры на CMU…"
    i=0
    printf '%s\n' "$PARTS" | while IFS='|' read -r name paths; do
        i=$((i + 1))
        # < /dev/null: ssh must not eat the rest of the part list on stdin
        kb=$(ssh_cmu "cd / && du -ck $paths 2>/dev/null | tail -n 1" < /dev/null | awk '{print $1}')
        echo "$i|$name|$paths|${kb:-0}"
    done > "$WORK/plan"
    total_kb=$(awk -F'|' '{s += $4} END {print s}' "$WORK/plan")
    nparts=$(wc -l < "$WORK/plan" | tr -d ' ')
    awk -F'|' '{printf "  [%s] %-9s %6.1f MB\n", $1, $2, $4 / 1024}' "$WORK/plan"
    echo "  всего ~$((total_kb / 1024)) MB до сжатия (передаётся меньше)"

    pid=""
    trap 'kill $pid 2>/dev/null; echo; echo "прервано — запусти sysdump ещё раз, продолжит с этой части"; exit 1' INT TERM
    done_kb=0; start_all=$(date +%s)
    while IFS='|' read -r i name paths kb; do
        f=$WORK/$(printf '%02d' "$i")-$name.tar.gz
        if [ -s "$f" ] && tar tzf "$f" > /dev/null 2>&1; then
            echo "[$i/$nparts] $name — уже скачано, пропускаю"
            done_kb=$((done_kb + kb)); continue
        fi
        echo "[$i/$nparts] $name ($((kb / 1024)) MB)…"
        ssh_cmu "cd / && tar czf - $paths 2>/dev/null" > "$f.tmp" < /dev/null &
        pid=$!
        t0=$(date +%s)
        while kill -0 "$pid" 2>/dev/null; do
            sleep 5
            got=$(($(wc -c < "$f.tmp") / 1024)); dt=$(($(date +%s) - t0))
            [ "$dt" -gt 0 ] && awk -v g="$got" -v dt="$dt" 'BEGIN {
                printf "      %6.1f MB получено, %4d KB/s, %d:%02d\n", g / 1024, g / dt, dt / 60, dt % 60 }'
            :
        done
        if wait "$pid" && tar tzf "$f.tmp" > /dev/null 2>&1; then
            mv "$f.tmp" "$f"
            done_kb=$((done_kb + kb))
            echo "      ✓ $(du -h "$f" | cut -f1 | tr -d ' ') за $(($(date +%s) - t0)) с — готово $((done_kb * 100 / (total_kb > 0 ? total_kb : 1)))%"
        else
            rm -f "$f.tmp"
            echo "      ✗ часть $name не скачалась (обрыв SSH?) — запусти sysdump ещё раз, продолжит отсюда"
            exit 1
        fi
    done < "$WORK/plan"
    trap - INT TERM

    out=$PROBE_OUT/cmu_sysdump_$(date +%Y%m%d-%H%M%S)
    rm -f "$WORK/plan"
    mv "$WORK" "$out"
    echo "✓ готово за $(( ($(date +%s) - start_all) / 60 )) мин: $out ($(du -sh "$out" | cut -f1 | tr -d ' '))"
    ;;
*)
    sed -n '2,24p' "$0"; exit 1 ;;
esac
