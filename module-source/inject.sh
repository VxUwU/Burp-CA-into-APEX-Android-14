#!/system/bin/sh
# Shared CA injection logic used by post-fs-data.sh (boot), the WebUI, and uninstall.sh.
# Usage: inject.sh {apply|remove|status|list|apps|check <pkg>|del <name>}
#   apply        -> clear disabled flag, rebuild+mount system store + install user store (Chrome)
#   remove       -> set disabled flag, unmount live + remove user-store certs
#   status       -> print key=value lines for the WebUI
#   list         -> print "source|name" for every managed cert (bundled + imported)
#   apps         -> list installed third-party packages (WebUI target picker)
#   check <pkg>  -> report whether the RUNNING target sees the CA in its own namespace
#   del <name>   -> delete an imported/bundled cert everywhere, then re-apply
#
# Certs come from TWO dirs:
#   $MODDIR/certs   -> bundled in the zip (returns on reflash)
#   $EXTRA          -> imported at runtime; lives OUTSIDE the module so it survives updates
#
# SAFETY MODEL (why apply can never cause "all apps: no internet"):
#   - The 145+ system roots are cached ONCE into a persistent BASELINE ($BASE), taken only when
#     APEX is pristine (at boot, before our overlay). Every rebuild uses the baseline — NEVER the
#     live/overlaid/mid-unmount APEX. This kills the old race where a runtime apply snapshotted an
#     empty APEX and dropped the system roots.
#   - The new store is built in a STAGING tmpfs and count-checked BEFORE the live overlay is touched.
#   - After binding, it is VERIFIED; on any failure it ROLLS BACK to the real APEX so apps keep a
#     complete trust store (internet stays up; the CA just isn't applied until the next boot).
MODDIR=${0%/*}
LEGACY=/system/etc/security/cacerts
APEX=/apex/com.android.conscrypt/cacerts
USER_STORE=/data/misc/user/0/cacerts-added
EXTRA=/data/adb/apex_burp_ca_certs
BASE=/data/adb/apex_burp_ca_base       # pristine system-CA baseline (persistent, survives updates)
FLAG=$MODDIR/disabled
LOG=$MODDIR/certfix.log
LOCKDIR=$MODDIR/.apply.lock
MIN_CERTS=50                            # safety floor: never bind a store with fewer roots than this

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

# Refresh the pristine baseline ONLY when APEX is not currently our overlay (i.e. at boot,
# before we bind). Atomic + count-guarded so a bad/partial read never clobbers a good baseline.
refresh_baseline() {
  grep -q " $APEX " /proc/mounts 2>/dev/null && return   # overlay present -> not pristine, keep baseline
  cnt=$(ls $APEX 2>/dev/null | wc -l)
  [ "$cnt" -ge "$MIN_CERTS" ] || return                  # APEX looks incomplete -> don't touch baseline
  rm -rf "$BASE.tmp"; mkdir -p "$BASE.tmp"
  cp $APEX/* "$BASE.tmp/" 2>/dev/null
  if [ "$(ls "$BASE.tmp" 2>/dev/null | wc -l)" -ge "$MIN_CERTS" ]; then
    rm -rf "$BASE"; mv "$BASE.tmp" "$BASE"
  fi
  rm -rf "$BASE.tmp"
}

# Tear down any existing overlay (idempotent). Safe because callers refill from a stable source.
teardown_overlay() {
  n=0; while [ $n -lt 8 ] && grep -q " $APEX " /proc/mounts 2>/dev/null; do
    umount $APEX 2>/dev/null || umount -l $APEX 2>/dev/null || break; n=$((n+1)); done
  n=0; while [ $n -lt 8 ] && grep -q " $LEGACY " /proc/mounts 2>/dev/null; do
    umount $LEGACY 2>/dev/null || umount -l $LEGACY 2>/dev/null || break; n=$((n+1)); done
}

# Write the per-namespace overlay helper (paths baked in). Executed inside each zygote's
# mount namespace via nsenter. Kept on /data so it's visible in every namespace.
write_overlay_script() {
  cat > "$MODDIR/.overlay.sh" <<EOF
#!/system/bin/sh
L=$LEGACY; A=$APEX
n=0; while [ \$n -lt 8 ] && grep -q " \$A " /proc/mounts 2>/dev/null; do umount \$A 2>/dev/null || umount -l \$A 2>/dev/null || break; n=\$((n+1)); done
grep -q " \$L " /proc/mounts 2>/dev/null && { umount \$L 2>/dev/null || umount -l \$L 2>/dev/null; }
mount -t tmpfs tmpfs \$L
cp $BASE/* \$L/ 2>/dev/null
for c in $MODDIR/certs/* $EXTRA/*; do [ -f "\$c" ] && cp "\$c" "\$L/" 2>/dev/null; done
chown 0:0 \$L/* 2>/dev/null; chmod 644 \$L/* 2>/dev/null
chcon u:object_r:system_security_cacerts_file:s0 \$L/* 2>/dev/null
mount -o bind \$L \$A 2>/dev/null
EOF
  chmod 755 "$MODDIR/.overlay.sh"
}

# All zygote pids (main + webview + per-app zygotes), excluding USAP pool blanks.
zygote_pids() {
  ps -A -o PID,NAME 2>/dev/null | grep -iE 'zygote' | grep -viE 'usap' | awk '{print $1}'
}

# Build the overlay INSIDE each zygote's mount namespace so apps forked afterward inherit
# it. Required where zygote runs in a mount namespace isolated from init (SukiSU/KernelSU
# mount-hiding), so the boot-time global mount never reaches apps. Reads the pristine
# baseline (never the live APEX). Apps already running keep their old view until restarted.
inject_zygotes() {
  [ "$(ls "$BASE" 2>/dev/null | wc -l)" -ge "$MIN_CERTS" ] || { echo "inject_zygotes: no baseline, skip" >> "$LOG"; return; }
  command -v nsenter >/dev/null 2>&1 || { echo "inject_zygotes: no nsenter, skip" >> "$LOG"; return; }
  write_overlay_script
  cnt=0
  for ZY in $(zygote_pids); do
    [ -e "/proc/$ZY/ns/mnt" ] || continue
    nsenter -t "$ZY" -m -- sh "$MODDIR/.overlay.sh" 2>/dev/null && cnt=$((cnt+1))
  done
  echo "inject_zygotes: injected into $cnt zygote ns" >> "$LOG"
}

apply() {
  # Single-flight lock so a WebUI double-tap can't run two applies at once.
  # Self-heal: clear a stale lock (>60s) left by a crashed run so boot injection never deadlocks.
  if [ -d "$LOCKDIR" ] && [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rmdir "$LOCKDIR" 2>/dev/null
  fi
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    echo "=== $(date) apply SKIPPED (already running) ===" >> "$LOG"; return
  fi

  echo "=== $(date) apply ===" > "$LOG"

  # 1. Wait until APEX conscrypt cacerts is populated (timing guard, max ~10s)
  i=0
  while [ -z "$(ls -A $APEX 2>/dev/null)" ]; do
    i=$((i+1)); [ $i -ge 100 ] && break
    sleep 0.1
  done
  echo "apex ready after ${i}x100ms, apex_count=$(ls $APEX 2>/dev/null | wc -l)" >> "$LOG"

  # 2. Refresh the pristine baseline while APEX is un-overlaid (boot), then REQUIRE a healthy one.
  refresh_baseline
  base_cnt=$(ls "$BASE" 2>/dev/null | wc -l)
  if [ "$base_cnt" -lt "$MIN_CERTS" ]; then
    echo "ABORT: no healthy baseline (have=$base_cnt need>=$MIN_CERTS) — leaving current store untouched" >> "$LOG"
    echo "=== done (aborted) ===" >> "$LOG"; rmdir "$LOCKDIR" 2>/dev/null; return
  fi
  echo "baseline system CAs=$base_cnt" >> "$LOG"

  # 3. Build the NEW store in a STAGING tmpfs (baseline + managed). Live overlay untouched yet.
  STAGE=/dev/.ca_stage
  rm -rf $STAGE; mkdir -p $STAGE
  cp "$BASE"/* $STAGE/ 2>/dev/null
  src_files | while read -r c; do cp "$c" "$STAGE/$(basename "$c")" 2>/dev/null; done
  stage_cnt=$(ls $STAGE 2>/dev/null | wc -l)
  if [ "$stage_cnt" -lt "$MIN_CERTS" ]; then
    echo "ABORT: staging too small ($stage_cnt) — refusing to bind (would break TLS)" >> "$LOG"
    rm -rf $STAGE; echo "=== done (aborted) ===" >> "$LOG"; rmdir "$LOCKDIR" 2>/dev/null; return
  fi

  # 4. Swap in the new store: tear down old overlay, fill LEGACY FROM STAGING (stable), then bind.
  teardown_overlay
  mount -t tmpfs tmpfs $LEGACY
  cp $STAGE/* $LEGACY/ 2>/dev/null
  chown 0:0 $LEGACY/* 2>/dev/null
  chmod 644 $LEGACY/* 2>/dev/null
  chcon u:object_r:system_security_cacerts_file:s0 $LEGACY/* 2>/dev/null
  echo "legacy tmpfs count=$(ls $LEGACY | wc -l)" >> "$LOG"
  rm -rf $STAGE

  mount -o bind $LEGACY $APEX 2>>"$LOG"
  bound=$(ls $APEX 2>/dev/null | wc -l)
  echo "apex after bind=$bound" >> "$LOG"

  # 5. Post-bind verification. Store MUST still hold the system roots AND our cert; else ROLL BACK.
  managed_ok=yes
  first=$(src_files | head -n1)
  if [ -n "$first" ] && ! ls "$APEX/$(basename "$first")" >/dev/null 2>&1; then managed_ok=no; fi
  if [ "$bound" -lt "$MIN_CERTS" ] || [ "$managed_ok" = no ]; then
    echo "VERIFY FAIL (bound=$bound managed_ok=$managed_ok) — rolling back to real APEX" >> "$LOG"
    teardown_overlay
    echo "rolled back: apps keep the real system trust store (internet safe; CA not applied)" >> "$LOG"
  else
    echo "VERIFY PASS (bound=$bound, managed CA present)" >> "$LOG"
  fi

  # 5b. Inject into the zygote namespace(s) so apps inherit the overlay on setups where the
  #     init/global mount does not reach app namespaces (SukiSU/KernelSU mount-isolation).
  #     No-op at post-fs-data (no zygote yet); the boot service re-runs apply once zygote is up.
  inject_zygotes

  # 6. Install the CAs into EVERY user's USER trust store (Chrome/Chromium, CT-exempt).
  users=$(install_user_stores)
  echo "user stores patched=$users (user0 count=$(ls $USER_STORE 2>/dev/null | wc -l))" >> "$LOG"

  echo "=== done ===" >> "$LOG"
  rmdir "$LOCKDIR" 2>/dev/null
}

remove() {
  echo "=== $(date) remove ===" >> "$LOG"
  teardown_overlay
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
  echo "baseline=$(ls "$BASE" 2>/dev/null | wc -l)"
  echo "burp_in_apex=$found"
}

list() {
  for c in "$MODDIR"/certs/*; do [ -f "$c" ] && echo "bundled|$(basename "$c")"; done
  for c in "$EXTRA"/*;        do [ -f "$c" ] && echo "imported|$(basename "$c")"; done
}

# List installed third-party packages (for the WebUI target picker).
apps() {
  pm list packages -3 2>/dev/null | sed 's/^package://' | sort
}

# Per-app trust check: does the RUNNING target actually see the managed CA in its
# own mount namespace? Answers "not trusted vs. pinning" without guessing.
check() {
  pkg="$1"
  [ -z "$pkg" ] && { echo "error=no package given"; return; }
  echo "pkg=$pkg"
  pid=$(pidof "$pkg" 2>/dev/null | awk '{print $1}')
  if [ -z "$pid" ]; then echo "running=no"; return; fi
  echo "running=yes"
  echo "pid=$pid"
  echo "managed=$(src_files | wc -l)"
  if command -v nsenter >/dev/null 2>&1; then
    echo "apex_count=$(nsenter -t "$pid" -m -- ls "$APEX" 2>/dev/null | wc -l)"
    vis=no
    for c in $(src_files); do
      nsenter -t "$pid" -m -- ls "$APEX/$(basename "$c")" >/dev/null 2>&1 && vis=yes
    done
    echo "burp_visible=$vis"
  else
    echo "apex_count=?"
    echo "burp_visible=unknown"
  fi
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
  apps)   apps ;;
  check)  check "$2" ;;
  del)    del "$2" ;;
  *) echo "usage: $0 {apply|remove|status|list|apps|check <pkg>|del <name>}"; exit 1 ;;
esac
