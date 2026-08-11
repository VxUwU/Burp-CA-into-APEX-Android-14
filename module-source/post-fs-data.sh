#!/system/bin/sh
# Runs at post-fs-data (BEFORE zygote) so every app inherits the trust store.
# The actual work lives in inject.sh (shared with the WebUI). If the WebUI toggle
# left a "disabled" flag, we skip injection this boot.
MODDIR=${0%/*}

if [ -f "$MODDIR/disabled" ]; then
  echo "=== $(date) post-fs-data: disabled by WebUI, skipping ===" > "$MODDIR/certfix.log"
  exit 0
fi

exec "$MODDIR/inject.sh" apply
