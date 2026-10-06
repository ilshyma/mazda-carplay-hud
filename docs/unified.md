# Unified CarPlay + Android Auto HUD

One package that puts turn-by-turn guidance from **either** phone on the
Mazda CMU150 HUD, with the **speed-limit sign taken from the stock
navigation** (NNG, nav SD card) in both cases. Neither Android Auto nor
CarPlay sends a posted speed limit to the head unit, so the stock nav is
the only source.

## Pieces

| Shim | Loaded into | Role |
| --- | --- | --- |
| `libpatch-blmjcicarplay.so` | `jciCARPLAY` | CarPlay iAP2 maneuvers -> HUD (direct `com.jci.vbs.navi`) |
| `libpatch-blmjciaapa.so` | `jciAAPA` | Android Auto guidance -> svcjcinavi (`GuidanceChangedForHUD`) |
| `libpatch-aap_service.so` | `aap_service` | GAL 1.6 (lanes) for Android Auto, `use_protocol_v1_6` |
| `libpatch-svcjcinavi.so` | `jcinavi` | HUD arbiter: OEM speed into AA frames, OEM speed out to CarPlay, mutes OEM blank frames under CarPlay |

## Speed-limit data path

```
NNG (map + TSR) --GuidanceChangedForHUD--> svcjcinavi --VBS_NAVI_SetHUDDisplayMsgReq--> HUD
                                              |  (merge shim)
          Android Auto --svcnavi signal-------+  AA frame gets the OEM speed spliced in
                                              |
                                              +--> /tmp/hud_oem_speed  "<limit> <unit>"
                                                          |
          CarPlay (jciCARPLAY) --direct VBS frame <-------+  painted with the OEM unit
                 |
                 +--> /tmp/hud_carplay_active (while a CarPlay route runs)
                          -> merge shim drops the OEM blank-maneuver frames (no flicker)
```

When no phone is guiding, the stock nav owns the HUD as usual (speed sign,
native routes). The CarPlay shim only writes the HUD while a CarPlay route is
active. When the route ends, the phone is unplugged, or the stock nav takes
turn-by-turn, it sends one blank-maneuver frame that keeps the OEM limit and
then stops writing.

This replaces the earlier `splim_bridge` / `splim_udpd` shell daemon
(dbus-monitor -> `/data_persist/splim`). The install removes it. If the
svcjcinavi shim is absent, the CarPlay shim still reads `/data_persist/splim`.

## Build

```sh
git submodule update --init mazda/m3-toolchain   # or set M3TOOLCHAIN_DIR
tools/docker-build.sh release                    # x86_64 container, any host
tools/package.sh                                 # -> dist/hud-mod/ + dist/hud-mod.zip
test/unified/run.sh                              # host test of the hand-off
```

## Install

With SSH up on the unit (toolkit USB unlock):

```sh
tools/deploy.sh install     # copy, md5-check, run install.sh, offer reboot
tools/deploy.sh status      # after reboot: which shim is loaded where, live speed
tools/deploy.sh uninstall
```

Or copy `dist/hud-mod/` to the unit and run `sh install.sh` as root.
`install.sh` patches the sm config the unit actually boots (`sm.conf` or
`sm_WCP.conf`) and replaces any previous KidMixer / oem-aa-mod lines. It also
sets `NaviSupported=TRUE` and installs the AA attribute XMLs if their
certificates exist. Each file it edits is backed up once to
`/data_persist/hud-mod-backup/`. Config lives in
`/data_persist/oem-aa-mod/libpatch.conf`. A re-install keeps your edited copy
there.

## Firmware assumptions

FW 74.00.324 (NA and EU). `force_street_name` reads a fixed offset in
`svcjcinavi.so`. `install.sh` checks that file's md5 and turns the option off
on any other build.
