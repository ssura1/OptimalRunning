# Manual test protocol

Everything in this repository that **cannot** be verified by `swift test`, `xcodebuild test`, or a
structural gate — and, for each item, why it cannot be, so that a future reader can tell "not yet
automated" from "not automatable".

Created in Wave 4 (T-072). The Legacy tier's section is disproportionately long, and that is the
honest state of affairs rather than an oversight: **Xcode 26 ships no watchOS 8 simulator runtime**,
so for `Apps/WatchLegacy` there is no middle ground between a host-side unit test and real Series 3
hardware.

---

## 0. Setting up Series 3 hardware testing

Read this once before the Legacy sections. It is the part with real obstacles.

### 0.1 What you need

| | |
|---|---|
| Apple Watch Series 3 | on watchOS 8.x — its terminal version. **Do not** update it; there is nothing to update to, but do not restore it to factory either, in case a restore ever pulls a different build. |
| An iPhone | paired to that watch. The pairing is what makes the watch a deployable destination. |
| Xcode 26.6 | verified working. See §0.3 for what makes this fragile. |
| An Apple ID | a free account is enough for 7-day development provisioning. |

### 0.2 First-time setup

1. **Pair the watch to the iPhone**, and connect the iPhone to the Mac by cable for the first
   deployment. Wireless deployment to a watch goes *through* the paired phone, so the phone has to be
   trusted by the Mac first.
2. On the watch: **Settings → Privacy & Security → Developer Mode**. On watchOS 8 this may instead
   appear only after the watch has been used as a run destination once — if you do not see it, proceed
   and come back.
3. In Xcode: **Window → Devices and Simulators**, confirm the watch appears under the paired iPhone.
   The first appearance can take several minutes while symbols are copied; "Preparing debugger
   support" is normal and slow on this hardware.
4. Open `Apps/WatchLegacy/OptimalRunnerLegacy.xcodeproj`. If the project is missing, regenerate it:
   ```
   cd Apps/WatchLegacy && xcodegen generate
   ```
5. Set the signing team on **both** targets — `OptimalRunnerLegacy` and
   `OptimalRunnerLegacyExtension`. Signing → Team → your Apple ID. Leave "Automatically manage
   signing" on.
6. Select the `OptimalRunnerLegacy` scheme and the watch as the run destination, then Run.

### 0.3 The one fragile thing, and how you will know it broke

The Legacy target is pinned to `ARCHS: armv7k` in `Apps/WatchLegacy/project.yml`, because Series 3
is 32-bit while every later watch is `arm64_32`.

**armv7k is no longer listed as a supported architecture by the watchOS SDK.** The watchOS 26.5
SDK's `SDKSettings.plist` reports `SupportedTargets.watchos.Archs` as `arm64, arm64e, arm64_32` — no
armv7k. The toolchain still *supports* it in practice: the compiler accepts the target triple, the
SDK's stub libraries still carry armv7k slices, and the whole app including `Core` links and produces
a correct binary. All of that was verified rather than assumed before the tier was built.

