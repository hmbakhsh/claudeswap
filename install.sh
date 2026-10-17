#!/bin/bash
# Installs (or updates) Claude Account Switcher into /Applications and opens it.
#   curl -fsSL https://raw.githubusercontent.com/hmbakhsh/claude-account-switcher/main/install.sh | bash
set -euo pipefail
REPO="hmbakhsh/claude-account-switcher"
APP="/Applications/Claude Account Switcher.app"
URL="https://github.com/$REPO/releases/latest/download/Claude-Account-Switcher.zip"

[[ "$(uname)" == "Darwin" ]] || { echo "Claude Account Switcher is Mac-only."; exit 1; }

echo "Downloading Claude Account Switcher…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"

pkill -f "Claude Account Switcher.app/Contents/MacOS/switcher" 2>/dev/null || true
rm -rf "$APP"
ditto "$TMP/Claude Account Switcher.app" "$APP"
open "$APP"
echo "Installed. It's in your Applications folder."
