import XCTest
import WatchKit
import ORIntervals
import ORModels
import ORPace
import LegacySupport

/// Performance validation on Series 3 hardware (T-072, NFR-1, NFR-2, NFR-3).
///
/// ## Read this before running
///
/// **This target exists to be run on a device, and its numbers mean nothing anywhere else.** Series 3
/// is armv7k at roughly 520 MHz; the Mac hosting `swift test` is two orders of magnitude faster, and
/// there is no watchOS 8 simulator to sit in between. A green run of this suite on any other
/// destination establishes only that the code compiles and the harness works.
///
/// So the measurements are *not* asserted against thresholds here. A hardcoded
/// `XCTAssertLessThan(elapsed, 0.005)` would pass trivially on a Mac and would therefore be a test
/// that reports success for the wrong reason — the exact pattern this project has been bitten by
/// twice. Instead each test measures, prints, and asserts only that the work actually happened; the
/// thresholds are checked by a human against `Tools/manual-test-protocol.md` §4, where the observed
/// figures are recorded.
///
/// To run: select the `OptimalRunnerLegacy` scheme, choose the Series 3 as destination, and run this
/// test target. See `Tools/manual-test-protocol.md` §0 for device setup.
final class PerformanceTests: XCTestCase {

    /// NFR-1 — zone evaluation under 5 ms per tick.
    ///
    /// Drives the real `RunEngine` over the real interval fixture, so what is measured is the actual
    /// per-tick cost of everything the engine does: rolling pace, grade, the target curve, zone
    /// classification, the step machine, and the alert policy.
    ///
    /// The **worst** tick matters more than the mean. A 4 ms average with a 40 ms outlier drops a
    /// frame, and a runner sees that as a stutter at exactly the moment a rep ends.
    func testPerTickEngineCost() throws {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: "intervals-4x1000"))
        let plan = try XCTUnwrap(fixture.plan)

        var engine = RunEngine(configuration: .default, plan: plan, profile: fixture.profile)
        var worst: TimeInterval = 0
        var total: TimeInterval = 0
        var ticks = 0

        for input in fixture.inputs {
            let started = Date()
            _ = engine.tick(input)
            let elapsed = Date().timeIntervalSince(started)
            worst = max(worst, elapsed)
            total += elapsed
            ticks += 1
        }

        let mean = total / Double(max(ticks, 1))
        print(
            """
            [T-072 / NFR-1] ticks=\(ticks) \
            mean=\(String(format: "%.3f", mean * 1_000)) ms \
            worst=\(String(format: "%.3f", worst * 1_000)) ms
            Record these in Tools/manual-test-protocol.md §4.2. Budget is 5 ms per tick on device.
            """
        )

        // Asserts only that the work happened — see the note on this class about thresholds.
        XCTAssertGreaterThan(ticks, 1_000, "the fixture did not drive a full run")
        XCTAssertGreaterThan(total, 0, "no time was measured, so the harness is not working")
    }

    /// The presentation cost per tick, which is what actually competes for the frame budget (NFR-2).
    ///
    /// `RunEngine.tick` is only half the per-second work; the other half is resolving a
    /// `MetricsScreen` and publishing it. On this tier that second half carries a specific risk:
    /// `ObservableObject` notifies on every assignment, unlike the Modern tier's `@Observable`, which
    /// is why `RunSessionModel` publishes one aggregate value only when it changes.
    func testPerTickPresentationCost() throws {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: "intervals-4x1000"))
        let replay = FixtureReplay.run(fixture)
        let plan = try XCTUnwrap(fixture.plan)

        var worst: TimeInterval = 0
        var total: TimeInterval = 0
        var changes = 0
        var previous: MetricsScreen?

        for output in replay.outputs {
            let started = Date()
            let screen = MetricsScreen.make(
                output: output, runType: plan.runType, profile: fixture.profile
            )
            let elapsed = Date().timeIntervalSince(started)
            worst = max(worst, elapsed)
            total += elapsed
            if screen != previous { changes += 1 }
            previous = screen
        }

        let mean = total / Double(max(replay.outputs.count, 1))
        print(
            """
            [T-072 / NFR-2] screens=\(replay.outputs.count) \
            publishes=\(changes) \
            mean=\(String(format: "%.3f", mean * 1_000)) ms \
            worst=\(String(format: "%.3f", worst * 1_000)) ms
            `publishes` is how many ticks would notify SwiftUI. If it approaches `screens`, the
            aggregate-value optimisation in RunSessionModel is not working.
            """
        )

        XCTAssertGreaterThan(replay.outputs.count, 1_000)
        // The aggregate value must actually deduplicate: a run where every tick publishes has lost
        // the only mitigation this tier has for `@Published`'s coarseness.
        XCTAssertLessThan(
            changes, replay.outputs.count,
            "every tick produced a distinct screen, so nothing is being deduplicated"
        )
    }

    /// The truncation budget, evaluated on the *running device's* real case size.
    ///
    /// The host-side matrix in `MetricsScreenTests` covers both case sizes against font-derived
    /// character budgets. What it cannot know is which panel the app is actually on, or whether the
    /// user has raised the system text size. This reports the live answer so §2.2 of the protocol has
    /// something concrete to compare against.
    func testTruncationBudgetOnThisDevice() throws {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: "tempo-5mi-rolling"))
        let replay = FixtureReplay.run(fixture)
        // Resolved here rather than via the extension target's `LegacyDevice`: a watchOS test
        // bundle cannot import the app extension it accompanies (the same confirmed Xcode limitation
        // documented for the Modern tier), so the one-line device query is repeated. The threshold
        // matches `LegacyDevice.caseSize` exactly — 38 mm is 136 pt, 42 mm is 156 pt.
        let screenWidth = Double(WKInterfaceDevice.current().screenBounds.width)
        let caseSize: LegacyCaseSize = screenWidth < 146 ? .mm38 : .mm42

        var offenders: [String] = []
        for output in replay.outputs {
            let screen = MetricsScreen.make(
                output: output, runType: .tempo, profile: fixture.profile
            )
            for risk in screen.truncationRisks(at: caseSize) {
                offenders.append(risk.description)
            }
        }

        print(
            """
            [T-072 / T-067] caseSize=\(caseSize.rawValue) \
            screenWidth=\(screenWidth) pt \
            offenders=\(Set(offenders).count)
            \(Set(offenders).sorted().joined(separator: "\n"))
            """
        )

        XCTAssertTrue(
            offenders.isEmpty,
            "a real run overflowed the layout budget on this device: \(Set(offenders).sorted())"
        )
    }

    /// Capture throughput: a full run's samples through the real store, including flushes.
    ///
    /// FR-D-6's durability comes from writing the whole accumulated array on every flush, which is
    /// O(n) per flush and therefore O(n²) across a run. That is fine for a 40-minute run and worth
    /// measuring on the slowest device, because it is the one place the design trades CPU for safety.
    func testCaptureThroughputWithRealFlushes() throws {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: "tempo-5mi-rolling"))
        let replay = FixtureReplay.run(fixture)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = SampleStore(directory: directory)
        store.startRun(runID: UUID())

        let started = Date()
        for output in replay.outputs {
            store.append(output.sample, flushIntervalSeconds: 30)
        }
        store.flush()
        let elapsed = Date().timeIntervalSince(started)

        print(
            """
            [T-072] captured \(replay.outputs.count) samples with real flushes in \
            \(String(format: "%.2f", elapsed)) s \
            (\(String(format: "%.2f", elapsed / Double(replay.outputs.count) * 1_000)) ms/sample)
            Budget context: the run loop has 1 000 ms per tick and needs almost none of it.
            """
        )

        XCTAssertGreaterThan(store.bufferedSampleCount, 1_000)
    }
}
