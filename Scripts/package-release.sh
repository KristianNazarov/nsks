#!/usr/bin/env bash
# Build KeySwitcher.app + installer .pkg + .dmg for sharing with colleagues.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="KeySwitcher"
VERSION="${1:-1.0.0}"
DIST="$ROOT/dist"
APP="$DIST/${APP_NAME}.app"
PKG_ROOT="$DIST/pkgroot"
PKG="$DIST/${APP_NAME}-${VERSION}.pkg"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"
DMG_STAGE="$DIST/dmg-stage"
IDENTIFIER="com.keyswitcher.app"

echo "==> Building app"
"$ROOT/Scripts/build-app.sh"

if [[ ! -d "$APP" ]]; then
  echo "App missing: $APP" >&2
  exit 1
fi

echo "==> Building component package"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP" "$PKG_ROOT/Applications/"

# Scripts for installer (optional welcome via distribution)
SCRIPTS="$DIST/pkgscripts"
rm -rf "$SCRIPTS"
mkdir -p "$SCRIPTS"

cat > "$SCRIPTS/postinstall" <<'EOF'
#!/bin/bash
# Open Privacy settings hint is left to the app; just launch KeySwitcher.
open -a "KeySwitcher" || true
exit 0
EOF
chmod +x "$SCRIPTS/postinstall"

pkgbuild \
  --root "$PKG_ROOT" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  --scripts "$SCRIPTS" \
  "$DIST/${APP_NAME}-component.pkg"

# Distribution XML → Installer.app wizard
DIST_XML="$DIST/distribution.xml"
cat > "$DIST_XML" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>KeySwitcher</title>
    <organization>com.keyswitcher</organization>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <pkg-ref id="${IDENTIFIER}"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="KeySwitcher">
        <pkg-ref id="${IDENTIFIER}"/>
    </choice>
    <pkg-ref id="${IDENTIFIER}" version="${VERSION}" onConclusion="none">${APP_NAME}-component.pkg</pkg-ref>
</installer-gui-script>
EOF

RESOURCES_PKG="$DIST/pkg-resources"
rm -rf "$RESOURCES_PKG"
mkdir -p "$RESOURCES_PKG"

cat > "$RESOURCES_PKG/welcome.html" <<'EOF'
<!DOCTYPE html>
<html lang="ru">
<head><meta charset="utf-8"><style>
body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px; line-height: 1.45; color: #222; }
h1 { font-size: 18px; }
</style></head>
<body>
<h1>Установка KeySwitcher</h1>
<p>KeySwitcher — menu bar утилита для быстрой смены раскладки EN ↔ RU (как Punto Switcher): последнее слово, выделенный текст и регистр.</p>
<p><b>После установки</b> откройте:</p>
<ul>
  <li>Системные настройки → Конфиденциальность и безопасность → Универсальный доступ</li>
  <li>Системные настройки → Конфиденциальность и безопасность → Мониторинг ввода</li>
</ul>
<p>Включите KeySwitcher в обоих списках, затем в меню приложения нажмите <b>Permissions → Retry Start Monitoring</b>.</p>
</body></html>
EOF

cat > "$RESOURCES_PKG/conclusion.html" <<'EOF'
<!DOCTYPE html>
<html lang="ru">
<head><meta charset="utf-8"><style>
body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px; line-height: 1.45; color: #222; }
h1 { font-size: 18px; }
</style></head>
<body>
<h1>Готово</h1>
<p>KeySwitcher установлен в <code>/Applications</code> и должен появиться в строке меню (иконка клавиатуры).</p>
<p>Не забудьте выдать разрешения Accessibility и Input Monitoring.</p>
<p>Установочный пакет можно удалить в Корзину.</p>
</body></html>
EOF

echo "==> Building product archive (Installer wizard)"
productbuild \
  --distribution "$DIST_XML" \
  --resources "$RESOURCES_PKG" \
  --package-path "$DIST" \
  "$PKG"

# Sign pkg if we have identity
IDENTITY="$("$ROOT/Scripts/ensure-signing-identity.sh" 2>/dev/null || true)"
if [[ -n "${IDENTITY:-}" && "$IDENTITY" != "-" ]]; then
  # Needs "Developer ID Installer" cert — app identity alone is not enough; skip quietly.
  if productsign --sign "$IDENTITY" "$PKG" "${PKG}.signed" 2>/dev/null; then
    mv "${PKG}.signed" "$PKG"
    echo "==> Signed package with $IDENTITY"
  else
    echo "==> PKG left unsigned (need Installer signing identity for productsign)"
  fi
fi

echo "==> Building DMG"
rm -rf "$DMG_STAGE" "$DMG"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
cp "$PKG" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
# Short readme on the disk
cat > "$DMG_STAGE/Установка.txt" <<'EOF'
KeySwitcher
===========

Вариант A (рекомендуется): откройте KeySwitcher-*.pkg — мастер установки.
Вариант B: перетащите KeySwitcher.app в папку Applications.

После установки выдайте Accessibility + Input Monitoring
(меню KeySwitcher → Permissions → Retry Start Monitoring).

Установочный .pkg / .dmg можно удалить в Корзину.
EOF

hdiutil create -volname "KeySwitcher" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG"

echo ""
echo "✅ App:  $APP"
echo "✅ PKG:  $PKG"
echo "✅ DMG:  $DMG"
echo ""
echo "Для коллег удобнее отдать DMG или PKG."
