# Pace ladder recording protocol

| Field | Value |
|---|---|
| Document | `Tools/pace-ladder-protocol.md` |
| Task | [S-061](../docs/standalone/implementation.md#s-061) |
| Settles | NFR-S-11, and NFR-S-8 if the optional final segment is included |
| Companion | [`Tools/motion-recording-protocol.md`](./motion-recording-protocol.md) |

---

## What this recording is for

One number: the exponent on the amplitude term of the step-length model.

The two runs already recorded say the shipped value is wrong but cannot say what is right. Cadence
is flat across them (ratio 0.975) while step length carries the entire speed change (1.318), and
Weinberg's fourth root supplies only **32%** of that. The calibrator absorbs the rest, and the giveaway
is that its learned scale ratio (1.284) matches the speed ratio (1.285) to a tenth of a percent — a
calibration constant tracking speed one-for-one, which is what a calibration constant must never do.

Two points cannot fit an exponent. Six can. That is the whole purpose of this outing, and
[ADR-S-06](../docs/standalone/design.md#adr-s-06) forbids touching the constant without it.

**You do not need to hit these paces precisely.** The fit uses your *measured* GNSS speed in each
segment, not the target. The targets exist only to spread the data across a wide enough speed range.
What actually matters is that each segment is internally steady, distinctly faster than the one
before, and long enough — so run by feel and let the analysis read the speed off the trace.

## The ladder

Anchored on your own measured paces, not generic ones: the 4.3 mi tempo run came out at **9:22/mi**
(2.863 m/s) and the slow mile at **12:02/mi** (2.228 m/s). Running your tempo back through the
profile's derivation puts your 10 k at roughly 8:50/mi and your easy pace near 11:30/mi.

| # | Target pace | ≈ speed | Effort it should feel like |
|---|---|---|---|
| 1 | 12:00 /mi | 2.24 m/s | Recovery. Slower than easy — conversational, almost lazy |
| 2 | 9:15 /mi | 2.90 m/s | Tempo — near where the 4.3 mi run sat |
| 3 | 11:10 /mi | 2.40 m/s | Easy |
| 4 | 8:45 /mi | 3.07 m/s | 10 k effort. Comfortably hard, not a sprint |
| 5 | 10:25 /mi | 2.57 m/s | Easy-to-long |
| 6 | 9:50 /mi | 2.73 m/s | Long-run pace |
| 7 | 12:00 /mi | 2.24 m/s | **Repeat of #1.** The fatigue control |

**Two minutes each**, running continuously through the pace changes — do not stop between segments.
Twelve minutes of running in the ladder, plus warm-up.

**The order is deliberately not monotone, and that is a correction from the first attempt.** A ladder
that only ascends confounds speed with elapsed time: fatigue, grip drift and arm tension all rise
together with pace, and any of them would produce the same apparent relationship as speed. The first
recording was monotone and survived only because segment 7 existed to break the tie
([S-063](../docs/standalone/implementation.md#s-063)). Interleaving breaks it structurally instead of
relying on one segment.

Segment 7 stays regardless — it is what makes this a controlled experiment rather than six samples.
If it produces a different amplitude and cadence from segment 1 at the same speed, fatigue is
confounding the fit. If it matches, the ladder is clean. Either answer is worth two minutes.

## How to record it

**Before you start**

- Same carry position as every previous capture: **hand-held, same hand, screen may be off.** The
  model is carry-specific, so a different hand or a pocket makes this trace unusable for its purpose.
- Flat ground. A gradient changes step length directly and would land in the fit as if it were speed.
  An out-and-back on level ground is ideal; a loop you know is flat is fine.
- Open sky. The fit needs good GNSS speed per segment.
- Warm up for 5–10 minutes **before** pressing Start, or run the first few minutes knowing they will
  be discarded.
- Nothing new in your hands or on your arms that would change the arm swing.

**During**

1. Press **Start** and begin segment 1.
2. **MARK once at each pace change** — as you begin accelerating into the next segment. Seven marks
   for seven segments, plus one final mark when you stop.
3. Hold each pace steady. The first 20 s of every segment is discarded as transition, so settle in
   and then stay there.
4. If you tap MARK by accident, tap it once more immediately — two marks within a few seconds are
   recognisable as a mistake, whereas one stray mark shifts every segment boundary after it.

**Optional, and it closes a second gap for free**

After segment 7, without stopping the recording: **MARK, then count your footfalls aloud for 60
seconds, then MARK**, and write the number down. That is a `countedSteps` reference — the only
*exact* reference obtainable in the field, and the only thing that can turn
[NFR-S-8](../docs/standalone/requirements.md#93-accuracy) from a comparison between two estimators
into a measurement. It is currently one of the two recordings
[`Fixtures/motion/README.md`](../Fixtures/motion/README.md) lists as missing; this is the cheapest
opportunity to get it.

**Afterwards**

Send the capture the same way as last time — it lands in the app's sandbox, not the repo:

```bash
# from the Motion Capture screen, share the .ndjson out, then:
swift Tools/scrub-trace.swift captures/<name>.motion.json Fixtures/motion/<name>.motion.json
```

The scrubber is not optional. It strips absolute latitude and longitude, keeps displacement and
shape, and re-reads its own output to prove no coordinate survived
([S-059](../docs/standalone/implementation.md#s-059)).

Tell me the counted-step number and anything that went differently from the plan — a segment cut
short, a road crossing, a pace you could not hold. A noted deviation is data; an unnoted one is
noise.

## What the first run of this protocol showed (2026-07-29)

Recorded as `Fixtures/motion/capture-2026-07-29-1757.motion.json`. Four sections landed rather than
seven, no marks were tapped, and the counted-step segment was skipped. The fit still worked, and the
reasons why are worth knowing before the next attempt:

* **Missing marks cost less than expected.** The analysis was moved onto 30 s sliding windows, each
  carrying its own measured speed, so segment boundaries were needed only for the fatigue check.
  Tap them if you can — they make the reconciliation unambiguous — but the fit does not depend on them.
* **The missing counted-step segment cost the most.** [NFR-S-8](../docs/standalone/requirements.md#93-accuracy)
  is still unvalidated and nothing else in the recording can close it. It is 60 seconds of counting.
* **Do not bother with a Strava export.** It re-exports the watch's own recording — the two integrate
  to an identical 2149.9 m — resampled to 1 Hz with the accuracy fields stripped. The Apple Health
  export carries `<speed>`, `<hAcc>` and `<vAcc>`; Strava carries none of them.
* **Apple Watch Series 3 on watchOS 8 has no stride-length, ground-contact or vertical-oscillation
  metrics.** Those need Series 8 or newer. Nothing was lost by asking, but do not plan around them.

## What will be done with it

1. Split at the marks, discard the first 20 s of each segment.
2. Per segment, take measured GNSS speed, cadence, and per-step peak-to-peak vertical amplitude.
3. Fit the exponent across all seven segments plus the two existing runs — nine points.
4. Compare segment 7 against segment 1 to bound the fatigue effect, and report it whichever way it
   comes out.
5. Change the default **only** if the fit is well-conditioned across the range. If the points do not
   support an exponent, that gets recorded as a finding and the constant stays at 0.25 — a bad fit
   from good data is still an answer, and [CON-S-7](../docs/standalone/requirements.md#con-s-7) means
   it will be reported as one rather than dressed up.
