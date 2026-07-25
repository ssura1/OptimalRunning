# Core sources

Pure Swift. **No Apple frameworks** — not HealthKit, CoreLocation, CoreMotion,
WatchKit, SwiftUI, UIKit, SwiftData, Charts or MapKit (ADR-001). Enforced by
`Tools/check-core-imports.sh` on every push.

Everything the product *decides* lives here, so it can be tested in milliseconds on a
Linux container and replayed deterministically from a recorded fixture.

| Module | Owns | Depends on |
|---|---|---|
| `ORModels` | Value types, units, configuration, wire DTOs, packing | — |
| `ORIntervals` | Workout plan resolution, the step state machine, run-type semantics | `ORModels` |
| `ORAlerts` | Dwell/cooldown haptic policy | `ORModels`, `ORIntervals` |
| `ORPace` | Rolling pace, target curve, grade, zones, settling, `RunEngine`, fixtures | `ORModels`, `ORIntervals`, `ORAlerts` |
| `ORStats` | Aggregates, personal bests, chart downsampling | `ORModels` |
| `ORColor` | Palette data plus contrast and colour-vision maths. No UI types. | `ORModels` |
| `ORConformance` | The shared assertion suite (test infrastructure, not product code) | all of the above |
| `ORReplay`, `ORSelfCheck` | CLIs | — |

**What does not belong here:** anything that needs a device, a simulator, a network,
or a clock. Time enters the engine only through sample timestamps.
