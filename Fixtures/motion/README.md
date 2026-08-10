# Motion traces

Recorded hand-held motion, and the only input from which the standalone tier may claim an accuracy
figure.

## What is here

Nine traces, recorded between 2026-07-28 and 2026-08-09, hand-held, runner height 1.77 m, across
five outings. They are the only real motion data this track has. The first seven are from an iPhone
17e (iOS 26.5.2); the two August traces are from an iPhone 18,5 (iOS 26.5.2).

| Trace | Duration | What it is |
|---|---|---|
| `capture-2026-07-28-1825.motion.json` | 10 s | A smoke check that the app no longer crashed on Start ([S-057](../../docs/standalone/implementation.md#s-057)) |
| `capture-2026-07-28-1826.motion.json` | 199 s | The labelled bench test ([S-058](../../docs/standalone/implementation.md#s-058)) |
| `capture-2026-07-28-1918.motion.json` | 40.8 min | **The primary validation set.** 4.3 mi hard tempo, six laps of one neighbourhood loop, marked at each lap end and each mile |
| `capture-2026-07-28-1959.motion.json` | 30 s | Walk between the tempo run and the slow mile |
| `capture-2026-07-28-2010.motion.json` | 12.4 min | 1 mi slow run — the second pace that made [S-061](../../docs/standalone/implementation.md#s-061) measurable |
| `capture-2026-07-28-2023.motion.json` | 2.9 min | Walk after the slow mile |
| `capture-2026-07-29-1757.motion.json` | 13.7 min | **The pace ladder** ([S-063](../../docs/standalone/implementation.md#s-063)). Four sections spanning 2.07-3.19 m/s, the only recording with deliberate, confound-controlled speed variation |
| `capture-2026-08-02-2019.motion.json` | 41.1 min | A second long outdoor run, 7151 m by GNSS. No marks and no references — see the note below on why it validates nothing on its own |
| `capture-2026-08-09-1924.motion.json` | 27.2 min | **The stationary-behaviour trace, and the first with marks bounding a counted segment.** Two 60 s running efforts, then 20.5 minutes of a phone lying still. The still stretch is why it is here |

**Why the 4.3 mi trace is the primary set.** Six passes of one loop is six independent readings of
the same distance, so it separates a scale error from a drift — which a single out-and-back cannot.
The lap boundaries are confirmed twice over: the GNSS track returns to within 30 m of its origin at
t = 439, 841, 1238, 1640 and 2040 s, and the runner's own marks land within 1–3 s of each closure.
Marks alternate lap ends with mile marks; mark #12 is 3.2 s after #11 and is the accidental tap.

**The bench trace carries a labelled timeline**, which is what makes it worth committing. The runner
recorded, in order: 31 s standing motionless with a single deliberate **jump at t≈29 s**; 29 s
walking with the screen on; 37 s walking with the screen **off**; then 99 s running. The four marks
in the trace bound those segments at 31.19, 60.19, 96.94 and 196.16 s.

**The 2026-08-09 trace is the one that changed what this directory can do.** It carries two marks,
at t = 5.1345 and t = 62.1517, bounding a 57.017 s segment the runner counted footfalls through —
the first anchored counted-step segment in the project. It also carries 20.5 minutes of a phone
lying still after the session ended, recorded by accident, and that accident found a defect no
running trace could have: the step detector reported **1526 steps** across the still stretch,
because the stationarity gate suppressed events without advancing the phase anchor and the
phase-locked fallback then back-filled the entire stop the moment the gate reopened. It now reports
52. `StationaryBackfillTests` pins both directions against this file, and the fix is bit-identical
on the marked running segment — 153 steps either way — which is what makes it a fix rather than a
suppression.

All nine still carry `"references": []`, deliberately, and the reason is now more specific than it
used to be. No trace holds a surveyed distance. And the counted-step numbers this project finally
has cannot be attached either, for two different reasons worth stating so nobody assumes it was an
oversight:

- The **marked** segment on 2026-08-09 has exact bounds and no written-down count. The runner
  counted and did not record the number — the exact failure the protocol warns about in as many
  words ("write the count down; you will forget"). An independent spectral integral puts it at
  153.5 steps and the detector at 153, but **an estimate is not a reference**, and putting one in
  the references block would launder it into ground truth.
- The **counted** number that does exist — 161, over the 60 s of `run-2026-08-09-2326-tempo` — has
  no marks around it, because it was bounded by the app's own Start and Stop rather than by taps in
  the capture tool. It is anchored to this trace only by wall-clock: the run started 119 s after
  the capture did, which the running burst's measured onset at t = 119.39 confirms.
  `MotionTrace.Reference` can be bounded by mark indices and by nothing else, so there is no
  honest way to record it here. **That is a gap in the trace format, not in the data**, and it is
  the first thing to fix before the next counted segment is recorded.

So **none of the nine validates an accuracy bound on its own** and `motionreplay` says so rather
than printing a number that reads like one. What the 4.3 mi trace does carry is a *stated* total
and a lap structure the GNSS track independently confirms, which is why §12.1 can quote a measured
figure for the fused distance while still calling NFR-S-11 unvalidated. The distinction is the
whole point of the references block: a stated distance is evidence, a surveyed one is proof.

## What is still not validated

**Step count (NFR-S-8) and uncalibrated distance (NFR-S-11).** See
[§12.1](../../docs/standalone/requirements.md#121-validation-status) for the full table.

The two recordings that would close the remaining gaps, in priority order:

1. ~~**A pace ladder**~~ — **recorded 2026-07-29**, four sections rather than seven and without
   marks, but it carried the deliberate speed variation the fit needed. The exponent is now measured
   ([S-063](../../docs/standalone/implementation.md#s-063)). A second ladder from a different runner,
   with the interleaved pace order the protocol now specifies, is what would make it general.
2. ~~**A counted-step segment**~~ — **recorded 2026-08-09, and it has moved NFR-S-8 from a comparison
   between two estimators to a measurement**, though not yet to a validation. Two things still stand
   between it and a closed requirement, and neither is another run:

   - **The trace format cannot hold the number.** A `countedSteps` reference can be bounded only by
     mark indices, and the count that exists was bounded by the app's Start/Stop rather than by
     marks. Give `MotionTrace.Reference` optional `fromSeconds`/`toSeconds` bounds and it fits.
     While that is open, `motionreplay` also compares a windowed `countedSteps` reference against
     the **whole-trace** step count — it reads `reference.value` and ignores `fromMarkIndex`, so the
     first person to add a windowed reference gets a confidently wrong percentage.
   - **NFR-S-8 asks for ≥ 5 minutes and every protocol here asks for 30–60 s.** The requirement and
     the procedure that is supposed to evidence it have never agreed. One of them has to move.

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
