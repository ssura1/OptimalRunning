#!/usr/bin/env bash
# CON-S-7 / AC-FR-S-F-3-4 — synthetic signals may never back an accuracy claim.
#
# The iOS Simulator has no accelerometer and no gyroscope (CON-S-1), so the tempting
# shortcut on this track is to generate "accelerometer-like" data and call the result
# validation. It is not. A synthetic signal is built from an assumption about what running
# looks like; running an estimator over it and reporting a distance error measures the
# generator's assumption round-tripped through the estimator — a tautology dressed as a
# result, and the same false-confidence failure as a test that asserts what its author
# believed rather than what the code does.
#
# Synthetic signals are legitimate for *structural* properties over labelled inputs: a
# known step count, a known cadence, a known stationary interval. Those are provable this
# way. Accuracy percentages are not, and they belong to recorded traces (FR-S-F-2).
#
# This gate fails when one file both references the synthetic generator and asserts an
# accuracy bound, which is the mechanical form of that rule.
set -euo pipefail
cd "$(dirname "$0")/.."

SEARCH_ROOTS=(
  "Apps/iPhone/PhoneMotion/Tests"
  "Apps/iPhone/Tests"
)

# The generator, by type name. Renaming it without updating this list would silently
# disable the gate, so the name is asserted to exist below.
GENERATOR='SyntheticGaitSignal'

# Assertions that state an accuracy *bound* — a percentage, an error, a tolerance against
# a reference. Deliberately narrow: `XCTAssertEqual(..., accuracy:)` on its own is fine and
# ubiquitous (comparing two floats), so what is banned is the vocabulary of *validation*.
BOUND_PATTERN='(accuracyFraction|percentError|errorPercent|withinPercent|distanceError|MAPE|referenceMetres[[:space:]]*[,)]|vs[[:space:]]+reference)'

status=0

if ! grep -rq "struct ${GENERATOR}" Apps/iPhone/PhoneMotion/Sources 2>/dev/null; then
  echo "::error::${GENERATOR} not found — this gate is checking for a type that no longer"
  echo "         exists, which means it has been silently disabled. Update GENERATOR."
  exit 1
fi

for root in "${SEARCH_ROOTS[@]}"; do
  [ -d "$root" ] || continue
  while IFS= read -r file; do
    if grep -qE "$BOUND_PATTERN" "$file"; then
      echo "::error::$file references $GENERATOR and asserts an accuracy bound."
      echo "         Accuracy claims must come from a recorded trace (CON-S-7)."
      grep -nE "$BOUND_PATTERN" "$file" | head -5
      status=1
    fi
  done < <(grep -rl "$GENERATOR" "$root" 2>/dev/null || true)
done

# The second half of the rule: a committed trace must declare what it can validate, or a
# reader has no way to tell an exercised pipeline from a validated one (AC-FR-S-F-2-4).
if [ -d "Fixtures/motion" ]; then
  while IFS= read -r trace; do
    if ! grep -q '"references"' "$trace"; then
      echo "::error::$trace has no references block — a trace must state what reference"
      echo "         data it carries and therefore what it is able to validate."
      status=1
    fi
  done < <(find Fixtures/motion -maxdepth 1 -name '*.motion.json' 2>/dev/null || true)
fi

# S-059 — no committed trace may carry absolute position.
#
# A recording made during a real run is a map of where its runner lives, and this
# repository is public. One trace was committed with 276 absolute fixes intact before this
# check existed. `Tools/scrub-trace.swift` replaces coordinates with offsets from the
# trace's own first fix, which keeps every quantity the validation uses — displacement,
# shape, bearing change — and discards the origin. The estimator never read the
# coordinates, so nothing is lost by their absence.
if [ -d "Fixtures/motion" ]; then
  while IFS= read -r trace; do
    if grep -qE '"(latitude|longitude)"' "$trace"; then
      count=$(grep -oE '"latitude"' "$trace" | wc -l | tr -d ' ')
      echo "::error::$trace carries $count absolute coordinates."
      echo "         This repository is public and a route is a home address. Scrub it:"
      echo "             swift Tools/scrub-trace.swift '$trace' '$trace.scrubbed'"
      echo "             mv '$trace.scrubbed' '$trace'"
      status=1
    fi
  done < <(find Fixtures/motion -name '*.motion.json' 2>/dev/null || true)
fi

if [ $status -eq 0 ]; then
  echo "ok: no synthetic signal backs an accuracy claim, no trace carries absolute position"
fi
exit $status
