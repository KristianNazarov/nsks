#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="KeySwitcher"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
KEYCHAIN="$ROOT/.signing/KeySwitcher.keychain-db"
KEYCHAIN_PASS="keyswitcher-signing"

echo "==> Building arm64 release"
swift build -c release --arch arm64 --disable-sandbox

BIN="$(swift build -c release --arch arm64 --disable-sandbox --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN" ]]; then
  echo "Binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN" "$MACOS_DIR/${APP_NAME}"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
echo -n "APPL????" > "$CONTENTS/PkgInfo"

IDENTITY="$("$ROOT/Scripts/ensure-signing-identity.sh")"
if [[ "$IDENTITY" == "-" || -z "$IDENTITY" ]]; then
  echo "==> Ad-hoc codesign (permissions may reset after each install)"
  codesign --force --deep --sign - --identifier com.keyswitcher.app "$APP_DIR"
else
  echo "==> Codesign with stable identity: $IDENTITY"
  if [[ -f "$KEYCHAIN" ]]; then
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
    codesign --force --deep --options runtime \
      --keychain "$KEYCHAIN" \
      --sign "$IDENTITY" \
      --identifier com.keyswitcher.app \
      "$APP_DIR"
  else
    # Identity from login keychain (manual Certificate Assistant)
    codesign --force --deep --options runtime \
      --sign "$IDENTITY" \
      --identifier com.keyswitcher.app \
      "$APP_DIR"
  fi
fi

codesign --verify --verbose=1 "$APP_DIR" 2>&1 | head -20 || true
echo "==> Done: $APP_DIR"
