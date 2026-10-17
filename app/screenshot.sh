#!/bin/bash
# Regenerates README screenshots from demo data (no real accounts shown).
#   app/screenshot.sh               accounts screen  -> docs/screenshot.png
#   app/screenshot.sh setup docs/welcome.png
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/ClaudeSwap.app"
[[ -d "$APP" ]] || ./app/build.sh
MODE="${1:-1}"
OUT="${2:-docs/screenshot.png}"
open -n --env CAS_DEMO="$MODE" "$APP"
sleep 4
PID="$(pgrep -f "$APP/Contents/MacOS/switcher" | tail -1)"
# Bring it to the front so colours and toggles render in their active state.
for _ in 1 2 3 4 5; do
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set frontmost to true"
  sleep 1
  FRONT="$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true')"
  [[ "$FRONT" == "$PID" ]] && break
done
WID="$(swift -e "import CoreGraphics
let l = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
for w in l where (w[\"kCGWindowOwnerPID\"] as? Int) == $PID && (w[\"kCGWindowLayer\"] as? Int) == 0 { print(w[\"kCGWindowNumber\"]!); break }")"
screencapture -x -l "$WID" "$OUT"
kill "$PID"
echo "Wrote $OUT"
