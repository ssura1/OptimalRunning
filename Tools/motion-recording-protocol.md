# Motion recording protocol

| Field | Value |
|---|---|
| Document | `Tools/motion-recording-protocol.md` |
| Task | [S-007](../docs/standalone/implementation.md#s-007) |
| Satisfies | FR-S-F-2, CON-S-7 |
| Companions | [`docs/standalone/requirements.md`](../docs/standalone/requirements.md), [`docs/standalone/design.md`](../docs/standalone/design.md) |

---

## Why you are being asked to do this

The iOS Simulator has **no accelerometer and no gyroscope at all**
([CON-S-1](../docs/standalone/requirements.md#con-s-1)). Unlike GPS — which Xcode can simulate from
a GPX route — there is no motion equivalent, and no scheme setting that produces one. This is a
harder constraint than anything the Series 3 tier hit, because Series 3 at least had a device.

So every accuracy figure in
[§9.3 of the standalone requirements](../docs/standalone/requirements.md#93-accuracy) is in exactly
one of two states: **validated against a recorded trace**, or **unvalidated**. There is no third
option, and generating a plausible-looking synthetic signal to fill the gap would be measuring the
generator rather than the estimator — the same false-confidence failure as a test that asserts what
its author believed rather than what the code does, with worse consequences here because there is no
golden reference to catch it against.

A recorded trace is the only input from which this track may claim a number.

## Before you go out

1. Build and install the app on a real iPhone from Xcode.
2. Open **Motion Capture** (developer screen).
3. Enter **your height in metres** — the step-length model uses it
   ([design.md §5.2](../docs/standalone/design.md#52-the-model)).
4. Confirm the availability line says device motion, accelerometer and gyroscope are all `yes`. If
   any says `NO` you are on a Simulator and nothing recorded will be usable.
5. Note the phone's **battery percentage**. It costs nothing and it is the only way
   [NFR-S-4](../docs/standalone/requirements.md#92-battery) ever gets a number.

## How to carry the phone

**In your hand, held the way you would normally hold it, and do not change how you carry it.**

Hand-held is the only supported carry position for v1
([CON-S-3](../docs/standalone/requirements.md#con-s-3)), and the reason is that carry position
changes the signal fundamentally rather than incrementally: a pocketed phone sees vertical
centre-of-mass oscillation at step frequency, while a hand-held one swings at *stride* frequency —
half of it — with a continuously changing orientation. A trace recorded half in-hand and half in a
pocket is two different experiments in one file, and neither half is long enough to be useful.

If you do change hands or pocket it, **tap MARK and note it** on the results sheet. A labelled
transition is useful data; an unlabelled one silently corrupts a fit.

You do not need to hold it any particular way up. The estimator projects acceleration onto gravity,
so the phone rotated 180° or held screen-inward produces the same vertical channel
([design.md §3.2](../docs/standalone/design.md#32-orientation-and-why-it-is-less-of-a-problem-than-it-looks)) —
and that invariance is asserted by a test, not assumed.

---

## Session A — the long run

| | |
|---|---|
| **What** | The planned ~4.3 mi high-effort run |
| **Phone** | In hand, per above |
| **Watch** | Worn, recording the same run — this is the distance reference |
| **Duration** | Whatever the run is. Longer is better; ≥ 20 minutes is the minimum useful |

**Marks to tap:**

| # | When | Why it matters |
|---|---|---|
| 1 | The moment you start *running*, after any walk-up | Separates the walk-up, whose gait is a different problem, from the run |
| 2, 3, … | Each mile, if you know where they are | Lets distance error be checked *per split* rather than only end-to-end, which is what distinguishes a constant scale error from a drift |
| last | The moment you stop running | As #1 |

**What this session validates:** distance over a long duration against the watch's GNSS; cadence at
a sustained hard effort; whether calibration converges and stays converged; and — the thing no
other session gives — how the acceleration amplitude tracks a genuinely varying pace, which is
[open question 3 in design.md §10.4](../docs/standalone/design.md#104-what-the-traces-must-settle)
and determines whether the amplitude term can carry the speed response at all.

**One optional addition that roughly doubles this session's value.** If the route passes anything
with a *known* distance — a 400 m track, a marked parkrun kilometre, a measured loop — tap MARK at
the start and end of it and note it. A surveyed reference is the only thing better than GNSS
([CON-S-7](../docs/standalone/requirements.md#con-s-7)), and 400 m of it pins the model's scale
better than 4 miles of GPS.

---

## Session B — the slow mile

| | |
|---|---|
| **What** | The planned ~1 mi easy run |
| **Phone** | Same hand, same grip |
| **Watch** | Worn, recording |

**Marks to tap:** start of running; end of running; **plus a counted-steps segment**.

### The counted-steps segment

**This is the single most valuable minute of the whole exercise.** At any steady point in the slow
mile:

1. Tap **MARK**.
2. Count your steps out loud — **every time either foot lands** — for a comfortable 30–60 seconds.
3. Tap **MARK** again.
4. Write the count down. Do it before you forget; you will forget.

That gives an **exact** step-count and cadence reference over a known interval. No GPS trace can
provide one, and it is what turns
[NFR-S-7](../docs/standalone/requirements.md#93-accuracy) (cadence, ±3 spm) and
[NFR-S-8](../docs/standalone/requirements.md#93-accuracy) (step count, ±2%) from stated targets into
measurements. Every other reference available in the field carries its own error; this one does not.

**What this session validates:** the low end of the cadence range; whether the model extrapolates
across efforts or only fits the one it was calibrated at; and the two step-counting requirements
above.

---

## What these two sessions cannot validate

Stated plainly so the results are not over-read.

**A GNSS outage.** Neither route is likely to contain one, and
[NFR-S-10](../docs/standalone/requirements.md#93-accuracy) — motion-derived distance during an
outage — is the single most important figure on this track. Two ways to get it:

- Run through a tunnel, an underpass, or a dense urban canyon, and mark the entry and exit.
- Or let [S-024](../docs/standalone/implementation.md#s-024) simulate one post-hoc, by deleting a
  segment of the recorded location track and replaying. This is a **legitimate** substitute, and it
  is worth being clear about why: the motion data underneath is real, so what is being tested is the
  estimator on a real signal with a real reference on either side. It is the exact opposite of a
  synthetic signal. `motionreplay --suppress-gnss-after <seconds>` does it, and
  `TraceTests.testSuppressingFixesAfterATimeProducesAnEstimatedTail` exercises the path.

**Battery.** Only if you note the percentage before and after.

**Anything about other runners.** Two sessions from one person fit and validate the model *for that
person*. Generalisation needs more people and is a later, separately-scoped exercise — and until it
happens, the shipped coefficients should be understood as one runner's.

---

## Getting the files off the phone

Each capture produces two files in **Files → On My iPhone → OptimalRunner → MotionCaptures**:

| File | What it is |
|---|---|
| `capture-<timestamp>.motion.json` | The assembled trace. This is the one to commit. |
| `capture-<timestamp>.ndjson` | The raw append-only stream. Kept deliberately — if assembly ever produces something wrong, this is the only copy of a run that cannot be repeated. |

Tap a capture in the app to share it; AirDrop to a Mac is quickest. They are also reachable through
the Files app without a debugger.

If the app was killed mid-capture, the `.ndjson` still exists and everything up to the last complete
line is intact — that is the entire reason for the two-format design
([`CaptureWriter`](../Apps/iPhone/Sources/Standalone/Capture/CaptureWriter.swift)).

---

## Results template

Fill one of these per session and keep it with the file.

```
Session:                     A (long) / B (slow mile)
Date, time:
Route:                       (road / trail / track / mixed; urban or open)
Weather:                     (rain changes grip, which changes the signal)

Device model, iOS:           (the capture header records these too — this is a cross-check)
Runner height (m):

Watch-reported distance:
Watch-reported moving time:
Watch-reported average pace:
Watch-reported average cadence:      (if available)

Phone battery before / after:

Counted-steps segment:       marks #___ to #___,  count = _____
Known-distance segment:      marks #___ to #___,  distance = _____ m
Mile marks:                  #___, #___, #___, #___

Carry position changed?      (yes/no — if yes, which marks)
Anything unusual:            (stopped at lights, carried a bottle, changed hands,
                              phone in pocket for a stretch)
```

## What happens to the file next

1. Committed under `Fixtures/motion/` with a `references` block stating what it carries and what
   each reference's own accuracy is ([S-022](../docs/standalone/implementation.md#s-022)).
2. `swift run motionreplay --trace <file>` prints cadence, step counts, distance, provenance and the
   comparison against every declared reference — including a reminder that no claim may be tighter
   than the reference it was made against.
3. The amplitude exponent `p` is fitted from it and committed **naming this trace**
   ([S-023](../docs/standalone/implementation.md#s-023)).
4. [§12.1 of the requirements](../docs/standalone/requirements.md#121-validation-status) moves the
   affected rows from *not validated* to a measured figure — or the requirement is restated to what
   the data actually supports, with the change explained.
