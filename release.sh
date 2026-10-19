#!/bin/bash
# Publish a new version end to end:  ./release.sh 1.1
# Tags it, waits for CI to build + attach the release, then bumps the Homebrew cask.
set -euo pipefail
V="${1:?usage: ./release.sh <version>   e.g. ./release.sh 1.1}"
APP_REPO="hmbakhsh/claudeswap"
TAP_REPO="hmbakhsh/homebrew-tap"
CASK="Casks/claudeswap.rb"

git tag "v$V"
git push origin "v$V"

echo "Waiting for the release build…"
RUN=""
until [[ -n "$RUN" ]]; do
  sleep 5
  RUN="$(gh run list -R "$APP_REPO" --workflow release.yml --branch "v$V" -L 1 --json databaseId -q '.[0].databaseId')"
done
gh run watch "$RUN" -R "$APP_REPO" --exit-status

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
gh release download "v$V" -R "$APP_REPO" -p ClaudeSwap.zip -D "$TMP"
SHA="$(shasum -a 256 "$TMP/ClaudeSwap.zip" | cut -d' ' -f1)"

FILE="$(gh api "repos/$TAP_REPO/contents/$CASK")"
NEW="$(jq -r .content <<<"$FILE" | base64 -d |
  sed -E "s/^  version \".*\"/  version \"$V\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/")"
gh api -X PUT "repos/$TAP_REPO/contents/$CASK" \
  -f message="claudeswap $V" \
  -f content="$(printf '%s\n' "$NEW" | base64)" \
  -f sha="$(jq -r .sha <<<"$FILE")" >/dev/null

echo "Released $V. Coworkers update with: brew update && brew upgrade --cask claudeswap"
