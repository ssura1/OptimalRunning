import XCTest

import ORModels

@testable import PhoneMotion

/// The stationarity gate must *end* steps, not defer them (AC-FR-S-B-3-5, DEG-S-8).
///
/// `StepDetectorTests.testEmitsNoEventsDuringAStationaryInterval` already asserts that no
/// event lands inside a stationary interval, and it passed throughout the period this
/// defect existed. It could not have caught it: in the synthetic signal, running resumes
/// with clean strong impacts, so a real impact peak re-anchors the phase before the
/// phase-locked fallback is consulted, and the back-fill never fires. The real trigger is
/// a stop long enough for the gate to hold, ending in a disturbance that is *not* a
/// footfall — a phone put down on a table and later knocked — while the cadence estimate
/// is still nominally confident. Only a recording contains that.
///
/// So this test is deliberately built on a recorded trace, and on the part of it the
/// runner apologised for: `capture-2026-08-09-1924` ends with 20.5 minutes of a phone
/// lying still after the session was over. Against a true zero the estimator reported
/// **1526 steps** there before this fix, and **52** after.
final class StationaryBackfillTests: XCTestCase {

    private static let traceName = "capture-2026-08-09-1924"

    private func loadTrace(_ name: String) throws -> MotionTrace {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PhoneMotionTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // PhoneMotion
            .deletingLastPathComponent()  // iPhone
            .deletingLastPathComponent()  // Apps
            .deletingLastPathComponent()  // repo root
        let url = root.appendingPathComponent("Fixtures/motion/\(name).motion.json")
        return try MotionTrace.decode(from: Data(contentsOf: url))
    }

    /// Cumulative step count at a time, from the once-per-second replay series.
    private func stepCount(_ result: TraceReplay.Result, at seconds: TimeInterval) -> Int {
        result.distanceSamples.last { $0.atSeconds <= seconds }?.stepCount
            ?? result.distanceSamples.first?.stepCount ?? 0
    }

    private func steps(
        _ result: TraceReplay.Result, from: TimeInterval, to: TimeInterval
    ) -> Int {
        stepCount(result, at: to) - stepCount(result, at: from)
    }

    /// A phone at rest takes no steps.
    ///
    /// The stationary window is derived from the trace rather than pasted in: `CMPedometer`
    /// stops emitting readings when nothing is happening, so its own silence dates the end
    /// of the session. It is used here exactly as `ADR-S-06 amendment 1` allows — as a
    /// baseline witness to *whether* something happened, never as a step-count reference.
    /// A minute of margin is added so the boundary itself is not the thing under test.
    func testAPhoneLyingStillProducesNoSteps() throws {
        let trace = try loadTrace(Self.traceName)
        let lastPedometerReading = try XCTUnwrap(trace.pedometer.last?.timestamp)
        let traceEnd = try XCTUnwrap(trace.motion.timestamps.last)
        let from = lastPedometerReading + 60
        XCTAssertGreaterThan(
            traceEnd - from, 600,
            "this trace is supposed to carry ten minutes or more of stillness")

        let result = TraceReplay.run(trace: trace)
        let counted = steps(result, from: from, to: traceEnd)
        let impliedCadence = Double(counted) / (traceEnd - from) * 60

        // Not asserted at zero. The phone was knocked and picked up a few times, and an
        // impact detector that reported nothing at all for a phone being handled would be
        // suppressing real events. What must not survive is a *rate* — the defect held a
        // running cadence across the whole stretch.
        XCTAssertLessThan(
            impliedCadence, 10,
            "a phone at rest implied \(String(format: "%.1f", impliedCadence)) spm over "
                + "\(Int(traceEnd - from)) s (\(counted) steps). Before the phase-anchor "
                + "fix this read 75.3 spm, from 1526 steps.")
    }

    /// The other direction, on the same trace: genuine running must be untouched.
    ///
    /// Without this, the defect could be "fixed" by suppressing everything. The window is
    /// the trace's own two marks, which bound the segment the runner counted aloud, and it
    /// is continuous running from the start of the capture — nothing precedes it that
    /// could be back-filled, which is why its count is *identical* before and after the
    /// fix and why it is the right control.
    func testRunningBetweenTheMarksIsUnaffected() throws {
        let trace = try loadTrace(Self.traceName)
        XCTAssertEqual(trace.marks.count, 2, "the counted-step segment's two marks")
        let from = trace.marks[0].timestamp
        let to = trace.marks[1].timestamp

        let result = TraceReplay.run(trace: trace)
        let counted = steps(result, from: from, to: to)
        let impliedCadence = Double(counted) / (to - from) * 60

        // Bounded by physiology rather than by the measured value, so this asserts that
        // the segment still reads as *running* rather than pinning a number that a later
        // improvement would have to update. The measured figure at the time of writing is
        // 153 steps over 57.017 s = 161.0 spm, which an independent spectral integral of
        // the same window puts at 153.5.
        XCTAssertGreaterThan(counted, 140, "the marked segment is a minute of running")
        XCTAssertTrue(
            (150.0...175.0).contains(impliedCadence),
            "marked segment implied \(String(format: "%.1f", impliedCadence)) spm, which is "
                + "not a running cadence")
    }
}
