import XCTest
import ORModels
import ORPace
@testable import WatchSupport

/// The Modern tier's half of the shared presentation golden (T-044, T-045; AC-FR-K-1-2).
///
/// This tier **generates** the golden and also asserts against it. Generating and asserting in the
/// same suite is not circular: generation happens only under an explicit environment variable, so
/// on every ordinary run — including CI — this is a pure comparison against a committed file. The
/// Legacy tier compares against that same file and can never write it.
///
/// See `PresentationGolden` for why the rendered strings need a golden of their own on top of the
/// engine goldens.
final class PresentationGoldenTests: XCTestCase {

    /// The structured fixture. Interval presentation is only exercised by a structured run, and
    /// `intervals-4x1000` is the committed one — T-069 explicitly says not to invent a new interval
    /// fixture when a golden one already exists.
    private static let fixtureName = "intervals-4x1000"

    private func recorded() throws -> PresentationGolden {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: Self.fixtureName))
        let replay = FixtureReplay.run(fixture)
        return PresentationGolden.record(
            fixtureName: fixture.name,
            outputs: replay.outputs,
            unit: fixture.profile.units
        )
    }

    /// The golden matches, or is written when regeneration is explicitly requested.
    func testTheRenderedIntervalPresentationMatchesTheCommittedGolden() throws {
        let produced = try recorded()
        let url = FixtureLocating.presentationGoldenURL(named: Self.fixtureName)

        if ProcessInfo.processInfo.environment["REGENERATE_PRESENTATION_GOLDEN"] == "1" {
            try FixtureCoder.makeEncoder().encode(produced).write(to: url)
            print("regenerated \(url.lastPathComponent) with \(produced.rows.count) rows")
            return
        }

        let committed = try FixtureLocating.loadPresentationGolden(named: Self.fixtureName)

        XCTAssertEqual(
            produced, committed,
            """
            the Modern tier's interval presentation changed.
            If deliberate, regenerate with REGENERATE_PRESENTATION_GOLDEN=1 and review the diff —
            it is a behavioural change to the run screen, and the Legacy tier is held to this same
            file (AC-FR-K-1-2), so it must be re-verified too.
            rows: \(produced.rows.count) vs \(committed.rows.count)
            """
        )
    }

    /// The golden is worth having: it records the four work reps, numbered one-based.
    ///
    /// Without this, a golden that recorded zero rows would compare equal to a committed empty
    /// golden and the suite would be green while asserting nothing.
    func testTheGoldenActuallyCapturesFourOneBasedWorkReps() throws {
        let golden = try recorded()

        XCTAssertGreaterThan(golden.rows.count, 8, "too few rows to have captured the reps")

        let workHeaders = Set(golden.rows.compactMap { row -> String? in
            guard row.kind == "WORK", let index = row.repIndex, let count = row.repCount
            else { return nil }
            return "REP \(index)/\(count)"
        })

        XCTAssertEqual(
            workHeaders, ["REP 1/4", "REP 2/4", "REP 3/4", "REP 4/4"],
            "the work reps are not numbered 1…4 — a one-based repIndex regression"
        )
    }
}
