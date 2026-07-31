# OptimalRunner — Standalone iPhone Track: Requirements

| Field | Value |
|---|---|
| Document | `docs/standalone/requirements.md` |
| Track | **Standalone** — pace management on iPhone alone, no paired watch |
| Version | 1.0 |
| Status | Draft for implementation |
| Last updated | 2026-07-27 |
| Companions | [`design.md`](./design.md), [`implementation.md`](./implementation.md) |
| Depends on | [`../requirements.md`](../requirements.md), [`../design.md`](../design.md), [`../implementation.md`](../implementation.md) |

---

## 0. How to read this document

This is a **separate track**, not a revision of the core product specification. Everything in
`docs/requirements.md`, `docs/design.md` and `docs/implementation.md` remains in force and unedited.
This document adds what is new, and cross-references what is reused.

- **Requirement IDs carry an `S` segment** so nothing collides with the core track:
  `FR-S-<letter>-<n>` (functional), `AC-FR-S-<letter>-<n>-<n>` (acceptance criteria),
  `NFR-S-<n>` (non-functional), `CON-S-<n>` (constraint), `R-S-<n>` (risk), `ADR-S-<nn>`
  (architecture decision, declared in [`design.md`](./design.md)). Task IDs are `S-###` in a fresh
  wave sequence `S0, S1, …`, unrelated to the core track's `T-###` / Wave 0–7.
