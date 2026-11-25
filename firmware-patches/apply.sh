#!/usr/bin/env bash
# Apply TeddyPal firmware patches onto a clean Kaayoos/clawpal v0.13.0 checkout.
# Usage:
#   ./firmware-patches/apply.sh /path/to/clawpal [--teddy] [--amp-icon]
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <path-to-clawpal-clone> [--teddy] [--amp-icon]" >&2
  exit 1
fi

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$(cd "$1" && pwd)"
shift

APPLY_TEDDY=0
APPLY_AMP_ICON=0
for arg in "$@"; do
  case "$arg" in
    --teddy) APPLY_TEDDY=1 ;;
    --amp-icon) APPLY_AMP_ICON=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

cd "$TARGET"

echo "1/3 Installing WS1850S NFC driver (firmware/main/nfc/)..."
mkdir -p firmware/main/nfc
cp "$PATCH_DIR/nfc/buddy_nfc.c" firmware/main/nfc/buddy_nfc.c
cp "$PATCH_DIR/nfc/buddy_nfc.h" firmware/main/nfc/buddy_nfc.h

echo "2/3 Applying core patch (NFC, POST /app, Amp 8-card Need-You, Weather Clock)..."
git apply "$PATCH_DIR/01-nfc-amp-weather.patch"

if [ "$APPLY_TEDDY" -eq 1 ]; then
  echo "3/3 Applying optional Teddy 8-bit orange Maine Coon mascot & quotes..."
  cp "$PATCH_DIR/generate_cat_mascot.py" scripts/generate_cat_mascot.py
  git apply "$PATCH_DIR/02-teddy-quotes.patch"
  python3 scripts/generate_cat_mascot.py
  python3 scripts/generate_mascot.py
  python3 scripts/generate_languages.py
else
  echo "3/3 Skipping Teddy mascot (pass --teddy to replace the crab with Teddy)."
fi

if [ "$APPLY_AMP_ICON" -eq 1 ]; then
  AMP_ICON="/Applications/Amp.app/Contents/Resources/PuckClassic.png"
  if [ -f "$AMP_ICON" ]; then
    echo "Bundling local Amp Puck icon into firmware home logos..."
    cp "$AMP_ICON" assets/logos/CodexLogo.png
    python3 scripts/generate_home_logos.py
  else
    echo "Warning: $AMP_ICON not found; keeping upstream Codex logo." >&2
  fi
fi

echo ""
echo "Done! Next steps inside $TARGET:"
echo "  1. Generate your own firmware signing key once (if you haven't already):"
echo "     python3 scripts/sign-firmware.py --init --key ~/.clawpal-mac/signing-key.pem"
echo "  2. Build with ESP-IDF v5.x:"
echo "     export CLAWPAL_SIGNING_KEY=~/.clawpal-mac/signing-key.pem"
echo "     python3 scripts/build-firmware.py --board waveshare-esp32-s3-touch-lcd-4.3b"
