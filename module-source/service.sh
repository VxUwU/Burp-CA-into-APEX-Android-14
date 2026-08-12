#!/system/bin/sh
# Runs in late_start (after the zygote is up). Injects the CA overlay into the zygote
# mount namespace(s) so every app forked afterward inherits it. This is required on
# SukiSU/KernelSU builds where the zygote runs in a mount namespace isolated from init,
# so the pre-zygote (post-fs-data) global mount never reaches apps.
#
# post-fs-data captured the pristine system-CA baseline; here we just wait for the runtime
# to settle and re-run apply(), which now performs the zygote-namespace injection.
MODDIR=${0%/*}

[ -f "$MODDIR/disabled" ] && exit 0

# Wait for boot to complete (zygote fully up, USAP pool settled), then a short grace.
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do sleep 1; i=$((i+1)); done
sleep 3

# Use `sh` so this works even if the module manager didn't preserve the +x bit on inject.sh.
exec sh "$MODDIR/inject.sh" apply