- **A bare `FR-A-1` always means the core track.** Standalone requirements never renumber, restate
  or supersede a core requirement. Where standalone behaviour differs from core behaviour, that is
  stated as a *divergence* with the core ID named, in [§5](#5-constraints-and-accepted-deviations).
- **Acceptance criteria** use the same [EARS](https://alistairmavin.com/ears/) phrasing as the core
  track, and the same rule applies: every AC is mechanically verifiable, by an automated test or by
  a scripted manual protocol. Where an AC can only be verified on hardware this document says so
  *at the AC*, rather than leaving it to be discovered later.
- Numeric defaults marked *(tunable)* are configuration fields, not literals. Core tunables live in
  `PaceEngineConfiguration` (NFR-21); this track's live in `MotionEstimationConfiguration`
  ([NFR-S-13](#96-maintainability)).
- **Figures attributed to the literature are cited.** Where a bound is an engineering target rather
  than a published measurement, it says so. This distinction is load-bearing: this track's central
  claim is a numeric one, and a guessed number dressed up as a measured one would be the worst
  possible failure here. See [§13](#13-references).

---

## 1. What this track is

> OptimalRunner works on an iPhone alone. Same product, same prescriptions, same post-run analysis —
> but with the phone in your hand as the only sensor, and your ears rather than your eyes as the
> primary channel.

The core product assumes a watch senses the run and a phone analyses it. This track removes the
watch. The value proposition is unchanged: prescribed tempo / easy / long / interval / VO2 max
sessions, real-time feedback on whether you are running them correctly, and the full analysis hub
afterwards. What changes is *how the phone knows how fast you are going* when it is the only device
in the system, and *how it tells you* when it cannot rely on being looked at.

### 1.1 Why this is a distinct track and not a feature

Three things are genuinely new, and each of them is the kind of thing that is cheap to specify up
front and expensive to retrofit:

1. **A new sensing problem.** A hand-held phone is not a wrist-worn IMU with a different case. It
   swings through a large arc, its orientation relative to the body changes continuously through
   that swing, and it is not rigidly coupled to the runner at all — it is held, with a grip that
   varies. The pedestrian-dead-reckoning literature that covers pocket and waist placement does not
   transfer unmodified ([§13](#13-references)), and the running literature that does handle aerial
   phases mostly assumes a foot-mounted sensor.
2. **A new feedback problem.** The core product's first conviction is that "during a run, the watch
   should tell you one thing" — a colour, read in under 250 ms of wrist-glance
   (`../requirements.md` §1). That conviction does not survive the phone being in a swinging hand.
   Reading it requires arresting the swing, raising the arm and focusing on a moving target, at the
   cost of looking away from the road. [FR-S-D-1](#fr-s-d-1--audio-is-the-primary-feedback-channel)
   re-decides the primary channel from first principles rather than inheriting
   [FR-J-1](../requirements.md#fr-j-1--colour-is-never-the-only-channel).
3. **A new verification problem.** The iOS Simulator has no accelerometer or gyroscope at all
   ([CON-S-1](#con-s-1)). Unlike GPS, which Xcode can simulate from a GPX file, there is no motion
   equivalent. Every claim this track makes about estimation accuracy has to come from recorded
   traces off real hardware or it is not a claim, it is a hope.

### 1.2 Business goals

Numbered in this track's own sequence; the core track's G-1…G-6 are unaffected.

| ID | Goal | Success metric |
|---|---|---|
| G-S-1 | Let a runner who owns no smartwatch use the product's core mechanic | A hand-held iPhone run produces the same zone timeline shape as a watch run over the same course, within the bounds of [NFR-S-3](#93-accuracy) |
| G-S-2 | Keep pace honest when GPS is not | Distance error during a GPS outage stays inside [NFR-S-4](#93-accuracy), rather than the pace display simply freezing or lying |
| G-S-3 | Do not require the runner to look at the phone | A complete tempo run is runnable with the screen face-down in the hand, verified in the manual protocol ([AC-FR-S-D-1-6](#fr-s-d-1--audio-is-the-primary-feedback-channel)) |
| G-S-4 | Get standalone runs into the hub for free | A standalone run appears in the Wave 3 run list, detail and statistics screens with no new persistence code ([ADR-S-01](./design.md#adr-s-01)) |
| G-S-5 | Be honest about what has actually been validated | Every accuracy figure in [§9.3](#93-accuracy) is traceable either to a cited publication or to a committed fixture recorded on real hardware — and the document states which |

### 1.3 Non-goals for this track's v1

Recorded so they are not silently re-scoped later:

- **Pocket, armband, waistband, hydration-vest or backpack carry.** Explicitly out of scope. See
  [CON-S-3](#con-s-3), which also states what it would take to add them.
- **Treadmill / indoor standalone running.** Out of scope, and for a specific reason:
  the calibration architecture ([FR-S-C-2](#fr-s-c-2--online-calibration-against-gnss)) has no
  reference signal indoors, so an indoor standalone run would be running an uncalibrated model with
  nothing to check it against. See [CON-S-8](#con-s-8).
- **Replacing the watch tiers.** A paired watch remains the better sensor and stays the recommended
  configuration. This track is for runners who do not have one, or have left it at home.
- **Heart rate.** A phone alone has no heart-rate sensor. Standalone runs record no HR and every
  surface that shows HR must degrade cleanly ([DEG-S-4](#8-degraded-modes-standalone)). Bluetooth
  chest straps are a plausible follow-on and are not in this pass.
- **Running-form metrics** (ground contact time, vertical oscillation). The signal to compute some
  of these is arguably present in the hand-held trace, but publishing a form metric derived from a
  swinging hand would be inventing precision. Out of scope for the same reason the core track
  excludes them.
- **A separate "standalone" app binary.** See [ADR-S-01](./design.md#adr-s-01) — this is a
  capability the existing iPhone app gains.

---

## 2. Personas

Additions to `../requirements.md` §2. The core personas are unchanged.

**P5 — "Watchless Wren" (primary for this track).** Runs 15–30 mpw. Owns an iPhone and no
smartwatch, and is not going to buy one for this. Already runs with the phone in her hand — that is
simply how she carries it — and has been using the stock Fitness app, which tells her pace but not
whether it is the right pace. She is exactly the persona the core product's value proposition was
written for and the core product's hardware assumption excluded.

**P6 — "Left-It-Home Leo" (secondary).** Owns a watch and uses the full product most days. Once a
week he forgets to charge it, or does not want to wear it, and wants the run to still count and to
still be paced. His requirement is not "the standalone experience is as good as the watch" — it is
"the run lands in the same history, correctly labelled as a lower-confidence recording"
([FR-S-E-2](#fr-s-e-2--provenance-is-visible-not-hidden)).

---

## 3. Glossary

Additions to `../requirements.md` §3. The core glossary — Target Pace, Pace Band, Pace Zone,
Rolling Pace, Progress, Grade Adjustment, Step (workout phase), Settling Window — is unchanged and
means the same thing here.

One collision is worth stating explicitly, because it is the sort of thing that produces a bug six
months later:

> **`Step` already means "one phase of a structured workout"** in the core glossary
> (warmup / work / recovery / cooldown). In this track, gait terminology needs the word too. The
> resolution is that **the gait sense is always qualified**: `StepEvent`, `stepLength`, `stepRate`,
> `stepFrequency`, `cadence`. The unqualified `Step` / `WorkoutStep` / `ResolvedStep` types keep
> their core meaning everywhere. No type in `PhoneMotion` is called `Step`.

| Term | Meaning |
|---|---|
| **Carry position** | Where on the body the phone is during the run. This track supports exactly one: **hand-held** (see [CON-S-3](#con-s-3)). |
| **Step event** | One foot strike. Two per gait cycle. |
| **Stride** | One full gait cycle — two step events, one per foot. |
| **Cadence** | Step events per minute (spm). Recreational running cadence is typically 150–192 spm; detectors here accommodate 120–240 spm ([§13](#13-references)). |
| **Step frequency** | Cadence expressed in Hz. 180 spm = 3.0 Hz. |
| **Stride frequency** | Half the step frequency. 180 spm = 1.5 Hz. **This is the frequency the arm swings at**, which is the central complication of this track ([FR-S-B-2](#fr-s-b-2--cadence-estimation)). |
| **Step length** | Ground distance covered by one step event. |
| **Gravity-aligned vertical acceleration** | The component of user acceleration projected onto the current gravity direction. Orientation-invariant by construction, which is what makes it usable from a device whose attitude changes continuously. |
| **Motion-derived distance** | Distance computed as `Σ stepLength(i)` over detected step events. |
| **GNSS** | Global navigation satellite system. Used in preference to "GPS" where the distinction from *the constellation* matters; `GPS` is retained in user-facing text and in core-track requirement names. |
| **Measured distance** | Distance derived from position fixes — the runner's displacement was observed. |
| **Estimated distance** | Distance derived from a motion model — the runner's displacement was inferred. The distinction is a first-class part of the sensor contract ([FR-S-A-3](#fr-s-a-3--the-capability-contract-states-how-distance-is-obtained)). |
| **Calibration gain** | The per-runner scalar (later, per-cadence-band vector) that scales the literature-shaped step-length model onto this runner's actual stride ([FR-S-C-2](#fr-s-c-2--online-calibration-against-gnss)). |
| **Motion trace** | A recorded file of raw motion samples plus whatever reference data was captured alongside. This track's equivalent of the core track's seven engine fixtures. |

---

## 4. Platform support

### 4.1 Tier matrix

This track adds a third **sensing tier**, alongside Modern and Legacy. It is not a third app.

| Tier | Device | OS | Codebase | Sensing |
|---|---|---|---|---|
| Modern | Apple Watch S4+ | watchOS 10+ | `Apps/WatchModern` | Watch sensors, phone as hub |
| Legacy | Apple Watch S3 | watchOS 8 | `Apps/WatchLegacy` | Watch sensors, phone as hub |
| **PhoneStandalone** | **iPhone, hand-held** | **iOS 17+** | **`Apps/iPhone` (same target)** | **Phone GNSS + phone IMU** |

The deployment floor stays at **iOS 17.0**, matching the existing app (`../requirements.md` §4.1).
Raising it was considered and rejected — see [CON-S-2](#con-s-2), which is where the most
consequential platform finding in this document lives.

### 4.2 Sensor availability, PhoneStandalone

| Capability | Available | Notes |
|---|---|---|
| GNSS | Yes | `CLLocationManager`, `.fitness` activity type, background updates |
| Accelerometer / gyroscope | Yes | `CMMotionManager` device motion, up to 100 Hz |
| Barometric altimeter | Yes | `CMAltimeter`, iPhone 6 and later — so grade adjustment ([FR-A-4](../requirements.md#fr-a-4--grade-adjustment)) is in scope |
| Step counting | Yes, two ways | `CMPedometer` (Apple's model) *and* this track's own model. Both are used, differently — [FR-S-C-1](#fr-s-c-1--distance-fusion) |
| Optical heart rate | **No** | No sensor exists. [DEG-S-4](#8-degraded-modes-standalone) |
| Local `HKWorkoutSession` | **iOS 26.0+ only** | Not iOS 17. [CON-S-2](#con-s-2) |
| `HKWorkoutBuilder` (write a workout) | Yes, iOS 12+ | This is the path used at the iOS 17 floor |
| Haptics | Yes | `UIFeedbackGenerator` / Core Haptics |
| Spoken audio | Yes | `AVSpeechSynthesizer` over a ducking audio session |

---

## 5. Constraints and accepted deviations

Same discipline as `../requirements.md` §5: each records the constraint, what was decided, and why.
Several of these are findings that contradict a reasonable prior assumption, and those are marked.

<a id="con-s-1"></a>
### CON-S-1 — The iOS Simulator has no accelerometer or gyroscope

**Constraint.** The Simulator provides no motion sensor data. There is no motion analogue of the
GPX-route location simulation that Xcode offers for `CLLocationManager`. `CMMotionManager`'s
availability properties report false in the Simulator, and no amount of scheme configuration changes
that. This is verified empirically in this track rather than assumed — see
[S-004](./implementation.md#s-004).

**Consequence, which is larger than it first looks.** This is a harder constraint than anything
Wave 4 hit with Series 3 hardware. Series 3 at least had a *device*; here the entire estimation
layer has no runtime environment in CI at all. It means:

- Every line of estimation logic must live somewhere that can be tested **without any sensor**,
  which is what forces [ADR-S-03](./design.md#adr-s-03)'s pure `PhoneMotion` package.
- Ground truth cannot be manufactured. It has to be recorded.
- Building the recording tool is therefore a *prerequisite*, not a convenience — it occupies the
  same position in this track that the seven recorded traces occupy in the core track's Wave 1.

**Decision.** The estimation layer is a pure package validated against committed motion traces
([FR-S-F-2](#fr-s-f-2--motion-trace-fixtures)); a raw-capture tool that records those traces on
device is built first ([FR-S-F-1](#fr-s-f-1--on-device-raw-motion-capture)); and synthetic signals
are used **only** for property tests over labelled inputs, never as validation of accuracy
([CON-S-7](#con-s-7)).

<a id="con-s-2"></a>
### CON-S-2 — A local `HKWorkoutSession` on iPhone is iOS 26, not iOS 17

**This contradicts the working assumption for this track and changes the design.**

**Constraint.** iOS 17 did introduce `HKWorkoutSession` *to the iPhone SDK*, but only as the
receiving end of a session mirrored from a paired Apple Watch. Verified against the iOS 26.5 SDK
headers shipped with the Xcode 26.6 installed on this machine, rather than from memory:

| Symbol | Availability | What it means |
|---|---|---|
| `HKWorkoutSession` (class) | `ios(17.0), watchos(2.0)` | The type exists on iPhone from iOS 17 |
| `HKHealthStore.workoutSessionMirroringStartHandler` | `ios(17.0)` | …and this is how iOS 17 gets one: **the watch mirrors it** |
| `HKWorkoutSessionType` `.primary` / `.mirrored` | `ios(17.0), watchos(10.0)` | The type distinction is from the same release |
| `HKWorkoutSession.init(healthStore:configuration:)` | **`ios(26.0)`**, `watchos(5.0)` | The only initializer that creates a *local* session |
| `HKWorkoutSession.associatedWorkoutBuilder()` | **`ios(26.0)`**, `watchos(5.0)` | |
| `HKLiveWorkoutBuilder` (class) | **`ios(26.0)`**, `watchos(5.0)` | |
| `HKWorkoutBuilder` (class) | `ios(12.0)`, `watchos(5.0)` | The non-live builder, available at our floor |

So on iOS 17 through 18 an iPhone app **cannot start its own workout session**. Apple's own framing
matches: iOS 26 is described as bringing `HKWorkoutSession` and `HKLiveWorkoutBuilder` to iPhone,
enabling iPhone-only fitness apps for users without a watch ([§13](#13-references)).

**Why it matters beyond an API name.** A live session is not decoration — on watchOS it is what
keeps sensors running while the app is backgrounded and what makes background haptics legal
(`../design.md` §7). At the iOS 17 floor none of that comes from HealthKit. Background execution
during a standalone run has to be earned another way: the `location` background mode with
`allowsBackgroundLocationUpdates`, plus the `audio` background mode for spoken cues
([FR-S-A-2](#fr-s-a-2--the-run-stays-alive-in-the-background)).

**Decision.** Target the **`HKWorkoutBuilder` path at the iOS 17 floor**, which is available and
sufficient to write a correct `HKWorkout` with route and distance. Do *not* raise the deployment
target to iOS 26 for this track — it would cut off the majority of in-service iPhones to buy an API
whose only unique contribution here is convenience, and it would fork the phone app's floor away
from the hub it shares a binary with. The capability contract
([FR-S-A-3](#fr-s-a-3--the-capability-contract-states-how-distance-is-obtained)) carries a field for
the session capability, so an iOS 26 path can be added later as a strictly better backend behind the
same seam without re-specifying anything.

<a id="con-s-3"></a>
### CON-S-3 — Hand-held is the only supported carry position for v1

**Constraint.** Carry position changes the signal fundamentally, not incrementally. A pocketed phone
is quasi-rigidly coupled to the pelvis and sees a signal dominated by vertical centre-of-mass
oscillation at step frequency. An armband sees the same arm swing as the hand but with fixed
orientation relative to the limb. A hand-held phone sees arm swing at **stride** frequency — half
the step frequency — with a grip-dependent, continuously changing orientation, plus footfall
transients transmitted up the body. A step detector tuned for one is wrong for the others, and a
step-length model fitted on one does not transfer.

**Decision.** v1 supports hand-held only, and says so in the product rather than silently degrading.
Generalising across carry positions on the first pass would mean either a motion-mode classifier
(more machinery than the core estimator, and untestable without traces for each mode) or a model
that is mediocre everywhere. The estimation package is nonetheless structured so that carry position
is an explicit input parameter with exactly one implemented case, so adding a second is adding a
case rather than rewriting a pipeline ([ADR-S-04](./design.md#adr-s-04)).

**What it would take to add pocket/armband later**, recorded now so it is a scoped task and not a
research project: recorded traces per position per runner; a per-position coefficient set; and
either a user-declared position or a classifier validated against those traces. Roughly the shape of
[FR-S-B](#epic-s-b--motion-derived-gait-estimation-p0) again, per position.

<a id="con-s-4"></a>
### CON-S-4 — Continuous motion sampling requires the app to stay alive, and iOS does not grant that for free

**Constraint.** `CMMotionManager` updates stop when the app is suspended. iOS suspends
backgrounded apps unless a background mode keeps them running. There is no `workout-processing`
background mode on iOS — that is watchOS only — and at the iOS 17 floor there is no live workout
session to hold the process up ([CON-S-2](#con-s-2)).

**Decision.** A standalone run declares `UIBackgroundModes` of `location` and `audio`, starts
`CLLocationManager` with `allowsBackgroundLocationUpdates = true` and
`pausesLocationUpdatesAutomatically = false`, and keeps the audio session active for cue playback.
The combination is what keeps the process scheduled with the screen locked. This is the standard
mechanism every iPhone running app uses, and it is stated here because omitting either mode produces
a run that silently stops recording in the runner's pocket-free hand the moment the screen sleeps —
a failure with no error message.

**Consequence for the privacy posture.** The app gains a `location`-always-adjacent permission
prompt it did not previously need. NFR-14/15/16 are unchanged and still hold — nothing leaves the
device — but the prompt is new for hub-only users, so it is requested lazily at first standalone
run, never at launch ([AC-FR-S-A-1-2](#fr-s-a-1--starting-a-standalone-run)).

<a id="con-s-5"></a>
### CON-S-5 — No published step-length model is validated for a hand-held phone at running speeds

**Constraint.** The literature splits cleanly, and the gap is exactly where this track sits:

- **Hand-held phone, walking.** Well covered. Renaudin, Susi & Lachapelle (2012) is the reference
  work, explicitly handling texting and swinging carry modes, reporting 2.5–5% of travelled distance
  for per-subject-calibrated models and 4–9% for a universal one.
- **Running, non-hand-held sensor.** Well covered. Falbriard et al. (2021) estimate running speed
  from shoe-worn IMUs at 5–20 km/h and are explicit that walking step-length methods "cannot be
  directly applied to running because of the aerial phases, where accelerometers are erroneous."
- **Hand-held phone, running.** Not covered by anything reputable that this search surfaced. The
  material that exists is consumer-grade and mostly about step *counting*, not distance.

**Decision.** Build the model as a *documented composition of published components* — a frequency
term from Renaudin's form, an amplitude term of Weinberg's form, a calibration gain in the spirit of
Apple's own arm-swing-and-stride model — and treat the composition itself as **an untested
hypothesis until this track's own recorded traces test it**. The design document states the model,
its provenance term by term, and the specific reasons each published component needs adapting for
running ([design.md §5](./design.md#5-the-step-length-model)). Accuracy requirements in
[§9.3](#93-accuracy) are stated as targets with their evidential basis named, and the traceability
section marks which are validated and which are not yet.

<a id="con-s-6"></a>
### CON-S-6 — A swinging phone cannot be the primary display, and looking at it degrades the sensor

**Constraint.** Two independent problems, one of which is specific to this design in an interesting
way:

1. **Safety and usability.** Reading a screen held in a swinging hand at running pace means arresting
   the swing, raising and stabilising the arm, and taking the eyes off the road. The core product's
   250 ms wrist-glance budget does not apply.
2. **The act of looking breaks the measurement.** The pace being displayed is derived from arm
   swing. A runner who stops swinging their arm to read the screen removes the very signal the
   number came from. The display and the sensor are in direct conflict in a way they are not on a
   wrist.

**Decision.** The primary feedback channel is **audio**, the secondary is **haptic**, and screen
colour is **tertiary** — retained in full, unchanged, for deliberate glances, stops, and the
armband case if it is ever supported. This is decided in
[FR-S-D-1](#fr-s-d-1--audio-is-the-primary-feedback-channel) with acceptance criteria, not inherited
from [FR-J-1](../requirements.md#fr-j-1--colour-is-never-the-only-channel).
[FR-J-1](../requirements.md#fr-j-1--colour-is-never-the-only-channel)'s substance — that colour is
never the *only* channel — is preserved and in fact strengthened: here colour is never even the
*primary* one.

<a id="con-s-7"></a>
### CON-S-7 — In the field, GNSS is the only available reference, and it is not exact

**Constraint.** Validating motion-derived distance needs a truth. The available truths, in
descending order of quality, are: a surveyed course (a 400 m track); a GNSS trace from a
well-sited device; and nothing. Published smartphone-app distance error on a 400 m track is around
2.85% MAPE, and sport watches range from 0.8% to 12.1% on the same kind of course, with systematic
underestimation in urban and forest terrain ([§13](#13-references)).

**Decision.** Three rules follow, and all three are enforced rather than merely intended:

1. **No accuracy claim is ever tighter than its reference.** [NFR-S-3](#93-accuracy) onwards state
   the reference used alongside the bound.
2. **Synthetic accelerometer-like signals are never used to validate accuracy.** They are used for
   property tests, where the labelled input *is* the truth by construction, and the property being
   asserted is a structural one (no double-counting, no missed steps beyond a bound). A synthetic
   sine wave asserting "distance error < 5%" would be measuring the generator, not the estimator.
   This is enforced by [FR-S-F-3](#fr-s-f-3--synthetic-signals-are-labelled-and-quarantined).
3. **A track lap beats a GPS trace where one is obtainable**, so the recording protocol asks for one
   when convenient and states plainly what is lost when it is not.

<a id="con-s-8"></a>
### CON-S-8 — Indoor standalone running has no reference at all, so it is out of scope for v1

**Constraint.** The whole architecture rests on GNSS being present *often enough* to calibrate the
motion model ([FR-S-C-2](#fr-s-c-2--online-calibration-against-gnss)). On a treadmill there is no
GNSS ever. An indoor standalone run would therefore be an uncalibrated model reporting a number with
nothing able to check it — and treadmill belt speed differs from overground gait mechanics anyway,
so a gain calibrated outdoors is not obviously the right gain indoors.

**Decision.** Indoor standalone is out of scope for v1. The app refuses cleanly rather than
producing a number it cannot stand behind: an indoor standalone run is offered as *timed only*, with
distance and pace suppressed and said to be suppressed
([DEG-S-6](#8-degraded-modes-standalone)). `CMPedometer`'s own distance is deliberately **not**
substituted here — it is a black box tuned for walking whose running behaviour we cannot
characterise, and quietly swapping it in would produce exactly the unverifiable number this
constraint exists to avoid.

---

## 6. Scope by release

| Release | Contents |
|---|---|
| **M-S1 — Ground truth (P0)** | On-device raw motion capture tool; export path; the recording protocol; the motion-trace fixture format. Nothing downstream is honest without this. |
| **M-S2 — Estimation engine (P0)** | `PhoneMotion`: orientation handling, cadence estimation, step detection, the step-length model, distance fusion and calibration. Property-tested; fixture-validated as traces arrive. |
| **M-S3 — Standalone capture (P0)** | The `RunSensorFeed` conformer, sensor plumbing, `HKWorkoutBuilder` write, durability, standalone runs landing in the hub. |
| **M-S4 — Feedback (P0)** | Audio cue engine, haptic patterns, the live-run screen. |
| **M-S5 — Hardening (P0)** | Degraded modes, battery, the standalone manual protocol, accuracy validation against recorded traces. |

---

## 7. Functional requirements

### EPIC S-A — Standalone run lifecycle on iPhone (P0)

> **User story.** As Watchless Wren, I want to start a tempo run from my phone, put my headphones
> in, and be told how I am doing — without owning a watch and without staring at a screen.

<a id="fr-s-a-1--starting-a-standalone-run"></a>
#### FR-S-A-1 — Starting a standalone run

| AC | Criterion |
|---|---|
| AC-FR-S-A-1-1 | THE SYSTEM SHALL offer, in the existing iPhone app, a way to start a run on the phone alone, using the same five run types as the watch ([AC-FR-A-7-1](../requirements.md#fr-a-7--run-type-selection)) and the same stored profile. |
| AC-FR-S-A-1-2 | THE SYSTEM SHALL request location and motion authorization at the point of first starting a standalone run, and SHALL NOT request either at app launch or on any hub-only path. |
| AC-FR-S-A-1-3 | WHEN starting a standalone run, THE SYSTEM SHALL state the supported carry position — hand-held — and SHALL record the declared carry position in the run record ([CON-S-3](#con-s-3)). |
| AC-FR-S-A-1-4 | WHEN location authorization is denied, THE SYSTEM SHALL still permit the run, SHALL run on motion-derived distance alone, and SHALL state that accuracy is reduced and that no route will be recorded. |
| AC-FR-S-A-1-5 | WHEN motion authorization is denied, THE SYSTEM SHALL still permit the run on GNSS alone, and SHALL state that pace will be unavailable during GPS outages. |
| AC-FR-S-A-1-6 | WHEN both are denied, THE SYSTEM SHALL refuse to start a paced run with a specific message naming what is needed and why, rather than starting a run that cannot measure anything. |
| AC-FR-S-A-1-7 | THE SYSTEM SHALL start a standalone run in ≤ 3 taps from app launch for the default run type. |

<a id="fr-s-a-2--the-run-stays-alive-in-the-background"></a>
#### FR-S-A-2 — The run stays alive in the background

| AC | Criterion |
|---|---|
| AC-FR-S-A-2-1 | WHILE a standalone run is active, THE SYSTEM SHALL continue to receive location and motion updates with the app backgrounded and the screen locked ([CON-S-4](#con-s-4)). *Hardware-verified — see [§12.2](#122-what-is-hardware-verification-only).* |
| AC-FR-S-A-2-2 | THE SYSTEM SHALL declare `UIBackgroundModes` containing `location` and `audio`, and SHALL set `allowsBackgroundLocationUpdates` and clear `pausesLocationUpdatesAutomatically` for the duration of the run only. |
| AC-FR-S-A-2-3 | WHEN a run ends, THE SYSTEM SHALL clear background location, stop motion updates, and deactivate the audio session, holding no wake source afterwards — the standalone analogue of [NFR-8](../requirements.md#92-battery), asserted by the same style of teardown test. |
| AC-FR-S-A-2-4 | WHEN the app is terminated mid-run, THE SYSTEM SHALL recover the partial run on next launch under the same rules as [FR-D-6](../requirements.md#fr-d-6--crash-and-interruption-durability), losing no more than 30 s. |

<a id="fr-s-a-3--the-capability-contract-states-how-distance-is-obtained"></a>
#### FR-S-A-3 — The capability contract states how distance is obtained

The existing `SensorCapabilities` (`../design.md` §8) has no way to express either of the two facts
this tier needs. Extending it is a design decision in its own right — see
[ADR-S-02](./design.md#adr-s-02) — not a matter of appending booleans.

| AC | Criterion |
|---|---|
| AC-FR-S-A-3-1 | THE SYSTEM SHALL express, in `SensorCapabilities`, whether a tier's distance is **measured** from position fixes, **estimated** from a motion model, or measured with an estimated fallback. |
| AC-FR-S-A-3-2 | THE SYSTEM SHALL express, in `SensorCapabilities`, which workout-session facility the tier has: a local `HKWorkoutSession`, a non-live `HKWorkoutBuilder` only, or neither ([CON-S-2](#con-s-2)). |
| AC-FR-S-A-3-3 | THE SYSTEM SHALL carry, on every emitted sample, which source produced that tick's distance, distinguishing motion-model distance from `CMPedometer` distance and from position-derived distance. |
| AC-FR-S-A-3-4 | THE SYSTEM SHALL preserve the existing watch tiers' behaviour byte-for-byte under this extension, proved by the existing tier-equivalence goldens continuing to pass unmodified ([AC-FR-K-1-2](../requirements.md#fr-k-1--parity)). |
| AC-FR-S-A-3-5 | WHEN a `SensorCapabilities` value is decoded from a payload written before this extension, THE SYSTEM SHALL decode successfully with documented defaults rather than failing. |

<a id="fr-s-a-4--writing-the-workout"></a>
#### FR-S-A-4 — Writing the workout to HealthKit

| AC | Criterion |
|---|---|
| AC-FR-S-A-4-1 | WHEN a standalone run ends, THE SYSTEM SHALL save an `HKWorkout` of activity type running with distance, energy, and — where location was available — a workout route, using `HKWorkoutBuilder` ([CON-S-2](#con-s-2)). |
| AC-FR-S-A-4-2 | THE SYSTEM SHALL record step boundaries for structured workouts, so an interval session done standalone is as legible in Health as one done on the watch. |
| AC-FR-S-A-4-3 | THE SYSTEM SHALL NOT write a heart-rate sample it does not have, and SHALL NOT synthesise one from pace. |
| AC-FR-S-A-4-4 | WHEN HealthKit write authorization is declined, THE SYSTEM SHALL still record the run locally and state clearly that Health is not being written, matching [AC-FR-D-1-7](../requirements.md#fr-d-1--session-management). |
| AC-FR-S-A-4-5 | THE SYSTEM SHALL record, in the run's own sidecar, the distance provenance breakdown — how many metres were measured and how many estimated ([FR-S-E-2](#fr-s-e-2--provenance-is-visible-not-hidden)). |

---

### EPIC S-B — Motion-derived gait estimation (P0)

> **User story.** As Watchless Wren, I want the phone in my hand to know how fast I am actually
> running — including in the underpass where GPS drops — so the colour and the voice mean something
> the whole way round.

This epic is the hard problem. Its requirements are deliberately stated in terms of *observable
outputs* — cadence, step events, step length, distance — and not in terms of a particular algorithm;
the algorithm is [design.md §3–§6](./design.md#3-the-signal-and-what-is-in-it) and is expected to be
revised as real traces arrive.

<a id="fr-s-b-1--motion-sampling"></a>
#### FR-S-B-1 — Motion sampling

| AC | Criterion |
|---|---|
| AC-FR-S-B-1-1 | THE SYSTEM SHALL sample device motion at 100 Hz *(tunable, 50–100 Hz)* during an active standalone run — adequate to capture footfall impact peaks, which the literature places within a 100 Hz sampling budget ([§13](#13-references)). |
| AC-FR-S-B-1-2 | THE SYSTEM SHALL supply, per sample, user acceleration with gravity removed, the gravity vector, and rotation rate, in the device frame. |
| AC-FR-S-B-1-3 | THE SYSTEM SHALL be robust to dropped and irregularly-spaced samples, and SHALL derive all timing from sample timestamps rather than from an assumed rate. |
| AC-FR-S-B-1-4 | WHEN sample delivery falls below 60% of the configured rate over a 10 s window, THE SYSTEM SHALL record a degradation flag rather than silently producing a low-confidence cadence ([DEG-S-3](#8-degraded-modes-standalone)). |
| AC-FR-S-B-1-5 | THE SYSTEM SHALL keep motion processing off the main thread and SHALL NOT retain raw motion samples beyond the analysis window during a normal run. |

<a id="fr-s-b-2--cadence-estimation"></a>
#### FR-S-B-2 — Cadence estimation

The central difficulty: a hand-held phone's dominant periodicity is the **arm swing**, which is at
**stride** frequency — half the cadence. A naive frequency estimator returns half the true cadence,
and a naive step counter therefore halves the distance.

| AC | Criterion |
|---|---|
| AC-FR-S-B-2-1 | THE SYSTEM SHALL estimate cadence over a sliding window of 5.12 s *(tunable, 2.5–8 s)*, updated at least once per second. |
| AC-FR-S-B-2-2 | THE SYSTEM SHALL resolve the stride-versus-step frequency ambiguity explicitly, and SHALL NOT rely on a fixed frequency threshold — the published walking threshold of 1.4 Hz falls inside the running stride-frequency range and would misclassify running as a matter of course ([§13](#13-references), [design.md §4.3](./design.md#43-resolving-the-stride-versus-step-ambiguity)). |
| AC-FR-S-B-2-3 | THE SYSTEM SHALL constrain reported cadence to a physiologically plausible 120–240 spm *(tunable)* and SHALL report *no* cadence rather than an out-of-range one. |
| AC-FR-S-B-2-4 | THE SYSTEM SHALL report a confidence value alongside cadence, and SHALL make that confidence available to the fusion layer ([FR-S-C-1](#fr-s-c-1--distance-fusion)). |
| AC-FR-S-B-2-5 | GIVEN a labelled synthetic signal at a known step frequency between 140 and 200 spm, with a stride-frequency arm-swing component of equal or greater amplitude, THE SYSTEM SHALL report the step frequency and not the stride frequency, for every case in the range. |
| AC-FR-S-B-2-6 | GIVEN a recorded hand-held running trace, THE SYSTEM SHALL report cadence within [NFR-S-1](#93-accuracy)'s bound of the reference cadence for that trace. |
| AC-FR-S-B-2-7 | THE SYSTEM SHALL produce identical cadence output for identical input, with no dependence on wall-clock time or randomness, matching [AC-FR-A-1-6](../requirements.md#fr-a-1--rolling-pace-estimation)'s determinism guarantee. |

<a id="fr-s-b-3--step-event-detection"></a>
#### FR-S-B-3 — Step event detection

| AC | Criterion |
|---|---|
| AC-FR-S-B-3-1 | THE SYSTEM SHALL emit a step event per detected foot strike, with a timestamp. |
| AC-FR-S-B-3-2 | THE SYSTEM SHALL enforce a refractory interval derived from the current cadence estimate, so that two events cannot be emitted closer together than is physiologically possible at that cadence. |
| AC-FR-S-B-3-3 | THE SYSTEM SHALL operate on a signal that is invariant to the phone's orientation in the hand, so that a phone rotated 180° or held screen-in produces the same step count. |
| AC-FR-S-B-3-4 | GIVEN a labelled synthetic signal containing exactly *n* steps at any cadence in 120–240 spm, THE SYSTEM SHALL detect between *n*−1 and *n*+1 events, and SHALL NOT double-count. |
| AC-FR-S-B-3-5 | GIVEN a labelled synthetic signal with an inserted 20 s stationary period, THE SYSTEM SHALL emit no step events during that period. |
| AC-FR-S-B-3-6 | GIVEN a recorded hand-held running trace with a reference step count, THE SYSTEM SHALL count within [NFR-S-2](#93-accuracy)'s bound. |

<a id="fr-s-b-4--step-length-estimation"></a>
#### FR-S-B-4 — Step length estimation

| AC | Criterion |
|---|---|
| AC-FR-S-B-4-1 | THE SYSTEM SHALL estimate a step length per step event from the runner's height, the current step frequency, and the acceleration amplitude over that step. |
| AC-FR-S-B-4-2 | THE SYSTEM SHALL use a model whose every term is attributable to published work, with the attribution recorded at the point of definition ([design.md §5](./design.md#5-the-step-length-model)). |
| AC-FR-S-B-4-3 | THE SYSTEM SHALL include an acceleration-amplitude term, and SHALL NOT be a function of cadence alone — at running speeds cadence carries only a small fraction of the speed variation, so a cadence-only model is structurally incapable of tracking pace changes ([design.md §5.1](./design.md#51-why-a-cadence-only-model-cannot-work-for-running)). |
| AC-FR-S-B-4-4 | THE SYSTEM SHALL clamp estimated step length to [0.5 m, 2.5 m] *(tunable)* and SHALL flag rather than silently clamp when the raw estimate falls outside. |
| AC-FR-S-B-4-5 | THE SYSTEM SHALL be monotonically non-decreasing in acceleration amplitude, holding cadence and height fixed — asserted as a property over generated inputs. |
| AC-FR-S-B-4-6 | WHEN the runner's height is unknown, THE SYSTEM SHALL use a documented default and SHALL mark the run's distance as lower-confidence until calibration has converged. |
| AC-FR-S-B-4-7 | THE SYSTEM SHALL produce a step length for every detected step event, with no gaps, so motion-derived distance is a simple sum. |

---

### EPIC S-C — Distance fusion and calibration (P0)

> **User story.** As Left-It-Home Leo, I want the mile splits from a phone-only run to be close
> enough to my watch's that I can compare them — and I want to know when they were not.

<a id="fr-s-c-1--distance-fusion"></a>
#### FR-S-C-1 — Distance fusion

The core track already fuses distance sources in priority order (`../design.md` §8.2: HealthKit,
then CoreLocation, then `CMPedometer`). This tier needs the same shape with a real step-length model
behind the motion leg instead of `CMPedometer`'s opaque one.

| AC | Criterion |
|---|---|
| AC-FR-S-C-1-1 | THE SYSTEM SHALL emit one monotonically non-decreasing cumulative distance, and SHALL NOT expose which source produced it to the pace engine — matching the core contract exactly (`../design.md` §8.2). |
| AC-FR-S-C-1-2 | THE SYSTEM SHALL prefer GNSS-derived distance whenever position fixes meet the accuracy threshold of [AC-FR-A-1-2](../requirements.md#fr-a-1--rolling-pace-estimation). |
| AC-FR-S-C-1-3 | WHEN GNSS is unavailable or degraded, THE SYSTEM SHALL substitute motion-derived distance, and SHALL mark the affected samples as estimated. |
| AC-FR-S-C-1-4 | THE SYSTEM SHALL accumulate *deltas* rather than absolute positions, so that a handover between sources never produces a step change in cumulative distance. A source switch SHALL NOT move cumulative distance by more than 5 m *(fixed correctness bound, not a tunable — the same reasoning as `DistanceFusion.maxSwitchJumpMetres` in `../design.md` §4)*. |
| AC-FR-S-C-1-5 | THE SYSTEM SHALL record, per sample, whether that tick's distance was measured or estimated, and SHALL total both at the end of the run. |
| AC-FR-S-C-1-6 | WHEN motion-derived and GNSS-derived distance disagree by more than 15% *(tunable)* over a 200 m window while both are nominally available, THE SYSTEM SHALL record a disagreement flag, SHALL continue to prefer GNSS, and SHALL suspend calibration updates for that window ([FR-S-C-2](#fr-s-c-2--online-calibration-against-gnss)). |
| AC-FR-S-C-1-7 | THE SYSTEM SHALL NOT let a single bad GNSS window corrupt the calibration state, and SHALL be shown not to by a fixture containing a deliberately corrupted GNSS segment. |

> **On AC-FR-S-C-1-6's "continue to prefer GNSS".** The disagreement check is deliberately a
> *detector*, not an override. GNSS on an open course is good to roughly 1–3%
> ([§13](#13-references)); an uncalibrated motion model is 4–9% at best and unvalidated for running
> ([CON-S-5](#con-s-5)). Letting the weaker estimator veto the stronger one because they disagree
> would be backwards. What the flag buys is that the *calibrator* stops learning from a window it
> cannot trust, which is where the damage would otherwise be permanent.

<a id="fr-s-c-2--online-calibration-against-gnss"></a>
#### FR-S-C-2 — Online calibration against GNSS

| AC | Criterion |
|---|---|
| AC-FR-S-C-2-1 | WHILE GNSS is good, THE SYSTEM SHALL compare motion-derived and GNSS-derived distance over closed windows and SHALL update a per-runner calibration gain from the comparison. |
| AC-FR-S-C-2-2 | THE SYSTEM SHALL persist the calibration state between runs, so a runner's second run starts calibrated. |
| AC-FR-S-C-2-3 | THE SYSTEM SHALL bound the calibration gain to [0.6, 1.6] *(tunable)* and SHALL treat a fit outside that range as evidence of a bad window, not of an unusual runner. |
| AC-FR-S-C-2-4 | THE SYSTEM SHALL bound the per-window change in the gain, so that no single window can move the model far, and SHALL converge within 10 minutes *(tunable)* of good GNSS running. |
| AC-FR-S-C-2-5 | THE SYSTEM SHALL maintain the gain per cadence band *(at least three bands)* once enough evidence exists in a band, and SHALL fall back to the global gain in bands without evidence — this is what makes the model track a runner across easy and interval paces rather than at one speed. |
| AC-FR-S-C-2-6 | THE SYSTEM SHALL expose calibration confidence, and the run record SHALL state whether the run was recorded with a converged calibration. |
| AC-FR-S-C-2-7 | THE SYSTEM SHALL never update calibration from a window flagged under [AC-FR-S-C-1-6](#fr-s-c-1--distance-fusion), from a window shorter than 100 m, or from one where cadence confidence was low. |
| AC-FR-S-C-2-8 | THE SYSTEM SHALL let the runner reset calibration, and SHALL state what that does. |

<a id="fr-s-c-3--pace-from-motion"></a>
#### FR-S-C-3 — Pace during a GNSS outage

| AC | Criterion |
|---|---|
| AC-FR-S-C-3-1 | WHILE GNSS is unavailable, THE SYSTEM SHALL continue to produce Rolling Pace from motion-derived distance, through the unmodified core estimator ([FR-A-1](../requirements.md#fr-a-1--rolling-pace-estimation)) — the fusion layer substitutes the distance, and `Core` is unchanged. |
| AC-FR-S-C-3-2 | WHILE distance is estimated, THE SYSTEM SHALL widen the pace band by 50% *(tunable)*, matching the core track's [DEG-1](../requirements.md#8-cross-cutting-degraded-modes) treatment of degraded GPS, so the app does not issue confident judgements on uncertain input. |
| AC-FR-S-C-3-3 | WHILE distance is estimated, THE SYSTEM SHALL indicate reduced accuracy on the run screen and SHALL say so once, audibly, at the transition — not repeatedly. |
| AC-FR-S-C-3-4 | WHEN GNSS returns, THE SYSTEM SHALL restore normal bands after the pace window has refilled, and SHALL NOT flap between wide and narrow bands more than once per 60 s *(tunable)*. |

---

### EPIC S-D — Feedback channels (P0)

> **User story.** As Watchless Wren, I want to be told "ease off, twelve seconds fast" in my
> headphones rather than having to look at anything at all.

<a id="fr-s-d-1--audio-is-the-primary-feedback-channel"></a>
#### FR-S-D-1 — Audio is the primary feedback channel

**This requirement deliberately re-decides, rather than inherits,
[FR-J-1](../requirements.md#fr-j-1--colour-is-never-the-only-channel)'s screen-colour-first
design.** The argument is in [CON-S-6](#con-s-6); the short form is that a hand-held display cannot
be glanced at safely at running pace, and that reading it destroys the arm-swing signal the reading
is derived from. What is preserved from FR-J-1 is its principle — no single channel carries meaning
alone — which here becomes: audio says it, haptics say it, and the screen says it, and any one of
them is sufficient.

| AC | Criterion |
|---|---|
| AC-FR-S-D-1-1 | THE SYSTEM SHALL deliver zone feedback primarily as spoken audio cues. |
| AC-FR-S-D-1-2 | WHEN the zone changes to a far zone and the dwell condition of [FR-B-1](../requirements.md#fr-b-1--haptic-alerts) is met, THE SYSTEM SHALL speak the direction and the signed pace delta — for example "ease off, twelve seconds fast" — using the runner's unit preference. |
| AC-FR-S-D-1-3 | THE SYSTEM SHALL reuse the core `AlertPolicy` dwell and cooldown machinery unchanged, so audio cues inherit its non-nagging guarantee (`../design.md` §7) rather than implementing a second, divergent policy. |
| AC-FR-S-D-1-4 | THE SYSTEM SHALL duck rather than stop other audio, SHALL resume it after the cue, and SHALL be audible when the ring/silent switch is set to silent. |
| AC-FR-S-D-1-5 | THE SYSTEM SHALL speak periodic progress summaries at a configurable interval — each mile or kilometre by default, off by default for elapsed-time announcements — containing split pace, average pace, and distance. |
| AC-FR-S-D-1-6 | THE SYSTEM SHALL permit a complete run — start, all interval transitions, all pace feedback, and end — to be conducted without the screen being looked at. *Hardware-verified: [§12.2](#122-what-is-hardware-verification-only).* |
| AC-FR-S-D-1-7 | THE SYSTEM SHALL allow the runner to disable spoken cues entirely, independently of haptics, and SHALL then leave haptics as the primary channel. |
| AC-FR-S-D-1-8 | THE SYSTEM SHALL NOT speak while the runner is inside the settling window ([FR-A-5](../requirements.md#fr-a-5--settling-window)), while paused, or during a VO2 max session's paced feedback — matching [AC-FR-B-1-4](../requirements.md#fr-b-1--haptic-alerts) exactly. |
| AC-FR-S-D-1-9 | THE SYSTEM SHALL construct every spoken string from localizable, non-concatenated components (NFR-23), and SHALL be intelligible when read by the system voice at running-appropriate rate. |

<a id="fr-s-d-2--haptics-are-the-secondary-channel"></a>
#### FR-S-D-2 — Haptics are the secondary channel

| AC | Criterion |
|---|---|
| AC-FR-S-D-2-1 | THE SYSTEM SHALL fire a haptic pattern for every event that produces a spoken cue, distinguishable by direction, matching [AC-FR-B-1-3](../requirements.md#fr-b-1--haptic-alerts)'s requirement for the watch. |
| AC-FR-S-D-2-2 | THE SYSTEM SHALL use a distinct haptic pattern for interval step transitions, and SHALL fire it even when spoken cues are disabled. |
| AC-FR-S-D-2-3 | THE SYSTEM SHALL deliver haptics with the screen locked and the app backgrounded during an active run. *Hardware-verified.* |
| AC-FR-S-D-2-4 | THE SYSTEM SHALL allow pace haptics to be disabled without disabling interval haptics, matching [AC-FR-B-1-7](../requirements.md#fr-b-1--haptic-alerts). |
| AC-FR-S-D-2-5 | THE SYSTEM SHALL degrade gracefully where the Taptic Engine is unavailable or Reduce Motion-adjacent settings suppress feedback, and SHALL NOT treat the absence of haptics as a failure to alert when audio succeeded. |

<a id="fr-s-d-3--the-screen-is-the-tertiary-channel"></a>
#### FR-S-D-3 — The screen is the tertiary channel

| AC | Criterion |
|---|---|
| AC-FR-S-D-3-1 | THE SYSTEM SHALL render a full-screen zone-coloured run view using the existing palettes (`../design.md` §11) with no new colour values. |
| AC-FR-S-D-3-2 | THE SYSTEM SHALL carry the same redundant encoding as the watch — direction glyph and signed delta ([FR-J-1](../requirements.md#fr-j-1--colour-is-never-the-only-channel)) — so the screen is fully self-sufficient when it *is* looked at. |
| AC-FR-S-D-3-3 | THE SYSTEM SHALL size the primary metric for legibility at arm's length in motion, larger than the watch layout's proportions, and SHALL keep the layout stable so glance targets do not move. |
| AC-FR-S-D-3-4 | THE SYSTEM SHALL NOT require any on-screen interaction during a run other than those the core track already permits: advancing an open-goal step, and the Controls actions. |
| AC-FR-S-D-3-5 | THE SYSTEM SHALL keep the screen awake while the run screen is foregrounded, and SHALL restore the system idle timer when it is not. |

---

### EPIC S-E — Standalone runs in the hub (P0)

<a id="fr-s-e-1--reuse-not-reimplementation"></a>
#### FR-S-E-1 — Reuse, not reimplementation

| AC | Criterion |
|---|---|
| AC-FR-S-E-1-1 | THE SYSTEM SHALL persist a standalone run through the existing `RunRecord` store and the existing ingest path, producing a record indistinguishable in structure from a watch-originated one ([ADR-S-01](./design.md#adr-s-01)). |
| AC-FR-S-E-1-2 | THE SYSTEM SHALL make standalone runs appear in the existing run list, run detail, and global statistics with no changes to those screens beyond the provenance surfacing of [FR-S-E-2](#fr-s-e-2--provenance-is-visible-not-hidden). |
| AC-FR-S-E-1-3 | THE SYSTEM SHALL include standalone runs in personal bests and aggregates on the same basis as watch runs. |
| AC-FR-S-E-1-4 | THE SYSTEM SHALL NOT create a second `runID` space, a second aggregate cache, or a second store. |
| AC-FR-S-E-1-5 | THE SYSTEM SHALL record `deviceTier` as a value distinguishing standalone from the two watch tiers, decoded safely by any existing consumer of the envelope. |

<a id="fr-s-e-2--provenance-is-visible-not-hidden"></a>
#### FR-S-E-2 — Provenance is visible, not hidden

| AC | Criterion |
|---|---|
| AC-FR-S-E-2-1 | THE SYSTEM SHALL show, on a standalone run's detail screen, what fraction of its distance was measured and what fraction estimated. |
| AC-FR-S-E-2-2 | THE SYSTEM SHALL show cadence as a first-class metric for standalone runs, since it is directly measured rather than derived. |
| AC-FR-S-E-2-3 | THE SYSTEM SHALL show `--` rather than a fabricated value for heart rate on standalone runs, in every surface including charts and statistics ([DEG-S-4](#8-degraded-modes-standalone)). |
| AC-FR-S-E-2-4 | THE SYSTEM SHALL indicate on a run recorded before calibration converged that its distance is lower-confidence, and SHALL say why. |
| AC-FR-S-E-2-5 | THE SYSTEM SHALL NOT retroactively rewrite a stored run's distance when calibration later improves — a recorded run is a record, not a prediction. |

---

### EPIC S-F — Capture and validation tooling (P0)

> This epic exists because of [CON-S-1](#con-s-1). It is scheduled *first*, before any estimation
> code, because nothing downstream can be honestly validated without it.

<a id="fr-s-f-1--on-device-raw-motion-capture"></a>
#### FR-S-F-1 — On-device raw motion capture

| AC | Criterion |
|---|---|
| AC-FR-S-F-1-1 | THE SYSTEM SHALL provide a developer-facing capture mode that records raw device motion at the configured rate to a file on device, for a session of at least 60 minutes. |
| AC-FR-S-F-1-2 | THE SYSTEM SHALL record, per sample: monotonic timestamp, user acceleration (x, y, z), gravity (x, y, z), rotation rate (x, y, z), and attitude. |
| AC-FR-S-F-1-3 | THE SYSTEM SHALL simultaneously record every location fix with its timestamp, coordinate, horizontal accuracy, altitude, and instantaneous speed, so a GNSS reference exists for the same clock. |
| AC-FR-S-F-1-4 | THE SYSTEM SHALL simultaneously record `CMPedometer` output, so Apple's own estimate is available as a comparison baseline rather than as a dependency. |
| AC-FR-S-F-1-5 | THE SYSTEM SHALL let the runner mark labelled events during capture — a lap boundary, a counted-steps segment, a start/stop — with one large touch target usable while running. |
| AC-FR-S-F-1-6 | THE SYSTEM SHALL flush to disk incrementally such that a crash or termination loses at most 30 s of capture. |
| AC-FR-S-F-1-7 | THE SYSTEM SHALL make captured files retrievable from the device without a debugger — via the Files app and the share sheet. |
| AC-FR-S-F-1-8 | THE SYSTEM SHALL record the device model, OS version, sample rate, and app version in the file header, so a trace is interpretable years later. |
| AC-FR-S-F-1-9 | THE SYSTEM SHALL keep the capture mode out of the shipping user experience — reachable deliberately, not discoverable accidentally. |

<a id="fr-s-f-2--motion-trace-fixtures"></a>
#### FR-S-F-2 — Motion trace fixtures

| AC | Criterion |
|---|---|
| AC-FR-S-F-2-1 | THE SYSTEM SHALL define a committed on-disk format for motion traces, versioned, decodable by the pure estimation package with no Apple framework dependency. |
| AC-FR-S-F-2-2 | THE SYSTEM SHALL support replaying a trace through the full estimation pipeline offline and printing cadence, step count, step lengths, and fused distance. |
| AC-FR-S-F-2-3 | THE SYSTEM SHALL support golden files for motion traces on the same terms as the core track's engine goldens: committed, regenerated only deliberately, producing a reviewable diff. |
| AC-FR-S-F-2-4 | THE SYSTEM SHALL state, per trace, what reference data it carries — surveyed distance, GNSS distance, counted steps — and what it is therefore able to validate. |
| AC-FR-S-F-2-5 | THE SYSTEM SHALL make a trace's reference distance and the estimator's output comparable in one command, so "how accurate is it today" is answerable without writing code. |

<a id="fr-s-f-3--synthetic-signals-are-labelled-and-quarantined"></a>
#### FR-S-F-3 — Synthetic signals are labelled and quarantined

| AC | Criterion |
|---|---|
| AC-FR-S-F-3-1 | THE SYSTEM SHALL keep synthetic motion signals structurally distinguishable from recorded ones, by type and by directory, so no test can mistake one for the other. |
| AC-FR-S-F-3-2 | THE SYSTEM SHALL use synthetic signals only where the generated label is the ground truth — step counts, known cadences, known stationary intervals — and SHALL NOT use them to assert a distance-accuracy percentage ([CON-S-7](#con-s-7)). |
| AC-FR-S-F-3-3 | THE SYSTEM SHALL state, in any accuracy figure it reports, whether the figure came from a recorded trace or has not yet been validated against one. |
| AC-FR-S-F-3-4 | THE SYSTEM SHALL fail CI if a synthetic generator is referenced from a test asserting a distance-accuracy bound, enforced structurally rather than by review. |

---

### EPIC S-G — Standalone settings and profile (P1)

<a id="fr-s-g-1--standalone-settings"></a>
#### FR-S-G-1 — Standalone settings

| AC | Criterion |
|---|---|
| AC-FR-S-G-1-1 | THE SYSTEM SHALL let the runner set their height, since the step-length model uses it ([AC-FR-S-B-4-1](#fr-s-b-4--step-length-estimation)), and SHALL offer to read it from HealthKit rather than asking twice. |
| AC-FR-S-G-1-2 | THE SYSTEM SHALL let the runner configure spoken-cue frequency and content, and haptic behaviour, independently. |
| AC-FR-S-G-1-3 | THE SYSTEM SHALL show current calibration state and offer a reset ([AC-FR-S-C-2-8](#fr-s-c-2--online-calibration-against-gnss)). |
| AC-FR-S-G-1-4 | THE SYSTEM SHALL persist standalone settings through the existing profile store, syncing to a watch where one exists without disturbing watch behaviour. |

---

## 8. Degraded modes (standalone)

Additions to `../requirements.md` §8. The core DEG-1…DEG-10 continue to apply where the condition
can arise on this tier.

| ID | Condition | Required behaviour |
|---|---|---|
| DEG-S-1 | GNSS lost mid-run | Substitute calibrated motion distance; mark samples estimated; widen bands 50%; announce once ([FR-S-C-3](#fr-s-c-3--pace-during-a-gnss-outage)) |
| DEG-S-2 | GNSS never acquired | Run on motion alone from the start; state reduced accuracy at start; no route |
| DEG-S-3 | Motion sample starvation | Flag; fall back to GNSS-only distance; suppress cadence rather than reporting a bad one ([AC-FR-S-B-1-4](#fr-s-b-1--motion-sampling)) |
| DEG-S-4 | No heart rate, ever | Show `--` everywhere; never synthesise; exclude from HR statistics rather than counting as zero |
| DEG-S-5 | Calibration not yet converged | Run normally; mark the run lower-confidence; say why ([AC-FR-S-E-2-4](#fr-s-e-2--provenance-is-visible-not-hidden)) |
| DEG-S-6 | Indoor / treadmill standalone | Offer a timed-only run with distance and pace suppressed and stated as suppressed ([CON-S-8](#con-s-8)) |
| DEG-S-7 | Phone put in a pocket mid-run | Detect the carry-position change from the loss of swing periodicity, flag it, and fall back to GNSS-only distance rather than feeding an out-of-domain signal into the model |
| DEG-S-8 | Runner stops holding the phone still (traffic light) | Stationary detection suppresses step events and Rolling Pace goes undefined, exactly as [AC-FR-A-1-5](../requirements.md#fr-a-1--rolling-pace-estimation) requires |
| DEG-S-9 | Audio route lost (headphones disconnect) | Continue the run; continue haptics; resume spoken cues on the device speaker; never silently stop alerting |
| DEG-S-10 | Interrupting phone call | Pause spoken cues, keep recording, keep haptics, resume cues after the call |
| DEG-S-11 | Low battery | Offer the core track's low-power treatment (DEG-5) adapted: reduce motion sample rate and GNSS duty cycle, keep audio and haptics |

---

## 9. Non-functional requirements

### 9.1 Performance

| ID | Requirement |
|---|---|
| NFR-S-1 | Cadence estimation for a 60-minute trace SHALL complete offline in under 5 s on a development machine, so a fixture run is a fast feedback loop. |
| NFR-S-2 | Live motion processing SHALL consume under 5% CPU on an iPhone 12 or later, sustained. *Hardware-verified.* |
| NFR-S-3 | A cadence estimate SHALL be available within 15 s of a run starting, so the settling window is not extended by the estimator's own warm-up. |

### 9.2 Battery

| ID | Requirement |
|---|---|
| NFR-S-4 | A 60-minute standalone GPS run SHALL consume no more than 20% of an iPhone 12's battery. *Hardware-verified; no automated proxy is claimed.* |
| NFR-S-5 | Low-power mode ([DEG-S-11](#8-degraded-modes-standalone)) SHALL reduce consumption by at least 25% relative to normal. *Hardware-verified.* |
| NFR-S-6 | The app SHALL hold no background location, motion, or audio session outside an active standalone run. |

### 9.3 Accuracy

**Every bound below names its evidential basis.** "Published" means a figure from a cited study is
the anchor. "Target" means the number is an engineering goal not yet backed by a measurement on this
system's own recorded traces — those become "validated" only when a committed trace demonstrates
them, and [§12.1](#121-validation-status) tracks which is which.

| ID | Requirement | Basis |
|---|---|---|
| NFR-S-7 | Cadence SHALL be within **±3 spm** of a trace's reference cadence, at steady running cadence in 150–200 spm. | Target. Anchored on movement-frequency step-detection accuracies of 95.3–96.7% reported for smartphone signals; ±3 spm at 175 spm is 1.7%. |
| NFR-S-8 | Step count SHALL be within **±2%** of a reference count over a continuous running segment of ≥ 5 minutes. | Target, same anchor. |
| NFR-S-9 | With good GNSS throughout, total distance SHALL be within **3%** of a surveyed reference. | Published: smartphone-app MAPE of 2.85% on a 400 m track; track-based sport-watch figures of 0.8–12.1%. This bound is mostly a property of GNSS, not of this track's work. |
| NFR-S-10 | During a GNSS outage, with a converged calibration, motion-derived distance SHALL be within **6%** of the reference distance for that outage. | Target, anchored on Renaudin et al.'s 2.5–5% for per-subject-calibrated handheld *walking*, loosened because running's aerial phase is a known additional error source ([CON-S-5](#con-s-5)). |
| NFR-S-11 | Without calibration, motion-derived distance SHALL be within **12%**. | Target, anchored on the same work's 4–9% universal-model range for walking, loosened for the same reason. |
| NFR-S-12 | A source handover SHALL never move cumulative distance by more than 5 m. | Structural. Directly testable, no reference needed. |

### 9.4 Reliability

| ID | Requirement |
|---|---|
| NFR-S-13 | No more than 30 s of run data SHALL be lost to any crash or termination, matching NFR-12. |
| NFR-S-14 | Estimation output SHALL be deterministic: the same trace SHALL produce bit-identical output across runs and across platforms that support the package. |

### 9.5 Privacy & security

| ID | Requirement |
|---|---|
| NFR-S-15 | NFR-14, NFR-15, NFR-16 and NFR-17 apply unchanged. Motion data is health data and SHALL NOT leave the device. |
| NFR-S-16 | Captured raw motion traces SHALL be treated as sensitive: excluded from any diagnostic export by default, and clearly labelled when shared deliberately. |
| NFR-S-17 | Background location SHALL be active only for the duration of an active run, and the app SHALL explain in its usage description that it is used to measure the run and never transmitted. |

### 9.6 Maintainability

| ID | Requirement |
|---|---|
| NFR-S-18 | The estimation package SHALL import no Apple framework and SHALL build and test on Linux, enforced by an extension of the existing import gate ([ADR-S-03](./design.md#adr-s-03)). |
| NFR-S-19 | Every tunable in this track SHALL live in exactly one configuration type with a documented default and validated range, on the same terms as NFR-21. |
| NFR-S-20 | CI SHALL fail on: an Apple-framework import in the estimation package; a synthetic generator referenced from an accuracy-bound test; a standalone requirement with no covering task. |
| NFR-S-21 | Line coverage of the estimation package SHALL not fall below 85%, matching the `Core` gate. |

---

## 10. Priority summary

| Priority | Epics | Rationale |
|---|---|---|
| **P0** | S-A, S-B, S-C, S-D, S-E, S-F | The track does not exist without any one of them. S-F is P0 and *first*, because it is what makes S-B checkable. |
| **P1** | S-G | Settings polish; the model works on documented defaults without it. |

---

## 11. Risks

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R-S-1 | The step-length model does not work well enough at running speeds from a hand-held phone, and no published result says whether it should ([CON-S-5](#con-s-5)) | **Medium** | **High** | Build the capture tool first; validate against recorded traces before building any UI on top; keep the model's terms separable so a failing term can be replaced without rewriting the pipeline; be willing to report "GNSS-only, with motion as cadence and a coasting fallback" as the honest v1 outcome |
| R-S-2 | No real traces are available, so the estimator ships validated only against synthetic signals | **High** at the time of writing | **High** | Recording protocol written and handed over as a concrete ask; accuracy ACs explicitly marked unvalidated until traces land; [FR-S-F-3](#fr-s-f-3--synthetic-signals-are-labelled-and-quarantined) makes it structurally impossible for a synthetic test to *claim* the validation |
| R-S-3 | Carry-position drift — runner switches hands, pockets the phone, carries a water bottle | Medium | Medium | [DEG-S-7](#8-degraded-modes-standalone) detects the loss of swing periodicity and falls back rather than extrapolating |
| R-S-4 | GNSS is good enough often enough that the motion model is never exercised, and its bugs stay hidden | Medium | Medium | Fixtures include deliberate outage segments; the fusion layer runs the motion leg continuously even when GNSS wins, so its output is always recorded and comparable |
| R-S-5 | Battery cost of 100 Hz motion plus continuous GNSS makes long runs impractical | Medium | Medium | Rate is tunable; [DEG-S-11](#8-degraded-modes-standalone) low-power path; NFR-S-4 measured on device before the track is called done |
| R-S-6 | Spoken cues are annoying or unintelligible at speed, and users turn them off — removing the primary channel | Medium | Medium | Cue frequency inherits the core dwell/cooldown policy rather than a new one; content is short and fixed-form; haptics remain a complete channel on their own |
| R-S-7 | Adding fields to `SensorCapabilities` and `DistanceSource` regresses the watch tiers | Low | High | [AC-FR-S-A-3-4](#fr-s-a-3--the-capability-contract-states-how-distance-is-obtained) requires the existing goldens to pass unmodified; the change is additive and the tier-equivalence suites are the gate |
| R-S-8 | iOS 26's local `HKWorkoutSession` becomes the expected way to do this and the `HKWorkoutBuilder` path looks dated | Medium | Low | The capability contract already models the distinction ([AC-FR-S-A-3-2](#fr-s-a-3--the-capability-contract-states-how-distance-is-obtained)); adding the session backend is a swap behind an existing seam |

---

## 12. Traceability and honesty

`Tools/check-traceability.swift` is extended by this track to parse `docs/standalone/*.md` with the
`S`-prefixed identifier pattern, and to fail on the same two conditions as the core track: a P0
standalone requirement with no covering task, and a task citing an identifier that does not exist.

### 12.1 Validation status

The accuracy requirements in [§9.3](#93-accuracy) are the ones where a false claim would matter most,
so their status is tracked explicitly and updated as traces land. At the time of writing:

Updated after the 4.3 mi validation run of 2026-07-28 ([S-060](./implementation.md#s-060),
[S-061](./implementation.md#s-061)). The reference is six laps of one loop, each lap independently
confirmed by GNSS track closure, with the runner's own lap and mile marks agreeing to within 1–3 s.

| Requirement | Target | Measured | Status |
|---|---|---|---|
| NFR-S-7 (cadence ±3 spm) | ±3 spm | Against a step rate measured by FFT from the recorded signal, per 30 s window: **+0.1%** on the tempo run (n=79) and **+0.1%** on the slow mile (n=23), **100% of windows within 3%** on both. Across all three running traces cadence spans 154.8-165.3 spm over a **1.77×** speed range | **Holds, on the strongest reference available.** The arbiter shares no code with the estimator and consults no pedometer. Below running cadences it was doubling until [S-062](./implementation.md#s-062); walks now read within 0.3% |
| NFR-S-8 (step count ±2%) | ±2% | On the pace ladder the detector reads 2204 against **2200** from integrating the spectral cadence — **+0.2%**. CMPedometer reads 2043, **−7.1%**, its third disagreement with the arbiter in three traces | **Still not validated, but much better supported.** The spectral integral is an independent measurement rather than a second estimator; only a `countedSteps` reference makes it exact, and the ladder skipped that segment |
| NFR-S-9 (GNSS distance 3%) | 3% | GNSS read **+2.65%** long over a known 4.3 mi, systematically: +1.48 to +2.62% at every one of six laps | **Holds, and the sign is now known.** The error is a scale bias, not noise |
| NFR-S-10 (outage distance 6%) | 6% | 67.9 s of real GNSS outage across four dropouts; the motion leg carried 95.3 m of it | **Partially exercised.** The outages were real but short; the bound is not yet demonstrated |
| NFR-S-11 (uncalibrated distance 12%) | 12% | **Not validated.** The pace ladder measured the exponent: fitted **0.670**, 95% CI [0.562, 0.837], zero held-out bias at **0.718**, against a shipped 0.25 that under-predicts step length by **+8.86%** one pace band from its calibration ([S-063](./implementation.md#s-063)) | **Open, and now blocked on [S-064](./implementation.md#s-064)** — the motion leg over-reads +13% independently of the exponent, and correcting the exponent alone makes the product worse |
| NFR-S-12 (handover 5 m) | 5 m | Structurally tested, and now also exercised against four real dropouts | Holds |
| — (fused distance) | — | **+1.27%** over 4.3 mi after [S-060](./implementation.md#s-060); +3.94% before it. Over the slow mile, **+3.00%**, of which GNSS contributed +3.25% and the fusion *recovered* 0.25 pp — every metre of it measured, none estimated | Better than GNSS alone on both runs. The slow mile's overshoot is inherited GNSS scale bias, not an estimator artifact and not cadence: see the decomposition below |
| — (sample rate) | 100 Hz | **100.42 Hz**, median interval 9.958 ms, worst gap 12.4 ms across five captures totalling 68 minutes, including 37 s with the screen off | Holds comfortably |
| — (sensor headroom) | no saturation | peak `userAcceleration` **50.25 m/s²** during hard tempo, against a ±16 g (157 m/s²) full scale | Holds with 3× headroom |

**Decomposing the slow mile's +3.00%.** Three candidate causes were separated rather than lumped,
because they have three different fixes:

| Source | Contribution | Evidence |
|---|---|---|
| Inherited GNSS scale bias | **+3.25%** | GNSS alone read 1661.7 m against a stated 1609.3. The tempo run's six independent lap closures put the same bias at +2.65%, so this is a consistent scale error, not slow-mile noise |
| Fusion | **−0.25 pp** | Fused 1657.6 m — the fusion pulled *toward* truth, and reported 0 m estimated, so it never left the measured leg |
| Cadence contamination | **none** | Cadence is +0.1% against the spectral arbiter over this trace. This was the hypothesised cause and the data refuted it |
| Step-length model | **not in this number** | The motion leg reads −2.01% here, but on a scale learned from this same run, so it is not independent evidence either way |

The actionable conclusion is that the slow mile does not show an estimator defect. It shows the GNSS
over-read already recorded under NFR-S-9, at a magnitude consistent with the tempo run.

**The first figure from the shipped product, 2026-07-30.** A 2.8 mi hand-held outdoor run reported
**2.88 mi, +2.9%** — inside NFR-S-9's bound, and consistent in sign and magnitude with the +2.65%
GNSS scale bias above. It is recorded as an observation and **not** as validation of that
requirement: the reference was a single unsurveyed distance rather than a closed loop with
independently confirmed laps, and one run cannot separate a scale bias from a coincidence.

It carries one piece of evidence for [S-064](./implementation.md#s-064) that the traces could not:
the run raised `stepLengthClamped` and told the runner that some step lengths had been limited. That
is the over-read appearing on a **different runner's gait** from the one every committed trace was
recorded with — which is the generality question S-064 and the second pace ladder both turn on.

### 12.2 What is hardware-verification-only

Recorded here rather than discovered later. These cannot be automated on this project's CI, for the
reasons given. **The protocol for all of them is
[`Tools/standalone-manual-protocol.md`](../../Tools/standalone-manual-protocol.md)**
([S-054](./implementation.md#s-054)), which names the hardware, the steps and a results template.

| Item | Why not automatable | Status |
|---|---|---|
| AC-FR-S-A-2-1 — background survival | Requires a real device, a locked screen, and elapsed wall-clock time | Protocol §1, **not yet run** as specified; incidentally exercised 2026-07-30 over a 25-minute run |
| AC-FR-S-D-1-6 — a run conducted without looking | Requires a runner | Protocol §2, **not yet run** |
| AC-FR-S-D-1-4 — audible on silent, ducks music | The Simulator has no ring switch and no audio route to change | Protocol §3.1 — **failed 2026-07-30**, fixed in [S-065](./implementation.md#s-065), **retest pending** |
| AC-FR-S-D-1-9 — cue intelligibility at speed | Requires ears, wind and music | Protocol §3.2 — **partially failed 2026-07-30** (first cue unparseable; voice robotic and too fast), addressed in [S-065](./implementation.md#s-065) and [S-066](./implementation.md#s-066), **retest pending** |
| S-066 — voice choice and speed | Which voices exist is a property of the device, not of the build | Protocol §3.2a, **not yet run** |
| DEG-S-9, DEG-S-10 — route loss, interrupting call | XCTest cannot disconnect headphones or place a call | Protocol §3.3–3.4, **not yet run** |
| AC-FR-S-D-2-1, AC-FR-S-D-2-3 — haptic distinctness, background haptics | The Simulator has no Taptic Engine | Protocol §4 — **informally passed 2026-07-30** ("could feel the haptics working"); the blind distinctness test is **not yet run** |
| NFR-S-2, NFR-S-4, NFR-S-5 — CPU and battery | No simulator proxy is meaningful | Protocol §6, **not yet run** |
| AC-FR-S-D-3-3 — legible at arm's length in motion | Requires a runner | Protocol §2 — **informally passed 2026-07-30**; the structured-session form is **not yet run** |
| Every accuracy figure | [CON-S-1](#con-s-1): the Simulator has no motion sensors at all | Recorded traces, per [§12.1](#121-validation-status) |

**A protocol item with no recorded result is an unverified requirement**, and this table says so
rather than implying otherwise. The tier's *logic* is covered — 180 tests in `PhoneSupport`, 104 in
`PhoneMotion`, and the boundary and audio-session suites in the app target — but most of what a
runner actually experiences is still unverified on hardware.

**The first field session, 2026-07-30**, is why several rows above changed from "not yet run" to a
result. Two hand-held outdoor phone runs with music playing. It found one severe defect
([S-065](./implementation.md#s-065) — the runner's music ducked at the first cue and stayed down for
the whole run) and two quality defects ([S-066](./implementation.md#s-066)), none of which any test
in this repository could have caught, and all of which sat in the layer §12.2 exists to describe.
It also produced the tier's first hardware distance figure: **2.88 mi against a 2.8 mi reference,
+2.9%**, inside [NFR-S-9](#nfr-s-9)'s 3% bound but from a single unsurveyed reference, so it is
recorded as an observation and not as validation of that requirement.

Entries marked *informally passed* were observed in passing rather than run as the protocol
specifies, and are **not** a substitute for it — "I could feel the haptics" is not the blind
four-pattern distinctness test that AC-FR-S-D-2-1 asks for.

---

## 13. References

**Platform, verified against the iOS 26.5 SDK in Xcode 26.6 on this machine** (header availability
annotations quoted in [CON-S-2](#con-s-2)):

- `HKWorkoutSession.h`, `HKLiveWorkoutBuilder.h`, `HKWorkoutBuilder.h`, `HKHealthStore.h` —
  `$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/HealthKit.framework/Headers/`
- Apple — [Track workouts with HealthKit on iOS and iPadOS, WWDC25 session 322](https://developer.apple.com/videos/play/wwdc2025/322/)
- Apple — [Running workout sessions](https://developer.apple.com/documentation/HealthKit/running-workout-sessions)
- Apple — [Calibrate your Apple Watch for improved Workout and Activity accuracy](https://support.apple.com/en-us/105048)
  — the arm-swing-and-stride model calibrated against GPS, and the precedent for
  [FR-S-C-2](#fr-s-c-2--online-calibration-against-gnss)

**Step detection and cadence from smartphone inertial signals:**

- Renaudin, V., Susi, M., Lachapelle, G. (2012). "Step Length Estimation Using Handheld Inertial
  Sensors." *Sensors* 12(7), 8507–8525. —
  [MDPI](https://www.mdpi.com/1424-8220/12/7/8507) ·
  [PMC3444061](https://pmc.ncbi.nlm.nih.gov/articles/PMC3444061/) ·
  [PubMed 23012503](https://pubmed.ncbi.nlm.nih.gov/23012503/)
  — the handheld reference work: the `s = h·(a·f_step + b) + c` model, the texting/swinging carry
  modes, the STFT-plus-peak-detection structure, the hand-versus-step frequency ambiguity and its
  1.4 Hz walking threshold, and the 2.5–5% calibrated / 4–9% universal error figures.
- Ricci, L. et al. — [Automated Accelerometer-Based Gait Event Detection During Multiple Running
  Conditions](https://pmc.ncbi.nlm.nih.gov/articles/PMC6480623/) — comparative accuracies of peak
  detection, autocorrelation, template matching and frequency-domain methods (95.3 ± 6% to
  96.7 ± 6.41% for the best classes), and the 120–240 spm working range.
- [Gait Event Detection and Travel Distance Using Waist-Worn Accelerometers across a Range of
  Speeds](https://arxiv.org/pdf/2307.04866)

**Step and stride length models:**

- Weinberg, H. (2002). "Using the ADXL202 in Pedometer and Personal Navigation Applications."
  Analog Devices Application Note AN-602 — the `K·(a_max − a_min)^(1/4)` amplitude form.
- Kim, J. W. et al. (2004) — the `K·(mean|a|)^(1/3)` form.
- [Adaptive Inertial Sensor-Based Step Length Estimation Model](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC9739942/)
- [Inertial Sensor-Based Step Length Estimation Model by Means of Principal Component
  Analysis](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8159098/)
- [Step-Detection and Adaptive Step-Length Estimation for Pedestrian Dead-Reckoning at Various
  Walking Speeds Using a Smartphone](https://www.mdpi.com/1424-8220/16/9/1423)

**Running-specific biomechanics and speed estimation:**

- Falbriard, M. et al. (2021). "Running Speed Estimation Using Shoe-Worn Inertial Sensors: Direct
  Integration, Linear, and Personalized Model." *Frontiers in Sports and Active Living* —
  [full text](https://www.frontiersin.org/journals/sports-and-active-living/articles/10.3389/fspor.2021.585809/full)
  — the aerial-phase objection to transplanting walking models, and RMSE figures of 0.20 m/s
  (direct integration), 0.12–0.16 m/s (linear), 0.09 m/s (personalized) across 5–20 km/h.
- van Oeveren, B. T. et al. (2019). "Inter-individual differences in stride frequencies during
  running obtained from wearable data." *Journal of Sports Sciences* —
  [Taylor & Francis](https://www.tandfonline.com/doi/full/10.1080/02640414.2019.1614137)
  — the group-level relation `SF (strides·min⁻¹) = 75.01 + 3.006 · speed (m·s⁻¹)` over
  1.64–4.68 m·s⁻¹, which is the quantitative basis for
  [AC-FR-S-B-4-3](#fr-s-b-4--step-length-estimation).
- [The Effect of Running Speed on Cadence and Running Kinetics](https://pmc.ncbi.nlm.nih.gov/articles/PMC12222555/)
- [Active Arm Swing During Running Improves Rotational Stability of the Upper Body and Metabolic
  Energy Efficiency](https://pmc.ncbi.nlm.nih.gov/articles/PMC11929735/) — arm swing in running is
  actively controlled rather than passive, unlike walking.
- Pontzer, H. et al. — [Control and function of arm swing in human walking and
  running](https://dash.harvard.edu/bitstreams/7312037c-83b3-6bd4-e053-0100007fdf3b/download)
  — shoulder acceleration contains both stride- and step-frequency components, which is the
  structural fact [FR-S-B-2](#fr-s-b-2--cadence-estimation) has to handle.

**Reference accuracy for GNSS distance:**

- [Accuracy of Distance Recordings in Eight Positioning-Enabled Sport Watches: Instrument Validation
  Study](https://mhealth.jmir.org/2020/6/e17118/) — 0.8–12.1% MAPE over 4 000 m on a 400 m track;
  systematic underestimation in urban and forest terrain.
- [Heart Rate and Distance Measurement of Two Multisport Activity Trackers and a Cellphone App in
  Different Sports](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8749603/) — cellphone-app MAPE of
  2.85% over a 1.6 km track interval run.
- Johansson, R. E. et al. (2020). "Accuracy of GPS sport watches in measuring distance in an
  ultramarathon running race." — [DOI](https://doi.org/10.1177/1747954119899880) — 0.6 ± 0.3% to
  1.9 ± 1.5%.

**Sampling and filtering:**

- [A Biomechanical Re-Examination of Physical Activity Measurement with
  Accelerometers](https://doi.org/10.3390/s18103399) — 100 Hz captures footfall impact peaks;
  a ~10 Hz low-pass retains activity-relevant acceleration with minimal noise.
