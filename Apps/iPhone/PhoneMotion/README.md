# PhoneMotion

The standalone iPhone tier's motion estimation, as pure arithmetic.

Raw motion samples in — step events, cadence, step lengths and a fused distance out. See
[`docs/standalone/design.md`](../../../docs/standalone/design.md) §3–§7 for the algorithm and
[ADR-S-03](../../../docs/standalone/design.md#adr-s-03) for why it lives here.

## What belongs here

- Signal processing: orientation resolution, filtering, resampling, autocorrelation.
- Gait estimation: cadence, step events, step length.
- Distance fusion and the GNSS calibration of the step-length model.
- The motion trace format and its offline replay.
- The labelled synthetic signal generator, for property tests **only**.

## What does not

- **Any Apple framework.** No CoreMotion, no CoreLocation, no SwiftUI, no SwiftData.
  `Tools/check-core-imports.sh` fails the build on one, and the constraint binds harder here than it
  does in `Core`: the iOS Simulator has no accelerometer and no gyroscope at all, so estimation code
  that needed a device would have no automated verification whatsoever.
- **Anything that decides what a runner should do.** Pace targets, zones, alerts and intervals are
  `Core`'s job (ADR-001). This package answers "how far and how fast", never "is that correct".
- **Sensor plumbing.** Converting `CMDeviceMotion` into `MotionSample` happens in the app target.
- **Accuracy claims from generated data.** See below.

## The rule that matters most

**A synthetic signal may prove a structural property. It may never back an accuracy claim.**

Generating "accelerometer-like" data and reporting a distance error measures the generator's own
assumption round-tripped through the estimator. `SyntheticGaitSignal` exists for properties whose
ground truth is *the label by construction* — a known step count, a known cadence, a known
stationary interval — and `Tools/check-motion-fixtures.sh` fails the build if it appears in a file
that asserts an accuracy bound.

Accuracy comes from recorded traces in `Fixtures/motion/`, and from nowhere else.

## Testing

```bash
swift test --package-path Apps/iPhone/PhoneMotion
```

Runs on Linux, in seconds, with no simulator. That is the whole point.

## Layout

```
Sources/PhoneMotion/
├── Configuration/   every tunable, in one place (NFR-S-19)
├── Model/           MotionSample, LocationFix, StepEvent, MotionEstimate
├── Signal/          Vector3, orientation resolution, biquads, resampling
├── Cadence/         autocorrelation and the stride-vs-step resolution
├── Steps/           step detection and the step-length model
├── Fusion/          distance fusion, calibration, the MotionEstimator facade
├── Trace/           the recorded-trace format and offline replay
└── Synthetic/       labelled generators — read the header before using
Sources/motionreplay/  offline replay CLI
```
