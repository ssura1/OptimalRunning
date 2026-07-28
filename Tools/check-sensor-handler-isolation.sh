#!/usr/bin/env bash
# S-057 — sensor callbacks must be passed as explicitly-typed `@Sendable` values,
# never as trailing closures.
#
# ## The bug this exists to prevent
#
# `CMDeviceMotionHandler` and `CMPedometerHandler` are plain Objective-C blocks with no
# `NS_SWIFT_SENDABLE`, so they import as non-Sendable closure types. A closure *literal*
# written inside a method of a `@MainActor` type therefore inherits main-actor isolation —
# silently, with no diagnostic, because the imported block type carries no isolation
# information for the compiler to contradict. CoreMotion then invokes it on the background
# queue it was handed, Swift's runtime checks the executor, finds it is not the main one,
# and traps with EXC_BREAKPOINT in `swift_task_isCurrentExecutor`.
#
# That is not a hypothetical. It killed five consecutive field captures within seconds of
# the first sample, which is why all five files were zero bytes, and it took a device to
# find: the Simulator has no accelerometer (CON-S-1), so the handler is never invoked and
# the check never runs. A bug that only exists on hardware, in a tool whose entire purpose
# is to be used on hardware, is worth a build failure.
#
# Both directions were verified before this gate was written. With the annotation, a
# main-actor access inside the handler is a compile error; without it, the identical access
# compiles clean. The annotation is what moves the failure from a run to a build.
#
# ## The rule
#
# Every call to a CoreMotion updates-with-handler API must use the explicit
# `withHandler:` argument label, which forces the handler to be a named value whose type —
# and therefore whose `@Sendable`-ness — is written down. A trailing closure is rejected
# because that is precisely the form that silently inherits isolation.
set -euo pipefail
cd "$(dirname "$0")/.."

# The exemption below is the reason altimeter calls are included rather than skipped: a
# handler delivered explicitly `to: .main` runs on the main actor, so a closure literal that
# inherits main-actor isolation is correct there. That is a property of the *call*, not of
# the API, which is why the rule is written in terms of the delivery queue.
APIS='startDeviceMotionUpdates|startAccelerometerUpdates|startGyroUpdates|startMagnetometerUpdates|startRelativeAltitudeUpdates|startAbsoluteAltitudeUpdates|startUpdates\(from:'
ROOTS="Apps/iPhone/Sources Apps/WatchModern/Sources Apps/WatchLegacy/Sources"
FAILED=0

for root in $ROOTS; do
  [ -d "$root" ] || continue
  while IFS= read -r file; do
    # Look at each call site and the two lines that may continue the statement. A call
    # that passes its handler properly names `withHandler:`; a trailing closure does not.
    while IFS=: read -r line _; do
      window=$(sed -n "${line},$((line + 2))p" "$file")
      # Delivered to the main queue: the closure runs on the main actor, so inheriting
      # main-actor isolation is correct rather than a trap.
      if printf '%s' "$window" | grep -qE 'to: \.main|to: OperationQueue\.main'; then
        continue
      fi
      if ! printf '%s' "$window" | grep -q 'withHandler:'; then
        echo "::error file=$file,line=$line::sensor callback passed as a trailing closure."
        echo "  A closure literal here inherits @MainActor isolation from the enclosing type"
        echo "  and will trap (EXC_BREAKPOINT) when the framework invokes it off the main"
        echo "  queue. Declare it explicitly instead:"
        echo "      let handler: @Sendable (CMDeviceMotion?, (any Error)?) -> Void = { ... }"
        echo "      motion.startDeviceMotionUpdates(using: ..., to: queue, withHandler: handler)"
        FAILED=1
      fi
    done < <(grep -nE "\.($APIS)" "$file" || true)
  done < <(grep -rlE "\.($APIS)" "$root" --include='*.swift' || true)
done

# The handlers that do exist must actually carry the annotation.
while IFS= read -r file; do
  if grep -q 'withHandler: handler' "$file" && ! grep -q '@Sendable (CM' "$file"; then
    echo "::error file=$file::a sensor handler is passed by name but is not declared"
    echo "  as an explicitly-typed @Sendable closure, so it may still be main-actor isolated."
    FAILED=1
  fi
done < <(grep -rlE "\.($APIS)" $ROOTS --include='*.swift' 2>/dev/null || true)

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "ok: every sensor callback is an explicitly-typed @Sendable value"
