#!/usr/bin/env bash
# NFR-18 — fail the build if Core line coverage drops below the threshold.
#
# Usage: Tools/coverage-gate.sh [minimum-percent]
#
# Only *product* targets are counted. Test infrastructure (ORConformance, TestSupport)
# and the two CLIs (ORReplay, ORSelfCheck) are excluded: they exist to exercise the
# engine, and counting them would let a contributor raise the number without testing
# anything.
#
# Runs on macOS and on Linux, which it previously did not. Two macOS-only assumptions
# had gone unnoticed because the only place this was ever run by hand was a Mac:
# `xcrun`, which does not exist off macOS, and `python3`, which the `swift:6.1`
# container has no copy of. The gate therefore failed with exit 127 on every CI run
# since it was written. The summariser is now a Swift script — the one interpreter a
# Swift project can assume — and llvm-cov is located rather than assumed.
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

if [ ! -e "$OBJ" ]; then
  echo "::error::no test binary at $OBJ — run: swift test --package-path Core --enable-code-coverage"
  exit 1
fi

# Locate llvm-cov. On macOS it comes via xcrun; on Linux it ships beside `swift` in the
# toolchain, which is not always on PATH — hence the third candidate.
if command -v xcrun >/dev/null 2>&1; then
  LLVM_COV=(xcrun llvm-cov)
elif command -v llvm-cov >/dev/null 2>&1; then
  LLVM_COV=(llvm-cov)
elif [ -x "$(dirname "$(command -v swift)")/llvm-cov" ]; then
  LLVM_COV=("$(dirname "$(command -v swift)")/llvm-cov")
else
  echo "::error::llvm-cov not found — tried xcrun, PATH, and the Swift toolchain directory"
  exit 1
fi

# Note the absence of `2>/dev/null`. Silencing llvm-cov is what let this script report a
# confusing "python3: command not found" instead of the real problem for as long as it did;
# a coverage gate that hides its own tooling errors is worse than no gate.
"${LLVM_COV[@]}" export -summary-only -instr-profile "$PROF" "$OBJ" \
  | swift Tools/coverage-summarize.swift "$PRODUCT_TARGETS" "$MIN"
