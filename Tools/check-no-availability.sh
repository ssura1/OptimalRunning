#!/usr/bin/env bash
# CON-3 / AC-FR-K-1-5 — no version-availability conditionals in a watch app target.
#
# Each watch tier has exactly one deployment target and its own source tree, so an
# `#available` check inside one means either dead code or the conditional soup the
# product memo explicitly rules out. Enforced rather than requested.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
for dir in Apps/WatchModern Apps/WatchLegacy; do
  [ -d "$dir" ] || continue
  if matches=$(grep -rnE '#available|@available\((watchOS|iOS)' "$dir" --include='*.swift' 2>/dev/null); then
    echo "::error::$dir must not contain availability conditionals (CON-3)"
    echo "$matches"
    status=1
  fi
done
[ $status -eq 0 ] && echo "ok: no availability conditionals in watch targets"
exit $status
