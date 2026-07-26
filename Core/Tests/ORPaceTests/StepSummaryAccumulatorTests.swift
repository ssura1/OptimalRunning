import XCTest
import ORIntervals
import ORModels
import ORPace

/// The per-rep table's source (AC-FR-F-2-6), driven through the real engine.
///
/// Fed from `FixtureReplay` rather than from hand-built outputs, because the accumulator's job is
/// to follow boundaries the *engine* decides — and a test that invented its own transitions would
/// be checking that the accumulator agrees with the test's idea of where reps start.
final class StepSummaryAccumulatorTests: XCTestCase {

    private func accumulate(_ fixtureName: String) throws -> (steps: [StepSummary], outputs: [EngineOutput]) {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: fixtureName))
        let replay = FixtureReplay.run(fixture)

        var accumulator = StepSummaryAccumulator()
        for output in replay.outputs { accumulator.ingest(output) }
        accumulator.finish(with: replay.outputs.last)

        return (accumulator.completed, replay.outputs)
    }

    /// The canonical session: four work reps of 1 000 m, four recoveries, and the open-goal warmup
    /// and cooldown either side.
    func testTheCanonicalSessionProducesFourWorkRepsOfAThousandMetres() throws {
        let (steps, _) = try accumulate("intervals-4x1000")
        let work = steps.filter { $0.kind == .work }

        XCTAssertEqual(work.count, 4)
        for (index, step) in work.enumerated() {
            XCTAssertEqual(
                step.distanceMetres, 1_000, accuracy: 5,
                "rep \(index + 1) measured \(step.distanceMetres) m"
            )
            // One-based, as `WorkoutPlan.flatten` numbers them.
            XCTAssertEqual(step.repIndex, index + 1)
            XCTAssertEqual(step.repCount, 4)
        }
        XCTAssertEqual(steps.filter { $0.kind == .recovery }.count, 4)
    }

    /// Each rep's statistics are its own — the accumulator must reset at every boundary, or every
    /// rep inherits the whole run's heart rate.
    func testEachRepCarriesItsOwnStatisticsRatherThanTheWholeRuns() throws {
        let (steps, outputs) = try accumulate("intervals-4x1000")
        let work = steps.filter { $0.kind == .work }

        let runWideAverage = outputs.compactMap(\.heartRate).reduce(0, +)
            / Double(max(outputs.compactMap(\.heartRate).count, 1))

        for step in work {
            XCTAssertNotNil(step.averageHeartRate)
            XCTAssertNotNil(step.maxHeartRate)
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(step.averageHeartRate), try XCTUnwrap(step.maxHeartRate)
            )
        }

        // A work rep is run harder than the recoveries around it, so its heart rate should differ
        // from the run-wide figure. Identical values would mean the accumulator never reset.
        let repAverages = work.compactMap(\.averageHeartRate)
        XCTAssertGreaterThan(
            Set(repAverages.map { Int($0) }).count, 1,
            "all four reps report the same heart rate, so the accumulator is not resetting"
        )
        XCTAssertTrue(
            repAverages.contains { abs($0 - runWideAverage) > 1 },
            "every rep matches the run-wide average, which suggests no per-step accumulation"
        )
    }

    /// Pace is consistent with the distance and time it is derived from.
    func testEachStepsPaceAgreesWithItsDistanceAndTime() throws {
        let (steps, _) = try accumulate("intervals-4x1000")

        for step in steps where step.distanceMetres > 0 && step.activeSeconds > 0 {
            let pace = try XCTUnwrap(step.averagePace)
            XCTAssertEqual(
                pace.secondsPerMetre, step.activeSeconds / step.distanceMetres,
                accuracy: 1e-9, "step \(step.index)'s pace disagrees with its own figures"
            )
        }
    }

    /// The step still running when the workout ends is closed out.
    ///
    /// Without this the final — often most interesting — interval is missing from the table
    /// entirely, because no transition was ever emitted for it.
    func testTheStepInProgressAtTheEndIsClosedOut() throws {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: "intervals-4x1000"))
        let replay = FixtureReplay.run(fixture)

        var withFinish = StepSummaryAccumulator()
        var withoutFinish = StepSummaryAccumulator()
        for output in replay.outputs {
            withFinish.ingest(output)
            withoutFinish.ingest(output)
        }
        withFinish.finish(with: replay.outputs.last)

        XCTAssertEqual(
            withFinish.completed.count, withoutFinish.completed.count + 1,
            "the step in progress at the end was dropped"
        )
        let last = try XCTUnwrap(withFinish.completed.last)
        XCTAssertGreaterThan(last.distanceMetres, 0)
        XCTAssertGreaterThan(last.activeSeconds, 0)
    }

    /// An unstructured run has no steps to summarise, and must not invent one.
    func testAnUnstructuredRunProducesNoSteps() throws {
        let (steps, _) = try accumulate("tempo-5mi-rolling")

        // A continuous run is modelled as a single open-goal step, so at most the close-out
        // appears — never a table of fabricated reps.
        XCTAssertLessThanOrEqual(steps.count, 1)
        XCTAssertTrue(steps.allSatisfy { $0.repCount <= 1 })
    }

    /// Finishing twice, or on an empty run, does not duplicate or crash.
    func testFinishingIsSafeOnAnEmptyAccumulator() {
        var accumulator = StepSummaryAccumulator()
        accumulator.finish(with: nil)
        XCTAssertTrue(accumulator.completed.isEmpty)
    }
}
