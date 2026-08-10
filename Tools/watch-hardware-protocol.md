# Modern watch — the one-outing hardware protocol

| Field | Value |
|---|---|
| Document | `Tools/watch-hardware-protocol.md` |
| Hardware | Apple Watch SE 3, watchOS 26 |
| Tasks | [T-098](../docs/implementation.md#t-098), [T-100](../docs/implementation.md#t-100), and Wave 2's outstanding hardware list |
| Closes | AC-FR-A-6-3, AC-FR-A-6-6, AC-FR-A-6-8, AC-FR-B-1-3, AC-FR-B-1-6, AC-FR-B-2-3, AC-FR-C-3, AC-FR-D-1-1…4, DEG-1, DEG-2 |
| Companion | [`Tools/manual-test-protocol.md`](./manual-test-protocol.md) §7 |

---

## What this outing is for

**Wave 2 shipped in July with eight items marked "requires physical hardware" and no hardware to
run them on.** They have been unverified since — not because they were unimportant, but because
nothing could reach them. This is the first outing with a real watch, and it also has to cover the
watchOS 26 work that landed on 2026-08-09.

It is designed for **one run of about 4.3 miles**, and it is sequenced rather than concatenated.
Reading the old checklists end to end and hoping they fit would not have worked: three of them
require *not looking at the screen* while four require looking closely at it, and one requires a
gesture that only functions during two specific steps of a structured workout.

---

## The constraint that shapes everything below

**No single recording can cover this list, and the reason is in the code rather than in the
plan.**

The watch's own Interval preset is `WorkoutPresets.intervals(reps: 4, workMetres: 800,
recoveryMetres: 400)` and it passes **no `workTarget`**. `RunTypeSemantics.target(for:)` returns
`nil` for a step with no target of its own, so an interval session started from the watch is
**never judged**: no zone colour, no pace haptics, no pace warnings. Meanwhile Double Tap advances
only an **open-goal** step (`canAdvanceManually: step.goal.isOpen`), and the only open-goal steps in
that plan are the warmup and the cooldown.

So the two halves of the list want different runs:

| Needs | Only available in |
|---|---|
| Steps, rep counter, transitions, transition haptics, final-100 m countdown, undo, **Double Tap on a step that is not the last one** | An **Interval** run |
| Zone colour, pace haptics, the pace warning screen, the 400 ms cross-fade | A **continuous** run — tempo, easy or long |

**The outing is therefore two recordings back to back, not two outings.** Run A is the structured
work, Run B is the pace-judged work, and you do not stop moving between them. That split is forced
by the product, so it is stated here rather than hidden in the step list.

> **Worth raising separately, and deliberately not fixed for this outing:** a runner who selects
> *Interval* on the watch gets no colour and no pace feedback during their hardest session of the
> week. `FR-C-5` explicitly permits interval steps to be judged, and the preset declines to. That
> may be intended — an 800 m rep is run on feel — but it is worth a decision rather than a default.

---

## Section 0 — Before you leave the house

Do this at a table. Two of these can only ever be done once.

### 0.1 Install fresh — this is the only chance at the authorization sheets

**Delete the app from the watch first if it is already there.** HealthKit's authorization sheet
appears exactly once per install, and AC-FR-D-1-1 is specifically about the *rationale strings* the
runner sees on it.

1. Build and install: open `Apps/WatchModern/OptimalRunnerWatch.xcodeproj`, set a signing team,
   run to the watch.
2. Start any run. When the sheets appear, **read them and photograph them**:

| Sheet | What must be true | Requirement |
|---|---|---|
| Health | Says it saves runs *including distance, heart rate and route*, and reads heart rate to show it live | AC-FR-D-1-1 |
| Location | Says location is used only during an active run and is never transmitted | AC-FR-D-1-1 |
| Motion | Says motion estimates pace when GPS is unavailable | AC-FR-D-1-1 |

3. **Grant everything.** Denial behaviour (AC-FR-D-1-7) is already covered on the Legacy tier in
   `manual-test-protocol.md` §6.2 and would cost this outing its HealthKit result.
4. End that run immediately and discard it.

### 0.2 Confirm the two gestures are actually on

Both are Settings toggles and both default differently between watches. If Double Tap is off, the
central new feature of this build silently does nothing and you will conclude it is broken.

- **Settings → Gestures → Double Tap** — must be **on**.
- **Settings → Gestures → Wrist Flick** — note whether it is on or off. Either is fine; you need to
  know which, to interpret §A.6.
- In the app: **Settings → crown advance** — leave it **off** for this outing. It shares an
  affordance with Double Tap and having both live makes an ambiguous result.

### 0.3 The design-system audit, static surfaces (T-098)

watchOS 26 restyles controls and toolbars automatically. Before running, look at each screen and
record whether anything is translucent, inset, or letterboxed that was not before:

| Screen | Look for |
|---|---|
| Start screen, run-type list | Any new material behind the list; run names still legible |
| Settings, and each picker inside it | Picker rows still readable; nothing clipped at 44 mm |
| Controls page (swipe right during the discarded run) | Pause/End targets still full width, still unambiguous |

**Anything that changed goes on the sheet at the end.** The metrics page is audited in motion, in
§A.1.

---

## Run A — Interval, 4 × 800 m with 400 m recovery

**Distance ≈ 3.4 mi. Time ≈ 34 min.** Select **Interval** on the start screen; the preset above is
what you get.

### A.1 Warmup — the design-system audit in motion, and GPS acquisition

Run easy for **about 600 m**. While you do:

- **Watch the screen fill.** It must reach the physical edges with no inset, no letterbox and no
  translucent material over the colour, on a curved 44 mm display (AC-FR-A-6-1, and T-098's real
  test). The warmup is untargeted, so expect the **neutral** background — you are auditing geometry
  here, not colour.
- **Check all five metrics are legible at a glance** without truncation (AC-FR-A-6-5).
- **GPS acquisition (DEG-1):** note roughly how long until distance starts advancing sensibly. If
  the first 100 m is obviously wrong, note it — this tier has never been tested outdoors.

### A.2 The Double Tap that matters — end the warmup

This is the single most important gesture of the outing, and the warmup is the **only**
non-destructive place to test it: on a continuous run the equivalent step is the last one, so
advancing it ends the run.

1. With the metrics page on screen, **double tap** — index finger and thumb, twice.
2. **It must advance to Work rep 1.** A 3 s transition screen appears and a transition haptic fires.

| Record | |
|---|---|
| Did it advance on the first attempt? | |
| How many attempts did it take? | |
| Did the screen dim or flash when it fired? | **It must not.** The advance button renders its label untouched precisely so the zone colour never changes on touch |

3. **Immediately look for the undo affordance.** It is on screen for **5 s** after a manual advance
   (`intervals.undoWindowSeconds`). Do not tap it — just confirm it appears and then disappears.

> If Double Tap does nothing at all: check §0.2 first, then try a **single deliberate tap** on the
> screen. If tap advances and Double Tap does not, that is a real finding and the run is still
> valid — carry on and note it.

### A.3 Rep 1 — the countdown and the transition

Run the 800 m at a comfortable effort. There is no target, so the screen stays neutral; that is
correct, not a fault.

- **At 700 m the final-100 m countdown appears.** Confirm it is legible while running hard.
- **At 800 m:** transition haptic, then the 3 s transition screen naming the next step.

### A.4 Recovery 1 — always-on dimmed rendering (AC-FR-A-6-6)

The simulator cannot enter the true always-on state, which is why this has never been checked.

1. Jog the recovery with your **wrist down and the screen left to sleep** — about **30 seconds**.
2. Then **look at the watch without raising your wrist to wake it.** Tilt your head, not your arm.

| Record | |
|---|---|
| Is the dimmed panel readable at all? | |
| Which metrics survive dimming? | |
| Is the zone colour still identifiable, or does dimming flatten it? | |

3. Now **raise your wrist properly** and time how long until the screen shows the correct colour and
   live values. **Under 500 ms** (AC-FR-A-6-8) — it should feel instant; note it if it does not.

### A.5 Rep 2 — background haptic delivery (AC-FR-B-1-6)

The one that needs a real workout session holding a background assertion with the screen asleep.

1. Run the rep with your **arm down and the screen asleep** for the whole second half — from about
   400 m into the rep. **Do not look at the watch.**
2. **The transition haptic at 800 m must still reach your wrist**, with the app backgrounded and the
   screen off.

| Record | |
|---|---|
| Did the haptic fire with the screen asleep? | **This is the pass/fail.** |
| Did it feel weaker or later than the one in §A.3? | |

### A.6 Recovery 2 — wrist flick, and whether it costs you the run screen

Wrist flick is new in watchOS 26, is supported on SE 3, and returns to the watch face. Nobody has
checked what that does mid-run.

1. **Flick your wrist** — turn it over and back — while the run is active and the metrics page is up.
2. Record what happens:

| Record | |
|---|---|
| Did it leave the app for the watch face? | |
| If so, how did you get back — Digital Crown, or did it return by itself? | |
| Did the run keep recording throughout? | **It must.** |

If it does leave the app, that is worth knowing before a runner discovers it at mile 8, and it is a
one-line note in the README rather than a defect.

### A.7 Rep 3 — the transition screen and the crown

AC-FR-B-2-3 is written about the warning screen, and Run B tests it there. The transition screen is
the same presentation mechanism, so it is worth one attempt here where it costs nothing.

- At the 800 m transition, **rotate the crown** during the 3 s transition screen. Note whether it
  dismisses early.

### A.8 Recovery 3 — the Controls page

- **Swipe right** to Controls (AC-FR-A-6-9). Audit it for the design-system change: are Pause and
  End still full-width and unambiguous?
- **Pause, wait 10 s, Resume.** Confirm elapsed time does not count the pause and distance does not
  jump on resume.
- Swipe back to Metrics.

### A.9 Rep 4, Recovery 4 — free

Nothing scheduled. Use it to repeat anything above that was ambiguous, especially §A.2 if Double Tap
was uncertain.

### A.10 Cooldown — the second Double Tap

The cooldown is the plan's other open-goal step.

1. Run ~100 m of cooldown.
2. **Double tap** to advance. This completes the plan.
3. Note whether the completion haptic is distinguishable from the transition haptic (feeds §C.1).

**Do not stop moving.** Keep jogging while you set up Run B.

---

## Run B — Tempo, about 0.9 mi

**Distance ≈ 0.9 mi. Time ≈ 9 min.** Start a **Tempo** run. Everything here is pace-judged, which is
why it cannot be part of Run A.

### The numbers you are working against

**Read your target off the watch before you start — do not use the number below as gospel.** The
metrics page shows the target pace in force, and it comes from the profile's tempo pace, which has
been edited several times across the exported runs (the five in `captures/exported_runs/` carry
three different tempo targets). The figures below are worked for a **9:22/mi** target because that
is what the 4.3 mi validation run measured; if your watch says something else, shift the whole
column by the difference.

A tempo run uses `PaceBand.tempo`, which is symmetric — 2% and 5% on both sides:

| Zone | Pace ratio | Worked at a 9:22/mi target |
|---|---|---|
| **tooFast** (red) | ≥5% faster | **faster than 8:54/mi** |
| slightlyFast (amber) | 2–5% faster | 8:54 – 9:11 /mi |
| **onTarget** (green) | within 2% | 9:11 – 9:33 /mi |
| slightlySlow (turquoise) | 2–5% slower | 9:33 – 9:50 /mi |
| **tooSlow** (blue) | ≥5% slower | **slower than 9:50/mi** |

The rule that survives a different target: **30 s/mi faster than target is comfortably red, 30 s/mi
slower is comfortably blue**, because 5% of a 9–10 min mile is about 28–30 s.

Three timings govern whether a haptic fires at all:

- **Settling: the first 400 m or 90 s shows neutral.** Colour will not appear before then. Do not
  conclude anything is broken during it.
- **Dwell: 20 s.** You must *hold* an off-target pace for 20 seconds before an alert fires. A brief
  surge produces nothing, by design.
- **Cooldown: 60 s.** No second alert within a minute of the first. This is why the segments below
  are spaced.

Aim about **30 s/mi** beyond each boundary rather than sitting on it — GPS noise and the 0.5%
hysteresis both blur the edge, and you are testing the alert, not the threshold.

### B.1 Settling — first 400 m

Run at target. Expect **neutral**. Confirm the colour does *not* appear yet.

### B.2 Too fast — red, a haptic, and the crown (AC-FR-B-1-3, AC-FR-B-2-3)

1. Accelerate to about **30 s/mi faster than your target** (~8:25/mi if the target is 9:22)
   and **hold it for a full 30 seconds**.
2. Expect, in order: background goes **red**, a **too-fast haptic**, and the **pace warning screen**.
3. **The warning screen auto-dismisses after 4 seconds.** Before it does, **rotate the Digital
   Crown** to dismiss it early.

| Record | |
|---|---|
| Did the crown dismiss it, and roughly how fast? | AC-FR-B-2-3 |
| Did you return to the same scroll position on the metrics page? | AC-FR-B-2-4 |
| Describe the too-fast haptic in your own words | Feeds §C.1 |

4. **Watch the colour change on the way back to target.** The cross-fade is 400 ms and must read as
   a fade, not a flash (AC-FR-A-6-3).

### B.3 On target — the negative control (60 s)

**This segment exists to catch a false positive, and it is as important as the two around it.**

Settle **on your target, within a few seconds either way**, and hold for a full minute.

| Record | |
|---|---|
| Is the background **green**? | |
| Did any haptic fire? | **It must not.** A haptic on-target is a defect |

This also serves as the 60 s alert cooldown before the next segment.

### B.4 Too slow — blue, and the auto-dismiss (AC-FR-B-1-3)

1. Slow to about **30 s/mi slower than your target** (~10:20/mi if the target is 9:22) and
   hold for **30 seconds**.
2. Expect **blue**, a **too-slow haptic**, and the warning screen.
3. **This time do nothing.** Confirm it dismisses itself after about 4 seconds.

| Record | |
|---|---|
| Describe the too-slow haptic | Feeds §C.1 |
| Did it auto-dismiss cleanly? | |

### B.5 Finish

Return to target for the last 200 m, then **swipe right to Controls and End**. Confirm you land back
on the start screen (AC-FR-A-6-9).

---

## Section C — Immediately after, before you forget

### C.1 Haptic distinctness (AC-FR-B-1-3, AC-FR-C-2-2)

Sit down and answer this **before checking anything on the phone**. The requirement is that the
three patterns are tellable apart *without looking*, and the memory fades fast.

| Pattern | Where you felt it | Describe it | Could you have identified it blind? |
|---|---|---|---|
| Transition | A.3, A.5 | | |
| Too fast | B.2 | | |
| Too slow | B.4 | | |

**Caveat on this result, stated so it is not over-read:** the transition haptic was felt in Run A
and the two pace haptics in Run B, several minutes apart. That is weaker than feeling all three
within one run, and it is a direct consequence of the constraint at the top of this document. If any
two are hard to tell apart, that is a finding worth acting on; if they seem distinct, treat it as
provisional.

### C.2 HealthKit — the save and the route write (AC-FR-D-1-2…4)

On the **iPhone**, open the Health app → Browse → Activity → Workouts.

| Check | Expected |
|---|---|
| Both runs present | Two workouts, correct start times |
| Activity type | Running |
| Distance and duration | Match what the watch showed, within rounding |
| Heart rate recorded | Average and max present |
| **Route present** | Open the workout — a map with your actual route. This is `HKWorkoutRouteBuilder` and has never been verified |
| Run A's segments | Rep boundaries visible as segments |

Also confirm the Smart Stack condition for [T-100](../docs/implementation.md#t-100): the workouts
carry a correct activity type and accurate start/end times. The suggestion itself is longitudinal —
it appears after a routine establishes, not today.

### C.3 Export both runs

**Profile → Developer → Export Runs**, and put both files in `captures/exported_runs/`. This is the
evidence the numbers above are checked against later, and it costs two taps.

### C.4 Battery (NFR-8)

| | |
|---|---|
| Watch battery before | ____ % |
| Watch battery after | ____ % |
| Elapsed | ____ min |

---

## Recording sheet

Copy this out and fill it in on the phone as you go — anything not written down within the hour is
lost, which this project has already learned once.

```
Date ______  Watch SE 3, watchOS ______  Build ______
Weather / GPS conditions ____________________

