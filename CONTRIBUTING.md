# Contributing to OptimalRunner

## Before you start

Read [`docs/design.md`](docs/design.md) §2 — the architecture decision records. They
record which parts of this codebase are deliberate and why, which is the difference
between improving it and quietly undoing a decision.

## Getting set up

```sh
swift build --package-path Core
swift run   --package-path Core ORSelfCheck
```

If that passes, you have everything you need to work on the engine. Xcode is required
only for the watch and phone targets.

## The rules that CI enforces

These are not style preferences. Each is a decision that would otherwise erode one
well-intentioned commit at a time, so each has a script.

**`Core` imports no Apple frameworks.** Not even "just for `CLLocation`". The moment
one file does, the test suite needs a simulator and the whole architecture is gone.
Convert platform types to `Core` value types in the app layer.

**No `#available` in a watch app target.** Each tier has one deployment target and its
own source tree. An availability check there means either dead code or the conditional
soup the product deliberately avoids.

**`Apps/WatchLegacy` is frozen — and a commit that touches it says so.** The Series 3
tier is in maintenance mode as of 2026-08-09 ([ADR-015](docs/design.md#adr-015)): it
keeps building and keeps running in CI, and it receives no new feature work. Because one
watch tier is moving and the other is standing still, a commit touching
`Apps/WatchLegacy` carries a **`[legacy]` prefix** in its subject so the tier is
unambiguous:

```
fix(watch): [legacy] keep the segment encoder compiling after the Core rename
```

This one is a convention rather than a script. It is worth keeping anyway: it makes the
frozen tier's history greppable, and a `[legacy]` commit that also touches
`Apps/WatchModern` is visibly wrong in a way an unlabelled one is not.

**No networking, anywhere.** No `URLSession`, no analytics SDK, no telemetry. "We don't
send your data anywhere" is only credible if something checks it.

**Every tunable lives in `PaceEngineConfiguration`.** A numeric literal in engine logic
is a review rejection. A constant at its use site cannot be tuned, cannot be
snapshotted into a run record, and cannot be validated. The standalone tier's equivalent
is `MotionEstimationConfiguration`, and a tunable named there may not be named anywhere
else in the phone app.

**Only the sensor-feed adapter imports `PhoneMotion`.** The phone's motion estimator is
still being improved — a refitted exponent, a calibration correction, possibly a
gyroscope term — and each of those should be a change to one package, not a hunt through
screens. So the run controller, the live screen, Statistics, Settings and the hub see
`Core` types only. If you need a fact the estimator has, put it on
`ORModels.MotionTelemetry` and let the adapter fill it in.

**Percentages are percentages of *pace*, never of speed.** 9:00/mi is 12.5% slower than
8:00/mi because 540/480 = 1.125. Getting this backwards does not crash anything — it
just mis-classifies every runner by a few percent, in a direction that varies with
pace. Use `PaceRatio`, never a bare `Double`.

## Tests

Assertions live in `Core/Sources/ORConformance`, and are run two ways from one
definition: by `swift run ORSelfCheck` (no Xcode required) and by the XCTest targets
(per-suite granularity and coverage in CI). Add new assertions to the conformance
suite, not to the XCTest wrappers.

`Core` line coverage must stay at or above 85%.

### Goldens

`Fixtures/golden/*.json` record the exact zone timeline, alert sequence and step
transitions each fixture produces. **Never edit one to make a test pass.** If your
change alters behaviour deliberately:

```sh
swift run --package-path Core ORReplay verify --update-goldens
```

The CLI prints what changed. Put that explanation in your PR body — a golden diff with
no justification is the clearest possible signal that something regressed.

## Reporting a bug

The most useful bug report is a fixture. If you can describe the conditions — "my pace
went red on a long descent" — that becomes a trace in `FixtureGenerator`, then a
failing assertion, then a fix, and it stays fixed.

## Pull requests

One task, one branch, named `t-###-short-slug` after its ID in
[`docs/implementation.md`](docs/implementation.md). Name the requirement IDs your change
satisfies in the PR body. Do not modify files outside your task's `Touches` list — if
you need to, the plan is wrong and should be amended first.
