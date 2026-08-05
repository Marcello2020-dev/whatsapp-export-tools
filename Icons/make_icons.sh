#!/bin/bash
set -euo pipefail

# Always work relative to this script's directory (repo-local).
ICONS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source image (must exist in this folder)
SRC="$ICONS_DIR/chat-export-studio-icon-1024.png"

# Output names (in this folder)
BASENAME="chat-export-studio"
ICONSET="$ICONS_DIR/${BASENAME}.iconset"

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: Quelle nicht gefunden: $SRC"
  echo "Lege eine 1024×1024 PNG-Datei unter folgendem Namen ab: chat-export-studio-icon-1024.png"
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

gen() {
  local size="$1"
  local name="$2"
  /usr/bin/sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null
}

gen 16   "icon_16x16.png"
gen 32   "icon_16x16@2x.png"

gen 32   "icon_32x32.png"
gen 64   "icon_32x32@2x.png"

gen 128  "icon_128x128.png"
gen 256  "icon_128x128@2x.png"

gen 256  "icon_256x256.png"
gen 512  "icon_256x256@2x.png"

gen 512  "icon_512x512.png"
cp -f "$SRC" "$ICONSET/icon_512x512@2x.png"

echo "OK: iconset erstellt: $ICONSET"

echo "Fertig. Xcode erzeugt beim Build die .icns-Datei aus dem AppIcon-Asset-Katalog."