0.1 Auth sheets photographed?          Y / N
0.2 Double Tap ON? Y/N   Wrist flick ON? Y/N   Crown advance OFF? Y/N
0.3 Static design-system changes: _______________________________

A.1 Edge-to-edge, no material?         Y / N   ______________________
A.1 GPS sensible within ____ s
A.2 DOUBLE TAP advanced warmup?        Y / N   attempts: ____
A.2 Any dim/flash on tap?              Y / N
A.2 Undo affordance seen for ~5 s?     Y / N
A.3 Countdown legible at 700 m?        Y / N
A.4 Always-on readable?                Y / N   which metrics: ________
A.4 Wrist raise to correct colour < 500 ms?   Y / N
A.5 BACKGROUND HAPTIC felt, screen asleep?    Y / N
A.6 Wrist flick left the app?          Y / N   run kept recording? Y / N
A.7 Crown dismissed transition screen?  Y / N
A.8 Controls page unchanged / pause correct?  Y / N
A.10 Double Tap ended cooldown?        Y / N

B.1 Neutral through settling?          Y / N
B.2 Red + too-fast haptic + warning?   Y / N
B.2 Crown dismissed warning < 4 s?     Y / N
B.2 Scroll position preserved?         Y / N
B.2 Cross-fade a fade, not a flash?    Y / N
B.3 Green on target?                   Y / N
B.3 ANY haptic on target?              Y / N   (must be N)
B.4 Blue + too-slow haptic?            Y / N
B.4 Auto-dismissed after ~4 s?         Y / N

