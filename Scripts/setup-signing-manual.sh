#!/usr/bin/env bash
# Opens Keychain Access and prints exact steps to create a Code Signing cert.
set -euo pipefail

echo "Opening Keychain Access…"
open -a "Keychain Access" || open "/System/Library/CoreServices/Applications/Keychain Access.app" || true

cat <<'EOF'

Создай сертификат (один раз):

1. В Keychain Access: меню Certificate Assistant → Create a Certificate…
2. Name:              KeySwitcher Local
   Identity Type:     Self Signed Root
   Certificate Type:  Code Signing
3. Create

Проверка:
  codesign -f -s "KeySwitcher Local" - <<<''

Потом:
  cd ~/Desktop/projects/key_switcher && ./Scripts/install.sh

В логе должно быть: Signed with stable identity: KeySwitcher Local

EOF
