# Motion traces

Recorded hand-held motion, and the only input from which the standalone tier may claim an accuracy
figure.

## Why this directory is currently empty

The iOS Simulator has no accelerometer and no gyroscope at all
([CON-S-1](../../docs/standalone/requirements.md#con-s-1)), so a trace can only be produced on real
hardware, during a real run. The capture tool that produces one exists
(`Apps/iPhone/Sources/Standalone/Capture/`); the runs have not been recorded yet.

Until a trace lands here, **every accuracy requirement on this track is unvalidated**, and
[§12.1 of the standalone requirements](../../docs/standalone/requirements.md#121-validation-status)
says so in a table rather than in prose that quietly ages.

To record one, follow [`Tools/motion-recording-protocol.md`](../../Tools/motion-recording-protocol.md).

## What belongs here

| Path | What |
|---|---|
| `<name>.motion.json` | A recording from a real device, with a `references` block |
| `golden/<name>.motion.golden.json` | Committed estimator output for that trace |

## What does not

**Synthetic signals.** Not in this directory, not under another name, not "just to have something to
test against". They live in `PhoneMotion`'s `Synthetic/` directory as a *type*, are used only for
properties whose label is the ground truth by construction, and `Tools/check-motion-fixtures.sh`
fails the build if one is used to assert an accuracy bound
([CON-S-7](../../docs/standalone/requirements.md#con-s-7)).

A synthetic trace committed here would be indistinguishable from a real one to every future reader,
which is precisely the confusion this separation exists to prevent.

## Every trace declares what it can validate

The `references` block is not optional — `check-motion-fixtures.sh` requires it — and each entry
carries **its own accuracy**, so no claim can be made tighter than the thing it was measured
against:

| Reference kind | Validates | Its own error |
|---|---|---|
| `surveyedDistance` | Distance, absolutely | Best available — a track is a track |
| `companionGNSSDistance` | Distance | ~1–3% |
| `phoneGNSSDistance` | Distance, and the fusion handover | ~1–3%, and correlated with the device under test, which is why it ranks below a companion |
| `countedSteps` | Step count and cadence | **Zero** — this is the only exact reference obtainable in the field |

A trace with no references can still exercise the pipeline and catch a crash. It cannot validate a
bound, and `motionreplay` says so in as many words rather than printing a number that reads like
one.

## Working with a trace

```bash
# What does the estimator make of it, and how does that compare to its references?
swift run --package-path Apps/iPhone/PhoneMotion motionreplay --trace Fixtures/motion/<name>.motion.json

# The full cadence series rather than a summary
swift run --package-path Apps/iPhone/PhoneMotion motionreplay --trace <path> --print-cadence

# Simulate a GNSS outage over real motion data (S-024). Legitimate because the motion
# underneath is real — the opposite of a synthetic signal.
swift run --package-path Apps/iPhone/PhoneMotion motionreplay --trace <path> --suppress-gnss-after 600

# Regenerate a golden. A deliberate act, with a justification in the PR body.
swift run --package-path Apps/iPhone/PhoneMotion motionreplay --trace <path> \
    --golden Fixtures/motion/golden/<name>.motion.golden.json --update-goldens
```

## Privacy

A motion trace is health data and a location trace is worse
([NFR-S-16](../../docs/standalone/requirements.md#95-privacy--security)). Anything committed here is
committed deliberately, by the person who recorded it, knowing that the location column describes
where they run.