C.1 Three haptics distinguishable?     Y / N   notes: _______________
C.2 Both workouts in Health?           Y / N
C.2 ROUTE MAP present?                 Y / N
C.2 Segments visible on Run A?         Y / N
C.3 Both runs exported?                Y / N
C.4 Battery ____ % → ____ % over ____ min

Anything that surprised you: ____________________________________
```

---

## What this outing still cannot close

Stated so the result is not over-read.

| Item | Why not | Where it goes |
|---|---|---|
| **A real GNSS outage** (DEG-1's hard case) | Needs a tunnel or an underpass on the route. If yours has one, mark it; otherwise this stays open | Same substitute as the standalone track: replay with `--suppress-gnss-after` |
| **Interval steps being *judged*** | The watch preset carries no target, so this is untestable from the watch alone | Needs a phone downlink, or a decision on the preset |
| **Smart Stack suggestion** ([T-100](../docs/implementation.md#t-100)) | Longitudinal — it appears once a routine establishes | Repeat runs at a consistent time |
| **Series 6/7/8 and SE 2 behaviour** | Different hardware, and now the *lower* half of the supported range ([ADR-014](../docs/design.md#adr-014)). `arm64_32` is gated in CI by [T-099](../docs/implementation.md#t-099), but nothing has run on that hardware | Open until someone has one |
| **Battery to NFR-8's standard** | One ~45 min run is not the 60 min at a controlled brightness the requirement means | Indicative only |
