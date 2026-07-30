# Motion traces

Recorded hand-held motion, and the only input from which the standalone tier may claim an accuracy
figure.

## What is here

Seven traces, recorded on 2026-07-28 and 2026-07-29 on an iPhone 17e (iOS 26.5.2), hand-held,
runner height 1.77 m, across three outings. They are the only real motion data this track has.

| Trace | Duration | What it is |
|---|---|---|
| `capture-2026-07-28-1825.motion.json` | 10 s | A smoke check that the app no longer crashed on Start ([S-057](../../docs/standalone/implementation.md#s-057)) |
| `capture-2026-07-28-1826.motion.json` | 199 s | The labelled bench test ([S-058](../../docs/standalone/implementation.md#s-058)) |
| `capture-2026-07-28-1918.motion.json` | 40.8 min | **The primary validation set.** 4.3 mi hard tempo, six laps of one neighbourhood loop, marked at each lap end and each mile |
| `capture-2026-07-28-1959.motion.json` | 30 s | Walk between the tempo run and the slow mile |
| `capture-2026-07-28-2010.motion.json` | 12.4 min | 1 mi slow run — the second pace that made [S-061](../../docs/standalone/implementation.md#s-061) measurable |
| `capture-2026-07-28-2023.motion.json` | 2.9 min | Walk after the slow mile |
| `capture-2026-07-29-1757.motion.json` | 13.7 min | **The pace ladder** ([S-063](../../docs/standalone/implementation.md#s-063)). Four sections spanning 2.07-3.19 m/s, the only recording with deliberate, confound-controlled speed variation |

**Why the 4.3 mi trace is the primary set.** Six passes of one loop is six independent readings of
the same distance, so it separates a scale error from a drift — which a single out-and-back cannot.
The lap boundaries are confirmed twice over: the GNSS track returns to within 30 m of its origin at
t = 439, 841, 1238, 1640 and 2040 s, and the runner's own marks land within 1–3 s of each closure.
Marks alternate lap ends with mile marks; mark #12 is 3.2 s after #11 and is the accidental tap.

**The bench trace carries a labelled timeline**, which is what makes it worth committing. The runner
recorded, in order: 31 s standing motionless with a single deliberate **jump at t≈29 s**; 29 s
walking with the screen on; 37 s walking with the screen **off**; then 99 s running. The four marks
in the trace bound those segments at 31.19, 60.19, 96.94 and 196.16 s.

All seven carry `"references": []`, deliberately. No trace holds a surveyed distance or a counted-step
segment, so **none validates an accuracy bound on its own** and `motionreplay` says so rather than
printing a number that reads like one. What the 4.3 mi trace does carry is a *stated* total and a
lap structure the GNSS track independently confirms, which is why §12.1 can now quote a measured
figure for the fused distance while still calling NFR-S-8 and NFR-S-11 unvalidated. The distinction
is the whole point of the references block: a stated distance is evidence, a surveyed one is proof.

## What is still not validated

**Step count (NFR-S-8) and uncalibrated distance (NFR-S-11).** See
[§12.1](../../docs/standalone/requirements.md#121-validation-status) for the full table.

The two recordings that would close the remaining gaps, in priority order:

1. ~~**A pace ladder**~~ — **recorded 2026-07-29**, four sections rather than seven and without
   marks, but it carried the deliberate speed variation the fit needed. The exponent is now measured
   ([S-063](../../docs/standalone/implementation.md#s-063)). A second ladder from a different runner,
   with the interleaved pace order the protocol now specifies, is what would make it general.
2. **A counted-step segment** — MARK, count footfalls aloud for 30–60 s, MARK, write the number down.
   It is the only *exact* reference obtainable in the field and the only thing that can turn NFR-S-8
   from a comparison between two estimators into a measurement. The ladder protocol folds this in as
   an optional final segment, so one outing can close both.

**On `CMPedometer` as a reference.** Every trace records it, and it is a *baseline, never an input*
([ADR-S-06 amendment 1](../../docs/standalone/design.md#adr-s-06-amendment-1)). Measured against a
step rate taken by FFT from the recorded signal, it undercounts the hand-held slow mile by **20.7%**.
Treating it as ground truth produced a confident and entirely wrong conclusion about
[S-061](../../docs/standalone/implementation.md#s-061). A second estimator is not an arbiter.

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

**Use `-c release`.** It is not a micro-optimisation: replaying the 40.8-minute trace takes
**110.9 s** in a debug build and **1.60 s** in release, a factor of 70. A tight numeric loop over
a quarter of a million samples is exactly the shape that costs the most unoptimised. NFR-S-1's
five-second budget holds comfortably in release and is missed by 33× in debug, which is why
`core.yml` asserts it in a release build and the debug test run skips it saying so.

```bash
# What does the estimator make of it, and how does that compare to its references?
swift run -c release --package-path Apps/iPhone/PhoneMotion motionreplay \
    --trace Fixtures/motion/<name>.motion.json

# The full cadence series rather than a summary
swift run -c release --package-path Apps/iPhone/PhoneMotion motionreplay \
    --trace <path> --print-cadence

# Simulate a GNSS outage over real motion data (S-024). Legitimate because the motion
# underneath is real — the opposite of a synthetic signal.
swift run -c release --package-path Apps/iPhone/PhoneMotion motionreplay \
    --trace <path> --suppress-gnss-after 600

# Regenerate a golden. A deliberate act, with a justification in the PR body.
swift run -c release --package-path Apps/iPhone/PhoneMotion motionreplay --trace <path> \
    --golden Fixtures/motion/golden/<name>.motion.golden.json --update-goldens
```

## Privacy

A motion trace is health data and a location trace is worse
([NFR-S-16](../../docs/standalone/requirements.md#95-privacy--security)).

**Nothing here carries absolute position.** Every trace has been through
[`Tools/scrub-trace.swift`](../../Tools/scrub-trace.swift), which replaces latitude and longitude
with `eastMetres`/`northMetres` measured from the trace's own first fix — preserving displacement,
shape, bearing change and turn radius, discarding the origin. `check-motion-fixtures.sh` fails the
build if a coordinate ever reappears.

This is enforced rather than remembered because remembering did not work: 276 absolute fixes were
committed to this public repository before the tool existed
([S-059](../../docs/standalone/implementation.md#s-059)). Scrub before promoting, always:

```bash
swift Tools/scrub-trace.swift captures/<name>.motion.json Fixtures/motion/<name>.motion.json
```
