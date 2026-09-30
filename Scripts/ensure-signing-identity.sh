#!/usr/bin/env bash
# Creates a dedicated keychain + self-signed code-signing identity.
# Avoids fragile login-keychain PEM/PKCS12 import on modern macOS.
set -euo pipefail

IDENTITY_NAME="${KEYSWITCHER_IDENTITY_NAME:-KeySwitcher Local}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT_DIR="${KEYSWITCHER_SIGNING_DIR:-$ROOT/.signing}"
KEYCHAIN="${SUPPORT_DIR}/KeySwitcher.keychain-db"
KEYCHAIN_PASS="keyswitcher-signing"
OPENSSL="${KEYSWITCHER_OPENSSL:-/usr/bin/openssl}"

mkdir -p "$SUPPORT_DIR"

export KEYSWITCHER_KEYCHAIN_PATH="$KEYCHAIN"
export KEYSWITCHER_KEYCHAIN_PASS="$KEYCHAIN_PASS"
export KEYSWITCHER_IDENTITY_NAME="$IDENTITY_NAME"

codesign_resolves() {
  local tmp app
  tmp="$(mktemp -d)"
  app="$tmp/t.app"
  mkdir -p "$app/Contents/MacOS"
  echo '#!/bin/sh' > "$app/Contents/MacOS/t"
  chmod +x "$app/Contents/MacOS/t"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.keyswitcher.signing-probe</string>
</dict></plist>
PLIST
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
  # Prefer dedicated keychain; also try default search list (manual Certificate Assistant).
  if codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY_NAME" \
      --identifier com.keyswitcher.signing-probe "$app" >/dev/null 2>&1 \
    || codesign --force --sign "$IDENTITY_NAME" \
      --identifier com.keyswitcher.signing-probe "$app" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

# Probe login keychain (manual Certificate Assistant identity).
probe_login_identity() {
  local tmp app
  tmp="$(mktemp -d)"
  app="$tmp/t.app"
  mkdir -p "$app/Contents/MacOS"
  echo '#!/bin/sh' > "$app/Contents/MacOS/t"
  chmod +x "$app/Contents/MacOS/t"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.keyswitcher.signing-probe</string></dict></plist>' \
    > "$app/Contents/Info.plist"
  if codesign --force --sign "$IDENTITY_NAME" --identifier com.keyswitcher.signing-probe "$app" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

if probe_login_identity; then
  echo "==> Using existing identity from login keychain: ${IDENTITY_NAME}" >&2
  echo "$IDENTITY_NAME"
  exit 0
fi

ensure_keychain() {
  if [[ -f "$KEYCHAIN" ]]; then
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
    return 0
  fi
  echo "==> Creating dedicated keychain: $KEYCHAIN" >&2
  security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN" >/dev/null 2>&1 || true
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
}

# Put our keychain on the search list (keep login/system)
configure_search_list() {
  local existing
  existing="$(security list-keychains -d user | sed -E 's/^[[:space:]]*"//;s/"[[:space:]]*$//' | tr '\n' ' ')"
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KEYCHAIN" $existing >/dev/null 2>&1 || \
    security list-keychains -d user -s "$KEYCHAIN" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true
}

ensure_keychain
configure_search_list

if codesign_resolves; then
  echo "$IDENTITY_NAME"
  exit 0
fi

echo "==> Creating certificate + key with $OPENSSL ($($OPENSSL version 2>/dev/null))" >&2

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KEY="$TMP/key.pem"
CSR="$TMP/req.csr"
CRT="$TMP/cert.pem"
EXT="$TMP/cert.ext"
P12="$TMP/cert.p12"
KEY_ENC="$TMP/key-enc.pem"

cat > "$EXT" <<'EOF'
[v3_req]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
EOF

"$OPENSSL" genrsa -out "$KEY" 2048 2>/dev/null
"$OPENSSL" req -new -key "$KEY" -out "$CSR" -subj "/CN=${IDENTITY_NAME}/O=KeySwitcher/C=US" 2>/dev/null
"$OPENSSL" x509 -req -in "$CSR" -signkey "$KEY" -out "$CRT" -days 3650 \
  -extfile "$EXT" -extensions v3_req 2>/dev/null

cp "$CRT" "$SUPPORT_DIR/KeySwitcherLocal.cer"
cp "$KEY" "$SUPPORT_DIR/KeySwitcherLocal.key"
chmod 600 "$SUPPORT_DIR/KeySwitcherLocal.key"

security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"

import_ok=0

# 1) Encrypted PEM key (macOS often rejects unencrypted keys)
"$OPENSSL" rsa -aes256 -in "$KEY" -out "$KEY_ENC" -passout pass:tmp-key-pass 2>/dev/null
echo "==> Import cert" >&2
if security import "$CRT" -k "$KEYCHAIN" -t cert -A >/tmp/ks-imp-cert.log 2>&1; then
  echo "    cert ok" >&2
else
  echo "    cert: $(tr '\n' ' ' </tmp/ks-imp-cert.log)" >&2
fi

echo "==> Import encrypted key" >&2
if security import "$KEY_ENC" -k "$KEYCHAIN" -t priv -A -P tmp-key-pass >/tmp/ks-imp-key.log 2>&1; then
  echo "    key ok" >&2
  import_ok=1
else
  echo "    key: $(tr '\n' ' ' </tmp/ks-imp-key.log)" >&2
fi

# 2) PKCS#12 into dedicated keychain — try several encodings
make_p12() {
  local out="$1"; shift
  "$OPENSSL" pkcs12 -export -out "$out" -inkey "$KEY" -in "$CRT" \
    -name "$IDENTITY_NAME" "$@" 2>/dev/null
}

try_p12() {
  local label="$1"; shift
  local pass="$1"; shift
  if ! make_p12 "$P12" "$@"; then
    echo "    p12 build failed ($label)" >&2
    return 1
  fi
  if security import "$P12" -k "$KEYCHAIN" -P "$pass" -A >/tmp/ks-imp-p12.log 2>&1; then
    echo "    p12 ok ($label)" >&2
    import_ok=1
    cp "$P12" "$SUPPORT_DIR/KeySwitcherLocal.p12"
    return 0
  fi
  echo "    p12 fail ($label): $(tr '\n' ' ' </tmp/ks-imp-p12.log)" >&2
  return 1
}

echo "==> Import PKCS#12 variants" >&2
try_p12 "pass+legacy-algs" "$KEYCHAIN_PASS" \
  -password "pass:${KEYCHAIN_PASS}" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 || true

try_p12 "empty-pass" "" \
  -password pass: \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 || true

if "$OPENSSL" pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
  try_p12 "openssl3-legacy" "$KEYCHAIN_PASS" \
    -legacy -password "pass:${KEYCHAIN_PASS}" || true
fi

# Allow codesign access without UI prompt
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" \
  "$KEYCHAIN" >/dev/null 2>&1 || true

if codesign_resolves; then
  echo "==> Identity ready: ${IDENTITY_NAME}" >&2
  echo "    Keychain: $KEYCHAIN" >&2
  echo "$IDENTITY_NAME"
  exit 0
fi

echo "" >&2
echo "❌ Automatic identity setup failed on this macOS." >&2
echo "" >&2
echo "One-time manual fix (recommended):" >&2
echo "  1. Open /System/Applications/Utilities/Keychain\\ Access.app" >&2
echo "     (or Spotlight: Keychain Access)" >&2
echo "  2. Keychain Access → Certificate Assistant → Create a Certificate…" >&2
echo "  3. Name: KeySwitcher Local" >&2
echo "     Identity Type: Self Signed Root" >&2
echo "     Certificate Type: Code Signing" >&2
echo "  4. Create, then run:  ./Scripts/install.sh" >&2
echo "" >&2
echo "-"
exit 0
