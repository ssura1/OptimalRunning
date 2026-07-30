#!/usr/bin/env bash
# ADR-S-01 / ADR-S-03 — only the sensor-feed adapter knows the estimator exists.
#
# ## What this protects, and from what
#
# ADR-S-01 says PhoneStandalone is a `RunSensorFeed` tier, so the UI depends on `Core`'s
# output and never on how that output was obtained. That is a statement about the design.
# This is the statement about the build.
#
# The pressure it resists is concrete and already dated: S-063 has a measured amplitude
# exponent waiting to replace the shipped 0.25, S-064 has a calibration over-read to fix
# first, and ADR-S-06 amendment 2 has a gyroscope term that would add a whole feature to
# the step-length model. All three change `PhoneMotion` and none of them should require
# touching a screen. They will require it the moment something outside the adapter reads a
# `PhoneMotion` type — because then "what does the run list show?" has an answer that
# depends on the estimator's internals, and the next person to change the estimator has to
# go and find out where.
#
# ## The three rules
#
#   1. No `import PhoneMotion` outside the adapter, the capture tool, and the package
#      itself.
#   2. `PhoneSupport` and `Core` declare no build dependency on `PhoneMotion`.
#   3. No tunable named in `MotionEstimationConfiguration` appears anywhere else in the
#      phone app.
#
# Rule 3 is narrower than "no tunable is duplicated" and it is worth being precise about
# why that is enough. Rule 1 means no file outside the adapter can *read* a tunable's value
# — you cannot name `configuration.stepLength.amplitudeExponent` without importing the
# package that declares it. So the only way left to duplicate one is to write the number
# down again under its own name, which is exactly what rule 3 catches. A bare `0.25` with
# no name attached is not mechanically distinguishable from any other quarter and is not
# claimed to be caught; it is also not the failure that happens, because the reason anyone
# copies a tunable is to display or re-derive it, and that copy arrives with the name.
#
# ## Why the capture tool is exempt
#
# `Apps/iPhone/Sources/Standalone/Capture` writes `MotionTrace`, which is `PhoneMotion`'s
# own on-disk format (FR-S-F-2). It is a developer tool, deliberately not on the run path
# (AC-FR-S-F-1-9), and its whole purpose is to produce files the estimator reads — so a
# dependency on the estimator's format is what it is *for*, not a leak. Exempting it here
# rather than silently is the point: the exemption is one line and is reviewable.
#
# ## Why tests are exempt
#
# The acceptance test for this boundary has to stand on both sides of it: it mutates the
# estimator's configuration and asserts that the run list, the statistics and the live
# screen move. A test that could not import `PhoneMotion` could not prove the boundary
# works, only that it exists. The rule protects the shipping code path, which is where the
# coupling would cost something.
set -euo pipefail
cd "$(dirname "$0")/.."

MODULE=PhoneMotion
PACKAGE_ROOT=Apps/iPhone/PhoneMotion
ADAPTER_ROOT=Apps/iPhone/Sources/Standalone/Sensors
CAPTURE_ROOT=Apps/iPhone/Sources/Standalone/Capture
TUNABLES_FILE=$PACKAGE_ROOT/Sources/PhoneMotion/Configuration/MotionEstimationConfiguration.swift

status=0
fail() { echo "::error::$1"; status=1; }

[ -d "$PACKAGE_ROOT" ] || { echo "ok: $MODULE not present"; exit 0; }

# ---------------------------------------------------------------------------
# 1. Import-level coupling.
# ---------------------------------------------------------------------------
importers=$(grep -rlE "^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+$MODULE\b" \
  --include='*.swift' . 2>/dev/null | sed 's|^\./||' | grep -v '/\.build/' | sort || true)

adapter_importer_seen=0

