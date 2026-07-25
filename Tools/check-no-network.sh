#!/usr/bin/env bash
# NFR-14 / NFR-15 — OptimalRunner is device-local. No backend, no telemetry, no SDK
# that transmits.
#
# "We don't send your data anywhere" is only a credible promise if something checks it
# on every push. Route and health data are among the most sensitive categories a phone
# holds, so this gate is deliberately blunt: any networking symbol at all fails.
set -euo pipefail
cd "$(dirname "$0")/.."

BANNED_IMPORT='Network|CFNetwork|Alamofire|Firebase|FirebaseAnalytics|Sentry|Mixpanel|Amplitude'
BANNED_SYMBOL='URLSession|NSURLConnection|CFStreamCreatePair|NWConnection'

status=0
for dir in Core/Sources Apps; do
  [ -d "$dir" ] || continue
  if matches=$(grep -rnE "^[[:space:]]*import ($BANNED_IMPORT)" "$dir" --include='*.swift' 2>/dev/null); then
    echo "::error::networking/telemetry import found — OptimalRunner is device-local (NFR-14, NFR-15)"
    echo "$matches"
    status=1
  fi
  if matches=$(grep -rnE "\b($BANNED_SYMBOL)\b" "$dir" --include='*.swift' 2>/dev/null); then
    echo "::error::networking symbol found — OptimalRunner is device-local (NFR-14, NFR-15)"
    echo "$matches"
    status=1
  fi
done

if matches=$(grep -rn 'NSAppTransportSecurity' Apps --include='*.plist' 2>/dev/null); then
  echo "::error::NSAppTransportSecurity implies network access (NFR-14)"
  echo "$matches"
  status=1
fi

[ $status -eq 0 ] && echo "ok: no networking or telemetry anywhere"
exit $status