But it is unsupported-and-working, which is a state that ends without warning. If a future Xcode
drops armv7k, the symptom is a build error naming the architecture, and the meaning is
[R-1](../docs/requirements.md#11-risks) arriving: the Series 3 window has closed. The planned
response is already written down — delete `Apps/WatchLegacy` and its CI job.

To confirm at any time that what you built is genuinely installable on a Series 3:

```
lipo -archs <path to OptimalRunnerExtension.appex/OptimalRunnerExtension>   # expect: armv7k
otool -l <same path> | grep minos                                          # expect: minos 8.0
```

If `lipo` reports `arm64_32`, the build will install on a Series 4+ and **fail on a Series 3** — that
is the failure to watch for, and it is silent until you try the actual device.

**CI asserts this too, so you are not the only guard.** `.github/workflows/legacy.yml` runs exactly the
two commands above on every push and fails the job on anything but `armv7k` / `minos 8.0`, and also
checks the bundle layout (`PlugIns/*.appex`, `_WatchKitStub/WK`, and the `WKWatchKitApp` key) since a
watchOS 9+ single-target bundle also builds cleanly and then refuses to launch. Both assertions were
verified against deliberately planted violations — a real `ARCHS=arm64_32` build does build
successfully, and the job does reject it. The manual check above remains useful for local builds, which
CI never sees.

Note that the CI pin is **two** values: `runs-on: macos-26` and `xcode-version: '26.6'`. A runner image
carries only a fixed set of Xcode versions, so the label is part of the pin — `macos-15` stops at Xcode
26.3 and cannot satisfy this job at all. If you change one, re-check the other against the
[runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md).

### 0.4 Practical notes for testing on this hardware

- **Everything is slow.** First launch after install can take 30 s+ while the OS validates. That is
  not the NFR-3 launch time; measure launch on a *second* cold start (§4.1).
- **The screen goes fully off**, not dim. Several requirements depend on this and cannot be observed
  on any later watch (§2.1, §3.2).
- **Battery drains fast** under GPS + HealthKit. Charge before a long protocol run.
- Debugging over the wire drops out frequently on this hardware. For anything timing-sensitive,
  prefer running **untethered** and checking results afterward rather than trusting a paused
  debugger's numbers.

---

## 1. Legacy tier — the fixture replay on real hardware (T-064)

**The single most important item in this document.**

`swift test` already runs all seven shared fixtures through Legacy's `SensorPipeline` and asserts the
output matches the committed goldens **exactly**, with no tolerance
([AC-FR-K-1-2](../docs/requirements.md)). That suite passes. It runs on the Mac's arm64 CPU.

Series 3 is **armv7k** — a genuinely different architecture, not merely an older OS. A watchOS 8
simulator could not settle this either, since a simulator runs on the host's CPU; and no watchOS 8
simulator exists regardless. So the question "does the pace engine produce bit-identical results on
Series 3's 32-bit FPU?" is answerable **only on the device**.

| | |
|---|---|
| **Status** | ⬜ **Not yet run on hardware.** Passing on the macOS host only. |
| **Why it matters** | A floating-point divergence here is the wave's central failure mode: two watches disagreeing about the same run, both looking plausible. |
| **What reduces the risk** | `testTheFusionArithmeticIsOrderStable` proves the fusion algorithm accumulates no per-tick rounding error — every offset is recomputed from the settled total. So a divergence, if any, would show immediately rather than hiding in the 1 500th tick. |

**How to run it on the watch.** The replay needs to execute *on* the device, which means it cannot be
an `swift test` invocation. The intended route:

1. Add a temporary debug entry point that calls `FixtureReplay.run` over
   `FixtureGenerator.standardFixtures()` and compares against the goldens bundled as resources.
2. Print each fixture's `finalCumulativeDistance` with `%.17g` — full `Double` precision. Anything
   less will hide exactly the difference being looked for.
3. Compare against the host values. They must match to the last bit. For reference, the host
   produces `5083.640774955034` for `treadmill-indoor`.

If they diverge, **do not** loosen the comparison to a tolerance. Write it up: the tier matrix in
`design.md` §8.1 gains a row, and the decision about what tolerance (if any) is acceptable is a
product decision, not a test-maintenance one.

---

## 2. Legacy tier — display and colour (T-066, T-067)

### 2.1 Wrist-raise to correct zone colour, under 500 ms (AC-FR-A-6-8)

| | |
|---|---|
| **Status** | ⬜ Hardware only |
| **Why not automatable** | The requirement is about the latency between a hardware gesture and a rendered frame. Series 3 has no always-on display, so the screen is *off* between raises and the app resumes from inactive — there is no dimmed intermediate state to inspect, and no API reports the timing. |

**Method.** Start a tempo run, hold a pace that puts you off-target so the colour is not neutral, drop
your wrist for 10 s, then raise it. Film it at 60 fps or higher; count frames from the wrist reaching
horizontal to the correct zone colour filling the screen. Under 500 ms is 30 frames at 60 fps. Repeat
five times — the first raise after a pause is the slow one, and it is the one that counts.

**Watch for:** the screen coming back showing the *previous* zone colour and then correcting. That is
a visible wrong-colour flash and fails the requirement even if the final state arrives in time.

### 2.2 Metric legibility at 38 mm (T-067)

| | |
|---|---|
| **Status** | ⬜ Hardware only (partially automated) |
| **Automated part** | `MetricsScreenTests` checks every zone × both palettes × both case sizes against character budgets derived from the real font metrics — 24 combinations, exhaustively. It caught one genuine layout bug: `"A BIT FAST +24"` overflowed the 38 mm caption row, which is why the signed delta now sits on its own row at that size. |
| **What is left** | A character budget is not a pixel measurement. Font substitution, and larger accessibility text sizes, can still truncate. |

**Method.** On a 38 mm Series 3, run each of the five run types briefly and confirm all five metrics
are fully visible with no ellipsis and no clipped digits. Then raise the system text size
(Settings → Display & Brightness → Text Size) to maximum and repeat. Photograph anything that
truncates.

### 2.3 Greyscale and CVD legibility (FR-J-1)

| | |
|---|---|
| **Status** | ⬜ Hardware only |
| **Automated part** | `ORColor`'s contrast tests — the *same tests* both tiers are checked against, per T-066 — verify every palette hex meets its WCAG ratio, and `MetricsScreenTests` verifies a glyph and signed delta accompany every zone. |
| **What is left** | Whether the zones are *distinguishable to a person* on this specific panel. |

**Method.** Photograph the run screen in each zone, convert to greyscale, and confirm you can name the
zone from the glyph and delta alone. Then enable Settings → Accessibility → Grayscale on the watch and
repeat live. Also test in direct sunlight — Series 3's display is the dimmest in the range, and this is
where the CVD-safe palette's lower saturation is most at risk.

---

## 3. Legacy tier — haptics and background behaviour (T-068)

### 3.1 Background haptic delivery

| | |
|---|---|
| **Status** | ⬜ Hardware only |
| **Why not automatable** | No simulator can deliver a haptic, and there is no watchOS 8 simulator in any case. `HapticDispatcherTests` covers *which* pattern fires and *when*; only "does the hardware buzz while backgrounded" is left. |

**Method.** Start a tempo run with a target pace you can deliberately miss. Lower your wrist so the
screen turns off and leave it down. Deliberately run too fast for longer than the dwell window.
Confirm the haptic still fires with the screen off. Repeat for too-slow, and for a step transition
during an interval session.

**This is the requirement most likely to be broken by a build-setting change** rather than by code: it
depends on `workout-processing` *and* `audio` in `UIBackgroundModes`. If haptics stop the moment the
screen sleeps, check those before looking at anything else.

### 3.2 Pattern distinguishability without looking (AC-FR-B-1-3, AC-FR-C-2-2)

| | |
|---|---|
| **Status** | ⬜ Hardware only |
| **Why not automatable** | It is a claim about human perception on a specific haptic engine. Series 3's is the weakest in the supported range, so passing on a Series 9 says nothing. |

**Method.** With the screen off and without looking, have someone trigger each of the four patterns in
random order; identify each. `.stepTransition` in particular must not be mistakable for a pace alert —
mistaking "your rep ended" for "slow down" makes a runner do the wrong thing.

### 3.3 Pace warning dropped while the wrist is down (AC-FR-B-2-5)

| | |
|---|---|
| **Status** | ⬜ Hardware only |
| **Automated part** | `AlertPresenter` implements and unit-tests the rule, keyed on `isScreenVisible`. |
| **What is left** | That watchOS 8's active/inactive lifecycle notifications actually fire when the wrist drops. This tier has no `isLuminanceReduced`, so the app's own lifecycle is the substitute signal, and whether it is a faithful one is a device question. |

**Method.** Wrist down, run deliberately off-pace for long enough to earn a warning, then raise your
wrist. **No stale warning should appear.** A warning that surfaces on raise, describing a pace from 30 s
ago, is the failure.

---

## 4. Legacy tier — performance on device (T-072)

All three are explicitly on-device-only: Series 3 is the slowest hardware the product supports, and
extrapolating from simulator or host timing is exactly what NFR-1/2/3 exist to prevent.

`Apps/WatchLegacy/Tests/PerformanceTests.swift` holds the harness; it must be run on the device, not
in a simulator.

### 4.1 Launch to start screen under 2 s (NFR-3)

| | |
|---|---|
| **Status** | ⬜ Hardware only |
| **Measured value** | ______ s |

**Method.** Install, then **force-quit and relaunch** — do not measure the post-install launch, which
includes one-time OS validation. Time from tap to the start screen being interactive. Take five cold
launches and record the median and the worst.

### 4.2 Zone evaluation under 5 ms per tick (NFR-1)

| | |
|---|---|
| **Status** | ⬜ Hardware only |
| **Measured value** | ______ ms median, ______ ms worst |

**Method.** Run the `PerformanceTests` measure block on the device. It drives the real engine over a
fixture, so what it reports is the actual per-tick cost of `RunEngine.tick` on armv7k. The worst case
matters more than the median: a 4 ms median with a 40 ms outlier drops frames.

### 4.3 No dropped frames on the run screen (NFR-2)

| | |
|---|---|
| **Status** | ⬜ Hardware only |
| **Why not automatable** | Frame delivery is a property of the compositor on real hardware. |

**Method.** Run a 10-minute interval session. Watch the elapsed-time digit: at 1 Hz it should update
without visible stutter. Pay attention specifically to the step-transition moments and the final-100 m
countdown, which are when the most work happens in one tick. If a Series 3 is going to drop frames, it
will be there.

**Note the `@Published` risk:** this tier uses `ObservableObject`, which notifies on every assignment,
where the Modern tier's `@Observable` tracks only what a view reads. `RunSessionModel` therefore
publishes one aggregate `screen` value and only when it changes. If frames drop, that granularity is
the first thing to examine.

---

## 5. Both watch tiers — paired-device sync (T-071, T-049, AC-FR-E-1-7)

| | |
|---|---|
| **Status** | ⬜ Hardware only — **two physical devices** |
| **Why not automatable** | The Simulator's WatchConnectivity does not exercise real reachability transitions. An iOS test run logs `WCErrorCodeDeviceNotPaired` on every context update, which is the honest result rather than a warning to suppress. |

**Automated part is substantial**, and worth knowing before spending device time: the transport queue,
eviction ordering, idempotent ingest, version gating, and backfill reconciliation are all covered
host-side. T-071's requirement — that the phone cannot distinguish a Legacy run from a Modern one
except by `deviceTier` — is verified by ingesting the *real bytes* this tier transmits
(`Fixtures/legacy-tier-envelope.payload`) through the same assertions T-049 established.

What remains is delivery itself:

1. **Uplink.** Complete a run on the Series 3 with the phone nearby. Confirm it appears in the iPhone
   app **within 60 s** (AC-FR-E-1-7). Record the observed time: ______ s.
2. **Out of range.** Complete a run with the phone left behind and powered off. Confirm the run
   survives, queued, and uploads when the phone returns. Confirm it is **not** duplicated.
3. **Relaunch mid-queue.** Queue a run out of range, force-quit the watch app, relaunch, then bring
   the phone back. The run must still arrive.
4. **Idempotency in the wild.** Trigger a re-send (toggle Airplane Mode on the watch mid-transfer).
   The phone must end with **one** run and correct lifetime totals — not two, and no doubled distance.
5. **`deviceTier` on arrival.** Confirm the ingested run is tagged `legacy`, and that its detail
   screen renders the route, splits, zone chart and per-rep table exactly as a Modern run does. A
   Legacy run must not be silently rendered as a lesser record.
6. **Downlink.** Change a pace on the phone; confirm the watch picks it up. Then change **units** on
   the watch and confirm a subsequent downlink does *not* overwrite it — the watch owns units and
   palette (`SettingsStore.merged(into:)`).

---

## 6. Both watch tiers — HealthKit export quality

### 6.1 Segment events in the saved workout (AC-FR-D-1-6) — Legacy specifically

| | |
|---|---|
| **Status** | ⬜ Hardware only |
| **Automated part** | `SegmentEventTests` asserts one segment per completed step including the final open one, that boundaries land on the committed golden's transition times, and that segments tile the run contiguously — against a fake backend. |
| **What is left** | That `HKWorkoutEvent(.segment)` events survive into the *saved* workout and are visible to other apps. |

This is Legacy's substitute for Modern's `beginNewActivity`, so a silent failure here is a permanently
worse export with nothing wrong on the watch.

**Method.** Run a 4×1000 m interval session on the Series 3. Afterwards, open the workout in Apple's
Fitness app and any third-party workout viewer, and confirm the interval structure is visible. Compare
against the same session recorded on a Modern watch: the boundaries should fall at the same points,
though Legacy's will present as segment markers rather than nested activities. **That presentational
difference is expected and documented** (design.md §8.1); missing boundaries are not.

### 6.2 Authorization denial still records the run (AC-FR-D-1-7)

| | |
|---|---|
| **Status** | ⬜ Hardware only |
| **Why not automatable** | HealthKit authorization cannot be denied programmatically. |

**Method.** Delete the app, reinstall, and **deny** health permissions. Complete a run. It must record
fully and sync to the phone; nothing should be written to Health, and no error should be shown. Denial
is a handled state, not a failure.

---

## 7. Modern tier

Carried forward from Wave 2 and Wave 3. See `Apps/WatchModern/README.md` and
`Apps/iPhone/README.md` for the full lists. In summary, still hardware-only:

- Double Tap advance on Series 9+ (AC-FR-C-3) — not implementable at the watchOS 10 floor; see the
  T-045 deviation note in `implementation.md`.
- Always-on dimmed rendering and its 500 ms wrist-raise behaviour.
- Background haptic delivery, as §3.1 but on modern hardware.
- The iPhone app's 300 ms statistics render and 60 fps list scrolling.
- VoiceOver quality on all three tiers.
