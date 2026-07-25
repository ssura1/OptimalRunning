import XCTest
import ORColor
import ORModels
import ORPace
import WatchSupport

/// The watchOS-side test target.
///
/// **Cannot `@testable import OptimalRunnerWatch`, and cannot even plainly
/// `import OptimalRunnerWatch`.** Both were tried, with and without `embed: false` on the
/// dependency — every combination fails with "Unable to resolve module dependency". This
/// is a real Xcode/watchOS limitation for unhosted single-target watchOS test bundles, not
/// a `project.yml` misconfiguration. Practical consequence: any logic worth unit-testing
/// lives in `WatchSupport` — a local, framework-free Swift package that both the app and
/// this target import as a `package:` dependency, the same way `Core` does — never as
/// `internal` code inside the app target itself.
///
/// **Why this target exists at all, given `swift test` covers WatchSupport.** The package
/// suite runs on the macOS host, which is fast and simulator-free but proves behaviour on
/// the wrong platform. This target runs the same logic compiled for watchOS, which is
/// where platform divergence actually shows up: `SampleStore`'s free-space query
/// originally used `volumeAvailableCapacityForImportantUsageKey`, which compiles on macOS
/// and does not exist on watchOS. That class of bug is invisible to `swift test` by
/// construction.
///
/// So this is deliberately a *thin* platform smoke suite, not a duplicate of the 125-test
/// package suite: enough to prove the tier's logic behaves identically when built for the
/// real target.
final class ScaffoldingTests: XCTestCase {

    func testCoreLinksOnWatchOS() {
        XCTAssertEqual(RunType.allCases.count, 5)
        XCTAssertEqual(PaceZone.allCases.count, 6)
    }

    /// Distance fusion behaves the same compiled for watchOS as it does on the host.
    func testDistanceFusionIsMonotonicOnWatchOS() {
        var fusion = DistanceFusion()
        var truth = 0.0
        var previous = 0.0

        for tick in 0..<300 {
            truth += 2.9
            let result = fusion.fuse(
                healthKit: DistanceReading(
                    source: .healthKit, cumulativeDistance: truth, isAvailable: tick % 2 == 0
                ),
                location: DistanceReading(
                    source: .location, cumulativeDistance: truth, isAvailable: true
                ),
                pedometer: DistanceReading(
                    source: .pedometer, cumulativeDistance: truth, isAvailable: true
                )
            )
            XCTAssertGreaterThanOrEqual(result.cumulativeDistance, previous)
            XCTAssertEqual(result.cumulativeDistance, truth, accuracy: 1e-9)
            previous = result.cumulativeDistance
        }
    }

    /// The free-space query — the specific call that differs by platform — returns a real
    /// answer on watchOS rather than trapping or reporting nothing.
    func testStorageQueryWorksOnWatchOS() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaffoldingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SampleStore(directory: directory)
        XCTAssertTrue(store.hasSufficientStorage(minimumBytes: 1))
        XCTAssertFalse(store.hasSufficientStorage(minimumBytes: .max))
    }

    /// Sample capture and orphan recovery survive watchOS's own filesystem, including the
    /// atomic replace `flush` depends on.
    func testSampleCaptureAndOrphanRecoveryWorkOnWatchOS() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaffoldingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SampleStore(directory: directory)
        let runID = UUID()
        store.startRun(runID: runID)

        for second in 0..<10 {
            store.append(
                RunSample(
                    timestamp: Double(second), cumulativeDistance: Double(second) * 3,
                    rollingPace: nil, heartRate: 150, relativeAltitude: 0, smoothedGrade: 0,
                    gradeFactor: .identity, rawTarget: nil, effectiveTarget: nil, zone: .onTarget
                ),
                flushIntervalSeconds: 30
            )
        }
        store.flush()

        let orphan = store.detectOrphan()
        XCTAssertEqual(orphan?.runID, runID)
        XCTAssertEqual(orphan?.sampleCount, 10)
        XCTAssertEqual(store.loadOrphan(runID: runID)?.count, 10)
    }

    /// Every zone renders a glyph and clears the contrast floor when the palettes are
    /// compiled for watchOS (FR-J-1, AC-FR-J-1-3).
    func testEveryZoneCarriesAGlyphAndClearsContrastOnWatchOS() {
        for palette in PaletteChoice.allCases {
            for zone in PaceZone.allCases {
                for luminance in LuminanceState.allCases {
                    let swatch = ZonePalette.palette(for: palette).swatch(for: zone, luminance: luminance)
                    XCTAssertGreaterThanOrEqual(swatch.contrastRatio, 4.5, "\(palette)/\(zone)/\(luminance)")
                    XCTAssertFalse(ZoneAffordance.affordance(for: zone).symbolName.isEmpty)
                }
            }
        }
    }

    /// VO2 max stays neutral at every zone, built for watchOS (FR-C-4).
    func testVO2MaxNeverColoursOnWatchOS() {
        let profile = RunnerProfile(tempoPace: Pace(minutesPerMile: 8))

        for zone in PaceZone.allCases {
            let sample = RunSample(
                timestamp: 100, cumulativeDistance: 400, rollingPace: Pace(minutesPerMile: 6),
                heartRate: 170, relativeAltitude: 0, smoothedGrade: 0, gradeFactor: .identity,
                rawTarget: nil, effectiveTarget: nil, zone: zone
            )
            let output = EngineOutput(
                zone: zone, rollingPace: Pace(minutesPerMile: 6),
                averagePace: Pace(minutesPerMile: 6.5), rawTarget: nil, effectiveTarget: nil,
                gradeFactor: .identity, smoothedGrade: 0, isGradeSignificant: false,
                isGradeAvailable: true, isGPSDegraded: false, isStationary: false,
                isSettling: false, progress: 0.4, activeElapsed: 100, cumulativeDistance: 400,
                heartRate: 170, step: .idle, stepTransition: nil, alert: nil,
                degradations: [], sample: sample
            )

            let screen = MetricsScreen.make(
                output: output, runType: .vo2max, profile: profile, luminance: .normal
            )
            XCTAssertFalse(screen.appliesZoneColour, "VO2 max coloured at \(zone) on watchOS")
            XCTAssertEqual(screen.zone, .neutral)
        }
    }
}
