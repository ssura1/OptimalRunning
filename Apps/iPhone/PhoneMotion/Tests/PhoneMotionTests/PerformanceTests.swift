import Foundation
import ORModels
import XCTest

@testable import PhoneMotion

/// Performance (S-053, NFR-S-1).
///
/// **Exactly one of the four performance requirements is asserted here, and the other three
/// say why they are not.** That asymmetry is the point, and it is the same call T-072 made
/// for the Series 3 tier: a CPU or battery figure measured in a simulator on a development
/// machine is not a measurement of anything a runner will experience, and asserting one
/// would put a green check next to a claim nobody had checked.
///
/// | Requirement | Here? | Why |
/// |---|---|---|
/// | NFR-S-1 — 60 min trace offline in < 5 s | **Yes** | Offline throughput on a dev machine is exactly what it says |
/// | NFR-S-2 — < 5% CPU sustained on device | No | No simulator proxy is meaningful |
/// | NFR-S-4 — < 20% battery for a 60 min run | No | Same |
/// | NFR-S-5 — low power saves ≥ 25% | No | Same |
///
/// The three absent ones are measured by hand and recorded in
/// `Tools/standalone-manual-protocol.md`.
final class StandalonePerformanceTests: XCTestCase {

    /// NFR-S-1 — a 60-minute trace processes offline in under five seconds.
    ///
    /// The bound exists so that a fixture run is a fast feedback loop rather than a coffee
    /// break; it is what makes "how accurate is it today" a question with a same-minute
    /// answer (AC-FR-S-F-2-5). Measured against the real 40.8-minute capture and scaled to
    /// the hour, because the alternative — generating an hour of synthetic signal — would
    /// measure the generator as much as the estimator.
    ///
    /// ## Why this asserts only in a release build
    ///
    /// The same replay of the same trace, on the same machine:
    ///
    /// | Build | Elapsed | Scaled to an hour |
    /// |---|---|---|
    /// | debug | 110.9 s | **163 s** |
    /// | release | 1.60 s | **2.36 s** |
    ///
    /// **A 70× difference**, which is what a tight numeric loop over a quarter of a million
    /// samples costs without optimisation. NFR-S-1 holds comfortably and only in release.
    ///
    /// There were three ways to handle that and two of them are wrong. Relaxing the bound
    /// to 165 s would restate a published requirement to match an unoptimised build, which
    /// is the kind of quiet redefinition this project's honesty rules exist to prevent.
    /// Asserting it anyway would make `swift test` permanently red. So the debug run
    /// **skips**, saying so — a skip is an honest "not checked here" — and `core.yml` runs
    /// this suite a second time with `-c release`, where the requirement is genuinely
    /// checked.
    ///
    /// The practical consequence is worth knowing before waiting two minutes for a replay:
    /// **run `motionreplay` with `-c release`.** `Fixtures/motion/README.md` says so now.
    func testASixtyMinuteTraceProcessesWellInsideTheBudget() throws {
        let trace = try Self.loadTrace("capture-2026-07-28-1918")
        let samples = trace.motion.samples()
        let durationSeconds = samples.last?.timestamp ?? 0
        XCTAssertGreaterThan(durationSeconds, 2000, "the trace is shorter than expected")

        let started = Date()
        _ = TraceReplay.run(trace: trace, configuration: .default)
        let elapsed = Date().timeIntervalSince(started)
        let scaledToAnHour = elapsed * (3600 / durationSeconds)
        let measured =
            "\(String(format: "%.2f", elapsed)) s for \(Int(durationSeconds)) s of running "
            + "= \(String(format: "%.2f", scaledToAnHour)) s per hour"

        #if DEBUG
            throw XCTSkip(
                "NFR-S-1 is a release-build bound and this is a debug build (\(measured)). "
                    + "core.yml re-runs this suite with -c release, where it is asserted.")
        #else
            XCTAssertLessThan(scaledToAnHour, 5.0, "NFR-S-1: \(measured)")
        #endif
    }

    /// Determinism (NFR-S-14) — the same trace produces bit-identical output.
    ///
    /// A performance test's neighbour rather than an afterthought: the reason the estimator
    /// can be replayed at all is that it has no wall clock and no randomness in it, and
    /// that property is what every golden file and every accuracy figure on this track
    /// stands on.
    func testTheSameTraceProducesBitIdenticalOutput() throws {
        let trace = try Self.loadTrace("capture-2026-07-28-2010")
        let first = TraceReplay.run(trace: trace, configuration: .default)
        let second = TraceReplay.run(trace: trace, configuration: .default)

        XCTAssertEqual(first.fusedDistanceMetres.bitPattern, second.fusedDistanceMetres.bitPattern)
        XCTAssertEqual(first.motionOnlyDistanceMetres, second.motionOnlyDistanceMetres)
        XCTAssertEqual(first.stepCount, second.stepCount)
        XCTAssertEqual(first.cadenceSamples, second.cadenceSamples)
        XCTAssertEqual(first.calibrationScale, second.calibrationScale)
    }

    /// NFR-S-3 — a cadence estimate exists within 15 s of the run starting.
    ///
    /// The bound matters because the settling window is already the runner's wait before
    /// the app says anything (FR-A-5); an estimator that added its own warm-up on top would
    /// make the first half-kilometre silent.
    func testACadenceEstimateArrivesWithinFifteenSeconds() throws {
        let trace = try Self.loadTrace("capture-2026-07-28-1918")
        let result = TraceReplay.run(trace: trace, configuration: .default)

        let first = result.cadenceSamples.first { $0.stepsPerMinute != nil }
        let at = try XCTUnwrap(first, "the trace produced no cadence at all").atSeconds
        XCTAssertLessThan(at, 15, "NFR-S-3: first cadence at \(at) s")
    }

    // MARK: - Loading

    private static func loadTrace(_ name: String) throws -> MotionTrace {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        url = url
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("motion")
            .appendingPathComponent("\(name).motion.json")
        return try MotionTrace.decode(from: try Data(contentsOf: url))
    }
}
