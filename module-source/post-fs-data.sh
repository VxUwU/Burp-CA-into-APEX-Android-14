#!/system/bin/sh
# Runs at post-fs-data (BEFORE zygote) so every app inherits the trust store.
# The actual work lives in inject.sh (shared with the WebUI). If the WebUI toggle
# left a "disabled" flag, we skip injection this boot.
MODDIR=${0%/*}

if [ -f "$MODDIR/disabled" ]; then
  echo "=== $(date) post-fs-data: disabled by WebUI, skipping ===" > "$MODDIR/certfix.log"
  exit 0
fi

# Use `sh` so this works even if the module manager didn't preserve the +x bit on inject.sh.
exec sh "$MODDIR/inject.sh" apply
