#!/usr/bin/env bash
# Claude multi-account auto-switch — one-shot setup (macOS).
#
# Installs claude-swap (https://github.com/realiti4/claude-swap), walks you
# through saving each of your Claude subscriptions, then runs `cswap auto` in
# the background so the active login moves to the account with the most quota
# left before you hit a 5h/7d limit. Works for anything that uses your default
# Claude Code login: the CLI, the VS Code extension, T3 Code.
#
#   ./setup.sh               install + add accounts + start background switcher
#   ./setup.sh --uninstall   stop the background switcher (keeps saved accounts)
#   THRESHOLD=80 ./setup.sh  switch at 80% used instead of 85%
set -euo pipefail

LABEL="dev.claude-swap.auto"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/claude-swap-auto.log"
THRESHOLD="${THRESHOLD:-85}"

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

stop_agent() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
}

if [[ "${1:-}" == "--uninstall" ]]; then
  stop_agent
  say "Background switcher removed. Saved accounts kept — 'cswap purge' deletes them."
  exit 0
fi

[[ "$(uname)" == "Darwin" ]] || die "macOS only. On Linux/Windows: 'uv tool install claude-swap', then see README."
command -v claude >/dev/null || die "Install Claude Code first: https://docs.claude.com/en/docs/claude-code"

say "Installing uv + claude-swap"
if ! command -v uv >/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
uv tool install --upgrade --python 3.12 claude-swap >/dev/null
CSWAP="$(command -v cswap || echo "$HOME/.local/bin/cswap")"
[[ -x "$CSWAP" ]] || die "cswap not found after install"

say "Save your accounts"
cat <<'EOF'
For EACH Claude subscription you own:
  1. In another terminal run:  claude   then type  /login  and sign in.
     (Never use /logout — it can kill the saved token of the account you leave.)
  2. Come back here and press Enter to save it.
EOF
while true; do
  read -r -p $'\nSigned in to an account to save? [Enter = save, d = done] ' ans
  [[ "$ans" == "d" ]] && break
  "$CSWAP" add || echo "Save failed — check you're signed in, then try again."
done

count="$("$CSWAP" list --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("accounts", d) if isinstance(d, dict) else d))' 2>/dev/null || echo "?")"
[[ "$count" == "?" || "$count" -ge 2 ]] || echo "Only $count account saved — auto-switch needs at least 2."

say "Starting background switcher (switches at ${THRESHOLD}% used)"
stop_agent
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$CSWAP</string><string>auto</string>
    <string>--threshold</string><string>$THRESHOLD</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"

say "Done"
"$CSWAP" list || true
cat <<EOF

  See usage:        cswap            (dashboard)   ·   cswap list
  Switch by hand:   cswap switch --strategy best
  Switcher log:     tail -f $LOG
  Stop switcher:    ./setup.sh --uninstall
EOF
