#!/system/bin/sh
# Runs when the module is removed. Cleans up the persistent USER-store certs that were
# installed for Chrome (the APEX/system bind mount is RAM-only and disappears on reboot).
# Also removes the external imported-cert dir so nothing is left behind.
# Covers EVERY Android user (owner + secondary + work profile), matching inject.sh.
MODDIR=${0%/*}
EXTRA=/data/adb/apex_burp_ca_certs
BASE=/data/adb/apex_burp_ca_base

for c in "$MODDIR"/certs/* "$EXTRA"/*; do
  [ -f "$c" ] || continue
  bn=$(basename "$c")
  for udir in /data/misc/user/*; do
    [ -d "$udir" ] && rm -f "$udir/cacerts-added/$bn" 2>/dev/null
  done
done

rm -rf "$EXTRA" "$BASE" 2>/dev/null
