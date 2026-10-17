#!/bin/bash
# Regenerates docs/screenshot.png from the app's demo data (no real accounts shown).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/Claude Account Switcher.app"
[[ -d "$APP" ]] || ./app/build.sh
open -n --env CAS_DEMO=1 "$APP"
sleep 4
PID="$(pgrep -f "$APP/Contents/MacOS/switcher" | tail -1)"
# Bring it to the front so colours and toggles render in their active state.
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set frontmost to true"
sleep 1
WID="$(swift -e "import CoreGraphics
let l = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
for w in l where (w[\"kCGWindowOwnerPID\"] as? Int) == $PID && (w[\"kCGWindowLayer\"] as? Int) == 0 { print(w[\"kCGWindowNumber\"]!); break }")"
screencapture -x -l "$WID" docs/screenshot.png
kill "$PID"
echo "Wrote docs/screenshot.png"
