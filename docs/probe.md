# Recording a test drive (CarPlay + Android Auto)

`install/hud_probe.sh` records everything needed to judge the HUD path for
both phones and to replay the phones' navigation at home. Use it with the
diag package, which adds the raw capture to the ship code.

## Before the drive (at the car, SSH up)

```sh
tools/docker-build.sh BUILD_DIR=build-diag EXTRA_CXXFLAGS='-DHUD_NAV_DIAG -DLOG_LEVEL=1' release
tools/package.sh diag
HUD_PKG=dist/hud-mod-diag tools/deploy.sh install      # reboot, then SSH again
tools/deploy.sh sysdump                                # once: CMU libs for QEMU tests
tools/deploy.sh status                                 # 4 shims loaded?
tools/deploy.sh probe start "drive 1"
```

The probe keeps running when the laptop disconnects and stops at the next
reboot. Data written up to a reboot or crash is kept and packed on the next
`probe start`.

## During the drive

Add a `probe mark` whenever the source changes, if someone can type:

```sh
tools/deploy.sh probe mark "AA wired, Google Maps route"
```

Cover, in any order:

| # | What | Answers |
|---|------|---------|
| 1 | Android Auto (wired), Google Maps route, a few turns | does svcjcinavi forward AA frames or zero the arrow; OEM speed spliced; lanes (GAL 1.6); street |
| 2 | Android Auto, Waze route | same, other app |
| 3 | CarPlay, Apple Maps route | maneuvers, road names from iOS, OEM speed, no flicker |
| 4 | CarPlay, Google Maps and Waze | road names per app |
| 5 | Stock nav route (no phone guidance) | EU street un-blank (`force_street_name_native`) |
| 6 | Switch AA -> CarPlay -> AA in one trip | hand-off, no stale arrow, no repaint under the other phone |
| 7 | Some driving with no route | speed sign from the stock nav only |
| 8 | End a route in the phone app; unplug the phone mid-route | HUD clears, sign stays |

Note what the HUD showed (photos help), especially anything that blinked,
stuck or stayed blank.

## After the drive

```sh
tools/deploy.sh probe stop
tools/deploy.sh probe fetch      # -> ~/Documents/mazda-hud-install/logs/hud-probe/
tools/deploy.sh probe clean
```

The session archive (`session-*.tar.gz`) contains:

| File | Content |
|------|---------|
| `dbus_service.log` / `.profile` | NNG `GuidanceChanged*` (incl. AA's svcnavi frames, by sender), every HUD call with its sender, `com.jci.aapa` / `com.jci.carplay`; `.profile` has the timestamps (join on sender + serial) |
| `dbus_hmi.log` / `.profile` | `com.jci.aapa`, `com.jci.carplay` (TBT entity, session), HUD settings |
| `aa_nav.log` | raw AA frames: `aa16` = GAL 1.6 nav frames, `aa15` = 1.5 callbacks (+ road name) |
| `cp_nav.log` | raw CarPlay iAP2 maneuver/guidance messages, TBT entity, session end |
| `merge.log` | svcjcinavi shim decision per HUD frame: `aa-frame`, `oem-spliced-aa`, `oem-native-unblank`, `oem-dropped`, `pass`, with the street actually sent |
| `state.log` | every 2 s: service PIDs, OEM speed shared with CarPlay, CarPlay-owns-HUD marker, free memory |
| `events.log` | service restarts with the shims they loaded, dmesg changes, size guards |
| `marks.log`, `meta.txt`, `final.txt`, `carplay_bridge.log` | notes, firmware/shim md5s/config, end state, CarPlay shim log |

These files contain location data (streets, maneuvers).

Limits: each capture file stops at 40 MB, each raw log at 24 MB, and
capture stops if `/data_persist` drops below 32 MB free (64 MB needed to
start).

## Tests for the probe itself

`test/probe/run.sh` runs it against real `dbus-daemon`/`dbus-monitor` with a
busybox userland. It checks that capture survives the starting shell exiting,
that a session cut short by a reboot is recovered, and that the diag logs are
collected.
