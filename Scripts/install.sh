#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="KeySwitcher"
SRC_APP="$ROOT/dist/${APP_NAME}.app"
KEYCHAIN="$ROOT/.signing/KeySwitcher.keychain-db"
KEYCHAIN_PASS="keyswitcher-signing"

DEST_DIR="/Applications"
if [[ ! -w "$DEST_DIR" ]]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi
DEST_APP="${DEST_DIR}/${APP_NAME}.app"

echo "==> Building release app"
"$ROOT/Scripts/build-app.sh"

if [[ ! -d "$SRC_APP" ]]; then
  echo "Built app not found at $SRC_APP" >&2
  exit 1
fi

echo "==> Installing to $DEST_APP"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3

rm -rf "$DEST_APP"
cp -R "$SRC_APP" "$DEST_APP"
chmod +x "$DEST_APP/Contents/MacOS/${APP_NAME}"

IDENTITY="$("$ROOT/Scripts/ensure-signing-identity.sh")"
if [[ "$IDENTITY" == "-" || -z "$IDENTITY" ]]; then
  codesign --force --deep --sign - --identifier com.keyswitcher.app "$DEST_APP"
  echo "⚠️  Ad-hoc signature: after each update you may need to re-grant Accessibility / Input Monitoring"
else
  if [[ -f "$KEYCHAIN" ]]; then
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
    codesign --force --deep --options runtime \
      --keychain "$KEYCHAIN" \
      --sign "$IDENTITY" \
      --identifier com.keyswitcher.app \
      "$DEST_APP"
  else
    codesign --force --deep --options runtime \
      --sign "$IDENTITY" \
      --identifier com.keyswitcher.app \
      "$DEST_APP"
  fi
  echo "==> Signed with stable identity: $IDENTITY"
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DEST_APP" 2>/dev/null || true
fi

echo ""
echo "✅ Installed: $DEST_APP"
echo "   open -a KeySwitcher"
echo ""
echo "If first install / first stable signature:"
echo "  System Settings → Privacy & Security → Accessibility + Input Monitoring"
echo "  Menu → Permissions / Diagnostics → Retry Start Monitoring"
