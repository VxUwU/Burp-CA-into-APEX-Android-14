#!/bin/bash
# Build the flashable KernelSU/SukiSU module zip from this folder.
# Run on WSL/Linux/macOS:  bash module-source/build_mod.sh
# Requires: zip
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"        # module-source/
OUT="$(cd "$HERE/.." && pwd)/dist"           # ../dist/
STAGE="$(mktemp -d)"
ZIP="$OUT/apex_burp_ca_module.zip"

mkdir -p "$OUT" "$STAGE/certs"

# LF-normalize text files, copy cert(s)
tr -d '\r' < "$HERE/module.prop"     > "$STAGE/module.prop"
tr -d '\r' < "$HERE/post-fs-data.sh" > "$STAGE/post-fs-data.sh"
chmod 755 "$STAGE/post-fs-data.sh"
cp "$HERE"/certs/*.0 "$STAGE/certs/" 2>/dev/null
chmod 644 "$STAGE"/certs/* 2>/dev/null || { echo "ERROR: no cert in certs/*.0"; exit 1; }

# Zip contents at root (module.prop must be at zip root)
( cd "$STAGE" && rm -f "$ZIP" && zip -r "$ZIP" . >/dev/null )
rm -rf "$STAGE"

echo "Built: $ZIP"
unzip -l "$ZIP"
