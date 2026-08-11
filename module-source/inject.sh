#!/system/bin/sh
# Shared CA injection logic used by post-fs-data.sh (boot), the WebUI, and uninstall.sh.
# Usage: inject.sh {apply|remove|status|list|del <name>}
#   apply       -> clear disabled flag, mount system store + install user store (Chrome)
#   remove      -> set disabled flag, unmount live + remove user-store certs
#   status      -> print key=value lines for the WebUI
#   list        -> print "source|name" for every managed cert (bundled + imported)
#   del <name>  -> delete an imported/bundled cert everywhere, then re-apply
#
# Certs come from TWO dirs:
#   $MODDIR/certs   -> bundled in the zip (returns on reflash)
#   $EXTRA          -> imported at runtime; lives OUTSIDE the module so it survives updates
MODDIR=${0%/*}
LEGACY=/system/etc/security/cacerts
APEX=/apex/com.android.conscrypt/cacerts
USER_STORE=/data/misc/user/0/cacerts-added
EXTRA=/data/adb/apex_burp_ca_certs
FLAG=$MODDIR/disabled
LOG=$MODDIR/certfix.log

mkdir -p "$EXTRA" 2>/dev/null

# Echo every managed cert file path (bundled first, then imported)
src_files() {
  for c in "$MODDIR"/certs/* "$EXTRA"/*; do
    [ -f "$c" ] && echo "$c"
  done
}

# Install every managed cert into EVERY Android user's trust store
# (owner user 0 + secondary users + work profile: /data/misc/user/10, 999, ...).
# Chrome/Chromium enforce CT for SYSTEM roots; a USER-installed root is CT-exempt.
install_user_stores() {
  n=0
  for udir in /data/misc/user/*; do
    [ -d "$udir" ] || continue
    us="$udir/cacerts-added"
    mkdir -p "$us" 2>/dev/null || continue
    src_files | while read -r c; do cp "$c" "$us/$(basename "$c")" 2>/dev/null; done
    chown 0:0 "$us"/* 2>/dev/null
    chmod 644 "$us"/* 2>/dev/null
    restorecon -R "$us" 2>/dev/null || chcon u:object_r:system_data_file:s0 "$us"/* 2>/dev/null
    n=$((n+1))
  done
  echo "$n"
}

# Remove one cert (by basename) from EVERY user's trust store.
remove_user_cert() {
  bn=$1
  for udir in /data/misc/user/*; do
    [ -d "$udir" ] || continue
    rm -f "$udir/cacerts-added/$bn" 2>/dev/null
  done
}

apply() {
  echo "=== $(date) apply ===" > "$LOG"

  # 1. Wait until APEX conscrypt cacerts is populated (timing guard, max ~10s)
  i=0
  while [ -z "$(ls -A $APEX 2>/dev/null)" ]; do
    i=$((i+1)); [ $i -ge 100 ] && break
    sleep 0.1
  done
  echo "apex ready after ${i}x100ms, apex_count=$(ls $APEX 2>/dev/null | wc -l)" >> "$LOG"

  # 2. Snapshot current APEX system CAs
  TMP=/dev/.apex_ca_snap
  rm -rf $TMP; mkdir -p $TMP
  cp $APEX/* $TMP/ 2>/dev/null

  # 3. tmpfs over legacy dir, refill with system CAs + every bundled/imported cert
  mount -t tmpfs tmpfs $LEGACY
  cp $TMP/* $LEGACY/ 2>/dev/null
  src_files | while read -r c; do cp "$c" "$LEGACY/$(basename "$c")" 2>/dev/null; done
  chown 0:0 $LEGACY/* 2>/dev/null
  chmod 644 $LEGACY/* 2>/dev/null
  chcon u:object_r:system_security_cacerts_file:s0 $LEGACY/* 2>/dev/null
  echo "legacy tmpfs count=$(ls $LEGACY | wc -l)" >> "$LOG"

  # 4. Bind the populated legacy dir over the read-only APEX dir
  mount -o bind $LEGACY $APEX 2>>"$LOG"
  echo "apex after bind=$(ls $APEX | wc -l)" >> "$LOG"
  rm -rf $TMP

  # 5. Install the CAs into EVERY user's USER trust store (for Chrome & Chromium browsers).
  #    Chrome enforces Certificate Transparency for certs chaining to a SYSTEM root and
  #    rejects the Burp CA (ERR_CERTIFICATE_TRANSPARENCY_REQUIRED). A USER-installed root
  #    is CT-exempt, so Chrome trusts it. Covers owner (user 0) + secondary/work profiles.
  users=$(install_user_stores)
  echo "user stores patched=$users (user0 count=$(ls $USER_STORE 2>/dev/null | wc -l))" >> "$LOG"

  echo "=== done ===" >> "$LOG"
}

remove() {
  echo "=== $(date) remove ===" >> "$LOG"
  umount $APEX 2>/dev/null || umount -l $APEX 2>/dev/null
  umount $LEGACY 2>/dev/null || umount -l $LEGACY 2>/dev/null
  src_files | while read -r c; do remove_user_cert "$(basename "$c")"; done
  echo "remove done" >> "$LOG"
}

status() {
  if [ -f "$FLAG" ]; then echo "state=disabled"; else echo "state=enabled"; fi

  # Read the APEX store from a REAL app's mount namespace (what apps actually see).
  # The WebUI's own shell runs in a different namespace that does NOT see the boot-time
  # bind mount, so a plain `ls /apex/...` here would falsely report the cert as missing.
  APP_PID=$(pidof com.android.systemui 2>/dev/null | awk '{print $1}')
  if [ -n "$APP_PID" ] && command -v nsenter >/dev/null 2>&1; then
    AC=$(nsenter -t "$APP_PID" -m -- ls "$APEX" 2>/dev/null | wc -l)
    found=no
    for c in $(src_files); do
      nsenter -t "$APP_PID" -m -- ls "$APEX/$(basename "$c")" >/dev/null 2>&1 && found=yes
    done
  else
    AC=$(ls $APEX 2>/dev/null | wc -l)
    found=no
    for c in $(src_files); do ls $APEX/"$(basename "$c")" >/dev/null 2>&1 && found=yes; done
  fi
  echo "apex_count=$AC"
  echo "user_count=$(ls $USER_STORE 2>/dev/null | wc -l)"
  echo "user_stores=$(ls -d /data/misc/user/*/cacerts-added 2>/dev/null | wc -l)"
  echo "burp_in_apex=$found"
}

list() {
  for c in "$MODDIR"/certs/*; do [ -f "$c" ] && echo "bundled|$(basename "$c")"; done
  for c in "$EXTRA"/*;        do [ -f "$c" ] && echo "imported|$(basename "$c")"; done
}

del() {
  name="$1"
  [ -z "$name" ] && { echo "usage: del <name>"; exit 1; }
  # strip any path, keep basename only (safety)
  name=$(basename "$name")
  rm -f "$MODDIR/certs/$name" "$EXTRA/$name" 2>/dev/null
  remove_user_cert "$name"
  echo "=== $(date) del $name ===" >> "$LOG"
  # re-apply so the live APEX overlay reflects the removal (unless disabled)
  [ -f "$FLAG" ] || apply
}

case "$1" in
  apply)  rm -f "$FLAG"; apply ;;
  remove) : > "$FLAG"; remove ;;
  status) status ;;
  list)   list ;;
  del)    del "$2" ;;
  *) echo "usage: $0 {apply|remove|status|list|del <name>}"; exit 1 ;;
esac
