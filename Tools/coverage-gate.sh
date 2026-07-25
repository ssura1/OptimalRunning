#!/usr/bin/env bash
# NFR-18 — fail the build if Core line coverage drops below the threshold.
#
# Usage: Tools/coverage-gate.sh [minimum-percent]
#
# Only *product* targets are counted. Test infrastructure (ORConformance, TestSupport)
# and the two CLIs (ORReplay, ORSelfCheck) are excluded: they exist to exercise the
# engine, and counting them would let a contributor raise the number without testing
# anything.
set -euo pipefail
cd "$(dirname "$0")/.."

MIN="${1:-85}"
PRODUCT_TARGETS="ORModels|ORPace|ORIntervals|ORAlerts|ORStats|ORColor"

BIN=$(swift build --package-path Core --show-bin-path)
PROF="$BIN/codecov/default.profdata"
if [ ! -f "$PROF" ]; then
  echo "::error::no coverage data — run: swift test --package-path Core --enable-code-coverage"
  exit 1
fi

# The test bundle differs between macOS (.xctest bundle) and Linux (bare binary).
if [ -d "$BIN/OptimalRunnerCorePackageTests.xctest" ]; then
  OBJ="$BIN/OptimalRunnerCorePackageTests.xctest/Contents/MacOS/OptimalRunnerCorePackageTests"
else
  OBJ="$BIN/OptimalRunnerCorePackageTests.xctest"
fi

xcrun llvm-cov export -summary-only -instr-profile "$PROF" "$OBJ" 2>/dev/null \
  | python3 -c '
import json, re, sys
data = json.load(sys.stdin)
pattern = re.compile(r"/Core/Sources/('"$PRODUCT_TARGETS"')/")
covered = total = 0
rows = {}
for f in data["data"][0]["files"]:
    m = pattern.search(f["filename"])
    if not m:
        continue
    lines = f["summary"]["lines"]
    covered += lines["covered"]
    total += lines["count"]
    t = m.group(1)
    c, n = rows.get(t, (0, 0))
    rows[t] = (c + lines["covered"], n + lines["count"])

print(f"{\"target\":<14}{\"covered\":>9}{\"lines\":>8}{\"pct\":>8}")
for t in sorted(rows):
    c, n = rows[t]
    pct = 100.0 * c / n if n else 100.0
    print(f"{t:<14}{c:>9}{n:>8}{pct:>7.1f}%")

pct = 100.0 * covered / total if total else 0.0
print(f"{\"-\"*39}")
print(f"{\"TOTAL\":<14}{covered:>9}{total:>8}{pct:>7.1f}%")
minimum = float("'"$MIN"'")
if pct < minimum:
    print(f"::error::Core coverage {pct:.1f}% is below the required {minimum:.0f}% (NFR-18)")
    sys.exit(1)
print(f"ok: Core coverage {pct:.1f}% meets the {minimum:.0f}% gate")
'
