# OptimalRunner — Requirements

| Field | Value |
|---|---|
| Document | `docs/requirements.md` |
| Version | 1.0 |
| Status | Draft for implementation |
| Last updated | 2026-07-24 |
| Companions | [`design.md`](./design.md), [`implementation.md`](./implementation.md) |

---

## 0. How to read this document

- **Requirement IDs** are stable: `FR-<epic>-<n>` (functional), `NFR-<n>` (non-functional), `CON-<n>` (constraint). Never renumber; mark superseded requirements as `DEPRECATED` and add a new ID.
- **Acceptance criteria** use [EARS](https://alistairmavin.com/ears/) phrasing (`WHEN … THE SYSTEM SHALL …`). Every AC is written to be mechanically verifiable — either by an automated test or by a scripted manual protocol. `design.md` names the test that covers it; `implementation.md` names the task that builds it.
- **Priority** follows the product memo:
  - **P0** — required for first usable release.
  - **P1** — medium priority.
  - **P2** — low priority / post-1.0.
- Numeric defaults marked *(tunable)* are configurable constants, not hardcoded literals. They live in one place (`PaceEngineConfiguration`) so they can be changed without touching logic.

---

## 1. Product vision

> A running app for all runners who want to train optimally. OptimalRunner has a simplistic UI during runs for pace management and advanced analysis post-run. Save routes, plan for races, & recover with OptimalRunner's generated plans. Train running techniques (tempo, intervals, strides, easy runs, long runs, etc.) all without the need for a track.

The product is built on two convictions:

1. **During a run, the watch should tell you one thing.** A runner glancing at their wrist mid-tempo-run should not have to parse numbers. The screen's dominant colour answers "am I running this correctly?" in under 250 ms of attention. Everything else on the screen is secondary.
2. **After a run, the phone should tell you everything.** All the analytical depth that is inappropriate on a 40 mm screen belongs in the iPhone hub.

The second conviction is what makes the first one affordable: because analysis is deferred, the watch UI can be radically simple.

### 1.1 Business goals

| ID | Goal | Success metric |
|---|---|---|
| G-1 | Let a runner hold a prescribed pace without staring at their wrist | ≥80% of tempo-run duration spent in the *On Target* band, measured across a user's 5th-and-later tempo run |
| G-2 | Replace the track for structured interval work | ≥95% of automatic interval transitions fire within ±15 m of the prescribed distance |
| G-3 | Make post-run analysis the reason people come back | ≥40% of completed runs are opened in the iPhone app within 24 h |
| G-4 | Be trustworthy about effort on hilly terrain | Grade-adjusted target within ±5% of Strava GAP for the same segment on grades in [−3%, +3%] |
| G-5 | Be a credible open-source project | A new contributor can build and run the full test suite from a clean clone in ≤15 minutes using only the README |
| G-6 | Support the runners who already own the hardware | Feature-complete pace management on Apple Watch Series 3 (see [§4](#4-platform-support) for the hard limits on this) |

### 1.2 Non-goals for 1.0

Explicitly out of scope, recorded so they are not silently re-scoped:

- Cycling, swimming, or any non-running activity.
- Social feeds, followers, sharing, leaderboards, segments.
- A backend service or user accounts. OptimalRunner 1.0 is device-local (see [NFR-14](#95-privacy--security)).
- Music control beyond the system Now Playing page.
- Live tracking / beacon for third parties.
- Running-form metrics (ground contact time, vertical oscillation, stride length). These are hardware-gated to recent watches and would split the tiers further.
- Nutrition, sleep, or recovery scoring beyond what plan generation needs.
- Android, Wear OS, or web.

---

## 2. Personas

**P1 — "Structured Sam" (primary).** Runs 25–40 mpw, has a goal race, knows what a tempo run is. Wants prescription and compliance feedback. Owns a Series 7. Frustrated that the stock Workout app tells him his pace but not whether it's the *right* pace.

**P2 — "Returning Rosa" (primary).** Comes back to running every spring, 10–20 mpw. Doesn't know her paces. Needs the app to derive them and to stop her running her easy days too hard — the single most common recreational-runner error. Owns a Series 3 she has no plans to replace.

**P3 — "Track-less Theo" (primary for intervals).** Wants to do 4×1000 m but has no track and does not want to do arithmetic on a loop. Needs the watch to count the metres and buzz on its own.

**P4 — "Contributor Chris" (secondary).** Found the repo on GitHub. Wants to add a feature. Needs the codebase to make it obvious where watch-tier code lives and needs CI to tell him when he's broken something.

---

## 3. Glossary

The memo used shorthand (`BF`, `AF`, `μ_Xt`, `μ_Xl`) for explanation only. **Those terms must not appear in the product, the UI, or the source code.** These are the canonical names:

| Term | Meaning | Memo equivalent |
|---|---|---|
| **Target Pace** | The reference pace for a run type, derived from the user's profile. Stored per run type. | `μ_Xt`, `μ_Xl` |
| **Target Pace Curve** | The expected pace *as a function of run progress*. Not flat: may drift slower toward the end of a run. | the black curve |
| **Opening Offset** | How much the curve deviates from Target Pace at progress = 0. | `BF` |
| **Closing Offset** | How much the curve deviates from Target Pace at progress = 1. | `AF` |
| **Pace Band** | The tolerance envelope around the Target Pace Curve, expressed as percentages of pace. Wider for easy and long runs. | "wiggle room" |
| **Pace Zone** | Which part of the band the runner is currently in. One of six values driving the screen colour. | — |
| **Rolling Pace** | Smoothed recent pace, the app's analogue of the stock Workout app's "current pace". | "rolling pace" |
| **Progress** | Fraction of the run completed, in [0, 1]. Distance-based when a target distance exists, otherwise time-based. | x-axis of the graph |
| **Grade Adjustment** | Multiplier applied to the Target Pace Curve to account for terrain slope. | "altimeter … expected pace should change" |
| **Step** | One phase of a structured workout (warmup, work, recovery, cooldown). | "warmup", "1000m", "jog" |
| **Settling Window** | Opening portion of a run where no pace judgement is rendered. | — |

**Pace percentages are always defined on pace, never on speed.** A 9:00/mi pace is *12.5% slower* than 8:00/mi because 540/480 = 1.125. This convention is load-bearing and is asserted by [AC-FR-A-1-4](#fr-a-1--rolling-pace-estimation).

---

## 4. Platform support

### 4.1 Device / OS matrix

| Tier | Devices | watchOS | Codebase | Notes |
|---|---|---|---|---|
| **Modern** | Series 4, 5, 6, 7, 8, 9, 10, 11, SE 1/2/3, Ultra 1/2/3 | 10.0+ | `Apps/WatchModern` | Deployment target 10.0 because watchOS 11 dropped Series 4 and 5; targeting 10.0 is what makes "Series 4+" true |
| **Legacy** | Series 3 | 8.0 | `Apps/WatchLegacy` | Series 3 tops out at watchOS 8.8.1 |
| **Phone** | iPhone | iOS 17.0+ | `Apps/iPhone` | iOS 17 for SwiftData; Swift Charts needs only 16 but SwiftData is the bigger lever |

The two watch tiers are **separate targets with separate source trees and no shared UI or sensor code**, per the memo's readability requirement. See [CON-3](#5-constraints-and-accepted-deviations) and `design.md` ADR-002.

### 4.2 Sensor availability by tier

| Capability | Legacy (S3) | Modern (S4+) |
|---|---|---|
| GPS | Yes (GPS models) | Yes |
| Optical heart rate | Yes | Yes |
| Barometric altimeter | Yes — introduced on Series 3 | Yes |
| Always-On Display | **No** | Series 5+ only |
| Double Tap gesture | No | Series 9+ / Ultra 2+ |
| `HKWorkoutActivity` (native interval segmentation) | No (watchOS 9+ API) | Yes |
| `HKQuantityTypeIdentifier.runningSpeed` / `runningPower` | No | Series 6+ |

Grade adjustment ([FR-A-4](#fr-a-4--grade-adjustment)) is available on **both** tiers because Series 3 has the altimeter.

---

## 5. Constraints and accepted deviations

These are places where the product memo describes behaviour the platform does not permit, or where research indicates the memo's approach needs adjustment. Each records the constraint, the decision taken, and why. **Nothing in the memo has been dropped** — each is delivered by a different mechanism.

<a id="con-1"></a>
### CON-1 — The Digital Crown press cannot be intercepted by third-party apps

**Constraint.** On watchOS, pressing the Digital Crown is a reserved system action equivalent to the iOS home button: it returns to the watch face or app switcher. There is no API for a third-party app to receive, consume, or suppress it. Crown *rotation* is available (`digitalCrownRotation` / `WKCrownDelegate`); crown *press* is not. The two-button "mark segment" chord used by Apple's own Workout app is likewise not exposed.

**Affected memo statements.** "click the Digital Crown" to end a warmup/cooldown; "if the user presses the Digital Crown the warning should go away"; "end the workout by clicking the Digital Crown themselves".

**Decision.** Every crown-press interaction is delivered by an equivalent one-handed gesture:

| Memo intent | Replacement | Tiers |
|---|---|---|
| Advance from an open-ended step | Tap anywhere on the metrics screen (full-screen target) | Both |
| Advance from an open-ended step (alt) | Double Tap gesture (`handGestureShortcut(.primaryAction)`) | Modern, Series 9+ |
| Advance from an open-ended step (alt) | Rotate crown past a detent, opt-in | Both |
| Dismiss a pace warning | Tap anywhere on the alert screen; also auto-dismisses | Both |
| End the workout | Swipe right to the Controls page → **End**, matching the stock Workout app | Both |

Rationale for full-screen tap on the metrics page: an accidental lap during a warmup is cheap and undoable ([FR-C-6](#fr-c-6--undo-a-manual-advance)); an accidental *end* is not, so ending stays behind a deliberate two-step gesture.

<a id="con-2"></a>
### CON-2 — The Series 3 build window is closing

**Constraint.** Series 3 requires a watchOS 8 deployment target. Apple requires App Store submissions to be built with the watchOS 26 SDK / Xcode 26 as of 28 April 2026 — Xcode 26 still permits a watchOS 8 deployment target, so this is currently satisfiable. Xcode 27 raises the minimum watchOS deployment target to 9.0, which will make the Legacy target unbuildable once Xcode 27's SDK becomes mandatory (expected ~April 2027).

**Decision.** Build Legacy now, and structure the repo so its eventual removal is deleting one directory and one CI job. The Legacy target shares *no* source files with Modern, so its removal cannot regress Modern. `CON-2` is tracked as a dated risk in [§11](#11-risks). The Legacy watch app ships under its own bundle identifier so its deployment target does not constrain the flagship app.

<a id="con-3"></a>
### CON-3 — "No conditionals" is enforced, not just requested

**Constraint.** The memo requires that tier-specific logic not be expressed as `if Series 3 { … } else { … }` inside shared files.

**Decision.** Beyond splitting the targets, CI mechanically fails any build where:
- `#available` / `if #available` appears anywhere under `Apps/WatchModern` or `Apps/WatchLegacy`;
- `Core/` imports `HealthKit`, `CoreLocation`, `CoreMotion`, `WatchKit`, `SwiftUI`, or `UIKit`.

This turns a style guideline into a build gate. See [NFR-18](#96-maintainability--open-source).

<a id="con-4"></a>
### CON-4 — Red/green as the primary signal excludes ~8% of male runners

**Constraint.** Red–green is the exact axis that deuteranopia and protanopia compress. Roughly 8% of men and 0.5% of women of northern-European descent have some form of red-green colour vision deficiency. A UI whose *only* channel is red-vs-green is unusable for them — and the memo's requirement that the colour be "clearly visible at all times" makes this a functional failure, not a cosmetic one.

**Decision.** The memo's palette ships as the default, unchanged. Three additions make it safe:
1. **Redundant encoding, always on** — a direction glyph and a signed pace delta are rendered on every zone screen, so colour is never the sole carrier of meaning ([FR-J-1](#fr-j-1--colour-is-never-the-only-channel)).
2. **An alternate palette** — a blue↔orange diverging scale, selectable in settings, that survives all three common CVD types ([FR-J-2](#fr-j-2--colour-vision-deficiency-palette)).
3. **Haptics** — already required by the memo, and they are a fully non-visual channel.

<a id="con-5"></a>
### CON-5 — Only one workout session may be active on the watch at a time

**Constraint.** watchOS permits a single active `HKWorkoutSession` system-wide. If the user starts a workout in Apple Fitness or another app, OptimalRunner's session is terminated.

**Decision.** Handle it as a first-class state, not a crash: persist partial run data continuously ([FR-D-6](#fr-d-6--crash-and-interruption-durability)), detect session termination, and on next launch offer to save the partial run.

<a id="con-6"></a>
### CON-6 — The raw metabolic cost curve is unusable as a live downhill target

**Constraint.** Minetti's cost-of-running polynomial is the standard model and fits oxygen cost well, but converting it directly into a pace target produces absurd downhill prescriptions: at −6% grade it demands 8:00/mi become 5:47/mi. Its cost minimum sits near −18% grade, whereas pooled athlete data puts the practical minimum nearer −10% to −12%. Runners cannot convert metabolic savings into speed one-for-one because braking forces and biomechanics bound descent speed.

**Decision.** Use Minetti as the basis but apply an asymmetric attenuation and saturating clamps, calibrated so the result tracks published GAP behaviour in the ±3% band where nearly all road running happens. Specified in [FR-A-4](#fr-a-4--grade-adjustment) and derived in `design.md` §5.4.

---

## 6. Scope by release

| Release | Contents |
|---|---|
| **M1 — Pace core (P0)** | Watch: tempo / easy / long pace management with colour, haptics, warning screen, grade adjustment, metrics page. Modern tier only. HealthKit write. |
| **M2 — Analysis hub (P0)** | iPhone: run list, run detail with charts, global statistics. Watch→phone sync. |
| **M3 — Intervals (P0)** | Watch: structured workouts, VO2 max mode, auto-advance, manual advance. iPhone: interval run detail. |
| **M4 — Legacy tier (P0 for G-6)** | Series 3 watch app at feature parity minus hardware-gated items. |
| **M5 — Planning (P1)** | iPhone: plan a run, generate a training schedule, today's-workout summary, push plan to watch. |
| **M6 — Routes & laps (P2)** | iPhone: save routes, save laps, compose a route from N repeats of a lap, custom workout builder. |

---

## 7. Functional requirements

### EPIC A — Pace management on the watch (P0)

> **User story.** As Structured Sam, I want the watch face to be green while I'm running my tempo run correctly and to change colour the moment I drift, so that I can hold my pace with a glance instead of doing arithmetic at threshold.

<a id="fr-a-1--rolling-pace-estimation"></a>
#### FR-A-1 — Rolling pace estimation

The system computes a smoothed **Rolling Pace** that is stable enough to drive a full-screen colour without flickering, and responsive enough to reflect a genuine change in effort within a few seconds.

| AC | Criterion |
|---|---|
| AC-FR-A-1-1 | WHEN location samples are available, THE SYSTEM SHALL compute Rolling Pace over a trailing distance window of 200 m *(tunable, 100–400 m)*, bounded below by 20 s and above by 60 s of elapsed time. |
| AC-FR-A-1-2 | WHEN a location sample has `horizontalAccuracy` > 20 m *(tunable)* or a negative accuracy, THE SYSTEM SHALL exclude it from the pace window and SHALL NOT let it affect Rolling Pace. |
| AC-FR-A-1-3 | WHEN GPS is unavailable or degraded for > 10 s, THE SYSTEM SHALL fall back to pedometer-derived pace and SHALL display a reduced-accuracy indicator. |
| AC-FR-A-1-4 | THE SYSTEM SHALL express all pace tolerances as percentages of pace such that a pace of 540 s/mi is exactly 12.5% slower than 480 s/mi. |
| AC-FR-A-1-5 | WHEN the runner is stationary for > 5 s, THE SYSTEM SHALL report Rolling Pace as undefined rather than as an unbounded number, and the zone SHALL become *Neutral*. |
| AC-FR-A-1-6 | GIVEN a recorded reference trace, THE SYSTEM SHALL produce a Rolling Pace series whose values are reproducible bit-for-bit across runs of the test suite. |

<a id="fr-a-2--target-pace-curve"></a>
#### FR-A-2 — Target Pace Curve

The expected pace is a function of progress, not a constant. It is defined by a run-type preset supplying an Opening Offset, a Closing Offset, and the shape between them.

| AC | Criterion |
|---|---|
| AC-FR-A-2-1 | THE SYSTEM SHALL evaluate the Target Pace Curve as `targetPace(progress) = basePace × (1 + drift(progress))` where `drift` is defined by the run-type preset. |
| AC-FR-A-2-2 | WHEN the run type is **Tempo**, THE SYSTEM SHALL apply `drift = 0` for progress < 0.5 and a linear ramp to +1.5% *(tunable)* at progress = 1. |
| AC-FR-A-2-3 | WHEN the run type is **Easy / Recovery**, THE SYSTEM SHALL apply `drift = 0` throughout. |
| AC-FR-A-2-4 | WHEN the run type is **Long**, THE SYSTEM SHALL apply `drift = 0` for progress < 0.6 and a linear ramp to +4.0% *(tunable)* at progress = 1. |
| AC-FR-A-2-5 | WHEN a run has a planned distance, THE SYSTEM SHALL compute progress as `distanceCovered / plannedDistance`, clamped to [0, 1]. |
| AC-FR-A-2-6 | WHEN a run has no planned distance but has a planned duration, THE SYSTEM SHALL compute progress from elapsed time. |
| AC-FR-A-2-7 | WHEN a run has neither a planned distance nor a planned duration, THE SYSTEM SHALL hold progress at 0, yielding a flat curve, and SHALL NOT apply any drift. |
| AC-FR-A-2-8 | THE SYSTEM SHALL expose Opening Offset, Closing Offset, and ramp start points as user-editable values per run type, with the defaults above restorable in one action. |

> **Design note (rationale for the defaults).** The memo's graph is *descriptive* — it shows what a real tempo run looks like, opening faster than target and drifting slower. The pacing literature is *prescriptive* and favours even or slightly negative splits; positive splits are the characteristic recreational-runner error. Prescribing a fast opening would therefore encode the mistake into the product. The resolution is to keep the prescribed curve near-flat while making the *band* generous on the fast side early ([FR-A-3](#fr-a-3--pace-band-and-zone-classification)) — so the memo's observed curve sits comfortably inside the band and the runner is never nagged for a normal fast start, but the app never *asks* for one. Long runs are the exception: the memo explicitly wants them to permit a slower finish, and that matches how long runs are actually coached, so Long carries a real +4% closing drift.

<a id="fr-a-3--pace-band-and-zone-classification"></a>
#### FR-A-3 — Pace Band and zone classification

| AC | Criterion |
|---|---|
| AC-FR-A-3-1 | THE SYSTEM SHALL classify the runner into exactly one of six zones: `tooFast`, `slightlyFast`, `onTarget`, `slightlySlow`, `tooSlow`, `neutral`. |
| AC-FR-A-3-2 | THE SYSTEM SHALL classify on the ratio `rollingPace / gradeAdjustedTargetPace`, where a ratio > 1 means slower than target. |
| AC-FR-A-3-3 | THE SYSTEM SHALL support **asymmetric** bands, with four independent thresholds per run type: `fastNear`, `fastFar`, `slowNear`, `slowFar`. |
| AC-FR-A-3-4 | THE SYSTEM SHALL ship these defaults *(tunable)*: **Tempo** 2.0 / 5.0 / 2.0 / 5.0 %; **Easy** 3.0 / 6.0 / 6.0 / 12.0 %; **Long** 2.5 / 5.5 / 5.0 / 10.0 %. |
| AC-FR-A-3-5 | WHEN the runner is within `fastNear` and `slowNear` of the curve, THE SYSTEM SHALL report `onTarget`. |
| AC-FR-A-3-6 | THE SYSTEM SHALL apply 0.5% *(tunable)* hysteresis to every zone boundary such that leaving a zone requires exceeding the boundary by the hysteresis margin. |
| AC-FR-A-3-7 | GIVEN a pace series that oscillates within the hysteresis margin of a boundary, THE SYSTEM SHALL NOT change zone more than once. |
| AC-FR-A-3-8 | THE SYSTEM SHALL evaluate zone at 1 Hz *(tunable)*. |

> **Rationale for asymmetry.** Easy runs are the case where asymmetry matters most: running an easy run too *fast* is the single most common and most costly recreational error, while running it slower than prescribed is nearly harmless. Easy therefore gets a tight fast side (3%) and a loose slow side (6%/12%). Tempo is symmetric because both errors defeat the session's purpose.

<a id="fr-a-4--grade-adjustment"></a>
#### FR-A-4 — Grade adjustment

> **User story.** As Structured Sam, I want the target to loosen when I hit a hill, so that the app is measuring my *effort* and not just my speed.

| AC | Criterion |
|---|---|
| AC-FR-A-4-1 | THE SYSTEM SHALL estimate grade from barometric relative altitude change over horizontal distance, using a trailing window of 100 m *(tunable)*. |
| AC-FR-A-4-2 | THE SYSTEM SHALL smooth the grade estimate and SHALL NOT alter the target on transient altitude noise; a grade change SHALL persist for 15 s *(tunable)* before it is applied. |
| AC-FR-A-4-3 | THE SYSTEM SHALL compute the adjustment factor as `1 + λ·(C(g)/C(0) − 1)` where `C` is the Minetti cost polynomial, `λ = 0.90` for `g ≥ 0` and `λ = 0.50` for `g < 0` *(tunable)*. |
| AC-FR-A-4-4 | THE SYSTEM SHALL clamp grade input to [−15%, +15%] and the resulting factor to [0.90, 1.30] *(tunable)*. |
| AC-FR-A-4-5 | WHEN grade is positive, THE SYSTEM SHALL increase the target pace value (prescribe a slower pace); WHEN grade is negative, THE SYSTEM SHALL decrease it. |
| AC-FR-A-4-6 | WHEN the altimeter is unavailable, THE SYSTEM SHALL disable grade adjustment, hold the factor at 1.0, and indicate this on the metrics page. |
| AC-FR-A-4-7 | THE SYSTEM SHALL display the currently applied adjustment when it differs from 1.0 by more than 1%, as a hill indicator with the adjusted target pace. |
| AC-FR-A-4-8 | THE SYSTEM SHALL record raw and grade-adjusted target pace in the run record so post-run analysis can show both. |
| AC-FR-A-4-9 | THE SYSTEM SHALL produce adjustment factors within ±5% of published Grade Adjusted Pace behaviour for grades in [−3%, +3%]. |

<a id="fr-a-5--settling-window"></a>
#### FR-A-5 — Settling window

| AC | Criterion |
|---|---|
| AC-FR-A-5-1 | WHEN a run or a paced step begins, THE SYSTEM SHALL suppress zone classification until the runner has covered 400 m *(tunable)* or 90 s *(tunable)*, whichever comes first. |
| AC-FR-A-5-2 | WHILE in the settling window, THE SYSTEM SHALL display the `neutral` colour and SHALL NOT fire any pace haptic. |
| AC-FR-A-5-3 | WHILE in the settling window, THE SYSTEM SHALL display all numeric metrics normally. |

> **Rationale.** Without this, every run opens with a solid red screen: the runner is accelerating from a standstill, GPS has not converged, and the pace window has not filled. That teaches users to ignore the colour, which destroys the product's core mechanic.

<a id="fr-a-6--the-run-screen"></a>
#### FR-A-6 — The run screen

| AC | Criterion |
|---|---|
| AC-FR-A-6-1 | THE SYSTEM SHALL fill the entire screen background with the current zone colour, edge to edge, with no letterboxing or inset. |
| AC-FR-A-6-2 | THE SYSTEM SHALL display, top to bottom: elapsed time, heart rate, rolling pace, average pace, distance. |
| AC-FR-A-6-3 | THE SYSTEM SHALL animate colour transitions over 400 ms *(tunable)* to avoid a jarring flash. |
| AC-FR-A-6-4 | WHEN a heart-rate sample is unavailable for > 10 s, THE SYSTEM SHALL display `--` for heart rate rather than a stale value. |
| AC-FR-A-6-5 | THE SYSTEM SHALL render all five metrics legibly at the smallest supported case size (38 mm on Legacy, 40 mm on Modern) without truncation or overlap at the default Dynamic Type size. |
| AC-FR-A-6-6 | *(Modern, Series 5+)* WHEN the display enters the always-on state, THE SYSTEM SHALL keep the zone colour as the dominant fill in a dimmed variant and SHALL keep elapsed time and rolling pace legible. |
| AC-FR-A-6-7 | *(Modern)* THE SYSTEM SHALL keep every pair of dimmed zone colours visually distinguishable, verified numerically in test. |
| AC-FR-A-6-8 | *(Legacy)* Series 3 has no always-on display; THE SYSTEM SHALL restore the correct zone colour within 500 ms of wrist raise. |
| AC-FR-A-6-9 | THE SYSTEM SHALL provide Controls (pause / resume / end / lap) on a page reachable by swiping right, matching the stock Workout app's interaction model. |

<a id="fr-a-7--run-type-selection"></a>
#### FR-A-7 — Run type selection

| AC | Criterion |
|---|---|
| AC-FR-A-7-1 | THE SYSTEM SHALL offer, on the watch start screen: Tempo, Easy / Recovery, Long, Interval, VO2 Max. |
| AC-FR-A-7-2 | WHEN a run type is selected, THE SYSTEM SHALL show its Target Pace and band before starting, so the runner can confirm the prescription. |
| AC-FR-A-7-3 | THE SYSTEM SHALL allow the target pace to be adjusted for this run only, without mutating the stored profile. |
| AC-FR-A-7-4 | WHEN the iPhone has pushed a planned workout for today, THE SYSTEM SHALL surface it as the first option on the start screen. *(P1)* |
| AC-FR-A-7-5 | THE SYSTEM SHALL start a run in ≤ 2 taps from app launch for the default run type. |

---

### EPIC B — Alerts and haptics (P0)

> **User story.** As Returning Rosa, I want the watch to buzz me when I've drifted badly, so that I don't have to keep checking my wrist — but I don't want it nagging me every ten seconds.

<a id="fr-b-1--haptic-alerts"></a>
#### FR-B-1 — Haptic alerts

| AC | Criterion |
|---|---|
| AC-FR-B-1-1 | WHEN the zone has been `tooFast` or `tooSlow` continuously for 20 s *(tunable)*, THE SYSTEM SHALL fire exactly one haptic. |
| AC-FR-B-1-2 | THE SYSTEM SHALL NOT fire a repeat haptic for the same zone within a cooldown of 60 s *(tunable)*. |
| AC-FR-B-1-3 | THE SYSTEM SHALL use a distinguishable haptic per direction: a "slow down" pattern for `tooFast` and a "speed up" pattern for `tooSlow`. |
| AC-FR-B-1-4 | THE SYSTEM SHALL NOT fire pace haptics during the settling window, while paused, while the zone is `neutral`, or during a VO2 Max workout. |
| AC-FR-B-1-5 | WHEN the runner returns to `onTarget`, THE SYSTEM SHALL reset the dwell timer so the next excursion is treated as new. |
| AC-FR-B-1-6 | THE SYSTEM SHALL deliver haptics while the app is backgrounded during an active workout session. |
| AC-FR-B-1-7 | THE SYSTEM SHALL allow pace haptics to be disabled entirely in settings without disabling interval haptics. |
| AC-FR-B-1-8 | GIVEN a one-hour simulated run that oscillates across the `tooFast` boundary every 25 s, THE SYSTEM SHALL fire no more than 60 haptics. |

<a id="fr-b-2--the-warning-screen"></a>
#### FR-B-2 — The warning screen

| AC | Criterion |
|---|---|
| AC-FR-B-2-1 | WHEN a pace haptic fires, THE SYSTEM SHALL present a full-screen warning stating the direction, the current pace, the target pace, and the signed difference. |
| AC-FR-B-2-2 | THE SYSTEM SHALL auto-dismiss the warning after 4 s *(tunable)*. |
| AC-FR-B-2-3 | THE SYSTEM SHALL dismiss the warning immediately on a screen tap or a crown rotation. See [CON-1](#con-1) for why this is not a crown press. |
| AC-FR-B-2-4 | WHEN the warning is dismissed, THE SYSTEM SHALL return to the metrics page in the same scroll position. |
| AC-FR-B-2-5 | THE SYSTEM SHALL NOT present a warning screen while the display is off or in the always-on dimmed state; the haptic alone SHALL suffice, and no warning SHALL be queued for later display. |
| AC-FR-B-2-6 | THE SYSTEM SHALL NOT allow a warning to obscure an interval transition; interval transitions take presentation priority. |

---

### EPIC C — Structured and VO2 Max workouts (P0)

> **User story.** As Track-less Theo, I want to run a warmup for as long as I like, then have the watch count out 4×1000 m with 1000 m jogs and buzz on its own at every changeover, then let me cool down and finish when I choose — all on a road loop, with no track and no mental arithmetic.

<a id="fr-c-1--workout-structure"></a>
#### FR-C-1 — Workout structure

| AC | Criterion |
|---|---|
| AC-FR-C-1-1 | THE SYSTEM SHALL represent a structured workout as an ordered list of steps, each with a kind (`warmup`, `work`, `recovery`, `cooldown`) and a goal. |
| AC-FR-C-1-2 | THE SYSTEM SHALL support goals of: open (manual advance), distance, and time. |
| AC-FR-C-1-3 | THE SYSTEM SHALL support repeat blocks with a count, so `4 × (1000 m work + 1000 m recovery)` is expressible without listing eight steps. |
| AC-FR-C-1-4 | THE SYSTEM SHALL support repeat counts from 1 to 40 and step distances from 100 m to 42 195 m. |
| AC-FR-C-1-5 | THE SYSTEM SHALL support the memo's canonical workout as a built-in preset: open warmup → 4 × (1000 m / 1000 m) → open cooldown. |
| AC-FR-C-1-6 | THE SYSTEM SHALL allow distances to be entered in metres, kilometres, or miles per the user's unit preference, and SHALL store them in metres. |

<a id="fr-c-2--automatic-advance"></a>
#### FR-C-2 — Automatic advance

| AC | Criterion |
|---|---|
| AC-FR-C-2-1 | WHEN a step has a distance goal and the distance covered *within that step* reaches the goal, THE SYSTEM SHALL advance to the next step without any user action. |
| AC-FR-C-2-2 | THE SYSTEM SHALL fire a haptic on every automatic advance, distinct from pace-alert haptics. |
| AC-FR-C-2-3 | THE SYSTEM SHALL advance within 1 s of the goal being met. |
| AC-FR-C-2-4 | THE SYSTEM SHALL measure step distance from the step's own start point, and SHALL NOT accumulate rounding error across steps — after 4 × 1000 m, total measured distance SHALL be within 0.1% of the sum of the step goals. |
| AC-FR-C-2-5 | WHEN the final step completes and it has a closed goal, THE SYSTEM SHALL advance to the next step; WHEN there is no next step, THE SYSTEM SHALL hold and prompt for manual end. |
| AC-FR-C-2-6 | THE SYSTEM SHALL display a transition screen naming the step just finished and the step now starting, for 3 s *(tunable)*. |
| AC-FR-C-2-7 | THE SYSTEM SHALL announce an upcoming automatic advance with a countdown in the final 100 m *(tunable)* of a work step. |

<a id="fr-c-3--manual-advance"></a>
#### FR-C-3 — Manual advance

| AC | Criterion |
|---|---|
| AC-FR-C-3-1 | WHEN the current step has an open goal, THE SYSTEM SHALL advance on a tap anywhere on the metrics page. |
| AC-FR-C-3-2 | *(Modern, Series 9+)* THE SYSTEM SHALL also advance on the Double Tap gesture. |
| AC-FR-C-3-3 | THE SYSTEM SHALL also advance via a crown-rotation detent when enabled in settings. |
| AC-FR-C-3-4 | WHEN the current step has a closed goal, THE SYSTEM SHALL NOT advance on tap — a tap SHALL be ignored — so a mis-tap cannot truncate a 1000 m rep. |
| AC-FR-C-3-5 | THE SYSTEM SHALL make the advance affordance visible on the metrics page whenever the step is manually advanceable. |

<a id="fr-c-4--vo2-max-mode"></a>
#### FR-C-4 — VO2 Max mode

| AC | Criterion |
|---|---|
| AC-FR-C-4-1 | THE SYSTEM SHALL offer VO2 Max as a distinct run type, separate from Interval. |
| AC-FR-C-4-2 | WHILE in VO2 Max mode, THE SYSTEM SHALL display a neutral background and SHALL NOT apply any zone colour. |
| AC-FR-C-4-3 | WHILE in VO2 Max mode, THE SYSTEM SHALL display the full metric stack: elapsed time, heart rate, rolling pace, average pace, distance. |
| AC-FR-C-4-4 | WHILE in VO2 Max mode, THE SYSTEM SHALL NOT fire pace haptics, and SHALL fire step-transition haptics. |
| AC-FR-C-4-5 | WHILE in VO2 Max mode, THE SYSTEM SHALL additionally display the current step, the rep number, and distance remaining in the step. |

> **Rationale.** The memo is precise about this: a VO2 max session is a *test of capability*, so prescribing a pace would contaminate the measurement. Interval mode, by contrast, may carry per-step pace targets — that is the distinction between the two run types.

<a id="fr-c-5--interval-mode-with-targets"></a>
#### FR-C-5 — Interval mode with per-step targets

| AC | Criterion |
|---|---|
| AC-FR-C-5-1 | THE SYSTEM SHALL permit each step in an Interval workout to carry its own target pace and band. |
| AC-FR-C-5-2 | WHEN a step carries a target, THE SYSTEM SHALL apply zone colouring and pace haptics for that step. |
| AC-FR-C-5-3 | WHEN a step carries no target, THE SYSTEM SHALL display the neutral background for that step. |
| AC-FR-C-5-4 | WHEN a step begins, THE SYSTEM SHALL apply a per-step settling window of 100 m *(tunable)* before colouring. |

<a id="fr-c-6--undo-a-manual-advance"></a>
#### FR-C-6 — Undo a manual advance

| AC | Criterion |
|---|---|
| AC-FR-C-6-1 | WHEN a manual advance occurs, THE SYSTEM SHALL offer an undo affordance for 5 s *(tunable)*. |
| AC-FR-C-6-2 | WHEN undo is taken, THE SYSTEM SHALL restore the previous step with its accumulated distance and time intact. |

---

### EPIC D — Workout lifecycle and data capture (P0)

<a id="fr-d-1--session-management"></a>
#### FR-D-1 — Session management

| AC | Criterion |
|---|---|
| AC-FR-D-1-1 | THE SYSTEM SHALL request HealthKit and location authorization before the first run, explaining why each is needed. |
| AC-FR-D-1-2 | WHEN a run starts, THE SYSTEM SHALL begin an `HKWorkoutSession` of activity type running with the correct indoor/outdoor location type. |
| AC-FR-D-1-3 | THE SYSTEM SHALL support pause and resume, and SHALL exclude paused time from elapsed time, average pace, and step progress. |
| AC-FR-D-1-4 | WHEN a run ends, THE SYSTEM SHALL save an `HKWorkout` with distance, energy, heart rate, and a workout route. |
| AC-FR-D-1-5 | *(Modern)* THE SYSTEM SHALL record each step as a native workout activity so other apps can read the interval structure. |
| AC-FR-D-1-6 | *(Legacy)* THE SYSTEM SHALL record each step boundary as a workout event, the watchOS 8 equivalent. |
| AC-FR-D-1-7 | WHEN the user declines HealthKit authorization, THE SYSTEM SHALL still permit runs and SHALL store them locally, with a clear indication that they are not written to Health. |

<a id="fr-d-2--sample-capture"></a>
#### FR-D-2 — Sample capture

| AC | Criterion |
|---|---|
| AC-FR-D-2-1 | THE SYSTEM SHALL record at 1 Hz: timestamp, cumulative distance, rolling pace, heart rate, relative altitude, smoothed grade, applied grade factor, effective target pace, and zone. |
| AC-FR-D-2-2 | THE SYSTEM SHALL record per-step summaries: kind, index, rep number, distance, elapsed time, average pace, average heart rate, max heart rate, elevation change. |
| AC-FR-D-2-3 | THE SYSTEM SHALL record a zone timeline as a run-length-encoded series, not one entry per sample. |
| AC-FR-D-2-4 | THE SYSTEM SHALL keep a 90-minute run's captured payload under 1 MB before compression. |

<a id="fr-d-6--crash-and-interruption-durability"></a>
#### FR-D-6 — Crash and interruption durability

| AC | Criterion |
|---|---|
| AC-FR-D-6-1 | THE SYSTEM SHALL flush captured samples to durable local storage at least every 30 s *(tunable)*. |
| AC-FR-D-6-2 | WHEN the app is terminated mid-run, THE SYSTEM SHALL on next launch detect the orphaned run and offer to save or discard it. |
| AC-FR-D-6-3 | WHEN the workout session is terminated by another app taking the system's single workout slot ([CON-5](#con-5)), THE SYSTEM SHALL treat it as an interruption, preserve data captured so far, and inform the user. |
| AC-FR-D-6-4 | THE SYSTEM SHALL never lose more than 30 s of run data to an unexpected termination. |

---

### EPIC E — Watch ↔ iPhone sync (P0)

<a id="fr-e-1--transfer"></a>
#### FR-E-1 — Transfer

| AC | Criterion |
|---|---|
| AC-FR-E-1-1 | WHEN a run ends, THE SYSTEM SHALL enqueue its payload for background transfer to the iPhone without requiring the iPhone to be reachable at that moment. |
| AC-FR-E-1-2 | THE SYSTEM SHALL retain a run's payload on the watch until the iPhone acknowledges it. |
| AC-FR-E-1-3 | THE SYSTEM SHALL deduplicate on a run identifier so a re-delivered payload does not create a duplicate record. |
| AC-FR-E-1-4 | THE SYSTEM SHALL version the payload schema and SHALL reject payloads whose major version it does not understand, with a clear message rather than a crash. |
| AC-FR-E-1-5 | WHEN watch storage for pending payloads exceeds 50 MB or 50 runs *(tunable)*, THE SYSTEM SHALL evict oldest-acknowledged-first and SHALL never evict an unacknowledged payload in favour of an acknowledged one. |
| AC-FR-E-1-6 | WHEN a payload is lost, THE SYSTEM SHALL be able to reconstruct a degraded run record from HealthKit alone, flagged as degraded. |
| AC-FR-E-1-7 | THE SYSTEM SHALL deliver a completed run to the iPhone within 60 s of the iPhone becoming reachable. |

---

### EPIC F — iPhone statistics hub (P0 — highest-priority phone feature)

> **User story.** As Structured Sam, I want to open my phone after a tempo run and see exactly where I drifted, so that I know whether to adjust my target for next time.

<a id="fr-f-1--run-list"></a>
#### FR-F-1 — Run list

| AC | Criterion |
|---|---|
| AC-FR-F-1-1 | THE SYSTEM SHALL list completed runs newest-first with date, run type, distance, duration, average pace, and average heart rate. |
| AC-FR-F-1-2 | THE SYSTEM SHALL support filtering by run type and by date range. |
| AC-FR-F-1-3 | THE SYSTEM SHALL render a list of 1 000 runs with scrolling that stays at 60 fps. |
| AC-FR-F-1-4 | WHEN there are no runs, THE SYSTEM SHALL show an empty state explaining how to record the first one. |

<a id="fr-f-2--run-detail"></a>
#### FR-F-2 — Run detail

| AC | Criterion |
|---|---|
| AC-FR-F-2-1 | THE SYSTEM SHALL show a pace-over-distance chart with the Target Pace Curve and the band overlaid, so compliance is visible at a glance. |
| AC-FR-F-2-2 | THE SYSTEM SHALL show a heart-rate chart on a shared x-axis with pace. |
| AC-FR-F-2-3 | THE SYSTEM SHALL show an elevation profile and, where grade adjustment was applied, the adjusted target alongside the raw target. |
| AC-FR-F-2-4 | THE SYSTEM SHALL show time-in-zone as a distribution, in both seconds and percentage. |
| AC-FR-F-2-5 | THE SYSTEM SHALL show a per-step table for structured workouts, with each rep's distance, time, average pace, and average heart rate. |
| AC-FR-F-2-6 | THE SYSTEM SHALL show splits per mile or per kilometre per the unit preference. |
| AC-FR-F-2-7 | WHERE a route was recorded, THE SYSTEM SHALL show it on a map coloured by zone. |
| AC-FR-F-2-8 | THE SYSTEM SHALL open a 90-minute run's detail view in under 1 s on an iPhone 12. |
| AC-FR-F-2-9 | THE SYSTEM SHALL make every chart legible without colour alone, and SHALL provide the underlying values via VoiceOver. |

<a id="fr-f-3--global-statistics"></a>
#### FR-F-3 — Global statistics

| AC | Criterion |
|---|---|
| AC-FR-F-3-1 | THE SYSTEM SHALL show lifetime totals: total distance, total moving time, total runs, total elevation gain. |
| AC-FR-F-3-2 | THE SYSTEM SHALL show the same totals for this week, this month, and this year. |
| AC-FR-F-3-3 | THE SYSTEM SHALL show a weekly distance chart for the trailing 52 weeks. |
| AC-FR-F-3-4 | THE SYSTEM SHALL show personal bests for 1 km, 1 mile, 5 km, 10 km, half marathon, and marathon, computed as best rolling segment within any run, not only from runs of exactly that distance. |
| AC-FR-F-3-5 | THE SYSTEM SHALL recompute aggregates incrementally on ingest, and SHALL NOT rescan all runs to render the statistics screen. |
| AC-FR-F-3-6 | THE SYSTEM SHALL render global statistics in under 300 ms with 1 000 runs stored. |

---

### EPIC G — Planning and training schedules (P1)

<a id="fr-g-1--plan-a-run"></a>
#### FR-G-1 — Plan a single run

| AC | Criterion |
|---|---|
| AC-FR-G-1-1 | THE SYSTEM SHALL let the user schedule a run on a future date with a type, a distance or duration, and an optional target pace. |
| AC-FR-G-1-2 | THE SYSTEM SHALL let the user compose a custom structured workout with arbitrary steps and repeat blocks. |
| AC-FR-G-1-3 | THE SYSTEM SHALL push planned workouts to the watch so they appear on the start screen on the day. |
| AC-FR-G-1-4 | THE SYSTEM SHALL validate a custom workout before saving and SHALL reject one with zero steps or a non-final open-goal step followed by no closed step. |

<a id="fr-g-2--training-plan-generation"></a>
#### FR-G-2 — Training plan generation

> **User story.** As Returning Rosa, I want to tell the app "half marathon in 12 weeks" and get a week-by-week schedule I can actually follow.

| AC | Criterion |
|---|---|
| AC-FR-G-2-1 | THE SYSTEM SHALL generate a plan from: goal distance, goal date, days available per week, and current fitness. |
| AC-FR-G-2-2 | THE SYSTEM SHALL derive current fitness from the user's recent runs where available, and SHALL fall back to asking for a recent race result. |
| AC-FR-G-2-3 | THE SYSTEM SHALL derive training paces from a fitness score using an established model, and SHALL show the derived Easy, Marathon, Threshold, Interval, and Repetition paces. |
| AC-FR-G-2-4 | THE SYSTEM SHALL periodize the plan into base, build, peak, and taper phases. |
| AC-FR-G-2-5 | THE SYSTEM SHALL NOT increase weekly volume by more than 10% week-over-week. |
| AC-FR-G-2-6 | THE SYSTEM SHALL insert a reduced-volume week of −25% *(tunable)* every fourth week. |
| AC-FR-G-2-7 | THE SYSTEM SHALL include at least one full rest day in every week. |
| AC-FR-G-2-8 | THE SYSTEM SHALL keep the long run between 20% and 30% of weekly volume. |
| AC-FR-G-2-9 | THE SYSTEM SHALL reduce volume monotonically through the taper. |
| AC-FR-G-2-10 | WHEN the requested goal cannot be reached without violating AC-FR-G-2-5, THE SYSTEM SHALL say so explicitly, and SHALL offer the nearest achievable goal date or distance rather than silently generating an unsafe plan. |
| AC-FR-G-2-11 | THE SYSTEM SHALL let the user regenerate, shift, or delete the plan at any time without losing recorded run history. |

<a id="fr-g-3--todays-workout"></a>
#### FR-G-3 — Today's workout

| AC | Criterion |
|---|---|
| AC-FR-G-3-1 | WHEN the user is following a plan, THE SYSTEM SHALL show a one-line summary of today's prescribed run — for example `4 × 1000 m` or `4 mi easy` — on the iPhone home screen. |
| AC-FR-G-3-2 | THE SYSTEM SHALL show the same summary on the watch start screen for that day. |
| AC-FR-G-3-3 | WHEN today is a rest day, THE SYSTEM SHALL say so. |
| AC-FR-G-3-4 | THE SYSTEM SHALL mark a planned workout complete when a matching run is recorded, and SHALL show plan adherence over the trailing 4 weeks. |

---

### EPIC H — Routes, laps, and custom runs (P2)

<a id="fr-h-1--routes"></a>
#### FR-H-1 — Saved routes

| AC | Criterion |
|---|---|
| AC-FR-H-1-1 | THE SYSTEM SHALL let the user save a completed run's route with a name. |
| AC-FR-H-1-2 | THE SYSTEM SHALL show a saved route's distance, elevation gain, and every past run on it. |
| AC-FR-H-1-3 | THE SYSTEM SHALL let the user compare their efforts on the same route over time. |

<a id="fr-h-2--laps"></a>
#### FR-H-2 — Saved laps

| AC | Criterion |
|---|---|
| AC-FR-H-2-1 | THE SYSTEM SHALL let the user designate a route as a lap. |
| AC-FR-H-2-2 | THE SYSTEM SHALL let the user define a new route as a saved lap repeated *n* times, computing total distance and elevation as *n* × the lap's. |
| AC-FR-H-2-3 | THE SYSTEM SHALL let a lap-derived route be used as the distance basis for a planned run. |

---

### EPIC I — Profile and pace derivation (P0)

<a id="fr-i-1--profile"></a>
#### FR-I-1 — Runner profile

| AC | Criterion |
|---|---|
| AC-FR-I-1-1 | THE SYSTEM SHALL store per-run-type target paces: tempo, easy, long. |
| AC-FR-I-1-2 | THE SYSTEM SHALL offer to derive these from a recent race result or a recent hard effort, rather than requiring the user to know them. |
| AC-FR-I-1-3 | THE SYSTEM SHALL let every derived pace be overridden manually. |
| AC-FR-I-1-4 | THE SYSTEM SHALL support miles and kilometres throughout, defaulting from the device locale, changeable at any time, with all stored data unit-independent. |
| AC-FR-I-1-5 | WHEN a user has completed 5 or more runs of a type, THE SYSTEM SHALL offer an updated target pace suggestion based on actual performance, and SHALL require explicit confirmation before changing anything. |
| AC-FR-I-1-6 | THE SYSTEM SHALL sync the profile to the watch, and the watch SHALL function on the last-synced profile with no phone present. |

---

### EPIC J — Accessibility (P0)

<a id="fr-j-1--colour-is-never-the-only-channel"></a>
#### FR-J-1 — Colour is never the only channel

| AC | Criterion |
|---|---|
| AC-FR-J-1-1 | THE SYSTEM SHALL display, on every zone screen, a direction glyph encoding the zone independently of colour. |
| AC-FR-J-1-2 | THE SYSTEM SHALL display a signed pace delta against the current target, in the user's units. |
| AC-FR-J-1-3 | THE SYSTEM SHALL keep every text element at a contrast ratio of at least 4.5:1 against its zone background, in both normal and dimmed variants, for every palette. |
| AC-FR-J-1-4 | THE SYSTEM SHALL verify AC-FR-J-1-3 numerically in an automated test, for the full cross-product of palette × zone × luminance state. |

<a id="fr-j-2--colour-vision-deficiency-palette"></a>
#### FR-J-2 — Colour vision deficiency palette

| AC | Criterion |
|---|---|
| AC-FR-J-2-1 | THE SYSTEM SHALL offer an alternate diverging palette that does not rely on the red–green axis. |
| AC-FR-J-2-2 | THE SYSTEM SHALL keep all five zone colours mutually distinguishable under simulated protanopia, deuteranopia, and tritanopia, verified numerically in an automated test. |
| AC-FR-J-2-3 | THE SYSTEM SHALL make the palette choice available during onboarding, not buried in settings. |

<a id="fr-j-3--general-accessibility"></a>
#### FR-J-3 — General accessibility

| AC | Criterion |
|---|---|
| AC-FR-J-3-1 | THE SYSTEM SHALL label every interactive element for VoiceOver. |
| AC-FR-J-3-2 | THE SYSTEM SHALL announce zone changes to VoiceOver users. |
| AC-FR-J-3-3 | THE SYSTEM SHALL honour Reduce Motion by cross-fading rather than animating colour transitions. |
| AC-FR-J-3-4 | THE SYSTEM SHALL remain usable at the largest Dynamic Type size, with metrics reflowing rather than truncating. |

---

### EPIC K — Legacy tier parity (P0 for G-6)

<a id="fr-k-1--parity"></a>
#### FR-K-1 — Legacy tier scope

| AC | Criterion |
|---|---|
| AC-FR-K-1-1 | THE SYSTEM SHALL deliver on Legacy: all of Epic A, Epic B, Epic C, Epic D, and Epic E. |
| AC-FR-K-1-2 | THE SYSTEM SHALL produce byte-identical pace-engine output on both tiers for the same input trace, verified by running the same fixtures against both tiers' adapters. |
| AC-FR-K-1-3 | THE SYSTEM SHALL document every Legacy divergence in the tier matrix in `design.md`, and SHALL keep that matrix accurate as a review requirement. |
| AC-FR-K-1-4 | THE SYSTEM SHALL NOT share any source file between `Apps/WatchModern` and `Apps/WatchLegacy` other than through `Core`. |
| AC-FR-K-1-5 | THE SYSTEM SHALL fail CI when a version-availability conditional appears in either watch app target. |

---

## 8. Cross-cutting: degraded modes

Every one of these is a state the app must handle explicitly, not an error to be surfaced raw.

| ID | Condition | Required behaviour |
|---|---|---|
| DEG-1 | GPS unavailable or poor | Fall back to pedometer pace; show indicator; keep colouring but widen bands by 50% *(tunable)* |
| DEG-2 | Altimeter unavailable | Grade factor pinned to 1.0; hill indicator hidden; noted in run record |
| DEG-3 | Heart rate dropout | Show `--`; do not affect pace logic |
| DEG-4 | Workout session pre-empted ([CON-5](#con-5)) | Preserve data; inform user; offer save on relaunch |
| DEG-5 | Watch battery < 10% | Offer a low-power mode: reduce GPS duty cycle, drop sample rate to 0.2 Hz, keep colour and haptics |
| DEG-6 | Watch storage full | Refuse to start a run with a clear message rather than starting and losing data |
| DEG-7 | iPhone unreachable for days | Queue transfers; no data loss; no user action required |
| DEG-8 | HealthKit authorization denied | Runs still record locally; state clearly that Health is not being written |
| DEG-9 | No profile / no target pace set | Offer to derive; permit an untargeted run with neutral colouring |
| DEG-10 | Run started indoors (treadmill) | Use pedometer distance; disable grade adjustment; no route |

---

## 9. Non-functional requirements

### 9.1 Performance

| ID | Requirement |
|---|---|
| NFR-1 | Zone evaluation SHALL complete in under 5 ms per tick on Series 3. |
| NFR-2 | The run screen SHALL sustain its refresh without dropped frames on Series 3. |
| NFR-3 | App launch to run-start screen SHALL be under 2 s on Series 3 and under 1 s on Modern. |
| NFR-4 | iPhone run detail SHALL open in under 1 s for a 90-minute run on an iPhone 12. |
| NFR-5 | Global statistics SHALL render in under 300 ms with 1 000 runs. |

### 9.2 Battery

| ID | Requirement |
|---|---|
| NFR-6 | A 60-minute outdoor GPS run SHALL consume no more than 25% of a Series 7 battery. |
| NFR-7 | Low-power mode (DEG-5) SHALL reduce consumption by at least 30% relative to normal. |
| NFR-8 | The app SHALL hold no wake locks and start no timers outside an active workout session. |

### 9.3 Accuracy

| ID | Requirement |
|---|---|
| NFR-9 | Interval auto-advance SHALL trigger within ±15 m of the goal under good GPS. |
| NFR-10 | Total recorded distance SHALL be within 1% of the sum of step goals for a track-verified 4 × 1000 m session. |
| NFR-11 | Grade adjustment SHALL match published GAP behaviour within ±5% for grades in [−3%, +3%]. |

### 9.4 Reliability

| ID | Requirement |
|---|---|
| NFR-12 | No more than 30 s of run data SHALL be lost to any single crash or interruption. |
| NFR-13 | Sync SHALL be at-least-once with idempotent ingest; duplicate delivery SHALL NOT create duplicate records. |

### 9.5 Privacy & security

| ID | Requirement |
|---|---|
| NFR-14 | OptimalRunner 1.0 SHALL operate entirely on-device. No run data, route data, or health data SHALL leave the user's devices. |
| NFR-15 | The app SHALL contain no analytics, telemetry, advertising, or third-party SDK that transmits data. |
| NFR-16 | Location SHALL be requested as when-in-use, escalated only for active workouts. |
| NFR-17 | Route data SHALL be excluded from any diagnostic export by default. |

### 9.6 Maintainability & open source

| ID | Requirement |
|---|---|
| NFR-18 | CI SHALL fail on: `#available` in a watch app target; Apple-framework imports in `Core`; a drop in `Core` line coverage below 85%. |
| NFR-19 | `Core` SHALL have zero dependencies on Apple frameworks and SHALL build and test on Linux. |
| NFR-20 | A clean clone SHALL build and run the full test suite in ≤15 minutes following only the README. |
| NFR-21 | Every tunable constant SHALL be declared in exactly one configuration type, with its default and permitted range. |
| NFR-22 | The repository SHALL carry a contributor guide, an architecture overview, and per-directory READMEs naming what belongs there. |

### 9.7 Internationalization

| ID | Requirement |
|---|---|
| NFR-23 | All user-facing strings SHALL be localizable; none SHALL be concatenated from fragments. |
| NFR-24 | Pace, distance, and elevation SHALL respect the unit preference everywhere, including charts and VoiceOver output. |

---

## 10. Priority summary

| Priority | Epics | Rationale |
|---|---|---|
| **P0** | A, B, C, D, E, F, I, J, K | Watch pace management and intervals are the product. iPhone past-run statistics is explicitly the most important phone baseline. Profile, accessibility, and Legacy parity are prerequisites, not extras. |
| **P1** | G | Planning and schedule generation — explicitly medium priority. |
| **P2** | H | Routes, laps, custom-run composition — explicitly low priority. |

---

## 11. Risks

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R-1 | Xcode 27's SDK becomes mandatory (~Apr 2027) and the Legacy target stops building ([CON-2](#con-2)) | High | Medium | Legacy is fully isolated; removal is one directory and one CI job. Ship it while the window is open. |
| R-2 | GPS pace noise makes the colour flicker and users lose trust | Medium | High | Distance-windowed rolling pace, hysteresis, settling window, dwell-gated haptics — all independently unit-tested against recorded traces |
| R-3 | Auto-advance fires late under poor GPS, so 1000 m reps run long | Medium | High | Pedometer fusion; countdown in the last 100 m; per-step distance measured independently |
| R-4 | Users find the full-screen colour alarming or exhausting | Medium | Medium | Settling window; hysteresis; a calmer palette option; 400 ms transitions |
| R-5 | Tap-to-advance is triggered accidentally by sleeve or rain | Medium | Medium | Tap only advances open-goal steps; undo affordance; End requires the Controls page |
| R-6 | Generated training plans injure someone | Low | High | Hard caps on volume progression; mandatory rest day; explicit refusal to generate unsafe plans; medical disclaimer at onboarding |
| R-7 | Two watch codebases diverge in behaviour | Medium | Medium | All judgement logic lives in `Core`; shared fixtures assert identical output on both tiers (AC-FR-K-1-2) |
| R-8 | SwiftData performance with large sample sets | Medium | Medium | Samples stored as packed binary blobs, not rows; incremental aggregates |

---

## 12. Traceability

Every requirement is traced in both directions:

- `design.md` §17 maps each `FR-*` and `NFR-*` to the component that implements it and the test that verifies it.
- `implementation.md` tags every task `T-###` with the requirement IDs it satisfies, and includes a completeness check asserting that every P0 requirement has at least one covering task.

CI runs `Tools/check-traceability.swift`, which parses all three documents and fails if any P0 requirement is unreferenced by a task, or if any task references a requirement ID that does not exist.

---

## 13. References

Physiology and pacing:

- Minetti, A. E., et al. (2002). "Energy cost of walking and running at extreme uphill and downhill slopes." *Journal of Applied Physiology* 93(3). — [journals.physiology.org](https://journals.physiology.org/doi/full/10.1152/japplphysiol.01177.2001) · [PubMed](https://pubmed.ncbi.nlm.nih.gov/12183501/)
- "The physiology and psychology of negative splits: insights into optimal marathon pacing strategies." — [PMC12307312](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12307312/)
- "Developing negative split pacing in endurance athletes: practical guidelines and training models." — [PMC12832444](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12832444/)
- Coyle & González-Alonso on cardiovascular drift; overview at [Uphill Athlete](https://uphillathlete.com/aerobic-training/heart-rate-drift/) and [Marathon Handbook](https://marathonhandbook.com/cardiac-drift/)
- Daniels' VDOT training-pace model — [Fellrnr summary](https://fellrnr.com/wiki/Jack_Daniels), [pace tables](https://www.brenoamelo.com/blog/vdot-pace-chart-printable)
- Riegel race-prediction formula, exponent 1.06 — [RunnersConnect](https://runnersconnect.net/race-calculators/), [accuracy analysis](https://www.runpacelab.com/guides/riegel-formula-accuracy/)

Grade adjustment:

- [Strava — Grade Adjusted Pace](https://support.strava.com/hc/en-us/articles/216917067-Grade-Adjusted-Pace-GAP)
- Schroeder, A. — [Reverse-engineering Strava's Grade Adjusted Pace](https://aaron-schroeder.github.io/reverse-engineering/grade-adjusted-pace.html)
- [Fellrnr — Grade Adjusted Pace](https://fellrnr.com/wiki/Grade_Adjusted_Pace)

Platform:

- Digital Crown press is not interceptable — [Apple Developer Forums](https://forums.developer.apple.com/forums/thread/49479)
- watchOS 11 drops Series 4 / 5 — [Tom's Guide](https://tomsguide.com/wellness/smartwatches/watchos-11-compatibility-see-if-your-apple-watch-is-update-eligible)
- Xcode 27 raises the minimum watchOS deployment target to 9.0 — [home-assistant/iOS#4749](https://github.com/home-assistant/iOS/issues/4749)
- App Store minimum SDK requirements — [Apple Developer News](https://developer.apple.com/news/upcoming-requirements/)
- Background haptics require an active workout session — [Ivan Parfenchuk](https://blog.theivan.io/watchkit/2020/02/02/apple-watch-haptics-in-background.html)
- `isLuminanceReduced` and always-on UI — [WWDC21: What's new in watchOS 8](https://developer.apple.com/videos/play/wwdc2021/10002/)
- Series 3 barometric altimeter — [Cycling Weekly](https://www.cyclingweekly.com/news/product-news/apple-watch-series-3-altimeter-350918)
