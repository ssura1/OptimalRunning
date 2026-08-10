#!/usr/bin/env bash
# Setting `allowsBackgroundLocationUpdates` requires the `location` background mode to be
# declared in the same tier's bundle. This checks the two agree.
#
# ## The bug this exists to prevent
#
# CoreLocation's own header states the rule with no room for interpretation:
#
#     Setting this property to YES when UIBackgroundModes does not include
#     "location" is a fatal error.
#
# Fatal means the process is killed. Not an exception that can be caught, not a property
# that silently fails to take effect — the app dies at the assignment. Both watch tiers
# shipped this way: `allowsBackgroundLocationUpdates = true` in `LiveSensorFeed` against a
# bundle declaring only `workout-processing` and `audio`.
#
# It took a device to find, and it presented as an authorization bug rather than a crash.
# `requestWhenInUseAuthorization` returns immediately and the *system* draws the permission
# sheet, so the sheet outlives the process that asked for it: the runner sees the prompt,
# taps Allow, and lands on the watch face. Nothing about that sequence points at a plist.
#
# Nothing else could have caught it. Neither watch `LiveSensorFeed` is reachable from any
# test — they are the device-only half of the split that keeps `SensorPipeline` testable —
# and the tiers had never been run on real hardware. `Apps/iPhone` had the declaration
# right from the start (CON-S-4) and even guards the assignment in `MotionCaptureRecorder`,
# so the knowledge existed in this repository and simply never crossed tiers. That is
# precisely the kind of erosion a structural gate is for.
#
# ## The rule
#
# Any tier whose sources set `allowsBackgroundLocationUpdates` to `true` must declare
# `location` among its background modes. Assignments to `false` are ignored: that is the
# documented way to *stand down* background updates and needs no declaration.
set -euo pipefail
cd "$(dirname "$0")/.."

FAILED=0
FOUND=0

# Read the tier's declaration from the *plist*, never from the project file that produces
# it. That is not a stylistic preference: `INFOPLIST_KEY_UIBackgroundModes` is a setting
# Xcode does not define — `INFOPLIST_KEY_*` covers a fixed allowlist, `UIBackgroundModes`
# is not on it — so it is accepted in silence and reaches nothing. WatchLegacy carried
# exactly that from Wave 4, which means a gate reading project.yml would have called a tier
# with *no* declared background modes correct. The plist is the artifact; check the artifact.
declared_modes() {
  local tier="$1"
  while IFS= read -r plist; do
    [ -n "$plist" ] || continue
    # The array that follows the key, not the whole file — a `location` string belonging
    # to some other key must not satisfy this.
    sed -n '/<key>UIBackgroundModes<\/key>/,/<\/array>/p' "$plist"
  done < <(grep -rl "<key>UIBackgroundModes</key>" "$tier" --include='*.plist' 2>/dev/null || true)
}

# And reject the no-op form outright wherever it appears, so it cannot come back looking
# like a declaration. The error is worth more than the failure: someone re-adding this would
# otherwise spend the same evening discovering it does nothing.
while IFS=: read -r file line _; do
  [ -n "${file:-}" ] || continue
  echo "::error file=$file,line=$line::INFOPLIST_KEY_UIBackgroundModes is not a build setting Xcode defines, so it silently reaches no plist."
  echo "  INFOPLIST_KEY_* only covers a fixed allowlist (see CoreBuildSystem.xcspec); the"
  echo "  usage-description keys are on it and UIBackgroundModes is not, which is why a block"
  echo "  containing both looks like it works. Declare the modes in an explicit Info.plist"
  echo "  instead — xcodegen's \`info: properties:\` merges fine alongside GENERATE_INFOPLIST_FILE."
  FAILED=1
# Anchored to an actual assignment (`KEY:` in YAML, `KEY =` in a pbxproj) so that prose
# warning people off the setting — including the comment this rule left behind in
# WatchLegacy's project.yml — does not trip the rule that prose exists to explain.
done < <(grep -rnE "^[[:space:]]*INFOPLIST_KEY_UIBackgroundModes[[:space:]]*[:=]" Apps --include='*.yml' --include='*.pbxproj' 2>/dev/null || true)

for tier in Apps/*/; do
  tier="${tier%/}"
  [ -d "$tier/Sources" ] || continue

  # Only the assignments that turn it on. `= false` is the documented way to stand down.
  while IFS=: read -r file line _; do
    [ -n "${file:-}" ] || continue
    FOUND=1
    if ! declared_modes "$tier" | grep -q 'location'; then
      echo "::error file=$file,line=$line::allowsBackgroundLocationUpdates is set to true, but $tier does not declare the \"location\" background mode."
      echo "  CoreLocation calls this a fatal error: the process is killed at this line, not"
      echo "  degraded. On a watch it presents as the app vanishing just after the location"
      echo "  permission sheet, because the system draws that sheet and it outlives the crash."
      echo "  Declare it alongside the tier's other modes:"
      echo "      UIBackgroundModes: [..., location]"
      FAILED=1
    fi
  done < <(grep -rn "allowsBackgroundLocationUpdates *= *true" "$tier/Sources" --include='*.swift' 2>/dev/null || true)
done

# A gate that silently matches nothing is a gate that has stopped working. The assignment
# is load-bearing in three tiers; if it is nowhere to be found, this script is being run
# against a tree it no longer understands.
if [ "$FOUND" -eq 0 ]; then
  echo "::error::no allowsBackgroundLocationUpdates assignment found in any tier — this gate is no longer checking anything."
  exit 1
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "ok: every tier setting allowsBackgroundLocationUpdates declares the location background mode"
