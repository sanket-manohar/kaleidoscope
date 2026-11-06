#!/usr/bin/env bash
# Replaces the link placeholders in the repository with your real values.
# Usage: tool/set_links.sh <github-username> [website-url] [youtube-handle] [instagram-handle]
set -euo pipefail
GH="${1:?github username required}"
SITE="${2:-https://$GH.github.io/kaleidoscope}"
YT="${3:-}"
IG="${4:-}"
files=$(grep -rlE "YOUR-GITHUB-USERNAME|YOUR-WEBSITE|YOUR-CHANNEL|YOUR-HANDLE" --exclude-dir=.git --exclude-dir=.dart_tool --exclude-dir=build --exclude=set_links.sh . || true)
for f in $files; do
  sed -i.bak \
    -e "s#https://YOUR-GITHUB-USERNAME.github.io/kaleidoscope#$SITE#g" \
    -e "s#https://YOUR-WEBSITE.com#$SITE#g" \
    -e "s#YOUR-GITHUB-USERNAME#$GH#g" "$f"
  [ -n "$YT" ] && sed -i.bak -e "s#@YOUR-CHANNEL#@$YT#g" "$f"
  [ -n "$IG" ] && sed -i.bak -e "s#YOUR-HANDLE#$IG#g" "$f"
  rm -f "$f.bak"
done
echo "Updated: $files"
