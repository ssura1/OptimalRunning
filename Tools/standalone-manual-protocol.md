# Standalone tier — manual verification protocol

| Field | Value |
|---|---|
| Document | `Tools/standalone-manual-protocol.md` |
| Task | [S-054](../docs/standalone/implementation.md#s-054) |
| Covers | [requirements §12.2](../docs/standalone/requirements.md#122-what-is-hardware-verification-only) in full |
| Companion | [`Tools/manual-test-protocol.md`](./manual-test-protocol.md) — the watch tiers' equivalent |

---

## Why this document exists

Everything in this file is a requirement CI **cannot** check, and the reason is nearly always
the same one: [CON-S-1](../docs/standalone/requirements.md#con-s-1) — the iOS Simulator has no
accelerometer, no gyroscope, no Taptic Engine, no battery, and no runner.

The temptation with a list like this is to write a test that *appears* to cover each item and
runs against a stub. That would be worse than nothing: it converts "unverified" into "green",
which is the specific failure this whole track is organised against
([CON-S-7](../docs/standalone/requirements.md#con-s-7),
[FR-S-F-3](../docs/standalone/requirements.md#fr-s-f-3--synthetic-signals-are-labelled-and-quarantined)).
So these live here, are done by hand, and are recorded with a date and a device.

**A protocol item with no recorded result is an unverified requirement**, and §12.1 says so
rather than implying otherwise.

---

## Required hardware

| Item | Why |
|---|---|
| iPhone 12 or later, iOS 17+ | NFR-S-2 and NFR-S-4 name the iPhone 12 as the reference device |
| Wired or Bluetooth headphones | §3 and §4 — ducking, route changes |
| A second phone | §4.3 — to place the interrupting call |
| A measured course, or a track | §6 — the only distance reference obtainable without surveying |
| A stopwatch | §6 — independent of the phone under test |
| Somewhere with a real GPS shadow | §5.2 — an underpass, a tunnel, a dense-street canyon |

A watch is **not** required and deliberately not used as a reference: it is a second estimator,
and [ADR-S-06 amendment 1](../docs/standalone/design.md#adr-s-06-amendment-1) records at length
what happens when a second estimator is treated as an arbiter.

---

## 1. Background survival — AC-FR-S-A-2-1

The single most important item here. Without it a standalone run silently stops recording the
moment the screen sleeps, with no error anywhere, and the runner discovers it at the end.

1. Start a standalone run outdoors.
2. Lock the screen. Put the phone in your hand as you would run with it.
3. Run for **at least 15 minutes**, screen locked throughout.
4. Unlock and end the run.

**Pass:** elapsed time matches the wall clock; distance is continuous with no flat stretch;
the sample count is within a few of one per second of the elapsed time.

**Fail modes worth naming:** a run that recorded the first 30 seconds and then stopped is
`UIBackgroundModes` missing or `allowsBackgroundLocationUpdates` unset. A run with a flat
stretch in the middle is `pausesLocationUpdatesAutomatically` not cleared — iOS decided the
runner had stopped.

## 2. A run conducted without looking — AC-FR-S-D-1-6

The product claim of this whole tier, so it is verified as a whole rather than in pieces.

1. Set a structured interval run.
2. Start it, put the phone in your hand, and **do not look at it again until you stop**.
3. Run the session. Follow the audio and the haptics only.

**Pass:** every interval transition arrived, every pace correction was intelligible, and you
knew what the workout wanted at every moment without looking. Note anything you had to guess.

---

## 3. Audio — FR-S-D-1

### 3.1 Ducking and the silent switch — AC-FR-S-D-1-4

| Step | Expected |
|---|---|
| Play music, start a run, wait for a cue | Music ducks, cue is audible, music returns to full volume |
| Wait for a **second** cue a few minutes later | Music ducks and returns again, independently |
| End the run | Music is at full volume |
| Set the ring/silent switch to **silent**, repeat | The cue is still audible |
| Set the phone's volume to 50%, repeat | The cue is still intelligible over the music |

The silent-switch case is the one that matters most: most runners run on silent, and
`.ambient` would be the tidier-looking category and would silence the product for them.

**The "music returns" rows are a regression check, not a formality.** The 2026-07-30 run
failed exactly there: the music ducked for the first cue and stayed down for the rest of the
run. `.duckOthers` ducks for as long as the session is *active*, not for as long as something
is speaking, and the first implementation held one activation across the whole run. The
sequence of session calls is now asserted in `SpeechCuePlayerTests` — but no test can hear
whether the volume actually comes back, which is why these rows exist.

Two cues, not one: a single cue would pass even if the release only ever happened at the end
of the run.

### 3.2 Intelligibility at speed — AC-FR-S-D-1-9

Judged by ear at running pace, with wind, over music. Record any cue you had to replay
mentally to parse.

| Cue | Heard as intended? |
|---|---|
| The **first** cue of the run | |
| "Ease off. *N* seconds fast." | |
| "Pick it up. *N* seconds slow." | |
| "Recovery. 400 metres." | |
| "Mile 3. 7:58. Average 8:02." | |
| "GPS signal lost. Pace is estimated." | |
| "Workout complete." | |

**The first cue has its own row because it failed on 2026-07-30** and later cues did not. It
pays two costs the others do not: the voice asset is loaded on first use, and the duck ramp
has not finished when the first word lands. Both are now paid ahead of time — the voice is
warmed at `start()` and every utterance has a 0.3 s lead-in — but "is the first cue as clear
as the fourth" is only answerable by ear.

**The split cue is the one under suspicion.** It contains two clock-style paces, and whether
`AVSpeechSynthesizer` reads "7:58" as "seven fifty-eight" rather than "seven colon five eight"
is a question about the system voice, not about this code. If it reads badly, the fix is in
`StandaloneStrings.splitCue`.

### 3.2a Voice and speed — S-052

Under **Profile › Phone Runs › Voice**. "Play a Sample" speaks a real pace cue, so this can
be judged indoors before committing a run to it.

| Step | Expected |
|---|---|
| Open the section with only the stock voice installed | The footer says better voices are a free download, and names where |
| Download an Enhanced or Premium English voice in Settings › Accessibility › Spoken Content › Voices, reopen | It appears in the picker, labelled with its quality, and is chosen by "Best available" |
| Play a sample at each of Slower / Normal / Faster | Audibly different, all three followable |
| Run with the chosen voice | It is still the chosen voice — the setting survives the run starting |

The default is **Normal**, which is 0.9× the platform default; the version tested on
2026-07-30 spoke at 1.1× and was reported as too fast. Third-party and Siri voices cannot be
used by any app — Apple's own downloads are the whole of what is available.

### 3.3 Route change — DEG-S-9

1. Start a run with headphones connected.
2. Mid-run, disconnect them.

**Pass:** the run continues, haptics continue, and the *next* cue comes out of the phone's
speaker. **Fail:** cues silently stop — the failure mode that leaves a runner with no feedback
and no indication anything changed.

### 3.4 Interrupting call — DEG-S-10

1. Start a run. Have the second phone call you.
2. Answer, talk for a minute, hang up.

**Pass:** recording never stopped; haptics fired throughout the call; spoken cues resumed
afterwards. Only the *most recent* missed cue is spoken on resume — a runner returning from a
two-minute call does not want the four pace corrections they missed, three of which describe a
pace they are no longer running.

---

## 4. Haptics — FR-S-D-2

### 4.1 Distinctness in the hand — AC-FR-S-D-2-1

The requirement is that direction is distinguishable, and the honest test is blind.

1. Have someone trigger patterns without telling you which.
2. While running, with the phone in your hand, name each one.

| Pattern | Identified correctly? |
|---|---|
| Ease off (descending double tap) | |
| Pick it up (ascending double tap) | |
| Step transition (triple tap) | |
| Workout complete (long, four taps) | |

**If ease-off and pick-it-up are confused at running pace, that is a failure**, and
`PhoneHapticPlayer` is the file that changes — the mapping is already testable, only the feel
is not.

### 4.2 Background haptics — AC-FR-S-D-2-3

Same as §1, but noting whether every haptic arrived with the screen locked.

### 4.3 Speech off — AC-FR-S-D-1-7

Turn spoken cues off in Profile › Phone Runs. Run a structured session.

**Pass:** haptics alone carried the whole workout.

---

## 5. Accuracy on real ground

Automated where possible ([§12.1](../docs/standalone/requirements.md#121-validation-status)),
but two things need a course.

### 5.1 Distance against a measured course — NFR-S-9

1. Run a known distance — a 400 m track is ideal; four laps in lane 1 is 1600 m.
2. Record with a standalone run, phone hand-held.

| Measure | Value | Against reference |
|---|---|---|
| App distance | | |
| Elapsed | | |

**Pass:** within 3%. Note which lane — lane 8 is 453 m per lap, and a lane mix-up looks
exactly like a 13% scale error.

### 5.2 A real GNSS outage — NFR-S-10, DEG-S-1

1. Start a run with a **converged** calibration (check Profile › Phone Runs says "Settled").
2. Run through a real GPS shadow of at least 200 m.

**Pass:** the "GPS signal lost" cue fires **once**; distance keeps advancing; the run detail
afterwards shows a measured/estimated split with a plausible estimated figure.

**This is currently the weakest-evidenced requirement on the track.** §12.1 records the
outages seen so far as 67.9 s across four dropouts — real, but short.

### 5.3 A counted-step segment — NFR-S-8

Still the single most valuable 60 seconds available, and still missing.

1. Mid-run, using the **Motion Capture** developer tool: MARK, count footfalls aloud for
   60 s, MARK.
2. Write the number down.

It is the only *exact* reference obtainable in the field. See
[`Fixtures/motion/README.md`](../Fixtures/motion/README.md).

---

## 6. Battery and CPU — NFR-S-2, NFR-S-4, NFR-S-5

Measured, recorded, **and not asserted anywhere in CI**. A simulator figure would be a
measurement of the development machine.

### 6.1 Battery over an hour — NFR-S-4

1. Charge to 100%. Note the exact percentage.
2. Airplane mode **off**, Wi-Fi off, Bluetooth on if using headphones.
3. Run a 60-minute standalone run, screen locked except to check.
4. Note the percentage at the end.

**Pass:** ≤ 20% consumed on an iPhone 12 or later.

### 6.2 Low-power mode — NFR-S-5

Repeat §6.1 with iOS Low Power Mode on.

**Pass:** at least 25% less consumed than §6.1.

### 6.3 CPU — NFR-S-2

With Xcode attached and the run active, read sustained CPU from the debug navigator over at
least 5 minutes of steady running.

**Pass:** under 5% sustained. Note the peak separately — a spike at a calibration window close
is expected and is not what the requirement bounds.

---

## Results template

Copy this per run and keep it with the release notes.

```
Date:                    ____________________
Device / iOS:            ____________________
App version (build):     ____________________
Weather / conditions:    ____________________

1.  Background survival (15 min locked)       PASS / FAIL   notes:
2.  Screen-never-looked-at run                PASS / FAIL   notes:
3.1 Music returns after cue 1 / cue 2 / end   PASS / FAIL
3.1 Ducking + silent switch                   PASS / FAIL
3.2 First cue intelligible                    PASS / FAIL
3.2 Intelligibility  (list any unclear cue)   PASS / FAIL   notes:
3.2a Voice chosen: ____________  speed: Slower / Normal / Faster
3.3 Headphone disconnect                      PASS / FAIL
3.4 Interrupting call                         PASS / FAIL
4.1 Haptic distinctness (blind)               ___ / 4 correct
4.2 Background haptics                        PASS / FAIL
4.3 Speech off, haptics only                  PASS / FAIL
5.1 Measured course:  reference ______ m, app ______ m, error ____ %
5.2 GNSS outage:      length ______ m, estimated ______ m, cue fired once? Y / N
5.3 Counted steps:    counted ______, app ______, error ____ %
6.1 Battery, 60 min:  ______ %        (bound: 20%)
6.2 Battery, low power: ______ %      (bound: 25% better than 6.1)
6.3 CPU sustained:    ______ %        (bound: 5%)   peak: ______ %

Anything that went differently from the plan:
```

**A deviation noted is data; a deviation unnoted is noise.** Record the road crossing, the
lost signal, the pace you could not hold — the analysis can handle a stated irregularity and
cannot handle an unstated one.

---

## Sending the runs back

**Profile › Developer › Export Runs.** Every recorded run is listed, newest first, phone and
watch alike — including runs recorded by an earlier build, because the export is assembled
from what the store already holds rather than from anything captured at the time. Nothing has
to be switched on beforehand.

Tap a run to prepare it, then share; or prepare the whole set and AirDrop them together. On a
Mac they belong in `data/`, which is not tracked by git.

Each file carries the summary, the full sample series, the splits, the degradation flags and —
for phone runs — the calibration state, the step count, and which stretches of the run were
estimated rather than measured. That last field is the first thing worth looking at when a
distance comes out wrong.

**Routes are stored as metres east and north of each run's own first fix.** The shape,
length, turn radius and fix spacing all survive; the origin does not, and there is no option
to include it. A screenshot of the run detail screen shows the map — an export does not, so
the two are not interchangeable and the export is the safer thing to send.

Worth pairing with a note of what the *reference* was: "2.80 mi by the measured course" turns
a file into a measurement.
