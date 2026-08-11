#!/usr/bin/env bash
# A finished run must actually reach the sync pipeline (T-106).
#
# ## The bug this exists to prevent
#
# Not a broken component — every component was fine. `RunEnvelopeBuilder`,
# `SyncCoordinator`, `PendingPayloadQueue` and `DownlinkApplier` were all written, all
# tested, and all correct. The phone's receiving half was complete and wired to `WCSession`.
#
# And none of it ran, because nothing in the watch app ever constructed any of it.
# `RunEnvelopeBuilder` was referenced nowhere outside its own file and its own tests.
# `SyncCoordinator` was never instantiated. There was no `WCSession` conformer on the watch
# at all. A finished run called `finalizeRun()`, which deleted the only file it had written,
# and that was the end of it — no error, no warning, nothing to notice, and 180 passing
# tests either side of a pipeline with no middle.
#
# That is a whole category of defect that unit tests structurally cannot catch: every part
# works, and the assembly does not exist. So the assembly is what this checks.
#
# ## The rules
#
# 1. `RunEnvelopeBuilder` is called from shipping code, not only from tests.
# 2. The watch app constructs a `SyncCoordinator`.
# 3. The watch app hands one to `RunSessionModel` as its `sink:`.
# 4. A `FileTransporting` conformer exists in the watch app target.
#
# Each is a thing that was false, and each was false silently.
set -euo pipefail
cd "$(dirname "$0")/.."

WATCH_APP="Apps/WatchModern/Sources"
SUPPORT="Apps/WatchModern/WatchSupport/Sources"
FAILED=0

fail () {
  echo "::error::$1"
  shift
  for line in "$@"; do echo "  $line"; done
  FAILED=1
}

# 1. The envelope builder is reachable from shipping code.
#    Excludes its own definition, so "it defines itself" cannot satisfy the rule.
if ! grep -rn "RunEnvelopeBuilder\.build" "$WATCH_APP" "$SUPPORT" \
      --include='*.swift' 2>/dev/null \
      | grep -qv "Transport/RunEnvelopeBuilder.swift"; then
  fail "no shipping code calls RunEnvelopeBuilder.build — a finished run is never turned into an envelope." \
       "This was true for three waves while the builder's own tests passed." \
       "The call belongs in RunSessionModel.end, after the samples are safe and before they are released."
fi

# 2. Something in the app actually constructs the coordinator.
if ! grep -rq "SyncCoordinator(" "$WATCH_APP" --include='*.swift' 2>/dev/null; then
  fail "the watch app never constructs a SyncCoordinator, so nothing can be queued for the phone." \
       "Expected in AppCoordinator, owned for the app's lifetime — a pending payload outlives its run."
fi

# 3. And hands it to the run as a sink. A coordinator that exists but is not connected to
#    the run is the same bug one layer up.
if ! grep -rq "sink:" "$WATCH_APP" --include='*.swift' 2>/dev/null; then
  fail "no RunSessionModel is given a sink:, so a finished run has nowhere to go." \
       "RunSessionModel.end only builds and hands over an envelope when a sink is present."
fi

# 4. A real transport exists. Without one the coordinator is holding a protocol nobody
#    implements outside tests, which is exactly the state this tier shipped in.
if ! grep -rlq ": *FileTransporting\|FileTransporting *{" "$WATCH_APP" --include='*.swift' 2>/dev/null; then
  fail "no FileTransporting conformer in the watch app target — the queue has nowhere to hand files." \
       "WatchConnectivity's WCSession.transferFile is the real one; the fakes live in tests."
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "ok: a finished run is built into an envelope, handed to a coordinator, and has a transport to leave on"
