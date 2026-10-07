#!/bin/sh
# Installer scenarios, run inside a busybox container by test/install/run.sh.
#   /dump  read-only CMU dump (jci/sm/sm*.conf, jci/version.ini,
#          jci/navi/svcjcinavi.so, etc/devmgr_config_master.xml)
#   /pkg   read-only dist/hud-mod
#   /aapxml upstream stock + patched aap_system_attributes*.xml (from git)
# Every scenario starts from a fresh fake root.
set -u
FAILS=0
ok()   { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
check() { if eval "$1"; then ok "$2"; else fail "$2"; fi; }

mkdir -p /fakebin
printf '#!/bin/sh\nexit 0\n' > /fakebin/mount
chmod +x /fakebin/mount
export PATH=/fakebin:$PATH

# The dump was taken with KidMixer's mod installed; derive the stock configs
# (no LD_PRELOAD / LD_LIBRARY_PATH lines, jciCARPLAY reset_board="yes").
mkdir -p /stock
for c in sm.conf sm_WCP.conf; do
  grep -v 'libpatch-' /dump/jci/sm/$c | grep -v 'LD_LIBRARY_PATH" env_value="/jci/lib:/usr/lib"' \
    | sed '/name="jciCARPLAY"/ s/reset_board="no"/reset_board="yes"/' > /stock/$c
done
sed 's#<name>NaviSupported</name><value>TRUE</value>#<name>NaviSupported</name><value>FALSE</value>#' \
  /dump/etc/devmgr_config_master.xml > /stock/devmgr_config_master.xml

# fresh_root SM_SOURCE_DIR: reset the fake CMU filesystem
fresh_root() {
  rm -rf /jci /data_persist /etc/devmgr_config_master.xml /etc/aap_system_attributes* /etc/androidauto
  mkdir -p /jci/sm /jci/navi /jci/scripts /data_persist /etc/androidauto/ucp /etc/androidauto/wcp
  cp "$1"/sm.conf "$1"/sm_WCP.conf /jci/sm/
  cp /dump/jci/version.ini /jci/
  cp /dump/jci/navi/svcjcinavi.so /jci/navi/
  cp /dump/etc/devmgr_config_master.xml /etc/
  for f in /etc/androidauto/ca.pem \
           /etc/androidauto/ucp/Mazda-2018-02-21-signed-CMU_2018.pem /etc/androidauto/ucp/Mazda-2018-02-21-CMU_2018.key \
           /etc/androidauto/wcp/Mazda-2020-06-05-CMU_DR_7_8_9_2020.pem /etc/androidauto/wcp/Mazda-2020-06-05-CMU_DR_7_8_9_2020.key \
           /etc/androidauto/Mazda-2018-02-21-signed-CMU_2018.pem /etc/androidauto/Mazda-2018-02-21-CMU_2018.key; do
    : > "$f"
  done
  cp /aapxml/stock/aap_system_attributes.xml /aapxml/stock/aap_system_attributes_UCP.xml /etc/
  echo "50 123" > /data_persist/splim            # left by the old splim_bridge
}
install_pkg()   { sh /pkg/install.sh > /tmp/out.txt 2>&1; }
uninstall_pkg() { sh /pkg/uninstall.sh > /tmp/out.txt 2>&1; }
preloads() {  # preloads SERVICE CONF -> LD_PRELOAD values in that service block
  awk -v s="name=\"$1\"" 'index($0, s) && /<service /{f=1; next} f && /LD_PRELOAD/{print} f && /<\/service>/{f=0}' "$2" \
    | grep -oE 'env_value="[^"]*"'
}
nonmod() { grep -v 'libpatch-' "$1" | grep -v 'LD_LIBRARY_PATH" env_value="/jci/lib:/usr/lib"' | sed 's/reset_board="no"/reset_board="yes"/'; }
want() { echo "env_value=\"/data_persist/oem-aa-mod/libpatch-$1.so\""; }

echo "[I1] unit with KidMixer's mod (your dump) -> install"
fresh_root /dump/jci/sm
install_pkg; rc=$?
check '[ $rc = 0 ]' "install exit 0"
for s in jciCARPLAY:blmjcicarplay jciAAPA:blmjciaapa jcinavi:svcjcinavi aap_service:aap_service; do
  svc=${s%%:*}; so=${s#*:}
  check '[ "$(preloads $svc /jci/sm/sm.conf)" = "$(want $so)" ]' "$svc has exactly our $so"
done
check '[ $(grep -c "LD_LIBRARY_PATH" /jci/sm/sm.conf) = 1 ]' "one LD_LIBRARY_PATH (jciCARPLAY)"
check '! grep -q cp-hud-mod /jci/sm/sm.conf' "KidMixer cp-hud-mod line gone"
check 'grep "name=\"jciCARPLAY\"" /jci/sm/sm.conf | grep -q "reset_board=\"no\""' "jciCARPLAY reset_board=no"
check '[ "$(nonmod /jci/sm/sm.conf | md5sum)" = "$(nonmod /dump/jci/sm/sm.conf | md5sum)" ]' "every other line of sm.conf unchanged"
check '[ $(grep -c libpatch- /jci/sm/sm_WCP.conf) = 0 ]' "inactive sm_WCP.conf has no preloads"
check 'grep -q "<name>NaviSupported</name><value>TRUE" /etc/devmgr_config_master.xml' "NaviSupported=TRUE"
check 'grep -q "<subscribe>TRUE</subscribe>" /etc/aap_system_attributes_UCP.xml' "AA XML installed (navigation subscribe)"
check '[ ! -e /data_persist/splim ]' "old splim file removed"

echo "[I2] re-install is idempotent"
cp /jci/sm/sm.conf /tmp/first
install_pkg
check 'cmp -s /tmp/first /jci/sm/sm.conf' "sm.conf byte-identical after 2nd install"

echo "[I3] uninstall -> stock"
uninstall_pkg; rc=$?
check '[ $rc = 0 ]' "uninstall exit 0"
check 'cmp -s /stock/sm.conf /jci/sm/sm.conf' "sm.conf == stock"
check 'cmp -s /stock/sm_WCP.conf /jci/sm/sm_WCP.conf' "sm_WCP.conf == stock"
check 'cmp -s /stock/devmgr_config_master.xml /etc/devmgr_config_master.xml' "devmgr master == stock (NaviSupported FALSE)"
check 'cmp -s /aapxml/stock/aap_system_attributes_UCP.xml /etc/aap_system_attributes_UCP.xml' "AA XML == stock"
check '[ ! -d /data_persist/oem-aa-mod ]' "mod dir removed"

echo "[I4] WCP hardware (get_board_type.sh exits 2)"
fresh_root /dump/jci/sm
printf '#!/bin/sh\nexit 2\n' > /jci/scripts/get_board_type.sh; chmod +x /jci/scripts/get_board_type.sh
install_pkg; rc=$?
check '[ $rc = 0 ]' "install exit 0"
check '[ $(grep -c libpatch- /jci/sm/sm_WCP.conf) = 4 ]' "sm_WCP.conf has the 4 preloads"
check '[ $(grep -c libpatch- /jci/sm/sm.conf) = 0 ]' "KidMixer line stripped from inactive sm.conf"
check '[ "$(preloads jciAAPA /jci/sm/sm_WCP.conf)" = "$(want blmjciaapa)" ]' "jciAAPA (args=new_hw) patched"

echo "[I5] over a manual oem-aa-mod install (/etc/*.xml.orig = stock)"
fresh_root /stock
awk '{print} /<service / && /name="jciAAPA"/ {print "            <environ_var env_name=\"LD_PRELOAD\" env_value=\"/data_persist/oem-aa-mod/libpatch-blmjciaapa.so\"/>"}' \
  /stock/sm.conf > /jci/sm/sm.conf
for x in aap_system_attributes.xml aap_system_attributes_UCP.xml; do
  cp /aapxml/stock/$x /etc/$x.orig; cp /aapxml/patched/$x /etc/$x
done
install_pkg; rc=$?
check '[ $rc = 0 ] && [ "$(preloads jciAAPA /jci/sm/sm.conf)" = "$(want blmjciaapa)" ]' "single jciAAPA preload"
uninstall_pkg
check 'cmp -s /aapxml/stock/aap_system_attributes_UCP.xml /etc/aap_system_attributes_UCP.xml' "uninstall restores the STOCK AA XML"
check 'cmp -s /stock/sm.conf /jci/sm/sm.conf' "sm.conf == stock"

echo "[I6] foreign LD_PRELOAD in a target service -> refuse, change nothing"
fresh_root /stock
awk '{print} /<service / && /name="jciAAPA"/ {print "            <environ_var env_name=\"LD_PRELOAD\" env_value=\"/data_persist/other/libfoo.so\"/>"}' \
  /stock/sm.conf > /jci/sm/sm.conf
before=$(md5sum /jci/sm/sm.conf /etc/devmgr_config_master.xml /etc/aap_system_attributes_UCP.xml)
install_pkg; rc=$?
check '[ $rc != 0 ]' "install refused (exit $rc)"
check 'grep -q "foreign LD_PRELOAD in jciAAPA" /tmp/out.txt' "says why"
check '[ "$(md5sum /jci/sm/sm.conf /etc/devmgr_config_master.xml /etc/aap_system_attributes_UCP.xml)" = "$before" ]' "configs untouched"
check '[ ! -d /data_persist/oem-aa-mod ]' "nothing copied"

echo "[I7] foreign LD_PRELOAD in another service is kept"
fresh_root /stock
awk '{print} /<service / && /name="jciCDRP"/ {print "            <environ_var env_name=\"LD_PRELOAD\" env_value=\"/data_persist/other/libbt.so\"/>"}' \
  /stock/sm.conf > /jci/sm/sm.conf
grep -q libbt.so /jci/sm/sm.conf || echo "  (note: no jciCDRP service in this dump)"
install_pkg; rc=$?
check '[ $rc = 0 ] && grep -q libbt.so /jci/sm/sm.conf' "install ok, other mod's line preserved"

echo "[I8] target service missing -> refuse"
fresh_root /stock
awk '/<service / && /name="aap_service"/ {skip=1} !skip {print} skip && /<\/service>/ {skip=0}' /stock/sm.conf > /jci/sm/sm.conf
cp /jci/sm/sm.conf /tmp/before
install_pkg; rc=$?
check '[ $rc != 0 ] && grep -q "service aap_service not found" /tmp/out.txt' "install refused, names the service"
check 'cmp -s /tmp/before /jci/sm/sm.conf' "sm.conf untouched"

echo "[I9] svcjcinavi.so is a different build -> street keys off"
fresh_root /stock
echo "different build" > /jci/navi/svcjcinavi.so
install_pkg; rc=$?
check '[ $rc = 0 ] && grep -q "^force_street_name = false" /data_persist/oem-aa-mod/libpatch.conf && grep -q "^force_street_name_native = false" /data_persist/oem-aa-mod/libpatch.conf' "both street keys forced false"

echo "[I10] AA XML certificates missing on the unit -> XML left stock"
fresh_root /stock
rm -f /etc/androidauto/ucp/*
install_pkg; rc=$?
check '[ $rc = 0 ] && cmp -s /aapxml/stock/aap_system_attributes_UCP.xml /etc/aap_system_attributes_UCP.xml' "UCP XML untouched"

echo
[ $FAILS = 0 ] && echo "installer: all passed" || echo "installer: $FAILS FAILED"
exit $FAILS