while IFS= read -r file; do
  [ -n "$file" ] || continue
  case "$file" in
    "$PACKAGE_ROOT"/*) continue ;;
    "$CAPTURE_ROOT"/*) continue ;;
    "$ADAPTER_ROOT"/*) adapter_importer_seen=1; continue ;;
    */Tests/*|*Tests.swift) continue ;;
  esac
  fail "$file imports $MODULE from outside the sensor-feed adapter (ADR-S-01)"
  echo "  Only $ADAPTER_ROOT may depend on the estimator. Everything else — the run"
  echo "  controller, the live screen, Statistics, Settings, the hub — sees Core types."
  echo "  If you need a fact the estimator has, add it to ORModels.MotionTelemetry and"
  echo "  have the adapter fill it in."
done <<< "$importers"

# A gate that passes because the thing it guards has moved is worse than no gate: it
# reports "ok" forever while the adapter sits somewhere unguarded. So the adapter is
# required to be where this script thinks it is, and to be the thing that imports the
# estimator.
if [ "$adapter_importer_seen" -eq 0 ]; then
  fail "no file under $ADAPTER_ROOT imports $MODULE"
  echo "  Either the adapter has moved — in which case fix ADAPTER_ROOT in this script —"
  echo "  or it no longer exists, in which case this gate has been checking nothing."
fi

# ---------------------------------------------------------------------------
# 2. Build-configuration coupling.
#
# `PhoneSupport` is the load-bearing one. It holds the run controller, the presentation
# models and the run analysis — everything the phone decides — and it is macOS-hosted so
# those decisions are testable in seconds (ADR-013). A dependency edge from there to the
# estimator would make rule 1 unenforceable in the place it matters most, because the
# import would then be legal at the package level and only this script would object.
#
# `Core` is checked for completeness and would additionally violate ADR-001.
# ---------------------------------------------------------------------------
for manifest in Apps/iPhone/PhoneSupport/Package.swift Core/Package.swift; do
  [ -f "$manifest" ] || continue
  # Comments stripped first, for the same reason check-tier-isolation.sh does it: these
  # manifests explain their boundaries at length and the explanation names the module.
  #
  # A here-string rather than `printf … | grep -q`, and that is not a style preference.
  # `grep -q` exits the instant it matches, the writer ahead of it takes SIGPIPE, and
  # `set -o pipefail` then reports the *pipeline* as failed — so the `if` was false
  # exactly when the check found something. This gate shipped that way for one commit and
  # passed a deliberately planted dependency; it is written here because the same trap
  # silently disables any `producer | grep -q` under pipefail.
  stripped=$(sed 's|//.*||' "$manifest")
  if grep -qE "\"$MODULE\"|$MODULE\"|/$MODULE" <<< "$stripped"; then
    fail "$manifest declares a dependency on $MODULE (ADR-S-01, ADR-S-03)"
    echo "  PhoneSupport holds the run controller, the screen models and the run analysis."
    echo "  A dependency edge from there makes the import ban unenforceable where it counts."
  fi
done

# ---------------------------------------------------------------------------
# 3. Tunable duplication.
#
# The tunable names are read out of the configuration type itself rather than listed here,
# so adding a knob extends this check automatically and a list cannot go stale. The leaves
# are the scalars: every tunable is a `Double` or an `Int`, while the seven grouping
# properties are struct-typed and `description` is a `String`. Matching on the type is what
# separates them, and it is why `steps`, `filters` and `cadence` — which collide with
# ordinary English used all over the app — are not in the list.
# ---------------------------------------------------------------------------
if [ -f "$TUNABLES_FILE" ]; then
  tunables=$(grep -oE '^[[:space:]]*public var [a-zA-Z]+: (Double|Int)\b' "$TUNABLES_FILE" \
    | awk '{print $3}' | tr -d ':' | sort -u)

  if [ -z "$tunables" ]; then
    fail "no tunables could be read from $TUNABLES_FILE — this check is inert"
  fi

  scan_roots=""
  for root in Apps/iPhone/Sources Apps/iPhone/PhoneSupport/Sources; do
    [ -d "$root" ] && scan_roots="$scan_roots $root"
  done

  for name in $tunables; do
    hits=$(grep -rlw "$name" $scan_roots --include='*.swift' 2>/dev/null \
      | grep -v "^$ADAPTER_ROOT/" | grep -v "^$CAPTURE_ROOT/" || true)
    [ -n "$hits" ] || continue
    fail "the $MODULE tunable '$name' is named outside the estimator"
    printf '%s\n' "$hits" | sed 's|^|  |'
    echo "  NFR-S-19: every tunable lives in exactly one configuration type. A second"
    echo "  mention is a second place S-063/S-064 would have to change."
  done
fi

# ---------------------------------------------------------------------------
# 4. The reverse edge.
#
# The estimator must not learn about the app. `check-core-imports.sh` already forbids Apple
# frameworks here; this forbids the tier packages, which are not frameworks and would
# otherwise pass that gate.
# ---------------------------------------------------------------------------
if matches=$(grep -rnE "^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(PhoneSupport|WatchSupport|LegacySupport)\b" \
  "$PACKAGE_ROOT/Sources" 2>/dev/null); then
  fail "$MODULE imports a tier package (ADR-S-03)"
  echo "$matches" | sed 's|^|  |'
fi

[ $status -eq 0 ] && echo "ok: only the sensor-feed adapter depends on $MODULE"
exit $status
