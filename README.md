<p align="center">
  <img src="Assets/running_man_heart.svg" width="96" alt="OptimalRunner">
</p>

# OptimalRunner

A running app for all runners who want to train optimally. OptimalRunner has a
simplistic UI during runs for pace management and advanced analysis post-run. Save
routes, plan for races, & recover with OptimalRunner's generated plans. Train running
techniques (tempo, intervals, strides, easy runs, long runs, etc.) all without the need
for a track.

---

## The idea

**During a run, the watch tells you one thing.** The screen's dominant colour answers
"am I running this correctly?" in under 250 ms of attention — red too fast, green on
target, blue too slow, with amber and turquoise in between. Everything else is
secondary.

**After a run, the phone tells you everything.** Deferring the analysis is what makes
the watch affordable to keep simple.

## Status

| Milestone | State |
|---|---|
| Core engine — pace, grade, zones, intervals, alerts, stats, colour | **Built and passing** |
| Watch (Series 4+) app | Not started — needs Xcode |
| iPhone hub | Not started — needs Xcode |
| Watch (Series 3) app, planning, routes | Not started |

## Build and test

`Core` has **no external dependencies and no Apple-framework dependencies**, so it
builds and tests anywhere a Swift toolchain runs, including a plain Linux container.

```sh
git clone <this repo> && cd OptimalRunning

swift build --package-path Core                  # build the engine
swift run   --package-path Core ORSelfCheck      # 592 assertions, no Xcode needed
swift run   --package-path Core ORReplay verify  # replay fixtures against goldens
swift test  --package-path Core                  # XCTest suite (needs Xcode on macOS)
```

`ORSelfCheck` exists because XCTest ships with Xcode rather than with the Command Line
Tools, and a contributor should not need a 10 GB download to check that the pace maths
is right. It runs the same assertions the XCTest targets do.

Useful when working on the engine:

```sh
swift run --package-path Core ORReplay timeline --fixture hilly-10k
```

## Architecture

One package of pure logic, surrounded by thin application shells.

```
Core/                  pure Swift — every decision the product makes. Builds on Linux.
Apps/iPhone/           iOS 17+ — statistics hub, and the standalone running tier
Apps/iPhone/PhoneMotion/  pure Swift — motion estimation for phone-only runs. Builds on Linux.
Apps/WatchModern/      watchOS 10+ — Series 4 and later
Apps/WatchLegacy/      watchOS 8 — Series 3 only
Fixtures/              recorded traces + committed golden outputs
Tools/                 CI gates and the replay CLI
docs/                  requirements, design, implementation plan
docs/standalone/       the same three, for the phone-only track
```

Every decision — what pace you should be running, what colour the screen is, whether to
buzz, whether the rep is over — is a pure function of recorded samples and
configuration. That single constraint is what makes the test suite run in seconds, keeps
the two watch tiers from drifting apart, and turns any bug report into a replayable
fixture.

The two watch tiers are **separate targets with no shared source**, because supporting
Series 3 from one target would mean gating every modern API behind `if #available` —
and CI fails the build if one appears.

## Documentation

- [`docs/requirements.md`](docs/requirements.md) — goals, user stories, and strictly
  testable acceptance criteria
- [`docs/design.md`](docs/design.md) — architecture, the pace engine's maths, data
  models, sync protocol, testing strategy
- [`docs/implementation.md`](docs/implementation.md) — 94 traceable tasks in dependency
  order
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to work on this

## Privacy

OptimalRunner is device-local. There is no backend, no account, no analytics, and no
third-party SDK. No run, route or health data leaves your devices. This is enforced on
every push by `Tools/check-no-network.sh` rather than merely promised.

## Licence

MIT — see [LICENSE](LICENSE).
