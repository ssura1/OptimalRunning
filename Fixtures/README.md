# Fixtures

Recorded engine input traces and their committed golden outputs. These are the
highest-value tests in the project, and also the project's bug-report format: "the
screen went red on my hill" becomes a fixture, then a failing test, then a fix.

| Fixture | Exercises |
|---|---|
| `tempo-5mi-rolling` | The memo's observed tempo shape — opening fast, closing slow — staying inside the band (ADR-005) |
| `intervals-4x1000` | The canonical VO2 max session: open warmup, 4 × (1000 m / 1000 m), open cooldown |
| `hilly-10k` | ±8% terrain; a steady-effort runner should read as on-target (FR-A-4) |
| `gps-dropout-tunnel` | 90 s without a usable fix; pedometer fallback (DEG-1) |
| `treadmill-indoor` | Pedometer only, no GPS or altimeter (DEG-10) |
| `stop-start-traffic` | Repeated 40 s stops; stationary handling, and *no* spurious haptics |
| `boundary-oscillation` | Pace parked on a zone edge; hysteresis (AC-FR-A-3-7) |

Fixtures are generated deterministically by `FixtureGenerator`, not hand-recorded, so
a contributor with no watch can reproduce them byte-for-byte.

```sh
swift run --package-path Core ORReplay generate                  # rebuild fixtures
swift run --package-path Core ORReplay verify                    # compare to goldens
swift run --package-path Core ORReplay verify --update-goldens   # accept a change
swift run --package-path Core ORReplay timeline --fixture hilly-10k
```

**Never edit a golden to make a test pass.** Regenerating one is a deliberate act:
the CLI prints what changed, and the PR body must say why.
