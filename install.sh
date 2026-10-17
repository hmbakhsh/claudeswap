#!/bin/bash
# Installs (or updates) ClaudeSwap into /Applications and opens it.
#   curl -fsSL https://raw.githubusercontent.com/hmbakhsh/claudeswap/main/install.sh | bash
set -euo pipefail
REPO="hmbakhsh/claudeswap"
APP="/Applications/ClaudeSwap.app"
URL="https://github.com/$REPO/releases/latest/download/ClaudeSwap.zip"

[[ "$(uname)" == "Darwin" ]] || { echo "ClaudeSwap is Mac-only."; exit 1; }

echo "Downloading ClaudeSwap…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"

pkill -f "(ClaudeSwap|Claude Account Switcher).app/Contents/MacOS/switcher" 2>/dev/null || true
rm -rf "$APP" "/Applications/Claude Account Switcher.app"  # old name, pre-1.4
ditto "$TMP/ClaudeSwap.app" "$APP"
open "$APP"
echo "Installed. It's in your Applications folder."
