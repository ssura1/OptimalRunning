#!/usr/bin/env bash
# ADR-001 — Core imports only the Swift standard library and cross-platform Foundation.
#
# This is what lets the whole engine build and test on a Linux container in seconds.
# The moment one file imports CoreLocation "just for CLLocation", the test suite needs
# a simulator and the architecture is gone. Cheaper to catch here than in review.
set -euo pipefail
cd "$(dirname "$0")/.."

BANNED='HealthKit|CoreLocation|CoreMotion|WatchKit|SwiftUI|UIKit|AppKit|WatchConnectivity|SwiftData|Charts|MapKit'

if matches=$(grep -rnE "^[[:space:]]*(@[a-zA-Z]+ )?import ($BANNED)" Core/Sources 2>/dev/null); then
  echo "::error::Core must not import Apple frameworks (ADR-001)"
  echo "$matches"
  exit 1
fi
echo "ok: Core imports no Apple frameworks"
