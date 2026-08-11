#!/system/bin/sh
# Runs when the module is removed. Cleans up the persistent USER-store certs that were
# installed for Chrome (the APEX/system bind mount is RAM-only and disappears on reboot).
# Also removes the external imported-cert dir so nothing is left behind.
MODDIR=${0%/*}
USER_STORE=/data/misc/user/0/cacerts-added
EXTRA=/data/adb/apex_burp_ca_certs

for c in "$MODDIR"/certs/* "$EXTRA"/*; do
  [ -f "$c" ] || continue
  rm -f "$USER_STORE/$(basename "$c")" 2>/dev/null
done

rm -rf "$EXTRA" 2>/dev/null
