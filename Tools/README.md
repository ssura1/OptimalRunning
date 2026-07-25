# Tools

| Script | Enforces |
|---|---|
| `check-core-imports.sh` | `Core` imports no Apple frameworks (ADR-001) |
| `check-no-availability.sh` | No `#available` in a watch app target (CON-3, AC-FR-K-1-5) |
| `check-no-network.sh` | No networking or telemetry anywhere (NFR-14, NFR-15) |
| `check-traceability.swift` | Every P0 requirement has a covering task, and no task cites a requirement that does not exist |
| `coverage-gate.sh` | `Core` line coverage stays at or above 85% (NFR-18) |

Each gate is verified to fail on a deliberate violation, not merely to pass on a clean
tree — a gate that has never gone red is not known to work.
