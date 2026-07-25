#!/usr/bin/env bash
# CON-3 / AC-FR-K-1-5 — no version-availability conditionals in a watch app target.
#
# Each watch tier has exactly one deployment target and its own source tree, so an
# availability check inside one means either dead code or the conditional soup the
# product memo explicitly rules out. Enforced rather than requested.
#
# Line comments are stripped before matching. The gate is about what the compiler
# sees, and a file that *documents* why it avoids an availability check — which is
# genuinely useful for the next reader, especially where a wanted API is gated behind
# a newer OS — was otherwise failing its own rule for explaining it. Also excludes
# each tier's `.build` directory, which holds SDK copies full of real `@available`.
set -euo pipefail
cd "$(dirname "$0")/.."

# Both forms matter and neither implies the other: `#available` is the runtime
# conditional, `@available(watchOS…)` the declaration attribute that lets one creep
# in later.
PATTERN='#available|@available\((watchOS|iOS)'

status=0
for dir in Apps/WatchModern Apps/WatchLegacy; do
  [ -d "$dir" ] || continue

  while IFS= read -r file; do
    # `sed` removes `//` to end of line, then `grep -n` keeps real line numbers
    # because the substitution is line-for-line rather than a deletion.
    if matches=$(sed 's://.*::' "$file" | grep -nE "$PATTERN"); then
      echo "::error::$file must not contain availability conditionals (CON-3)"
      echo "$matches" | sed "s|^|  $file:|"
      status=1
    fi
  done < <(find "$dir" -name '*.swift' -not -path '*/.build/*' -print)
done

[ $status -eq 0 ] && echo "ok: no availability conditionals in watch targets"
exit $status
