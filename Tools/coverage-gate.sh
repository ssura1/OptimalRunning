#!/usr/bin/env bash
# NFR-18 — fail the build if Core line coverage drops below the threshold.
#
# Usage: Tools/coverage-gate.sh [minimum-percent] [package-path]
#
# Defaults to `Core`. The standalone track's `PhoneMotion` (ADR-S-03) is gated on the
# same 85% terms (NFR-S-21), so the package is a parameter rather than a hardcoded path —
# it was hardcoded, and duplicating this script per package would have meant two copies of
# the llvm-cov-location logic below to keep in step.
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
PACKAGE="${2:-Core}"

# Product targets per package. Test infrastructure and CLIs are excluded everywhere: they
# exist to exercise the code under test, and counting them would let a contributor raise
# the number without testing anything.
case "$PACKAGE" in
  Core)
    PRODUCT_TARGETS="ORModels|ORPace|ORIntervals|ORAlerts|ORStats|ORColor"
    BUNDLE="OptimalRunnerCorePackageTests"
    SOURCE_ROOT="Core/Sources"
    ;;
  Apps/iPhone/PhoneMotion)
    # `SyntheticGaitSignal` is deliberately *included*: it ships in the library, it is
    # exercised by the property suite, and excluding it would hide an untested generator
    # behind a green gate — which on this track is exactly the wrong thing to hide.
    PRODUCT_TARGETS="PhoneMotion"
    BUNDLE="PhoneMotionPackageTests"
    SOURCE_ROOT="PhoneMotion/Sources"
    ;;
  *)
    echo "::error::no product-target list for package '$PACKAGE' — add one here"
    exit 1
    ;;
esac

BIN=$(swift build --package-path "$PACKAGE" --show-bin-path)
PROF="$BIN/codecov/default.profdata"
if [ ! -f "$PROF" ]; then
  echo "::error::no coverage data — run: swift test --package-path $PACKAGE --enable-code-coverage"
  exit 1
fi

# The test bundle differs between macOS (.xctest bundle) and Linux (bare binary).
if [ -d "$BIN/$BUNDLE.xctest" ]; then
  OBJ="$BIN/$BUNDLE.xctest/Contents/MacOS/$BUNDLE"
else
  OBJ="$BIN/$BUNDLE.xctest"
fi

if [ ! -e "$OBJ" ]; then
  echo "::error::no test binary at $OBJ — run: swift test --package-path $PACKAGE --enable-code-coverage"
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
  | swift Tools/coverage-summarize.swift "$PRODUCT_TARGETS" "$MIN" "$SOURCE_ROOT"
