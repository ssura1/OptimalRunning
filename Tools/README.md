# Tools

| Script | Enforces |
|---|---|
| `check-core-imports.sh` | `Core` and `PhoneMotion` import no Apple frameworks (ADR-001, ADR-S-03) |
| `check-motion-fixtures.sh` | No synthetic motion signal backs an accuracy claim (CON-S-7, AC-FR-S-F-3-4) |
| `check-no-availability.sh` | No `#available` in a watch app target (CON-3, AC-FR-K-1-5) |
| `check-no-network.sh` | No networking or telemetry anywhere (NFR-14, NFR-15) |
| `check-phonemotion-isolation.sh` | Only the sensor-feed adapter depends on `PhoneMotion`, and no estimator tunable is named twice (ADR-S-01, NFR-S-19) |
| `check-sensor-handler-isolation.sh` | Sensor callbacks are explicitly `@Sendable`, never trailing closures that inherit `@MainActor` (S-057, CON-S-1) |
| `check-location-background-mode.sh` | A tier setting `allowsBackgroundLocationUpdates` declares the `location` background mode — CoreLocation kills the process otherwise (AC-FR-B-1-6, CON-S-4) |
| `check-tier-isolation.sh` | No tier reaches into another tier's sources |
| `check-traceability.swift` | Every P0 requirement has a covering task, and no task cites a requirement that does not exist |
| `coverage-gate.sh` | `Core` and `PhoneMotion` line coverage stay at or above 85% (NFR-18, NFR-S-21) |

Each gate is verified to fail on a deliberate violation, not merely to pass on a clean
tree — a gate that has never gone red is not known to work.

| Protocol | For |
|---|---|
| `manual-test-protocol.md` | The watch tiers, by hand |
| `watch-hardware-protocol.md` | The Modern tier's hardware-only list, sequenced into one ~4.3 mi outing |
| `standalone-manual-protocol.md` | The phone tier, by hand — everything CI cannot reach (S-054) |
| `motion-recording-protocol.md` | Recording a raw motion trace for algorithm work |
| `pace-ladder-protocol.md` | The speed-varying recording the step-length model is fitted against |

| Script | Does |
|---|---|
| `scrub-trace.swift` | Replaces absolute GNSS fixes in a recorded trace with offsets from its own first fix, before it is ever committed (S-059) |

The same transform runs on-device in `RunExport` ([S-067](../docs/standalone/implementation.md#s-067)),
which is how a recorded run leaves a test phone — **Profile › Developer › Export Runs**. Exports and
traces from the same run are compared against each other, so the two implementations must agree on
the constant they use.
