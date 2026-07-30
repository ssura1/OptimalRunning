# Tools

| Script | Enforces |
|---|---|
| `check-core-imports.sh` | `Core` and `PhoneMotion` import no Apple frameworks (ADR-001, ADR-S-03) |
| `check-motion-fixtures.sh` | No synthetic motion signal backs an accuracy claim (CON-S-7, AC-FR-S-F-3-4) |
| `check-no-availability.sh` | No `#available` in a watch app target (CON-3, AC-FR-K-1-5) |
| `check-no-network.sh` | No networking or telemetry anywhere (NFR-14, NFR-15) |
| `check-phonemotion-isolation.sh` | Only the sensor-feed adapter depends on `PhoneMotion`, and no estimator tunable is named twice (ADR-S-01, NFR-S-19) |
| `check-sensor-handler-isolation.sh` | Sensor callbacks are explicitly `@Sendable`, never trailing closures that inherit `@MainActor` (S-057, CON-S-1) |
| `check-tier-isolation.sh` | No tier reaches into another tier's sources |
| `check-traceability.swift` | Every P0 requirement has a covering task, and no task cites a requirement that does not exist |
| `coverage-gate.sh` | `Core` and `PhoneMotion` line coverage stay at or above 85% (NFR-18, NFR-S-21) |

Each gate is verified to fail on a deliberate violation, not merely to pass on a clean
tree — a gate that has never gone red is not known to work.
