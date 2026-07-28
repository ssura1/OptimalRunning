#!/usr/bin/env bash
# ADR-001 — the pure packages import only the Swift standard library and cross-platform
# Foundation.
#
# This is what lets the whole engine build and test on a Linux container in seconds.
# The moment one file imports CoreLocation "just for CLLocation", the test suite needs
# a simulator and the architecture is gone. Cheaper to catch here than in review.
#
# Two roots, for the same reason under two ADRs:
#
#   Core                      ADR-001 — judgement logic shared by every tier.
#   Apps/iPhone/PhoneMotion   ADR-S-03 — the standalone tier's motion estimation.
#
# PhoneMotion is here because the constraint binds *harder* there than in Core. The iOS
# Simulator has no accelerometer and no gyroscope at all (CON-S-1), so estimation code
# that imported CoreMotion would be verifiable only by hand, on a phone — which for a
# numerical algorithm is not verification. Keeping it framework-free is what makes it
# testable at all, not merely testable faster.
set -euo pipefail
cd "$(dirname "$0")/.."

BANNED='HealthKit|CoreLocation|CoreMotion|WatchKit|SwiftUI|UIKit|AppKit|WatchConnectivity|SwiftData|Charts|MapKit|AVFoundation'

ROOTS=(
  "Core/Sources"
  "Apps/iPhone/PhoneMotion/Sources"
)

status=0
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  if matches=$(grep -rnE "^[[:space:]]*(@[a-zA-Z]+ )?import ($BANNED)" "$root" 2>/dev/null); then
    echo "::error::$root must not import Apple frameworks (ADR-001, ADR-S-03)"
    echo "$matches"
    status=1
  fi
done

[ $status -eq 0 ] && echo "ok: no pure package imports an Apple framework"
exit $status
