#!/usr/bin/env bash
# Debug loop for layout-on-selection failures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/Library/Logs/KeySwitcher/keyswitcher.log"

echo "=== KeySwitcher selection debug ==="
echo ""
echo "Log file: $LOG"
echo ""
echo "STEP A — What does AX see when text is selected?"
echo "  1. Open Sublime (or Cursor), select a word like ghbdtn"
echo "  2. Keep that app focused"
echo "  3. In Terminal run:"
echo "       swift \"$ROOT/Scripts/ax-probe.swift\""
echo "  4. Paste the output back into chat"
echo ""
echo "STEP B — What does KeySwitcher decide on hotkey?"
echo "  1. Install/restart KeySwitcher: \"$ROOT/Scripts/install.sh\""
echo "  2. Menu → Clear Debug Log (or: rm -f \"$LOG\")"
echo "  3. Select text in target app"
echo "  4. Press Right ⌘+Right ⇧  (or: swift \"$ROOT/Scripts/sim-layout-hotkey.swift\")"
echo "  5. Show last traces:"
echo "       tail -n 80 \"$LOG\""
echo ""
echo "STEP C — Compare with Change Case"
echo "  Select same text → Right ⌘+Right ⌥"
echo "  If case works but layout does not, the TRACE lines will show where layout bails."
echo ""

mkdir -p "$(dirname "$LOG")"
touch "$LOG"

if [[ "${1:-}" == "tail" ]]; then
  echo "--- last 80 log lines ---"
  tail -n 80 "$LOG"
elif [[ "${1:-}" == "probe" ]]; then
  echo "Running ax-probe in 1s — focus the target app now…"
  sleep 1
  swift "$ROOT/Scripts/ax-probe.swift"
elif [[ "${1:-}" == "hotkey" ]]; then
  echo "Firing simulated hotkey in 1s — focus the target app now…"
  sleep 1
  swift "$ROOT/Scripts/sim-layout-hotkey.swift"
  echo ""
  echo "--- last 40 log lines ---"
  tail -n 40 "$LOG" 2>/dev/null || true
else
  echo "Commands:"
  echo "  $0 probe   # run AX probe (focus target first)"
  echo "  $0 hotkey  # simulate layout chord + show log"
  echo "  $0 tail    # show recent KeySwitcher log"
fi
