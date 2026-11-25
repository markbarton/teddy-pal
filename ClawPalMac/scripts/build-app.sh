#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ClawPalMac.app"
BUNDLE_ID="${CLAWPAL_BUNDLE_ID:-dev.teddypal.mac}"

cd "$ROOT"
swift build --build-system native -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/ClawPalMac" "$APP/Contents/MacOS/ClawPalMac"

# Optional: if Amp Desktop is installed locally, bundle its icon (never committed to git).
if [ -f "/Applications/Amp.app/Contents/Resources/PuckClassic.png" ]; then
  cp "/Applications/Amp.app/Contents/Resources/PuckClassic.png" "$APP/Contents/Resources/AmpPuck.png"
elif [ -f "$ROOT/Resources/AmpPuck.png" ]; then
  cp "$ROOT/Resources/AmpPuck.png" "$APP/Contents/Resources/AmpPuck.png"
fi

cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ClawPalMac</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ClawPalMac</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>ClawPalMac connects to your ClawPal desk display over your local Wi-Fi network.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>ClawPalMac reads and controls Spotify and Apple Music for your ClawPal desk display and NFC album cards.</string>
</dict>
</plist>
EOF

# Prefer the persistent local Code Signing identity so rebuilds keep a stable
# designated requirement (preserving macOS Keychain "Always Allow" & TCC grants).
SIGN_ID="${CLAWPAL_SIGN_IDENTITY:-ClawPalMac Local Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_ID\""; then
  echo "Signing with valid Keychain identity: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$APP"
elif security find-identity -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_ID\""; then
  echo "Signing with Keychain identity: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$APP"
else
  echo "Warning: '$SIGN_ID' not found in Keychain; falling back to ad-hoc signature"
  codesign --force --deep --sign - "$APP"
fi
echo "Built: $APP"
