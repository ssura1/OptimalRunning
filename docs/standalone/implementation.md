# OptimalRunner — Standalone iPhone Track: Implementation Plan

| Field | Value |
|---|---|
| Document | `docs/standalone/implementation.md` |
| Track | **Standalone** — pace management on iPhone alone, no paired watch |
| Version | 1.0 |
| Status | Executing — Waves S0–S5 built; [S-063](#s-063) and [S-064](#s-064) open |
| Last updated | 2026-07-30 |
| Companions | [`requirements.md`](./requirements.md), [`design.md`](./design.md) |
| Depends on | [`../implementation.md`](../implementation.md) — the core track's Waves 0–4 are complete and are the substrate this builds on |

---

## 0. How to execute this plan

Same contract as the core track (`../implementation.md` §0), with this track's own identifier space.

| Field | Meaning |
|---|---|
| **ID** | `S-###`. Stable forever. Never reused or renumbered. Unrelated to the core track's `T-###`. |
| **Wave** | `S0`…`S5`. A fresh sequence, not a continuation of the core Waves 0–7. |
| **Depends on** | Task IDs — `S-###` from this track, `T-###` where a core task is a genuine prerequisite. |
| **Satisfies** | Requirement IDs from [`requirements.md`](./requirements.md). |
| **Touches** | Paths this task may create or modify. Two tasks in a wave never overlap. |
| **Done when** | Objective, checkable conditions. |

The core track's rules apply unchanged, plus two that are specific to this track and are the whole
reason it is sequenced the way it is:

6. **No accuracy claim from a synthetic signal.** A test that asserts a distance-, cadence- or
   step-count *accuracy percentage* must read a recorded trace. Synthetic generators are for
   structural properties over labelled inputs only. This is a CI gate
   ([S-008](#s-008)), not a convention — see
   [CON-S-7](./requirements.md#con-s-7) and [design.md §8.3](./design.md#83-synthetic-signals-and-the-wall-between-them).
7. **Ground truth before tuning.** No estimator parameter is tuned against anything except a
   recorded trace or a first-principles argument written down in `design.md`. "It looked better on
   my walk to the kitchen" is not a justification and cannot be reviewed.

### Wave overview

```mermaid
graph LR
    S0["Wave S0<br/>Contract, package,<br/>gates, CAPTURE TOOL<br/>S-001…S-008"] --> S1["Wave S1<br/>Estimation engine<br/>S-011…S-021"]
    S0 --> S2["Wave S2<br/>Validation against<br/>recorded traces<br/>S-022…S-025"]
    S1 --> S2
    S1 --> S3["Wave S3<br/>Standalone capture<br/>S-031…S-035"]
    S2 -.->|"quality gate"| S3
    S3 --> S4["Wave S4<br/>Feedback + live UI<br/>S-041…S-045"]
    S4 --> S5["Wave S5<br/>Hardening<br/>S-051…S-055"]
```

The dotted edge is the important one. **Wave S3 onwards should not start until Wave S2 has produced
a real accuracy number**, because everything after S2 is UI and plumbing built on the assumption
that the estimator works. Building it first would mean discovering the estimator does not work after
paying for the app around it — and it is exactly the ordering the track brief asked for: estimation
first, UI only once the estimation layer is trustworthy.

### Milestone mapping

| Milestone | Waves | Tasks | Ships |
|---|---|---|---|
| M-S1 — Ground truth | S0 | S-001…S-008 | The contract, the pure package, the gates, and the on-device capture tool |
| M-S2 — Estimation engine | S1, S2 | S-011…S-025 | Cadence, steps, step length, fusion, calibration — property-tested, then trace-validated |
| M-S3 — Standalone capture | S3 | S-031…S-035 | A standalone run that records, saves, and lands in the hub |
| M-S4 — Feedback | S4 | S-041…S-045 | Spoken cues, haptics, the live run screen |
| M-S5 — Hardening | S5 | S-051…S-055 | Degraded modes, settings, performance, the manual protocol |

---

## Wave S0 — Contract, package, gates, and ground truth

Everything here is prerequisite. [S-006](#s-006) — the capture tool — is the one that unblocks
reality, and it is scheduled in this wave rather than later for the reason
[CON-S-1](./requirements.md#con-s-1) gives: nothing downstream can be honestly validated without it.

<a id="s-001"></a>
### S-001 — The `PhoneMotion` package and its Linux lane

| | |
|---|---|
| **Wave** | S0 |
| **Depends on** | T-001 |
| **Satisfies** | NFR-S-18, NFR-S-21, CON-S-1 |
| **Touches** | `Apps/iPhone/PhoneMotion/Package.swift`, `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/**`, `Apps/iPhone/PhoneMotion/README.md`, `.github/workflows/core.yml` |

Create the pure estimation package per [ADR-S-03](./design.md#adr-s-03): depends on `ORModels` and
nothing else, declares no Apple-framework import, and carries **no `platforms:` floor** so it builds
on Linux alongside `Core`. Add it to `core.yml`'s Linux lane with the same 85% coverage gate.

**Done when:** `swift build --package-path Apps/iPhone/PhoneMotion` succeeds; `swift test` runs on
the Linux container image `core.yml` already uses; the README states what belongs in the package and
what does not; the coverage gate runs against it.

<a id="s-002"></a>
### S-002 — Extend the sensor contract

| | |
|---|---|
| **Wave** | S0 |
| **Depends on** | S-001 |
| **Satisfies** | FR-S-A-3, CON-S-2, CON-S-3 |
| **Touches** | `Core/Sources/ORModels/Domain/RunTypes.swift`, `Core/Sources/ORModels/Domain/Samples.swift`, `Core/Tests/ORModelsTests/**`, `Apps/WatchModern/WatchSupport/Tests/WatchSupportTests/TierEquivalenceTests.swift`, `Apps/WatchLegacy/LegacySupport/Tests/LegacySupportTests/TierEquivalenceTests.swift` |

Implement [ADR-S-02](./design.md#adr-s-02): `DistanceCapability`, `WorkoutSessionCapability`, the two
new `SensorCapabilities` fields with memberwise defaults and a `decodeIfPresent` decoder,
`DistanceSource.motionModel`, `DeviceTier.phoneStandalone`, and `CarryPosition`
([ADR-S-04](./design.md#adr-s-04)).

The two watch tiers' `rank(_:)` helpers are the only exhaustive switches over `DistanceSource`, and
they are updated here — a named, deliberate consequence rather than a surprise. **The proof that
this changed nothing is that the committed watch goldens still pass without modification**
(AC-FR-S-A-3-4).

**Done when:** both watch tiers' full suites pass with no golden regenerated; a `SensorCapabilities`
JSON written without the new keys decodes with the documented defaults; `DistanceSource.motionModel`
does not trip `RunEngine`'s indoor inference, asserted by a test; every new type is
`Codable, Sendable, Hashable` and round-trips.

<a id="s-003"></a>
### S-003 — `MotionEstimationConfiguration`

| | |
|---|---|
| **Wave** | S0 |
| **Depends on** | S-001 |
| **Satisfies** | NFR-S-19 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Configuration/**`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/ConfigurationTests.swift` |

One `Codable, Sendable` struct holding every tunable this track declares — sample rate, filter
cutoffs, autocorrelation window, cadence range, refractory fraction, detector threshold factor, step
length clamps and exponent, calibration window length, learning rate, movement cap, gain bounds,
disagreement threshold — each with its documented default, its permitted range, and a `validate()`.

The 5 m handover bound is **deliberately not here**: it is a correctness constraint, not a tunable,
and lives in the type that enforces it, exactly as `DistanceFusion.maxSwitchJumpMetres` does on the
watch (`../design.md` §4).

**Done when:** every value marked *(tunable)* in `requirements.md` and `design.md` has a field;
`validate()` rejects each out-of-range value with a specific error; the type round-trips through
JSON; no estimation source file contains a numeric literal that belongs here.

<a id="s-004"></a>
### S-004 — Establish the Simulator's motion capability empirically

| | |
|---|---|
| **Wave** | S0 |
| **Depends on** | T-005 |
| **Satisfies** | CON-S-1 |
| **Touches** | `Apps/iPhone/Tests/MotionAvailabilityTests.swift` |

[CON-S-1](./requirements.md#con-s-1) is the constraint the whole track's testing strategy is built
on, so it is *measured*, not assumed. A test in the iOS app target records what
`CMMotionManager` reports in the environment it is running in — accelerometer, gyroscope, device
motion availability — and asserts the finding that the strategy depends on.

**Done when:** the test runs on an installed simulator and records the result; the finding is
written into `design.md` §10.1 as measured rather than asserted; the test is written so it passes on
a real device too, where the answer is different, rather than being a simulator-only assertion that
would fail the moment someone runs the suite on hardware.

<a id="s-005"></a>
### S-005 — Motion trace format and codec

| | |
|---|---|
| **Wave** | S0 |
| **Depends on** | S-001 |
| **Satisfies** | FR-S-F-2, NFR-S-16 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Trace/**`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/TraceTests.swift`, `Fixtures/motion/README.md` |

The versioned columnar trace format from [design.md §8.2](./design.md#82-the-trace-format): header
(device, OS, app version, sample rate, height, carry position, declared references), parallel arrays
for motion, a location array, a pedometer array, and a marks array. Encoded and decoded in the pure
package so the estimator can read a trace with no Apple framework present.

**Done when:** a 60-minute 100 Hz trace encodes and decodes losslessly within stated per-column
resolution; the header states which references the trace carries; decode of a 360 000-sample trace
completes in under 2 s; `Fixtures/motion/README.md` states what belongs there and, explicitly, that
synthetic signals do not.

<a id="s-006"></a>
### S-006 — On-device raw motion capture

| | |
|---|---|
| **Wave** | S0 |
| **Depends on** | S-005, T-052 |
| **Satisfies** | FR-S-F-1, CON-S-1, CON-S-4 |
| **Touches** | `Apps/iPhone/Sources/Standalone/Capture/**`, `Apps/iPhone/project.yml` (Info.plist keys, background modes) |

The developer-facing capture screen from [design.md §8.1](./design.md#81-the-capture-tool). Records
device motion at 100 Hz, every location fix, `CMPedometer` output, and one-tap marks; writes
incrementally; exposes files through the Files app and the share sheet.

This task is the **critical path of the entire track**. Everything in Waves S1 and S2 that claims a
number depends on a file this produces.

**Done when:** a 60-minute capture completes on a real device without dropping below 90% of the
configured sample rate; the file is retrievable without a debugger; a kill mid-capture loses at most
30 s; the mark button is usable at running pace; the capture screen is reachable deliberately and
not discoverable by accident.

<a id="s-007"></a>
### S-007 — The recording protocol

| | |
|---|---|
| **Wave** | S0 |
| **Depends on** | S-006 |
| **Satisfies** | FR-S-F-2, CON-S-7 |
| **Touches** | `Tools/motion-recording-protocol.md` |

The written protocol for what to record, how, and what each recording is able to prove. See
[§ Recording protocol](#recording-protocol-what-to-capture-and-why) below for the version handed
over in this pass.

**Done when:** the protocol names, per session, the required duration, pace, route characteristics,
carry behaviour, and the reference that makes it useful; it states what each session validates and
what it cannot; it has a results template.

<a id="s-008"></a>
### S-008 — Structural gates for this track

| | |
|---|---|
| **Wave** | S0 |
| **Depends on** | S-001, S-005 |
| **Satisfies** | NFR-S-20, CON-S-7 |
| **Touches** | `Tools/check-core-imports.sh`, `Tools/check-motion-fixtures.sh`, `Tools/check-traceability.swift`, `.github/workflows/gates.yml` |

Three gate changes:

1. `check-core-imports.sh` scans `Apps/iPhone/PhoneMotion/Sources` with the same banned list, so
   [ADR-S-03](./design.md#adr-s-03)'s purity is mechanically enforced rather than reviewed.
2. `check-motion-fixtures.sh` — new. Fails when a test file references a synthetic motion generator
   *and* asserts an accuracy bound. This is the mechanical form of
   [CON-S-7](./requirements.md#con-s-7), and it is the gate that stops this track's central risk
   from being papered over by a green suite.
3. `check-traceability.swift` parses `docs/standalone/*.md` with the `S`-prefixed identifier
   pattern, and fails on the same two conditions as the core track.

**Done when:** each gate passes on the clean tree; each fails with a clear `::error::` when a
violation is planted; the traceability checker reports both tracks' counts and fails when a
standalone P0 requirement loses its covering task.

---

## Wave S1 — The estimation engine

All of Wave S1 is pure, Linux-testable, and property-tested. None of it can claim an accuracy figure
— that is Wave S2's job, and the gate from [S-008](#s-008) enforces the separation.

<a id="s-011"></a>
### S-011 — Vector maths and orientation resolution

| | |
|---|---|
| **Wave** | S1 |
| **Depends on** | S-001, S-003 |
| **Satisfies** | FR-S-B-1, AC-FR-S-B-3-3 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Signal/Vector3.swift`, `.../Signal/OrientationResolver.swift`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/OrientationTests.swift` |

`Vector3`, and the two channels of [design.md §3.2](./design.md#32-orientation-and-why-it-is-less-of-a-problem-than-it-looks):
the gravity-projected vertical `a_v` and the gravity-free magnitude `a_m`.

**Done when:** applying any fixed rotation to a whole sample stream leaves `a_v` and `a_m` unchanged
to within floating-point tolerance, asserted as a property over generated rotations; a degenerate or
zero gravity vector yields *no* vertical channel rather than a division by zero; the sign convention
(`a_v` positive upward) is asserted with a named test rather than left to a comment.

<a id="s-012"></a>
### S-012 — Causal Butterworth filters

| | |
|---|---|
| **Wave** | S1 |
| **Depends on** | S-003 |
| **Satisfies** | FR-S-B-1, NFR-S-14 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Signal/Biquad.swift`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/FilterTests.swift` |

Second-order Butterworth sections as a causal biquad cascade, for the gait band (0.7–7.0 Hz) and the
impact band (5–25 Hz) from [design.md §3.3](./design.md#33-filtering).

**Explicitly not zero-phase.** A forward-backward pass would be the standard offline choice and is
unavailable here: live estimation and fixture replay must produce bit-identical output
(NFR-S-14), and a backward pass is not causal.

**Done when:** the magnitude response is within 1 dB of the analytic Butterworth response at a set
of probe frequencies across each band; DC and a 30 Hz tone are attenuated by the gait band by at
least 20 dB; the filter is stable over 360 000 samples with no coefficient drift; identical input
produces identical output across repeated runs.

<a id="s-013"></a>
### S-013 — Normalized autocorrelation with parabolic refinement

| | |
|---|---|
| **Wave** | S1 |
| **Depends on** | S-012 |
| **Satisfies** | FR-S-B-2, NFR-S-1 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Cadence/Autocorrelation.swift`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/AutocorrelationTests.swift` |

Normalized autocorrelation over the lag range, peak search, and the parabolic interpolation from
[design.md §4.1](./design.md#41-cadence-by-normalized-autocorrelation) — which is not an
optimisation but a requirement, since one sample of lag error at 180 spm is already 5.4 spm against
a ±3 spm bound.

**Done when:** a pure sinusoid at a known non-integer-sample period is recovered to within 0.3% of
its true period, across the whole lag range — the arithmetic that makes NFR-S-7 reachable at all; a
constant signal yields no peak rather than a spurious one; a 5.12 s window at 100 Hz is processed in
under 2 ms.

<a id="s-014"></a>
### S-014 — Cadence estimator and the stride/step ambiguity

| | |
|---|---|
| **Wave** | S1 |
| **Depends on** | S-013 |
| **Satisfies** | FR-S-B-2, NFR-S-3 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Cadence/CadenceEstimator.swift`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/CadenceTests.swift` |

The estimator from [design.md §4.3](./design.md#43-resolving-the-stride-versus-step-ambiguity): the
disjoint-interval range rule, harmonic confirmation, the boundary treatment, and the three-factor
confidence of [§4.4](./design.md#44-confidence).

**The test that matters most** is the labelled sweep required by AC-FR-S-B-2-5: cadences from 140 to
200 spm, each with a stride-frequency component of equal or greater amplitude, every one of which
must return the step rate. That sweep fails against the published 1.4 Hz threshold for every case
above 168 spm, which is the point of writing it.

**Done when:** the sweep passes for every cadence in 140–200 spm at 1 spm resolution; out-of-range
input yields `nil` rather than a clamped value; confidence falls when the harmonic check fails; a
first estimate is available within 15 s of stream start (NFR-S-3); output is deterministic.

<a id="s-015"></a>
### S-015 — Step detector and the phase-locked fallback

| | |
|---|---|
| **Wave** | S1 |
| **Depends on** | S-014 |
| **Satisfies** | FR-S-B-3 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Steps/StepDetector.swift`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/StepDetectorTests.swift` |

Impact-envelope peak detection with an adaptive threshold and a cadence-derived refractory interval,
plus the phase-locked fallback from
[design.md §4.2](./design.md#42-step-events-from-the-impact-envelope).

**Done when:** over labelled synthetic signals of *n* steps across 120–240 spm, the detected count is
in [n−1, n+1] with no double counting; no two events are ever closer than the refractory interval;
a labelled 20 s stationary interval produces no events; suppressing the impact channel entirely
drives the fallback and the step *rate* is preserved even though individual event times are not.

<a id="s-016"></a>
### S-016 — Step length model

| | |
|---|---|
| **Wave** | S1 |
| **Depends on** | S-015 |
| **Satisfies** | FR-S-B-4, NFR-S-11 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Steps/StepLengthModel.swift`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/StepLengthTests.swift` |

The model from [design.md §5.2](./design.md#52-the-model), the clamps of
[§5.5](./design.md#55-bounds), and the no-GNSS van Oeveren prior of
[§5.4](./design.md#54-the-no-gnss-prior).

**No fabricated scale constant** ([ADR-S-06](./design.md#adr-s-06)): with no calibration the model
reports *unavailable* rather than a number, and the prior is used only on the explicit no-GNSS path.

**Done when:** the van Oeveren prior reproduces the [design.md §5.1](./design.md#51-why-a-cadence-only-model-cannot-work-for-running)
table to within 0.001 m at every listed speed — the check that the published relation was
transcribed correctly; step length is monotonically non-decreasing in amplitude at fixed height and
cadence, as a property; NaN and infinite inputs yield no estimate rather than propagating; an
uncalibrated model with no prior path returns `nil` and never a default.

<a id="s-017"></a>
### S-017 — Calibrator

| | |
|---|---|
| **Wave** | S1 |
| **Depends on** | S-016 |
| **Satisfies** | FR-S-C-2 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Fusion/Calibrator.swift`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/CalibratorTests.swift` |

Window qualification, the bounded update, the whole-value bootstrap, per-cadence-band gains, and
persistable `CalibrationState`, per [design.md §6.2](./design.md#62-calibration).

**Done when:** the gain stays inside its bounds under any observation sequence including adversarial
ones, as a property; no single window moves it by more than the cap; the bootstrap takes the first
observation whole and every subsequent one through the cap; a window failing any qualification
condition contributes nothing; the state round-trips through JSON; convergence from bootstrap is
within the configured window count.

<a id="s-018"></a>
### S-018 — Distance fusion

| | |
|---|---|
| **Wave** | S1 |
| **Depends on** | S-017 |
| **Satisfies** | FR-S-C-1, FR-S-C-3, NFR-S-12, DEG-S-1, DEG-S-2, DEG-S-3, DEG-S-7, DEG-S-8 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Fusion/DistanceFusion.swift`, `.../Fusion/MotionEstimator.swift`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/FusionTests.swift` |

The state machine of [design.md §6.1](./design.md#61-the-fusion-state-machine), delta accumulation,
the disagreement detector of [§6.3](./design.md#63-sanity-checking-gnss), and the `MotionEstimator`
facade of [§7.1](./design.md#71-what-phonemotion-exposes).

**Done when:** cumulative distance is non-decreasing under every generated source-switch sequence;
no switch moves it by more than 5 m; a corrupted-GNSS segment raises the disagreement flag,
suspends calibration, and does **not** override GNSS; motion-model samples are marked estimated and
the measured/estimated totals sum to the whole; the carry-position-change signature suppresses the
motion leg rather than feeding it out-of-domain input.

<a id="s-019"></a>
### S-019 — Labelled synthetic signal generator

| | |
|---|---|
| **Wave** | S1 |
| **Depends on** | S-005 |
| **Satisfies** | FR-S-F-3 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Synthetic/**`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/SyntheticTests.swift` |

A generator producing signals with a *known* step count, cadence, stationary interval and
stride-frequency arm-swing component — in a type explicitly named and documented as synthetic, in
its own directory, so [S-008](#s-008)'s gate can see it.

**Done when:** generated signals carry their labels as data; the type name and directory make the
synthetic/recorded distinction unmissable; the gate from S-008 fires when a test uses this type to
assert an accuracy percentage.

<a id="s-020"></a>
### S-020 — Property test suite

| | |
|---|---|
| **Wave** | S1 |
| **Depends on** | S-018, S-019 |
| **Satisfies** | NFR-S-14, NFR-S-21 |
| **Touches** | `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/PropertyTests.swift` |

Every property in [design.md §10.2](./design.md#102-property-tests), hand-rolled generators, seeded
so failures reproduce.

**Done when:** all thirteen properties pass with at least 500 cases each; each names the requirement
it defends; the suite runs in under 60 s; a deliberately introduced off-by-one in the refractory
logic is caught.

<a id="s-021"></a>
### S-021 — `motionreplay` CLI

| | |
|---|---|
| **Wave** | S1 |
| **Depends on** | S-018 |
| **Satisfies** | FR-S-F-2 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/motionreplay/**` |

The offline replay tool of [design.md §8.4](./design.md#84-the-replay-cli): cadence over time, step
count, step-length distribution, fused distance, provenance split, and the comparison against the
trace's declared reference — plus `--update-goldens` producing a reviewable diff.

**Done when:** a trace replays and prints all of the above; the reference comparison names which
reference it used and what that reference's own accuracy is; `--update-goldens` writes a golden a
subsequent run matches exactly.

---

### Waves S0 and S1 — as built

Deviations and findings from executing this plan, recorded here rather than left in commit
messages — the discipline the core track's "Wave 4 — as built" section established.

**The environment, first, because it shaped how everything was verified.** This repository lived
under `~/Desktop` while Waves S0 and S1 were built, and `~/Desktop` on this machine is synced by
iCloud Drive. The effect was severe rather than cosmetic: `git rev-parse HEAD` took **93 seconds at
0% CPU**, and `swift build` stalled indefinitely. All verification was therefore run against an
`rsync` copy under `/private/tmp`, which is not synced.

The cause was identified afterwards and is worth writing down, because the natural conclusion from a
hanging `git status` is that the repository is broken and it is not. With the disk at 96% full,
macOS had **evicted 720 of the repository's 1121 files** to iCloud placeholders — most of `.git` and
several golden fixtures among them — and every read of an evicted file blocks on an on-demand
download. The 2.4 GB of SwiftPM `.build` directories inside the synced folder were both the largest
source of sync churn and the reason the disk had no headroom. The repository now lives at
`~/Downloads/running_app/OptimalRunning`, which is not synced; the same `git rev-parse` takes 0.02 s.
Keep it out of `~/Desktop` and `~/Documents`.

**S-001 — `PhoneMotion` declares platform floors after all**, restated from `Core` rather than
chosen. The manifest was written with none, on the correct principle that arithmetic over arrays of
doubles has no deployment target to state. SwiftPM disagrees: `Core` declares `.macOS(.v13)` (core
track T-063), and a package may not depend on a product with a higher floor than its own. The Linux
lane — the only thing [ADR-S-03](./design.md#adr-s-03) was protecting — is unaffected, because
SwiftPM ignores `platforms:` there entirely. Reconciled in that ADR.

**S-016 — the van Oeveren prior is valid over a far narrower band than reading the paper suggests,
and this was found by implementing it.** The relation was fitted over 1.64–4.68 m·s⁻¹; inverted,
that entire speed range maps to a cadence band of **159.9–178.2 spm**. Below the floor it returns a
*negative* speed — at 150 spm, −0.0033 m/s — and above the ceiling it implies 6.65 m/s for a runner
at 190 spm. `priorStepLength` now returns `nil` outside `[2.665 Hz, 2.969 Hz]` rather than
extrapolating, and a runner outside that band on a GNSS-free first run gets a timed run with no
distance, which is what [ADR-S-06](./design.md#adr-s-06) prescribes anyway. Written up in
[design.md §5.4](./design.md#54-the-no-gnss-prior).

This is also the sharpest available statement of [§5.1](./design.md#51-why-a-cadence-only-model-cannot-work-for-running)'s
argument, and it is worth the emphasis: **a 185% increase in running speed shows up as an 11%
increase in cadence.** A model that reads speed from cadence is reading an 11% signal to explain a
185% effect.

#### Five real bugs the tests caught

All five were caught by tests written to the acceptance criteria before the code was tuned, and all
five were in shipped-looking code that ran without complaint.

**1 — The autocorrelation picked an arbitrary *multiple* of the period.** A periodic signal
correlates with itself at every multiple of its period, and for a clean signal those peaks are
within floating-point noise of one another, so "take the largest" picks whichever one happened to
score higher. `testRecoversANonIntegerPeriodToWellUnderOneSample` reported a **200% period error** on
a pure sinusoid. Fixed by preferring the shortest lag within 85% of the best peak — the standard
fundamental-frequency rule — which is also provably safe for the stride-versus-step problem, since
`L` and `2L` map to the same cadence by construction ([§4.3](./design.md#43-resolving-the-stride-versus-step-ambiguity)).

**2 — The step detector had no refractory interval before the first cadence estimate existed.** The
refractory is derived from the live cadence, and `(cadence?.stepPeriodSeconds ?? 0)` is zero when
there is no cadence yet — so for the first several seconds of every run the gate was wide open, and
the property suite found event gaps of 0.08 s against a 0.15 s bound. Fixed with a floor at the
fastest physiologically admissible step period.

**3 — There was no stationarity gate at all, so the detector kept counting steps at a traffic
light.** [AC-FR-S-B-3-5](./requirements.md#fr-s-b-3--step-event-detection) requires no events during
a stationary interval and nothing implemented it. The adaptive threshold cannot do the job by
itself, and the reason is worth recording: being *relative* — mean plus kσ over a trailing window —
it follows the signal down and finds "peaks" in sensor noise. Worse, the phase-locked fallback keeps
synthesising steps at the last known cadence for as long as the correlation window remembers it. An
absolute RMS floor on the gait band now suppresses both, and `steps.stationaryRMSThreshold` is a new
tunable.

**4 — Calibration learned from a bad window before the disagreement check could see it.** The
disagreement comparison ran on a 200 m window while the calibration window is 100 m, so the first
calibration window closed and was **applied** before the first disagreement window had been
evaluated. `testCalibrationDoesNotMoveWhileDisagreementIsSuspended` caught the scale moving its full
per-window cap on data where GNSS reported double the motion leg. The check now runs on the
calibration window itself, immediately before applying it — suspension after the fact is no use when
the damage is already in the persisted state.

**5 — Window qualification was all-or-nothing and disqualified the first window of every run.**
[AC-FR-S-C-2-7](./requirements.md#fr-s-c-2--online-calibration-against-gnss) forbids learning from a
window "where cadence confidence was low", which was implemented as "where *any* step lacked a
confident cadence". Every run begins with a few seconds of no cadence estimate at all while the
correlation window fills, so every run's *first* window was disqualified — the exact window a
first-ever calibration depends on. `testSuppressingFixesAfterATimeProducesAnEstimatedTail` failed
with no calibration after a clean 60 s of GNSS. Now a window qualifies if ≥ 80% of its steps carried
a confident cadence.

#### Smaller things, recorded because they will look arbitrary otherwise

- **The filters are causal, never zero-phase.** Offline gait analysis normally uses a
  forward-backward pass; that is unavailable here because live estimation and fixture replay must be
  bit-identical ([NFR-S-14](./requirements.md#94-reliability)) and a backward pass is not causal.
- **`Rotation.axisAngle` is written out element by element.** The nine compound expressions in one
  array literal defeat Swift's type checker outright — a compile error, not a slow build.
- **`CadenceEstimator`'s analysis is `static`.** Passing `&vertical` while calling a `mutating`
  method on `self` is an exclusivity violation. The config and previous estimate are hoisted into
  locals instead.
- **The coverage gate and its summariser now take a package path and a source root.** They were
  hardcoded to `Core`; `PhoneMotion` is gated on the same 85% terms
  ([NFR-S-21](./requirements.md#96-maintainability)), and duplicating the script would have meant
  two copies of the llvm-cov-location logic to keep in step.
- **`DistanceFusion` takes the calibration configuration as an init parameter.** The first
  implementation reached for a mutable static, which is global mutable state in a package whose
  entire value is determinism.
- **Cadence *confidence* and the minimum autocorrelation *peak* were the same constant, and should
  not have been.** `minimumPeakCorrelation` (0.30) gates whether an estimate is emitted at all;
  confidence is a product of three factors ([§4.4](./design.md#44-confidence)) and lives on a
  different scale entirely. Reusing one for the other made the calibration gate far laxer than it
  read. `cadence.minimumTrustedConfidence` now exists and is shared by the calibrator and the
  phase-locked fallback, so the two cannot come to disagree about what "trusted" means.
- **Three literals moved into configuration** under [NFR-S-19](./requirements.md#96-maintainability)
  — the trusted-confidence threshold, the confident-step fraction, and the stationary RMS floor.
  Three others stayed as declared constants with their reasoning at the declaration, following the
  core track's own distinction (`design.md` §4): `Autocorrelator.fundamentalPreferenceRatio`,
  `StepDetector.fallbackLatenessFactor` and `CadenceEstimator.channelDisagreementThreshold` are
  algorithm correctness constants, not values a runner or a deployment might legitimately vary.
- **`Tools/check-motion-fixtures.sh` was committed without its executable bit**, which only the
  first push revealed. Every local run had invoked it as `bash Tools/check-motion-fixtures.sh`;
  `gates.yml` invokes it directly, so CI failed with exit 126 — `Permission denied` — while the
  gate passed on every machine it had ever been run on. The mode is now `100755`, and the other
  five CI-invoked scripts were checked the same way rather than one at a time. The lesson is the
  narrow one: a gate verified through an interpreter is not verified the way CI runs it.

#### What is *not* built, and is not pretended to be

- **No recorded trace exists**, so Wave S2 has not run and every accuracy requirement in
  [§9.3](./requirements.md#93-accuracy) remains **unvalidated**. The
  [validation-status table](./requirements.md#121-validation-status) says so, and
  `Tools/check-motion-fixtures.sh` makes it structurally impossible for a synthetic test to claim
  otherwise.
- **The capture tool has not been run on a device.** The app target builds and its suite passes, and
  [S-004](#s-004) measured the Simulator reporting `deviceMotion`, `accelerometer`, `gyroscope` and
  `pedometer` all **false** — which both confirms [CON-S-1](./requirements.md#con-s-1) and exercises
  the tool's refusal path. But "records a clean 60-minute trace" is a claim only a phone can
  support, and it has not been made.
- ~~**Waves S3–S5 are specified and not built.** The gate between S2 and S3 is deliberate: the shape
  of the standalone app legitimately depends on what the traces measure.~~ **Built.** Wave S2
  produced the traces and the accuracy figures the gate was waiting for, and Waves S3–S5 were built
  against them — see [Waves S3–S5 — as built](#waves-s3s5--as-built). The paragraph above is left
  standing rather than deleted because the gate is the reason the wave took the shape it did.

---

<a id="s-056"></a>
### S-056 — The first field session recorded nothing, and why

**Satisfies** FR-S-F-1, AC-FR-S-F-1-6 · **Wave** S1 (unplanned)

The first attempt to record on a real phone produced **five consecutive captures of zero bytes**.
The app exited when *Start capture* was tapped, and when it stayed up the screen stopped responding,
so MARK could not be pressed. This is the failure mode [S-006](#s-006) exists to prevent, and it
reached a run because the capture tool shipped with **no tests at all** — the app target had six,
none of which touched capture. "It is only a developer tool" was exactly the wrong reason to leave
it unverified: a bug here is not a degraded feature, it is a run that cannot be re-recorded without
going outside again.

**What was ruled out by measurement, not by reading.** `CaptureWriter` was suspected first and is
innocent: `CaptureWriterTests` drives it directly and it writes, flushes, recovers a truncated
stream and assembles correctly. Two false leads were followed and are recorded because both are easy
to repeat — `plutil -extract` **rewrites the file in place** unless given `-o -`, which corrupts the
very plist being inspected; and `URL.resourceValues` caches, so reading a file's size before and
after an append returns the first answer twice and reads exactly like a product that never wrote.
Neither was a defect in the app.

**The defects that were real**, each independently capable of producing what the field session saw:

| | Defect | Consequence |
|---|---|---|
| 1 | The recorder was a `@StateObject` **inside** `MotionCaptureView`, a `NavigationLink` destination | Navigating away destroyed it mid-capture: sensors stopped, `finish` never ran, no trace assembled. Directly matches "I reopened the page and the recording had stopped" |
| 2 | Every sample hopped to the **main actor** to JSON-encode and `write(2)` | 100 main-actor hops a second, each doing file I/O |
| 3 | `@Published` counters mutated at **100 Hz** | SwiftUI rebuilt the whole screen every frame — an unresponsive UI, and an app whose main thread is wedged when the system asks it to suspend is one the watchdog terminates |
| 4 | `guard let data = try? encoder.encode(record) else { return }` | An encoding failure produced an empty capture, no error, and no way to distinguish that from a silent sensor. `JSONEncoder` rejects non-finite doubles by default |
| 5 | A fresh `JSONEncoder` per record | Built and torn down a hundred times a second |
| 6 | `isIdleTimerDisabled` never set | The screen slept, putting Face ID between the runner and the one control that has to work |
| 7 | Location authorisation never surfaced | Without it the `location` background mode cannot hold the process up ([CON-S-4](./requirements.md#con-s-4)), so capture dies at screen-lock with no error |

**The fix.** Capture work leaves the main thread entirely: `CaptureSink` is a serial queue that every
record passes through, which is also what makes `CaptureWriter`'s lack of an internal lock sound —
three sensor streams arrive on three queues and something has to serialise them. Motion at 100 Hz
touches neither the main actor nor the recorder. Location (~1 Hz) and the pedometer still build their
records on the main actor, because at that rate it costs nothing and the code is plainer for it.
Counters are read from the sink twice a second by the display timer instead of being published by the
sensor. Marks are written **synchronously** — a mark is the one record a runner cannot supply twice,
so it is on disk before the button's action returns rather than queued behind a backlog of samples.
The recorder is owned by `OptimalRunnerApp` and injected, so a capture outlives the screen.

**What killed the app was none of the above** — see [S-057](#s-057). This section originally closed by
naming "the watchdog terminated a wedged main thread" as the leading explanation, on the strength of
defects 2 and 3. The crash reports say otherwise: `EXC_BREAKPOINT` in a Swift isolation check, not
`0x8badf00d`. The guess is left recorded here rather than quietly deleted, because it is a fair
illustration of how far a plausible mechanism can be from the real one when the evidence has not been
read yet. Everything in the table above is a genuine defect and worth having fixed; none of them was
the crash.

**Tests.** Ten, where there were none: bytes-on-disk assertions for the writer (including a
deliberately non-finite sample, which must surface rather than vanish), and concurrent multi-queue
drivers for the sink asserting that no record is lost and no two writes interleave into invalid JSON.
Every one asserts on the file, because the failure being chased wrote nothing while reporting nothing.

---

<a id="s-057"></a>
### S-057 — The crash itself: a sensor callback that inherited main-actor isolation

**Satisfies** FR-S-F-1, CON-S-1 · **Wave** S1 (unplanned)

All five crash reports are identical, and none of them is a watchdog kill:

```
exception:   EXC_BREAKPOINT (SIGTRAP)
queue:       NSOperationQueue (QOS: USER_INITIATED)

  _dispatch_assert_queue_fail
  dispatch_assert_queue
  _swift_task_checkIsolatedSwift
  swift_task_isCurrentExecutorWithFlagsImpl
  closure #1 in MotionCaptureRecorder.startMotion()
  thunk for @escaping @callee_guaranteed (CMDeviceMotion?, Error?) -> ()
  -[NSBlockOperation main]
```

**The mechanism.** `CMDeviceMotionHandler` is a plain Objective-C block —
`typedef void (^CMDeviceMotionHandler)(CMDeviceMotion *, NSError *)` — with no
`NS_SWIFT_SENDABLE`. It therefore imports as a *non-Sendable* closure type, and a closure literal
written inside a method of a `@MainActor` type **inherits main-actor isolation**. No diagnostic is
possible: the imported block type carries no isolation information for the compiler to contradict.
CoreMotion then invokes the closure on the `NSOperationQueue` it was handed, Swift's runtime checks
the current executor, finds it is not the main one, and traps. The first motion sample arrives 10 ms
after `startDeviceMotionUpdates`, which is why every capture died within seconds and why all five
files were zero bytes: nothing survived long enough to be written.

**Both directions were verified before the fix was accepted**, because "add `@Sendable` and hope" is
not a diagnosis:

| | Result |
|---|---|
| Handler declared `@Sendable`, main-actor access added inside | `error: main actor-isolated property 'motionSampleCount' can not be mutated from a Sendable closure` |
| Original inline trailing closure, *identical* access added | `** BUILD SUCCEEDED **` |

The second row is the bug in one line: the same code that is a compile error in a non-isolated
closure compiles silently in an inferred-main-actor one, and only fails on hardware.

**The fix** is to write the handler's type out and mark it `@Sendable`, which opts the closure out of
isolation inference and moves the question to compile time. Any main-actor access added to a sensor
handler in future is now a build error rather than a crash on a run.

**Why the Simulator could never have caught it.** The handler is only invoked when a sample arrives,
and the Simulator has no accelerometer at all ([CON-S-1](./requirements.md#con-s-1)). The constraint
this whole track is built around turned up here as a crash rather than as a missing number — the
`swift_task_isCurrentExecutor` check simply never runs where there is nothing to deliver.

**Two more instances, found by the gate rather than by the crash.**
[`Tools/check-sensor-handler-isolation.sh`](../../Tools/check-sensor-handler-isolation.sh) was written
to prevent a recurrence and immediately failed on code that had shipped in Waves 2 and 4:

- `Apps/WatchModern/.../LiveSensorFeed.swift` — the pedometer handler called
  `MainActor.assumeIsolated` from CMPedometer's background queue. That is a hard fatal error, not a
  check that quietly passes.
- `Apps/WatchLegacy/.../LiveSensorFeed.swift` — the pedometer handler assigned to a main-actor
  property directly from the same background queue. On a Series 3 that traps about ten seconds into
  any run, as soon as the watch first reports distance.

Neither had been observed because neither watch app has been run on real hardware. Both are fixed the
same way. The altimeter calls in both tiers are left as they were and the gate exempts them: they
pass `to: .main`, so the closure genuinely does run on the main actor, and the exemption is written
in terms of the delivery queue rather than the API for exactly that reason.

**What this says about the testing strategy.** Three of the four defects on this track that reached a
device were invisible to every test that exists, because they live in the seam between a framework's
threading contract and Swift's isolation model. The gate is the response: not a test, which would
need the hardware it is trying to substitute for, but a structural rule that makes the dangerous form
unrepresentable.

---

<a id="s-058"></a>
### S-058 — What the first real trace said

**Satisfies** FR-S-B-2, FR-S-C-1, CON-S-1, CON-S-7 · **Wave** S1 (unplanned)

The first bench recording ran to 199 s on an iPhone 17e, hand-held, with a labelled timeline: 31 s
standing motionless including one deliberate jump, 29 s walking screen-on, 37 s walking **screen-off**,
then 99 s running. Both traces are committed under
[`Fixtures/motion/`](../../Fixtures/motion/). Neither declares a reference, so **neither validates an
accuracy bound** — what they establish is behaviour, and that turned out to be worth more at this
stage than a number.

**What held.** Sampling is better than the design assumed: 100.41 Hz mean, median interval 9.959 ms,
**worst gap 12.4 ms, and not one gap above 50 ms across the whole session** — including the 37 s with
the screen off. Background execution under the `location` mode ([CON-S-4](./requirements.md#con-s-4))
is now a measurement rather than a hope. The labelled segments separate cleanly in gait-band RMS —
**0.25 m/s² standing, 2.30 walking, 10.44 running** — and the jump appears as a 14.8 m/s² impulse at
t=29.12 s, so the orientation projection is doing its job on real, continuously rotating hand-held
data. The running segment produced a median 163 spm at 0.82 confidence, which is exactly what a
runner of this height and effort should produce. Both diagnostic flags fired correctly and the
calibrator refused to learn, which is the behaviour those mechanisms exist for.

**Two failure modes, both at rest, neither reachable by any synthetic signal.**

**1. Cadence was reported while standing perfectly still.** Across the stationary segment the
estimator emitted 175–231 spm at confidence up to **0.816** — above `minimumTrustedConfidence` of
0.4, so the calibrator would have treated it as evidence and a runner waiting at a crossing would
have been shown a running cadence.

The cause is that `stationaryRMSThreshold` was consulted **only** by `StepDetector`. Steps were
correctly suppressed; cadence was not, because `CadenceEstimator` had no amplitude gate at all. And
it needed one for a specific reason: **normalised autocorrelation is amplitude-blind.** It divides
out the window's energy, so noise correlates exactly as strongly as running. Confidence built on
correlation alone therefore cannot distinguish a stopped runner from a fast one — amplitude is the
information the correlation throws away, so it has to be carried alongside it.

The fix adds `Autocorrelator.rootMeanSquare` over precisely the window the correlation uses, and
gates the estimate on the step detector's existing floor — *the same* value, passed in by
`MotionEstimator`, not a second copy, because two numbers that must agree are one number waiting to
disagree. Replaying the trace, confident cadence during the standing segment falls from **15 of 32
seconds to 2**, and the two survivors are the seconds immediately after the jump, at confidence 0.164
and 0.195 — below the trust threshold, and correct, because a real 14.8 m/s² impulse genuinely does
put energy in the window. Walking and running are untouched (28/29, 36/36, 99/100), and the running
median moves by 0.45 spm. The floor of 1.0 sits with roughly ninefold margin on either side of the
measured boundary.

**2. GNSS accumulated 70.9 m while the phone was motionless.** Fifteen per cent of the session,
fabricated. The accuracy gate did not catch it and could not: horizontal accuracy was a healthy 5.1 m
throughout, which is exactly when position wander is admitted rather than rejected. This does not
stay in the distance column — the GNSS series is the reference the calibrator fits the step-length
model against, so the fabricated distance becomes a fabricated scale.

The gate is on speed rather than displacement, and the choice is forced by the fix rate: at 1 Hz a
walker covers ~1.4 m per fix, which is *below* the position noise, so a displacement threshold large
enough to reject jitter would also reject walking. `CLLocation.speed` is Doppler-derived and does not
have that problem — the same trace measured **0.07 m/s standing, 1.44 walking, 2.71 running**. The
threshold is 0.5 m/s, an order of magnitude clear of both sides. Replaying the recorded fixes through
it returns **401.9 m against CMPedometer's independent 384.5 m**, where the ungated figure was 476.6 m:
+4.5% instead of +24%, with 100% of the standing jitter removed and 3 m of genuine slow walking lost
with it.

An unavailable speed (`-1`) falls back to the implied speed rather than defaulting to "moving", since
an unknown speed is not evidence of motion.

**Why the synthetic suite could not have found either.** Both are *at-rest* failures, and the
synthetic generator's stationary intervals contain no signal — so there was nothing for a correlator
to lock onto and no GNSS to wander. Real sensor noise has structure; synthetic silence does not. This
is the same lesson as [S-057](#s-057) arriving from a different direction: thirty seconds of a runner
standing still was worth more than any amount of generated data, and it cost nothing to record.

**Still open.** The step-length model remains unvalidated — the calibration scale of 0.52 is fitted
against a GNSS reference now known to have been 24% high, so it says nothing yet. `motionOnlyDistance`
of 124.7 m over 168 s of movement is implausibly short and is the first thing the next trace should
settle. Walking is reported at ~225 spm because the configured range is 120–240 spm and a hand-held
walker's arm swing falls outside it; walking is out of scope for v1
([CON-S-3](./requirements.md#con-s-3)) and this is recorded rather than fixed.

---

<a id="s-059"></a>
### S-059 — A published trace is a home address

**Satisfies** CON-S-7 · **Wave** S1 (unplanned)

The two bench traces committed in the first revision of [S-058](#s-058) carried **276 absolute GNSS
fixes** at 42.28 N, 71.60 W — recorded during a real run, from the runner's home, in a public
repository. That commit was rewritten to exclude them and the history force-pushed; the traces
returned scrubbed.

Nothing in the estimator ever read `latitude` or `longitude` — distance arrives through
`cumulativeDistanceMetres` and speed through `speedMetresPerSecond`. The coordinates rode along
purely because the capture tool had them. `RecordedFix` therefore makes them optional and adds
`eastMetres`/`northMetres` measured from the trace's own first fix, which preserves displacement,
track shape, bearing change and turn radius while discarding the origin. Decoding tolerates both
shapes so older traces still load.

`Tools/scrub-trace.swift` performs the conversion and **re-reads its own output**, exiting non-zero
if a coordinate survived; `check-motion-fixtures.sh` fails the build on any committed trace carrying
one. Both were verified in both directions before being accepted — the gate flagged both files with
exact counts, then passed after the scrub.

**One consequence cannot be fixed from here.** A force-push removes the commit from `main` but GitHub
retains unreachable objects and still serves them by SHA. Purging them requires asking GitHub Support
to garbage-collect the repository. That is recorded because it is the part that is still outstanding,
not because it is comfortable.

#### Second occurrence, 2026-07-29 — `.gitignore` is not a guard

It happened again, twice in one session, and neither the original gate nor `.gitignore` saw it. The
pace-ladder GPX and both raw captures arrived staged: **`git add` on a specific path overrides
`.gitignore` silently**, and once a file is in the index the ignore rule stops applying to it
forever. Nothing was committed — both were caught by reading `git status` — but "caught by eye" is
not a control.

The original check asked *is this file in `Fixtures/motion` and does it carry coordinates*, which is
the wrong question. It now asks **is git tracking a coordinate anywhere**, which is the thing that
actually matters and the only phrasing that survives a file arriving from a directory nobody
anticipated. Raw captures live in `data/` and are ignored; the ignore is now backed by a gate that
does not care where the file came from.

The synthetic Core fixtures are exempted **by content rather than by path** — they must carry the
fictional 51.5/−0.12 London anchor *and* no real-world latitude — so a genuine trace cannot be
smuggled past by moving it into an exempt directory. Verified in both directions: staging either of
the two files that actually caused this fails the gate with the remediation command, and the clean
tree passes.

---

<a id="s-060"></a>
### S-060 — An outage billed twice

**Satisfies** FR-S-C-1, AC-FR-S-C-1-1, NFR-S-10 · **Wave** S2

The 4.3 mi run produced a fused distance **worse than either leg feeding it**: +3.94%, against
+2.65% for GNSS and +1.13% for motion. A fusion that is worse than both its inputs is not a tuning
problem, it is an accounting error, and six laps of one loop made it visible by giving six
independent readings of the same distance.

**Two mechanisms, and only one is fixed by the obvious repair.**

`MotionCaptureRecorder` stamped every fix with `relativeTime()` — *now* — while CoreLocation buffers
fixes whenever delivery is deferred and hands the backlog over in one call. The trace therefore holds
**19 fixes at t=1126.071 spanning 50.9 m**, 34 at t=1171.4 spanning 97.2 m, and two smaller batches:
**184.7 m of real running recorded as having taken zero seconds.** The fusion re-anchors on one delta
when GNSS returns, so it discarded the first of those and added the other eighteen on top of motion
distance already accrued for the same stretch.

Using `CLLocation.timestamp` fixes the recorder. It does **not** fix the fusion, and reasoning about
why is the more useful half: with honest timestamps the backlog still describes time before the
handover, each delta is individually plausible, and the double-count returns by a route no
plausibility bound can see. Two guards are therefore needed, and they catch different things:

| Guard | Catches |
|---|---|
| `maxPlausibleSpeedMetresPerSecond` (12 m/s) | Deltas no elapsed time can justify. Zero elapsed admits zero distance — the general rule at its limit, not a special case |
| `motionCoveredUntil` | Backlog fixes describing time the motion leg already billed, whose deltas are individually reasonable |

**Verified in both directions**, per [S-057](#s-057)'s bar. Removing `motionCoveredUntil` makes the
backlog test re-bill 87.0 m; removing the plausibility bound makes the collapsed-timestamp test
contribute 51.3 m — against the 50.9 m the real trace actually holds. A third test asserts ordinary
GNSS is untouched and passes in every configuration, so neither guard is a false negative.

**Result on the real run:** fused error **+3.94% → +1.27%**, and the GNSS leg alone lands at −0.11%
of the true 4.3 mi.

---

<a id="s-061"></a>
### S-061 — The step-length model does not generalise across paces

**Satisfies** FR-S-B-4, NFR-S-11, CON-S-5 · **Wave** S2 · **Open**

One outing produced a hard tempo run and a slow mile from the same runner, in the same carry
position, an hour apart. That is the comparison [design.md §5.1](./design.md#51-why-cadence-alone-cannot-work)
was written to predict and had never been able to test.

| | Tempo | Slow mile | Ratio |
|---|---|---|---|
| Speed | 2.83 m/s | 2.16 m/s | 1.309 |
| Cadence | 159.6 spm | 161.4 spm | **0.989** |
| True step length | 1.075 m | 0.815 m | 1.318 |
| Calibration constant the model requires | 0.513 | 0.413 | **1.241** |

**§5.1's conclusion is confirmed, and understated.** It argued from van Oeveren that cadence carries
roughly 7% of a speed change and the amplitude term must carry the rest. Measured here, cadence
carries **−3.6%** — not merely little, but slightly the wrong way, while step length carries
essentially the whole of it. Any cadence-only model would have read these two runs as the same
pace.

**But the model as shipped cannot express that.** The constant it needs differs by **24.1%** between
the two paces, which is the definition of not generalising: calibration can absorb a fixed scale
error, and this is not one. Solving for the exponent that would reconcile them gives **p ≈ 1.15**
against the shipped 0.25 — Weinberg's fourth root, which the literature fitted to *walking*.

> ## ~~Correction (2026-07-29) — the cadence row above was our own bug, not physiology~~
>
> **SUPERSEDED, same day, by the block that follows. Everything in this box is wrong.** It is kept
> intact because the mistake in it is worth more than the conclusion was: it treats a second
> estimator as an arbiter. Read it as a worked example, not as findings.
>
> ~~The slow mile's "161.4 spm" is not a measurement.~~ `CMPedometer` is recorded in every trace and was
> never consulted when this was written; it is an independent estimator and it is the arbiter this
> entry claimed did not exist. Time-aligned against it, per cadence band:
>
> | CMPedometer band | n | Ours | CMPedometer | Error |
> |---|---|---|---|---|
> | 145–200 spm | 986 | 160.0 | 159.2 | **+0.5%** |
> | 120–145 spm | 103 | 160.0 | 138.7 | **+15.4%** |
> | below 120 spm | 136 | 160.6 | 109.9 | **+46.1%** |
>
> Ours reports ~160 spm *in every band*. On the tempo run that looks like excellent accuracy
> (IQR 158.1–162.0 against CMPedometer's 157.2–162.1) only because the runner genuinely held ~159 spm
> for 95% of it. On the slow mile, where CMPedometer spends 42% of its samples below 120 spm, ours
> never once reads below 147.
>
> The mechanism is [`CadenceConfiguration.minStepsPerMinute = 120`](../../Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Configuration/MotionEstimationConfiguration.swift):
> the admissible band is 120–240 spm, so cadences below 120 are **structurally unrepresentable**, and
> the disjoint-interval trick of §4.3 that resolves stride-versus-step re-reads such a lag as a
> stride and doubles it. That is also why the two walk traces report 207.8 and 211.2 spm against
> CMPedometer's 103.9 and 105.7 — a clean factor of two.
>
> **What this does to the finding.** Cadence *does* respond to speed: 159.2 → 136.9 spm, a 14% drop
> across a 31% speed change, so it carries roughly half of it, not −3.6% and not §5.1's 7%. The
> shipped model was then fed a cadence 17.9% too high on the slow mile, and the calibrator shrank the
> scale to compensate — which is a large part of the 1.284 scale ratio observed. Dividing it out
> leaves roughly **9%** of genuine cross-pace inconsistency, not 24.1%. That is a rough decomposition,
> not a refit, and it is *smaller* than what was reported: the step-length model may well be within
> what calibration absorbs once it is fed a correct cadence.
>
> The exponent question is therefore **not settled and not urgent**; [S-062](#s-062) is, and must land
> before the pace ladder is recorded, or the ladder will measure the same clamp at six paces instead
> of two.

> ## Correction to the correction (2026-07-29, same day) — the original finding was right
>
> **The block above is wrong, and it is wrong because it trusted `CMPedometer`.** Two estimators that
> disagree identify a problem; they cannot say whose. The strike-throughs it introduced into the
> original entry have been reverted, because the original entry was correct.
>
> The actual arbiter is the recorded signal. Measured directly from the traces by FFT — sharing no
> code with the autocorrelation path and consulting no pedometer — the gait spectrum is a clean
> harmonic ladder at **1.33 / 2.66 / 3.99 / 5.32 Hz**, every rung an integer multiple of the 1.33 Hz
> stride, putting the step rate at 2.66 Hz = 159.6 spm. Per 30 s window:
>
> | Trace | Spectral arbiter | PhoneMotion | CMPedometer counted |
> |---|---|---|---|
> | 4.3 mi tempo (n=79) | 159.3 spm | **159.3 (+0.1%, 100% of windows within 3%)** | 156.9 (−1.7%, 62%) |
> | 1 mi slow (n=23) | 161.5 spm | **161.4 (+0.1%, 100% within 3%)** | 128.5 (**−20.7%**, 0%) |
>
> So PhoneMotion's cadence was correct on both runs all along, and `CMPedometer`'s `cumulativeSteps`
> is what undercounts — by a fifth on the slow mile. The "+15.4% / +46.1% error" table above is
> measuring the *pedometer's* error with the sign flipped. §12.1's NFR-S-7 row has been restored
> accordingly.
>
> **The original S-061 finding therefore stands, and the strike-throughs above are reinstated:**
> cadence really is flat across these two paces (159.6 vs 161.4 by our estimator, 159.3 vs 161.5 by
> the arbiter — the two paces agree to 0.1% on both), and step length really does carry the whole
> speed change. §5.1 is confirmed and understated, exactly as first written.
>
> **What the amplitude term actually does**, now measurable per-step from the raw signal:
>
> | | Tempo | Slow mile | Ratio |
> |---|---|---|---|
> | Speed | 2.863 m/s | 2.228 m/s | 1.285 |
> | Cadence (spectral) | 158.5 spm | 162.6 spm | 0.975 |
> | True step length | 1.084 m | 0.822 m | **1.318** |
> | Per-step peak-to-peak vertical | 34.77 m/s² | 24.43 m/s² | 1.423 |
> | Weinberg term at *p* = 0.25 | — | — | **1.092** |
>
> The shipped exponent captures **32%** of the step-length change it needs to. The rest is left to
> calibration, and the calibrator duly absorbs it: the learned scales are 0.5198 and 0.4047, a ratio
> of **1.284** against a speed ratio of **1.285**. Those agreeing to 0.1% is the sharpest statement of
> the defect — the model's pre-calibration output is very nearly *speed-blind*, so the calibration
> constant is forced to track speed one-for-one, which is precisely what a calibration constant must
> not do.
>
> The exponent reconciling these two paces is **p ≈ 0.78** — superseding the "p ≈ 1.15" first
> recorded, which came from RMS rather than per-step peak-to-peak. Still two points, still not a fit;
> see the prescription below, which is unchanged and now the only open item here.

> ### Refinement (2026-07-29, pace ladder) — "speed-blind" was true of the model, not the feature
>
> The wording above says the model's output is "very nearly *speed-blind*". That is correct about the
> **model** and was read, including by me, as an indictment of the **feature**. The pace ladder
> separates them, and the distinction matters because it points at different fixes:
>
> * The amplitude feature is **not** speed-blind. Over 27 non-overlapping 30 s windows spanning a
>   1.54× speed range, `log(step length)` on `log(per-step peak-to-peak)` fits with slope **0.670**,
>   95% CI **[0.562, 0.837]** by moving-block bootstrap, **R² = 0.773**. Zero is nowhere near the
>   interval.
> * The **exponent throws that information away**. At the shipped 0.25 the model reproduces only
>   about a third of the step-length change the feature is telling it about, which is what forces the
>   calibration constant to track speed one-for-one.
>
> So the 1.284-vs-1.285 observation stands exactly as recorded, and its cause is now identified: not
> a blind feature, a crushed one. [S-063](#s-063) has the fit and [S-064](#s-064) has the reason the
> exponent still must not be changed on its own.

**The default is deliberately left at 0.25.** Two paces from one runner in one session cannot
support replacing a published exponent, whether the candidate is 1.15 or 0.78; that would be
fabricating a constant with extra steps, which is exactly what [ADR-S-06](./design.md#adr-s-06)
exists to forbid. What the data supports is the *finding*, which is recorded here, and a
prescription for the recording that would settle it: a deliberate **pace ladder**, specified in
[Tools/pace-ladder-protocol.md](../../Tools/pace-ladder-protocol.md), which turns two points into
six and makes the exponent an actual fit rather than a line through two dots.

Until then [NFR-S-11](./requirements.md#93-accuracy) stays unvalidated, and the honest reading of the
calibrated distance figures is that they hold **at the pace the calibration was learned at**.

---

<a id="s-062"></a>
### S-062 — A cadence below the range floor is doubled, not rejected

**Satisfies** FR-S-B-2, NFR-S-7 · **Wave** S2 · **Done**

~~Found by the correction to [S-061](#s-061), which is the whole reason that entry's conclusion was
wrong.~~ Found while investigating [S-061](#s-061), on a hypothesis that turned out to be wrong about
the runs and right about everything slower than one.

`CadenceConfiguration.minStepsPerMinute = 120` makes the admissible band 120–240 spm, and §4.3
resolves stride-versus-step by mapping the two readings of a lag to disjoint intervals — which is
exact **provided the true cadence is inside that band**. Outside it the rule does not degrade, it
silently reinterprets. A 104 spm walk has a 0.579 s step period; that is outside the step interval
`[0.25, 0.5]`, so it lands in the stride interval and is reported as `120/0.579` = 207.3 spm.

Measured on the two walk traces, against a step rate taken by FFT from the recorded signal:

| Trace | True (spectral) | Reported | Ratio | Predicted by the mechanism |
|---|---|---|---|---|
| `…-1959` | 103.7 spm | 207.8 | **2.005** | 120/0.579 = 207.3 |
| `…-2023` | 106.1 spm | 211.2 | **1.991** | 120/0.566 = 212.2 |

~~Cadences below 120 spm cannot be reported… it never reads below 147 on the slow mile, where
CMPedometer puts 42% of samples below 120.~~ **Struck: that was the pedometer undercounting.** The
slow mile is genuinely run at ~161 spm and the estimator was right about it. The defect is real but
its blast radius is *slower than running* — walk breaks, warm-ups, the crossings in
[DEG-S-8](./requirements.md#98-degraded-modes) — and it never touched the figures in §12.1.

Severity is further limited by machinery that was already working: the doubled readings carried a
median confidence of 0.29–0.34 against a `minimumTrustedConfidence` of 0.4, so only 8–20% of them
were trusted and the calibrator never saw them. What was wrong was `current`, which is what a live
UI shows — and 210 spm shown to someone walking is wrong whatever a confidence field says elsewhere.

#### The fix — a stride reading must be earned

Lowering the floor alone cannot work, for the reason first recorded here: it breaks the
`max ≤ 2 × min` invariant that §4.3's disambiguation depends on. So the range is untouched and the
*interpretation* is widened instead. When the dominant lag lands in the stride interval, a stride
reading now has to be supported, and a contradicted one is re-read as a step down to
`slowGaitFloorStepsPerMinute` (60 spm — exactly the step reading at the longest lag the correlator
already searches, so this widens interpretation and not the search, and costs nothing).

**Two conditions, and the second is the one that matters.** The harmonic check alone is not enough,
and the property suite proved it: a running stride whose arm swing dominates its impacts
(`armSwingAmplitude: 20, impactAmplitude: 4`) has a weak half-lag correlation *for the same reason a
walking step does*, because the arm swing's own anti-correlation at half its period swamps the small
impact term. Read on periodicity alone those two cases are identical, and the first attempt at this
fix duly halved a true 140–200 spm cadence across 61 assertions.

What separates them is **amplitude**, which is the physical question anyway — walking or running?
The two candidate readings of such a lag are `60/L ∈ [60, 120]` and `120/L ∈ [120, 240]`: a walking
cadence and a running one. Measured over 5.12 s windows of the same gait-band signal the threshold is
compared against:

| Trace | p5 | median | p95 |
|---|---|---|---|
| walk `…-1959` | 2.63 | 3.02 | **3.64** |
| walk `…-2023` | 2.14 | 2.68 | 3.49 |
| slow mile | **7.09** | 7.96 | 9.14 |
| tempo | 9.58 | 10.91 | 12.64 |

The gap runs 3.64 → 7.09 with nothing in it, consistent with the 0.25 / 2.30 / 10.44
standing/walking/running figures [S-058](#s-058) measured independently on the bench trace.
`strideReadingRMSFloor = 5.0` sits inside it, and is placed so that **running is never re-read**:
being wrong here costs a walk shown at double, not a run shown at half.

#### Verification, both directions ([S-057](#s-057) bar)

| Trace | Before | After | Independent references |
|---|---|---|---|
| `…-1959` walk | 207.8 | **103.9** | spectral 103.7 · CMPedometer 103.9 |
| `…-2023` walk | 211.2 | **105.7** | spectral 106.1 · CMPedometer 105.7 |
| `…-1918` tempo | 159.578 | 159.573 | spectral 159.3 |
| `…-2010` slow mile | 161.4 | 161.4 | spectral 161.5 |

The walks converge onto *both* independent references, which agree with each other. The runs move by
0.005 spm and 1 mm of fused distance over 7 km — not zero, and it should not be zero: both running
traces contain stops, and during a stop the path is supposed to engage. A handful of firings in 41
minutes and none during running is exactly that signature.

`SlowGaitCadenceTests` asserts the before/after ratio is 2.0 rather than either figure against a
constant, since the defect *is* a doubling and stating it that way needs no external number to stay
correct. The pre-fix estimator is reproduced by setting `slowGaitFloorStepsPerMinute` to the range
floor, which disables this path exactly and nothing else.

**One lesson recorded deliberately.** The walking half of this is tested against the recorded traces,
not the generator, because the generator lays *impulses* at the step rate and an impulse train is
harmonic-rich in a way a recorded walk is not — its vertical channel is nearly a pure sinusoid at the
step rate, 1.00 relative power against 0.03 at the subharmonic. A synthetic walk therefore never
reaches the code path it was written to prove, and passed while the bug was still live.

---

<a id="s-063"></a>
### S-063 — The amplitude exponent, measured: 0.25 is wrong, ~0.70 is right, and it must not ship alone

**Satisfies** FR-S-B-4, NFR-S-11, CON-S-5 · **Wave** S2 · **Open**

`StepLengthConfiguration.amplitudeExponent` has always carried the instruction that "whatever value
ends up here must name the trace it came from". This is that trace:
`capture-2026-07-29-1757.motion.json`, a deliberate pace ladder,
[protocol](../../Tools/pace-ladder-protocol.md).

#### What was recorded, against what was asked for

The protocol specified seven segments. **No marks were tapped**, so boundaries had to be recovered
from the signal, and only those both GNSS receivers agree on are used. At K=4 the phone and the
watch put boundaries within 2 s of each other (≈264, 461, 693 s); at K≥5 they disagree, so the finer
structure is not recoverable and is not claimed.

| | Recorded | Consequence |
|---|---|---|
| Pace sections | **4** (3 ascending + 1 repeat), not 7 | Fewer, wider steps; range is still 1.54× |
| Marks | **none** | Boundaries inferred; segment identity is a hypothesis, so the fit below deliberately does not use it |
| Counted-step segment | **absent** | [NFR-S-8](./requirements.md#93-accuracy) stays unvalidated. This was the one measurement that could have closed it |
| Fatigue-control repeat | **present** | Earned its keep twice over — see the confound test |

The fit therefore runs on **27 non-overlapping 30 s windows**, not on segment means. That sidesteps
the missing marks entirely: each window carries its own measured speed, so boundaries are needed only
for the fatigue check.

#### The fit

Speed is CoreLocation Doppler from the same device as the motion, never position differencing —
integrating position inflates distance with noise, and the inflation is speed-dependent (measured at
+8.0% to +10.6% across speed bands), which is exactly the bias that would corrupt a slope.

| Feature | slope | 95% CI | R² |
|---|---|---|---|
| per-step peak-to-peak vertical | **0.670** | [0.562, 0.837] | 0.773 |
| \|userAcceleration\| RMS | 0.856 | [0.729, 1.138] | 0.807 |
| **\|ω\| RMS (gyroscope)** | 0.785 | [0.631, 0.905] | **0.812** |
| cadence | 1.398 | [−3.794, 8.318] | **0.008** |

Intervals are moving-block bootstrap, because adjacent windows of one continuous run are
autocorrelated and ordinary standard errors would overstate the precision.

Held out directly, which is the product's actual question — calibrate `C` on the slow windows, then
predict the fast ones:

| p | held-out bias | held-out scatter |
|---|---|---|
| **0.25 (shipped)** | **+8.86%** | 8.92% |
| 0.67 | +0.88% | 4.51% |
| **0.718** | **0.00%** | — |
| 0.75 | −0.57% | 4.51% |
| 1.00 | −4.98% | 6.58% |

Both bias and scatter minimise together near **0.70**, and the regression slope and the zero-bias
point agree. The shipped 0.25 under-predicts step length by nearly 9% one pace band away from where
it calibrated.

**Cadence contributes nothing.** R² 0.008, and a CI spanning [−3.8, +8.3]. Adding it to any model
worsens AIC. Across all three running traces — 128 windows, speed 1.80–3.19 m/s, a **1.77× range** —
cadence spans 154.8–165.3 spm, a 1.07× range. [design.md §5.1](./design.md#51-why-cadence-alone-cannot-work)
is confirmed for a fourth time and can stop being an open question.

#### The confound test, and why the fatigue repeat mattered

A monotone-ascending ladder confounds speed with elapsed time: fatigue, grip drift or arm tension
would all produce the same correlation. The final section returns to opening pace, which breaks it.

| | speed | a_pp | \|ω\| RMS | cadence |
|---|---|---|---|---|
| S3 / S1 | 1.309 | 1.436 | 1.377 | 1.004 |
| **S4 / S1** (repeat) | **1.035** | **1.056** | **1.115** | 1.006 |

The features come back down with the speed instead of staying at their S3 values. The relationship
is speed, not drift. **Future ladders should interleave the paces rather than ascend monotonically**
— the protocol has been updated — but on this recording the repeat did the job.

#### Why the exponent is still not changed

Swept through the real pipeline it makes the product **worse**, monotonically: fused error under a
simulated outage goes +6.11% at p=0.25 to +13.00% at p=0.67. That is not a contradiction of the fit
above, it is [S-064](#s-064) — the motion leg carries an independent over-read that the compressed
exponent was partly hiding. Fixing one of two compensating errors makes the visible error grow.

So the number is recorded, with the trace it came from, and the default stays at 0.25 until S-064 is
resolved and both can be validated together. Shipping a better-fitted exponent on top of a known
accumulator defect would trade a documented inaccuracy for an undocumented one.

**And it is one runner, one session.** The other two traces cannot corroborate it — see S-064 for why
they are structurally unable to. A tight fit to this session is a real result; it is not evidence
about anybody else, and [ADR-S-06](./design.md#adr-s-06) still governs.

---

<a id="s-064"></a>
### S-064 — The motion leg over-reads independently of the exponent

**Satisfies** FR-S-B-4, NFR-S-11 · **Wave** S2 · **Open**

On the pace ladder the motion-only accumulator reports **2510.8 m over 2204 steps = 1.139 m/step**,
against a measured mean step length of **1.008 m** (GNSS path ÷ steps) or 0.930 m (Doppler ÷ steps).
An over-read of **+13% to +22%** that has nothing to do with the exponent, and grows with it.

**It is not the step count.** That was the obvious suspect and it is innocent: integrating the
spectral cadence over the capture gives **2200 steps**, against the detector's 2204 — **+0.2%**.
CMPedometer's 2043 is **−7.1%**, its third disagreement with the arbiter in three traces
([ADR-S-06 amendment 1](./design.md#adr-s-06-amendment-1)).

**It is not the clamps.** They sit at 0.5–2.5 m and the mean is 1.139, though `stepLengthClamped`
does fire on a minority of steps and that is worth understanding separately.

That leaves the calibrated scale and the per-cadence-band gain of
[AC-FR-S-C-2-5](./requirements.md#fr-s-c-2--calibrating-the-step-length-model) as the remaining
candidates — the calibrator solves for `C` over qualifying GNSS windows while the accumulator applies
it to every step, and any mismatch in which steps those are lands here.

**Why the other two traces cannot help.** Neither the 4.3 mi tempo run nor the slow mile contains
real speed variation to test against:

* Tempo lap times are 400, 402, 397, 402, 400, 400 s — constant to **±0.6%**.
* Folding the six laps onto a common phase, the lap-to-lap correlation of the speed profile is
  **r = 0.000** (range −0.176 to +0.319).

Their window-to-window speed spread is Doppler noise, not pacing. Regressing any feature against
noise correctly returns a slope of zero, which is precisely what they do (tempo: slope 0.009,
R² 0.000). **This retires "the features fail to transfer across sessions" as a reading of that
result** — there was nothing there to transfer to. What does transfer is the level: fitted on the
ladder, the two-feature model predicts the other two sessions with bias **+0.70%** and **−0.67%**.

**Addendum (Waves S3–S5) — the same structure seen from the product end.** Building the isolation
boundary's acceptance test produced an independent observation of this cancellation, from a
different direction and without any of the analysis above.
[`StandaloneBoundaryTests`](../../Apps/iPhone/Tests/StandaloneBoundaryTests.swift) replays the 4.3 mi
trace twice with `amplitudeExponent` at 0.25 and 0.670. With GNSS available throughout, **the two
runs' distances differ by less than the display's own resolution** — the calibrator re-fits `C`
against the same reference, so the change in the unscaled model is very nearly cancelled. Suppress
GNSS after the tenth minute and the difference appears immediately, at **2.6%** over the outage.

Two things follow that were not obvious from the offline fit. **The exponent is nearly unobservable
on a well-calibrated GNSS run and fully observable during an outage** — which is exactly the regime
[NFR-S-10](./requirements.md#93-accuracy) bounds and exactly the one with the least evidence behind
it. And **the direction of its effect is not predictable from the model in isolation**: a larger `p`
produces a smaller fitted `C`, so the residual's sign depends on how the outage stretch's amplitudes
compare with the calibration stretch's. It came out *negative* here, against the model's positive
prediction, which is worth knowing before anyone reasons about which way a refit will move a runner's
distance.

Separately, the same test tried the per-cadence-band gain as its second knob and found it produces
**bit-identical** distances at band widths of 5 spm and 40 spm on this trace — the run holds
154–165 spm throughout, so every window lands in the same band either way. **The band gain is not
testable against any trace currently committed**, which is a second reason a second pace ladder
matters.

---

## Wave S2 — Validation against recorded traces

**This wave is blocked on hardware.** It cannot be started, let alone completed, without files from
[S-006](#s-006) recorded on a real phone during a real run. That is not a scheduling inconvenience —
it is the entire content of [CON-S-1](./requirements.md#con-s-1).

<a id="s-022"></a>
### S-022 — Commit the first recorded traces

| | |
|---|---|
| **Wave** | S2 |
| **Depends on** | S-006, S-007, S-021 |
| **Satisfies** | FR-S-F-2, CON-S-7 |
| **Touches** | `Fixtures/motion/*.motion.json`, `Fixtures/motion/README.md` |

**Done when:** at least one recorded hand-held running trace of ≥ 20 minutes is committed with its
reference data; the README states per trace what it carries and what it can validate; the traces
replay through `motionreplay` without error.

<a id="s-023"></a>
### S-023 — Fit the amplitude exponent and publish the coefficients

| | |
|---|---|
| **Wave** | S2 |
| **Depends on** | S-022 |
| **Satisfies** | FR-S-B-4, NFR-S-10 |
| **Touches** | `Apps/iPhone/PhoneMotion/Sources/PhoneMotion/Steps/StepLengthModel.swift`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/FitTests.swift`, `docs/standalone/design.md` (§5.3) |

Fit `p` offline over the committed traces, per
[design.md §5.3](./design.md#53-why-p--025-is-a-starting-point-and-not-an-answer). Commit the fitted
value **with the trace that produced it named at the point of definition**, so the number's
provenance is permanent.

**Done when:** `p` is fitted, committed, and attributed; the fit's residuals are reported; if the
fitted `p` differs materially from Weinberg's 0.25 the design document is reconciled rather than
left claiming the prior; if the model does not fit the data at any `p`, that is recorded as a
finding and [R-S-1](./requirements.md#11-risks) is escalated rather than the number being forced.

<a id="s-024"></a>
### S-024 — Trace goldens and the accuracy report

| | |
|---|---|
| **Wave** | S2 |
| **Depends on** | S-023 |
| **Satisfies** | NFR-S-7, NFR-S-8, NFR-S-9, NFR-S-10, NFR-S-11 |
| **Touches** | `Fixtures/motion/golden/**`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/TraceGoldenTests.swift`, `docs/standalone/requirements.md` (§12.1) |

Commit goldens for every trace and assert each accuracy NFR against the reference the trace
actually carries.

**Done when:** each of NFR-S-7 through NFR-S-11 is either **validated**, with the trace and number
recorded in [requirements §12.1](./requirements.md#121-validation-status), or **restated** to a
figure the data supports with the change explained; no NFR is left claiming an unmeasured bound.

<a id="s-025"></a>
### S-025 — Settle the open assumptions

| | |
|---|---|
| **Wave** | S2 |
| **Depends on** | S-024 |
| **Satisfies** | CON-S-5, NFR-S-2 |
| **Touches** | `docs/standalone/design.md`, `docs/standalone/requirements.md` |

Answer the five questions in
[design.md §10.4](./design.md#104-what-the-traces-must-settle) from the recorded data, and reconcile
both documents.

**Done when:** each of the five is answered with the evidence named; QS-3 and QS-5 in
[design.md §12](./design.md#12-open-questions) are resolved or restated; any assumption the data
contradicted is corrected in place rather than annotated.

---

## Wave S3 — Standalone capture

**Gated on S-024 producing an accuracy figure that supports the product.** If it does not, this wave
changes shape — the honest v1 may be GNSS-primary with motion providing cadence and a short coasting
fallback, which is a smaller product but a true one.

<a id="s-031"></a>
### S-031 — `StandaloneSensorFeed`

| | |
|---|---|
| **Wave** | S3 |
| **Depends on** | S-018, S-002 |
| **Satisfies** | FR-S-A-1, FR-S-B-1, CON-S-4 |
| **Touches** | `Apps/iPhone/Sources/Standalone/Sensors/**` |

The `RunSensorFeed` conformer: `CMMotionManager` device motion at the configured rate,
`CLLocationManager` configured for fitness with background updates, `CMAltimeter` for grade, feeding
`PhoneMotion` and emitting `EngineInput` at 1 Hz. Declares its `SensorCapabilities` per
[design.md §7.2](./design.md#72-the-sensorcapabilities-extension).

**Done when:** the feed emits at 1 Hz with correct provenance; capabilities report
`.measuredWithEstimatedFallback` and `.builderOnly`; authorization denial paths behave per
AC-FR-S-A-1-4/5/6; sample starvation raises the flag rather than degrading silently.

<a id="s-032"></a>
### S-032 — Standalone run controller and durability

| | |
|---|---|
| **Wave** | S3 |
| **Depends on** | S-031 |
| **Satisfies** | FR-S-A-2, NFR-S-13, NFR-S-6, DEG-S-11 |
| **Touches** | `Apps/iPhone/PhoneSupport/Sources/PhoneSupport/Standalone/**`, `Apps/iPhone/Sources/Standalone/Run/**` |

The observable object owning the feed, engine, sample store and cue engine; 30 s flush; orphan
recovery; background lifecycle; complete teardown.

**Done when:** a simulated run drives state end to end; a kill loses at most 30 s; the orphan is
offered on next launch; **after `end()`, no location subscription, motion update, audio session or
timer remains**, asserted by the same style of teardown test that backs NFR-8 on the watch.

<a id="s-033"></a>
### S-033 — HealthKit workout writer

| | |
|---|---|
| **Wave** | S3 |
| **Depends on** | S-032 |
| **Satisfies** | FR-S-A-4, CON-S-2 |
| **Touches** | `Apps/iPhone/Sources/Standalone/Health/**`, `Apps/iPhone/PhoneSupport/Sources/PhoneSupport/Standalone/WorkoutComposition.swift` |

`HKWorkoutBuilder` + `HKWorkoutRouteBuilder`, per [ADR-S-07](./design.md#adr-s-07). Step boundaries
as workout events. No fabricated heart rate.

**Done when:** a saved workout is readable in Health with distance and route; declined write
authorization records locally and says so; no HR sample is ever written; interval structure is
present.

<a id="s-034"></a>
### S-034 — Standalone runs in the hub

| | |
|---|---|
| **Wave** | S3 |
| **Depends on** | S-032 |
| **Satisfies** | FR-S-E-1, FR-S-E-2, DEG-S-4, DEG-S-5 |
| **Touches** | `Apps/iPhone/PhoneSupport/Sources/PhoneSupport/Standalone/**`, `Apps/iPhone/Sources/Features/RunDetail/**` |

Compose a `RunEnvelope` with `deviceTier == .phoneStandalone` and ingest it through the **existing**
`RunLibrary` path — no new store, no new ingest.

**Done when:** a standalone run appears in the run list, detail and statistics with no changes to
those screens beyond provenance; measured/estimated split and cadence are shown on detail; heart
rate reads `--` everywhere including aggregates, never zero; the existing ingest tests pass against
a standalone envelope.

<a id="s-035"></a>
### S-035 — Background execution and permissions

| | |
|---|---|
| **Wave** | S3 |
| **Depends on** | S-031 |
| **Satisfies** | FR-S-A-2, NFR-S-15, NFR-S-17, CON-S-4 |
| **Touches** | `Apps/iPhone/project.yml`, `Apps/iPhone/Sources/Standalone/Permissions/**` |

Background modes, usage descriptions that explain *why*, lazy authorization at first standalone run
only.

**Done when:** `plutil` confirms `location` and `audio` background modes and every usage
description; a hub-only session triggers no location or motion prompt, asserted by a test that
exercises the hub paths and checks the authorization request count; background survival is verified
on device and recorded in the manual protocol.

---

## Wave S4 — Feedback and the live run screen

<a id="s-041"></a>
### S-041 — Audio session and cue engine

| | |
|---|---|
| **Wave** | S4 |
| **Depends on** | S-032 |
| **Satisfies** | FR-S-D-1, DEG-S-9, DEG-S-10 |
| **Touches** | `Apps/iPhone/Sources/Standalone/Audio/**`, `Apps/iPhone/PhoneSupport/Sources/PhoneSupport/Standalone/CueComposer.swift` |

`.playback` + `.duckOthers` + `.mixWithOthers`; `AVSpeechSynthesizer`; the cue vocabulary of
[design.md §9.2](./design.md#92-the-cue-vocabulary), driven by the **unchanged** `ORAlerts.AlertPolicy`
([ADR-S-05](./design.md#adr-s-05)).

**Done when:** cues are composed from the existing `AlertCommand` cases with no new policy; music
ducks and resumes; the ring/silent switch does not suppress cues; a route change continues the run
on the speaker; an interrupting call pauses cues and resumes them.

<a id="s-042"></a>
### S-042 — Split announcements

| | |
|---|---|
| **Wave** | S4 |
| **Depends on** | S-041 |
| **Satisfies** | FR-S-D-1, NFR-S-19 |
| **Touches** | `Apps/iPhone/PhoneSupport/Sources/PhoneSupport/Standalone/SplitAnnouncer.swift` |

Distance-triggered split announcements on their **own** channel, deliberately not routed through
`AlertPolicy` — a mile split is not an alert and must not consume an alert's cooldown.

**Done when:** splits fire at exact unit boundaries in the runner's units; they do not suppress or
get suppressed by pace alerts; they are disableable independently; the strings are localizable and
unconcatenated.

<a id="s-043"></a>
### S-043 — Haptics

| | |
|---|---|
| **Wave** | S4 |
| **Depends on** | S-041 |
| **Satisfies** | FR-S-D-2 |
| **Touches** | `Apps/iPhone/Sources/Standalone/Haptics/**` |

Direction-distinct patterns for each `AlertCommand`, firing whether or not speech is enabled.

**Done when:** every command has a distinguishable pattern; disabling speech leaves haptics as a
complete channel; disabling pace haptics leaves interval haptics working; absence of a Taptic Engine
degrades rather than erroring; distinctness is verified on device and recorded in the manual
protocol.

<a id="s-044"></a>
### S-044 — Live run screen

| | |
|---|---|
| **Wave** | S4 |
| **Depends on** | S-032, S-043 |
| **Satisfies** | FR-S-D-3, DEG-S-6 |
| **Touches** | `Apps/iPhone/Sources/Standalone/Views/**` |

The tertiary-channel screen of [design.md §9.4](./design.md#94-the-screen-when-it-is-looked-at):
existing palettes, existing glyphs, phone-scaled proportions, stable layout, screen kept awake.

**Done when:** every zone renders its exact palette hex with no new colour literal; the glyph and
signed delta are present per FR-J-1; the layout does not reflow between zones; the idle timer is
restored when the screen is dismissed; an indoor standalone run shows the timed-only treatment.

<a id="s-045"></a>
### S-045 — Standalone start flow

| | |
|---|---|
| **Wave** | S4 |
| **Depends on** | S-044 |
| **Satisfies** | FR-S-A-1, CON-S-3 |
| **Touches** | `Apps/iPhone/Sources/Standalone/Start/**` |

Run type selection reusing the existing profile and presets, the carry-position statement, and the
three-tap start budget.

**Done when:** a run starts in ≤ 3 taps for the default type; all five run types are reachable; the
supported carry position is stated before the run and recorded on it.

---

## Wave S5 — Hardening

<a id="s-051"></a>
### S-051 — Degraded-mode coverage

| | |
|---|---|
| **Wave** | S5 |
| **Depends on** | S-044 |
| **Satisfies** | DEG-S-1, DEG-S-2, DEG-S-3, DEG-S-4, DEG-S-5, DEG-S-6, DEG-S-7, DEG-S-8, DEG-S-9, DEG-S-10, DEG-S-11, CON-S-8 |
| **Touches** | `Apps/iPhone/Sources/Standalone/Degradation/**`, `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/DegradationTests.swift` |

Each of the eleven standalone degraded modes handled and surfaced.

**Done when:** each has a named test proving the required behaviour; each surfaces a clear message
rather than a raw error; none causes data loss.

<a id="s-052"></a>
### S-052 — Standalone settings and profile

| | |
|---|---|
| **Wave** | S5 |
| **Depends on** | S-034 |
| **Satisfies** | FR-S-G-1 |
| **Touches** | `Apps/iPhone/Sources/Features/Profile/Standalone/**` |

Height (offered from HealthKit), cue and haptic preferences, calibration state and reset.

**Done when:** height reads from HealthKit with permission and is editable without; every setting
persists and takes effect immediately; calibration state is legible and resettable; watch behaviour
is unaffected.

<a id="s-053"></a>
### S-053 — Performance and battery

| | |
|---|---|
| **Wave** | S5 |
| **Depends on** | S-044 |
| **Satisfies** | NFR-S-1, NFR-S-2, NFR-S-4, NFR-S-5 |
| **Touches** | `Apps/iPhone/PhoneMotion/Tests/PhoneMotionTests/PerformanceTests.swift`, `Tools/standalone-manual-protocol.md` |

Offline throughput asserted in CI; CPU and battery measured on device and recorded, **not** asserted
in a simulator where the figure would be meaningless — the same honesty T-072 applied to Series 3.

**Done when:** a 60-minute trace processes offline within NFR-S-1; on-device CPU and battery are
measured and recorded; the suite asserts no on-device threshold it cannot actually measure.

<a id="s-054"></a>
### S-054 — Standalone manual protocol

| | |
|---|---|
| **Wave** | S5 |
| **Depends on** | S-053 |
| **Satisfies** | NFR-S-2, NFR-S-4, NFR-S-5, CON-S-1, CON-S-6 |
| **Touches** | `Tools/standalone-manual-protocol.md` |

Everything CI cannot check: background survival, audibility at speed over wind and music, haptic
perceptibility in the hand, accuracy against a measured course, battery, and the
screen-never-looked-at run of AC-FR-S-D-1-6.

**Done when:** the protocol covers every item in
[requirements §12.2](./requirements.md#122-what-is-hardware-verification-only); it names the required
hardware; it has a results template.

<a id="s-055"></a>
### S-055 — Documentation reconciliation

| | |
|---|---|
| **Wave** | S5 |
| **Depends on** | S-054 |
| **Satisfies** | NFR-S-20 |
| **Touches** | `docs/standalone/**`, `Apps/iPhone/README.md`, `README.md` |

Every judgement call and deviation recorded in the documents, not in commit messages — the
discipline the core track's "Wave 4 — as built" section established.

**Done when:** the validation-status table is current; the tier divergence matrix is accurate; every
deviation from this plan is written up with its reasoning.

---

<a id="waves-s3s5--as-built"></a>
### Waves S3–S5 — as built

Deviations and findings from executing this plan, recorded here rather than in commit messages.

**The wave was built boundary-first, and that was a deliberate reordering.** The plan lists S-031
(the feed) before S-032 (the controller) before the UI; what was actually built first was the
*adapter seam*, the gate that enforces it, and one integration test that proves it — before any
screen existed. The reason is that the boundary's value is entirely in what it prevents, and
prevention has to be in place before the thing it prevents has been written. Every screen added
afterwards was added against a build that would have failed if it reached for the estimator.

<a id="s3s5-the-boundary"></a>
#### The isolation boundary, and what it cost

[`Tools/check-phonemotion-isolation.sh`](../../Tools/check-phonemotion-isolation.sh) enforces three
rules: no `import PhoneMotion` outside the sensor-feed adapter, no build dependency on it from
`PhoneSupport` or `Core`, and no estimator tunable named anywhere else in the phone app. It is
verified to fail on a planted violation of each, in both directions, on the same terms as every
other gate.

Making that enforceable required four changes that were not in the plan:

1. **`MotionFlag` moved from `PhoneMotion` to `ORModels`.** These values have to reach the run
   record and the detail screen (AC-FR-S-E-2-4, DEG-S-5), and a type declared in the estimator can
   only get there by every screen importing the estimator. One declaration, both sides.
2. **`ORModels` gained `MotionTelemetry`, `CalibrationSummary` and `CalibrationStoring`.** The
   sensor contract already lived in `Core` ([ADR-S-02](./design.md#adr-s-02)); these extend it with
   the facts a motion-sensing tier reports that a watch has no equivalent of. `CalibrationStoring`
   is deliberately declared over opaque `Data` — the encoded shape belongs to the estimator and
   will change when [S-064](#s-064) lands, and a store that knew the field names would change with
   it.
3. **`RunEnvelope` gained an optional `standalone: StandaloneRunFacts?`** rather than a schema
   version bump. A synthesised `Codable` omits an absent optional's key entirely, so
   `Fixtures/legacy-tier-envelope.payload` still decodes and a watch envelope's bytes are
   unchanged — asserted by a test rather than reasoned about, because "adding an optional is safe"
   is true of synthesised coding and false of several hand-written alternatives.
4. **`RunnerProfile` gained four standalone fields and a hand-written `init(from:)`.** The fields
   are non-optional, so a synthesised decoder would have rejected every profile snapshot written
   before they existed — and `RunEnvelope` snapshots the profile into every stored run, so that
   would have made a runner's whole history unreadable after an update. Same remedy as
   `SensorCapabilities.init(from:)`.

**The gate had a bug that made one of its four checks vacuous, and verifying it is what found the
bug.** The manifest-dependency check was written as `printf … | grep -q …` under `set -o pipefail`.
`grep -q` exits the instant it matches; the writer ahead of it takes `SIGPIPE`; `pipefail` then
reports the *pipeline* as failed — so the condition was false exactly when the check found
something. A deliberately planted `.package(path: "../PhoneMotion")` in `PhoneSupport/Package.swift`
passed. Fixed with a here-string, and the trap is written into the script, because the same shape
silently disables any `producer | grep -q` under `pipefail`.

<a id="s3s5-the-acceptance-test"></a>
#### The acceptance test, and what it measured on the way

`Apps/iPhone/Tests/StandaloneBoundaryTests.swift` replays a committed 4.3 mi trace through the
production adapter, composer, hub ingest, analysis and screen model — twice, with one field of
`MotionEstimationConfiguration` changed between the runs — and asserts the run list, the lifetime
statistics, the detail screen and the live screen all move. It lives in the app's test bundle
because that is the only place both sides of the boundary are visible; the gate exempts tests for
that reason and keeps the ban on `Sources`.

Three findings came out of getting it to pass, and all three are about the estimator rather than
about the test:

**1. On a run with good GNSS throughout, the calibrator absorbs an exponent change almost
entirely.** The first version of the test left GNSS on and asserted that swapping `p` from 0.25 to
0.670 moved the distance; it moved it by less than the display's own resolution. That is the
calibrator working correctly — it re-fits `C` against the same GNSS reference, so a change in the
unscaled model is very nearly cancelled by an equal and opposite change in the scale. The test now
suppresses GNSS after the tenth minute, which is where the exponent *matters*: while the motion leg
is carrying the run on a scale learned earlier (DEG-S-1).

This is the same compensating-errors structure [S-064](#s-064) records, arrived at from a different
direction, and it is worth stating plainly: **the exponent is nearly unobservable on a
well-calibrated GNSS run and fully observable during an outage.** That is exactly the regime
[NFR-S-10](./requirements.md#93-accuracy) bounds and exactly the one with the least evidence behind
it.

**2. The direction of the exponent's effect is not predictable from the model alone.** The test
originally asserted that a larger exponent produces a larger distance, which is true of
`C · h · (A/(h·f²))^p` in isolation for a group above 1. With the calibrator in the loop it came out
**2.6% lower**, because a larger `p` produces a smaller fitted `C` and the sign of the residual
depends on how the outage stretch's amplitudes compare with the calibration stretch's. The
assertion is now on magnitude, with the reasoning recorded next to it.

**3. The per-cadence-band gain has no observable effect on the tempo trace.** It was the natural
second knob to demonstrate the boundary with — it is the other half of what S-064 will touch — and
band widths of 5 spm and 40 spm produced bit-identical distances. The run holds 154–165 spm
throughout, so every window lands in the same band either way. That is a true fact about the
recording rather than a broken boundary, and the test uses the step-detection threshold instead
with the negative result written down. **The band gain needs the pace ladder's speed range to be
observable at all**, which is a second reason a second ladder matters.

<a id="s3s5-deg-s-7"></a>
#### DEG-S-7 had a flag and no detector

Writing the S-051 coverage table — one named test per degraded mode — found that
`MotionFlag.carryPositionChanged` was declared, that `DistanceFusion` exposed `insert(flag:)` and
`disqualifyCurrentWindow()` for it, and that nothing called either. The mode was specified,
plumbed, and never implemented, and no test failed because no test asked.

It is implemented now, in `PhoneMotion`, because the detection is a signal question. The design is
worth recording because the obvious version is wrong: cadence confidence collapsing is *evidence*
of a pocketed phone, but on its own it is also what a traffic light looks like, and a flag that
fires every time a runner stops is a flag that means nothing. The detector requires a
**contradiction between two live sources** — swing periodicity gone while GNSS says the runner is
still moving — and it introduced `CarryPositionConfiguration` for its two tunables.

**The first implementation had a stale-witness bug**, caught by the test that says the flag must not
fire during a GNSS outage. Holding the last fix's speed without its timestamp made the witness
immortal: during an outage the last good fix kept testifying that the runner was moving, so every
outage long enough to also lose cadence confidence reported a carry-position change. Staleness is
now judged against the same dropout window the fusion uses to switch legs, so "GNSS is carrying the
run" and "GNSS can witness the carry position" are one condition rather than two that can drift
apart.

<a id="s3s5-deviations"></a>
#### Other deviations, each with its reason

**AC-FR-S-C-1-5's "per sample" provenance is stored as run-length-encoded spans, not a column.**
The literal reading is a `distanceSource` column in `PackedSamples`. That would change a columnar
format the watch tiers' goldens are written against, to carry a value that is constant across
minutes at a time. `StandaloneRunFacts.estimatedSpans` is exact, is a few dozen bytes, and lets the
detail chart shade the estimated stretches — which the column would also have allowed and nothing
else would. The in-flight requirement is unaffected: `EngineInput.distanceSource` is per tick and is
what drives the accumulation.

**`RunEngine`'s "trusted with no fix" rule now distinguishes `.motionModel` from `.pedometer`.**
AC-FR-S-C-3-2 requires the pace band to widen by 50% while distance is estimated, and the engine
widens it on `isGPSDegraded`, which was false for a standalone outage: with no fix, any non-location
source counted as trusted. That rule exists for treadmills — a permanently GPS-degraded indoor run
would widen the band for the whole session and record a degradation describing nothing. So the line
now names `.pedometer` and `.healthKit` rather than "not location". Neither watch tier emits
`.motionModel`, so their behaviour is unchanged, which AC-FR-S-A-3-4 requires and the
tier-equivalence goldens check.

**`NSHealthUpdateUsageDescription` was missing.** The app previously only *read* from Health — the
watch owned live capture and wrote the workout — so the write description had never been needed.
Its absence is not a warning: `requestAuthorization(toShare:)` traps without it. Added, and
`StandalonePermissionsTests` now reads all four descriptions out of the built bundle's own
`Info.plist` rather than out of `project.yml`, because a project regenerated from a stale spec would
pass a source-file check and ship without them.

**Heart rate is stripped structurally in `StandaloneWorkoutComposer`, not merely never supplied.**
The tier has no heart-rate sensor and the feed always reports `nil`, so this looked unnecessary
until a test composed a Wave 1 fixture — recorded on a watch, and carrying heart rate — as a
standalone run and got a phone-only run with a full HR series. AC-FR-S-A-4-3 is now enforced at the
composer rather than trusted upstream, and `StandaloneWorkoutWriting` has no parameter that could
carry one.

**Indoors there is no distance, not a hidden one.** DEG-S-6 says distance and pace are
"suppressed *and stated as suppressed*", and the first implementation read that as a display rule —
the screen showed `--` while the pipeline kept accumulating metres underneath. Reviewing the split
announcer caught what that meant: a treadmill run would have called out mile splits it had not
covered, and would have stored a distance in the run record. A belt gives the phone nothing to
measure displacement against, so the metres the step-length model produces indoors describe
nothing. `MotionPipeline` now reports zero distance for an indoor run — one place, so no surface
can disagree with another — and the composer records `DegradationFlag.indoorRun` so the run says
*why* it has none. It is added there rather than inferred by `RunEngine` from `.pedometer` with no
fix, because this tier does not use `CMPedometer` at all and misreporting the source to trigger an
inference would be a lie in the record.

That change has a consequence worth following through rather than leaving: **every interval preset's
steps end at a distance**, so indoors a rep would never end and the runner would be stuck on step
one with nothing to advance it — `canAdvanceManually` is true only for open goals. The start flow
therefore offers the three steady types indoors and the full five outdoors, and says why. Hiding
them is the honest form of DEG-S-6's "offer a timed-only run"; showing them and letting one hang
would not be.

**`StandaloneSampleStore` duplicates the watch's `SampleStore` rather than sharing it.** Not
laziness and not tier-isolation dogma: what differs is what has to survive. A watch run's samples
are the whole record; a standalone run's are not, because its cadence, provenance, calibration state
and estimated spans are facts no `RunSample` carries. A recovered orphan that lost them would come
back claiming a distance with nothing to say about where the distance came from.

**`CueSpeaking` and `HapticPlaying` are `@MainActor`**, for the same reason `RunSensorFeed` is: the
run controller is main-actor isolated and calls both synchronously from its tick, so the alternative
is an enqueued hop between an alert being decided and the buzz arriving.

**The `@MainActor` test-fixture trap, hit for the second time in this repository.** The three
standalone suites held their fakes as stored properties assigned in `setUpWithError`. That compiled
on Xcode 26 (Swift 6.3.3) and **failed CI's Xcode 16.4 (Swift 6.1)**: `XCTestCase.setUpWithError` is
`nonisolated`, and the feed and the cue and haptic spies are `@MainActor` because they conform to
main-actor protocols. Wrapping the body in `MainActor.assumeIsolated` inverted the failure — CI
would have accepted it, and the local toolchain rejected it with "sending `self` risks causing data
races". The async `setUp()` override compiled locally but was an untested bet on 6.1.

`WatchSupport`'s `RunSessionModelTests` had already met this and written the answer down: allocate
per test in an already-isolated context, register cleanup with `addTeardownBlock`, hold nothing in a
stored property. The three suites now use that shape — a `Harness` struct built by `makeHarness()`
— which is the one form both toolchains accept.

The lesson is not about concurrency. **The precedent was in the repository and I did not look for it
before writing the suites**, so a solved problem cost a red build. The comment on
`makeScratchDirectory` in each suite now names the other suite, so the next person finds it from
either end.

**A local-environment note that will cost someone an hour otherwise.** Adding a *new file* to
`ORModels` does not invalidate a dependent package's cached build plan on this SwiftPM version, so
`swift test --package-path Apps/WatchModern/WatchSupport` failed with `cannot find type
'StandaloneRunFacts' in scope` — an error inside `Core`, from a package that had not changed. Both
watch packages needed `rm -rf .build` once and then passed unchanged (WatchSupport 160 tests,
LegacySupport 39). CI checks out fresh and never sees it; a contributor pulling this commit will.

**The boundary test replays 12 minutes rather than the full 40.8.** Six full replays of 245 000
samples took eleven minutes in a debug simulator build, for a claim that is structural rather than
statistical. Twelve minutes of the same recorded signal fits a calibration, exercises an outage and
propagates a configuration change; the suite runs in about four.

**NFR-S-1 is a release-build bound, and the margin is 70×.** Writing the performance test found it
failing by a factor of 33 — and the same replay of the same trace on the same machine takes
**110.9 s** in debug and **1.60 s** in release, which scales to 163 s and 2.36 s per hour of
trace against a five-second budget. So the requirement holds comfortably, and only in release.

Two of the three available responses were wrong. Relaxing the bound to 165 s would restate a
published requirement to match an unoptimised build; asserting it in `swift test` would make the
suite permanently red. The debug run now **skips**, naming the figure it measured, and `core.yml`
re-runs the performance suite with `-c release` where the bound is genuinely checked — 3.7 s for
the whole suite. `Fixtures/motion/README.md`'s `motionreplay` invocations gained `-c release` for
the same reason: two minutes versus two seconds is the difference between the tool being used and
not.

<a id="s3s5-not-built"></a>
#### What is *not* built, and is not pretended to be

- **Nothing in `Tools/standalone-manual-protocol.md` has been run.** Background survival, cue
  intelligibility at speed, haptic distinctness in the hand, battery and CPU are all unverified —
  [§12.2](./requirements.md#122-what-is-hardware-verification-only) says which and why. The protocol
  exists and has a results template; it is waiting on a device and a runner.
- **The live screen has never been seen on hardware.** Its *model* is tested exhaustively without a
  simulator, which is the point of `StandaloneMetricsScreen` being a value type — but "legible at
  arm's length in motion" (AC-FR-S-D-3-3) is a claim only a run can support.
- **`HKWorkoutBuilder` has never written a real workout.** The composition and the authorization
  paths are tested against a fake; the framework call is not, and cannot be in CI.
- **[S-063](#s-063) and [S-064](#s-064) remain open**, and this wave does not touch them. What it
  does is make them a one-package change when they land — which the acceptance test now demonstrates
  rather than asserts.

---

<a id="wave-s6-first-field-session"></a>
## Wave S6 — What the first field session found

The first run of the built product on real hardware, 2026-07-30: two phone runs, 0.22 mi and
2.88 mi, hand-held, outdoors, with music playing.

**Most of it worked.** Haptics were felt and were distinct. The live screen was legible. Distance
came out **2.88 mi against a 2.8 mi reference — +2.9%**, and the run appeared in the library with
the phone badge, the provenance bar, and the motion notices, exactly as the tier matrix says it
should. None of that had been seen outside a test before.

**The audio did not.** Three findings, one of them severe, all of them in a layer no CI run can
reach — which is the whole argument for [S-054](#s-054) existing.

One observation is recorded here and deliberately not acted on, per the track brief: the 2.88 mi run
carried the `stepLengthClamped` flag and reported "some step lengths were outside the plausible
range and were limited". That is [S-064](#s-064)'s over-read seen from the product end on a
*different runner's* gait than the traces were fitted to. It is evidence for that task, not a
defect in this wave.

### S-065 — The music ducked and never came back

**Satisfies** FR-S-D-1, AC-FR-S-D-1-3 · **Wave** S6 · **Done**

> "The music would temporarily dim but WOULD NOT get back louder again after the audio message
> ended."

**`.duckOthers` ducks for as long as the session is active, not for as long as something is
speaking.** [S-041](#s-041) activated the session at the first cue and released it at `stop()`,
with a comment reasoning that reactivating per cue would make the music stutter every minute. The
reasoning was sound and the conclusion was backwards: the alternative it actually chose was not
"no stutter", it was a runner's music at reduced volume for twenty-five minutes.

The fix is to hold the session for a *cue* rather than for a *run*: activate per cue, and release
with `.notifyOthersOnDeactivation` once the utterance reports back. Nothing else restores another
app's volume. The stutter the original comment worried about is real, and is bounded by a 0.25 s
quiet period that coalesces cues arriving together — a step transition and a split land within a
second of each other and now share one duck.

Three things fell out of writing the test, and each is a separate way back into the same failure:

1. **The route-change handler clears the "configured" flag** so the next cue reconfigures for the
   new route (DEG-S-9). A release guarded on that flag would silently do nothing, and headphones
   coming out mid-cue would leave the music down for the rest of the run. `deactivate()` is
   therefore *not* guarded on it, with a comment saying why, because the guard is the obvious
   thing to add.
2. **A cue that never reports back would hold the session forever.** The release is driven by
   `didFinish`/`didCancel`; a synthesizer that declines to speak — because the session would not
   activate, because the route vanished — delivers neither. Found because the first version of the
   test waited on a real utterance and timed out on a simulator, which has no audio route. A 30 s
   watchdog now bounds it. No cue is remotely that long, so a healthy run never reaches it.
3. **An interruption must not release the session.** The system already took it for the call, and
   `stopSpeaking` delivers `didCancel` on the way out — which would otherwise walk straight into a
   release under someone else's phone call.

**Verified in both directions.** `AudioSessionControlling` extracts the two `AVAudioSession` calls
so the *sequence* is observable;
[`SpeechCuePlayerTests`](../../Apps/iPhone/Tests/SpeechCuePlayerTests.swift) asserts the release, its
options, its timing relative to the utterance, and each of the three routes above. What no test can
assert is that the volume audibly returns — there is no API that reports another app's loudness, and
a simulator has no other app. §3.1 of the manual protocol carries that, and now asks for **two**
cues, because one would pass even if the release only ever happened at the end of the run.

### S-066 — A robotic voice, spoken too fast

**Satisfies** FR-S-G-1, AC-FR-S-D-1-9 · **Wave** S6 · **Done**

> "The length of the audio message is right the voice just sounds really robotic … if there is any
> way to import a different voice to make it sound more human and less robotic (and also a little
> slower) that would be great."

**There is no way to import a voice.** `AVSpeechSynthesizer` loads no third-party assets and Siri's
voices are not vended to apps. What exists is Apple's own Enhanced and Premium voices — a free
download in Settings › Accessibility › Spoken Content › Voices — which are **not installed by
default**. With nothing else present, `AVSpeechSynthesisVoice(language:)` returns the compact voice,
and the compact voice is the robotic one. The app was not choosing badly; it was not choosing at all.

So `SpeechVoiceCatalog` picks the best installed voice by quality, the settings screen offers the
list with quality labels, and the footer states the true answer including the part that is a "no".
Novelty voices are excluded (a joke voice reading "ease off, twelve seconds fast" is not a pace cue)
and so is Personal Voice, which needs an authorization this app does not request — offering one that
would silently fail is worse than not offering it.

Rate moves from a hardcoded `1.1 ×` to a profile field defaulting to **0.9 ×**, with three named
steps. `RunnerProfile` gains `speechRateScale` and `speechVoiceIdentifier`; the identifier is an
opaque `String` that `Core` never interprets, for the same reason `CalibrationStoring` trades in
opaque `Data`. A rate arriving from a synced watch or a stored envelope is clamped where it crosses
the boundary — spelled out rather than composed from `min`/`max`, because `Swift.max(.nan, 0.6)` is
`.nan` and a `NaN` rate is an utterance AVFoundation declines to speak at all.

### S-067 — Runs that can leave the phone

**Satisfies** NFR-S-21, CON-S-5 · **Wave** S6 · **Done**

Screenshots were the only way to get a run off the device, and a screenshot of "2.88 mi" cannot be
analysed. **Profile › Developer › Export Runs** lists every recorded run — both tiers, including
runs recorded by earlier builds, because the export is assembled from what the store already holds
rather than from anything captured at the time of the run.

Each file carries the summary, the full sample series, the splits, the degradation flags, and for
phone runs the calibration state, the step count and the estimated spans. That last field is the
first question asked of a distance that looks wrong.

**Routes are reduced to metres east and north of each run's own first fix**, using the same transform
as `Tools/scrub-trace.swift`. This is structural, not a setting: `ExportedFix` has no field that
could hold a latitude, so an export that leaked one would not compile. [S-059](#s-059) is why —
a convenience switch here would be that mistake with a nicer interface.

Both halves are tested, because either alone is worthless. An export that carries no position is
trivial to write (emit nothing) and an export that preserves everything is the mistake already made.
So: the origin must be gone — asserted against the serialised **bytes**, since the model is where a
field could later be added that happens to carry a coordinate — and the track's length must survive,
within 1% of its haversine length.

The privacy assertion was checked by planting a leak, and **the first version of it passed anyway at
one of four precisions**: `String(format: "%.5f", 42.361145)` is `"42.36115"`, which does not occur
in `"42.361145"`, so a rounding check skips whichever precisions happen to round up. It truncates now.

---

<a id="recording-protocol-what-to-capture-and-why"></a>
## Recording protocol — what to capture, and why

This is the concrete form of [S-007](#s-007), and it is written here because it is the one thing in
this track that cannot be done by writing code.

**Why it is being asked for.** [CON-S-1](./requirements.md#con-s-1): the Simulator has no
accelerometer. Every accuracy figure in [requirements §9.3](./requirements.md#93-accuracy) is either
recorded-trace-validated or unvalidated, and there is no third option. Substituting a synthetic
signal here would be the same false-confidence failure as a test that asserts what its author
believed — with worse consequences, because there would be no golden reference to catch it.

### Session A — the long run (highest value)

| | |
|---|---|
| **What** | The planned ~4.3 mi high-effort run |
| **Phone** | In the hand, held normally, screen orientation whatever is natural. **Do not** put it in a pocket, and do not consciously change how you carry it. |
| **Watch** | Worn and recording the same run — this is the distance reference |
| **Capture** | Start the capture tool immediately before starting the watch; stop it immediately after |
| **Marks** | Tap the mark button at: (1) the moment you start running, after any walk-up; (2) each mile, if you know where they are; (3) the moment you stop running |
| **Validates** | Distance over a long duration against the watch's GNSS; cadence at a sustained hard effort; whether calibration converges and stays converged; how amplitude tracks a genuinely varying pace |

**One optional addition that would roughly double this session's value:** if the route passes
anything with a known distance — a 400 m track, a marked parkrun kilometre, a measured loop — mark
the start and end of it. A surveyed reference is the only thing better than GNSS
([CON-S-7](./requirements.md#con-s-7)), and 400 m of it is worth more than 4 miles of GPS for
pinning the scale.

### Session B — the slow mile

| | |
|---|---|
| **What** | The planned ~1 mi easy run |
| **Phone** | Same hand, same grip |
| **Watch** | Worn and recording |
| **Marks** | Start of running; end of running; **plus one counted-steps segment** — see below |
| **Validates** | The low end of the cadence range; whether the model extrapolates across efforts or only fits the one it was calibrated at; the step-count accuracy of NFR-S-8 |

**The counted-steps segment is the single most valuable 60 seconds of this whole exercise.** At any
steady point in the slow mile: tap mark, count your steps out loud (both feet — every time either
foot lands) for a comfortable 30–60 seconds, tap mark again, and note the count. That gives an
*exact* step-count and cadence reference over a known interval, which no GPS trace can provide, and
it is what turns NFR-S-7 and NFR-S-8 from targets into measurements.

### What each session cannot validate

Stated so the results are not over-read:

- Neither session validates behaviour during a **GNSS outage**, since neither route is likely to
  contain one. That is [NFR-S-10](./requirements.md#93-accuracy), the single most important figure
  in this track, and it needs either a run through a tunnel/underpass/dense urban canyon, or an
  outage simulated post-hoc by deleting a segment of the recorded location track and replaying —
  which is a legitimate and honest substitute *because the motion data underneath it is real*, and
  is what [S-024](#s-024) will do.
- Neither validates **battery** ([NFR-S-4](./requirements.md#92-battery)) unless the phone's battery
  percentage is noted before and after. If it is convenient, note it; it costs nothing.
- Two sessions from one runner do not establish anything about **other runners**. The first traces
  fit and validate the model for one person; generalisation needs more people and is a later,
  explicitly-scoped exercise.

### Results template

Record alongside each file:

```
Session:              A (long) / B (slow mile)
Date, time:
Device model, iOS:                          (the capture header records this too)
Runner height (m):                          (the model uses it — design.md §5.2)
Watch-reported distance:
Watch-reported average pace:
Watch-reported average cadence:             (if available)
Phone battery before / after:
Counted steps segment: marks #__ to #__, count = ____
Known-distance segment: marks #__ to #__, distance = ____
Anything unusual: (changed hands, carried something, stopped at lights, rain)
```

---

## Appendix A — Scope of the first implementation pass

Recorded here so the boundary between "specified" and "built" is legible rather than inferred.

| Wave | Status after this pass |
|---|---|
| S0 | Built |
| S1 | Built |
| S2 | **Blocked on recorded traces.** Specified, tooling ready, cannot be executed without hardware |
| S3–S5 | Specified, not built |

The stopping point is deliberate and follows the track brief: the estimation engine done properly is
a better outcome than the estimation engine plus a shaky UI. The gate between S2 and S3 exists
because the shape of Wave S3 legitimately depends on what S2 measures.

## Appendix B — Definition of done (this track)

The core track's Appendix B applies unchanged, plus:

9. No accuracy figure is stated without naming whether it came from a recorded trace.
10. `PhoneMotion` imports no Apple framework and its tests run on Linux.
11. Any tuned parameter names the trace it was tuned against, at the point of definition.
12. `requirements.md` §12.1's validation-status table is current as of the change.

## Appendix C — Requirement coverage

Verified mechanically by [S-008](#s-008)'s extension to `check-traceability.swift`.

| Epic | Requirements | Covering tasks |
|---|---|---|
| S-A — Lifecycle | FR-S-A-1…4 | S-002, S-031, S-032, S-033, S-035, S-045 |
| S-B — Gait estimation | FR-S-B-1…4 | S-011, S-012, S-013, S-014, S-015, S-016, S-023, S-031 |
| S-C — Fusion & calibration | FR-S-C-1…3 | S-017, S-018 |
| S-D — Feedback | FR-S-D-1…3 | S-041, S-042, S-043, S-044 |
| S-E — Hub integration | FR-S-E-1, FR-S-E-2 | S-034 |
| S-F — Tooling | FR-S-F-1…3 | S-005, S-006, S-007, S-019, S-021, S-022 |
| S-G — Settings | FR-S-G-1 | S-052 |
| Constraints | CON-S-1…8 | S-001, S-002, S-004, S-006, S-007, S-008, S-025, S-031, S-033, S-035, S-051, S-054 |
| Degraded modes | DEG-S-1…11 | S-018, S-032, S-034, S-041, S-051 |
| Non-functional | NFR-S-1…21 | S-001, S-003, S-005, S-008, S-012, S-013, S-014, S-016, S-018, S-020, S-024, S-025, S-032, S-035, S-042, S-053, S-054, S-055 |
