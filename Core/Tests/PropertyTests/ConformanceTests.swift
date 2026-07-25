import XCTest
import ORConformance

/// XCTest wrapper over the shared conformance suite.
///
/// The assertions themselves live in `ORConformance` so that they can also be run by
/// `swift run ORSelfCheck` on a machine without Xcode, and — per design.md §16.4 — by
/// the watch app test targets, which must be checked against the *same* suite to make
/// the tier-equivalence guarantee (AC-FR-K-1-2) mean anything.
///
/// Each method maps to one suite so a CI failure names the component, not the file.
final class PropertyConformanceTests: XCTestCase {

    private func assertSuite(_ suite: CheckSuite, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(suite.results.isEmpty, "\(suite.name) ran no checks", file: file, line: line)
        for result in suite.failures {
            XCTFail("[\(suite.name)] \(result.name): \(result.failure ?? "failed")", file: file, line: line)
        }
    }

    func testGoldenReplay() { assertSuite(GoldenChecks.goldenReplay(goldenDirectory: Conformance.defaultGoldenDirectory)) }

    func testEngineBehaviour() { assertSuite(GoldenChecks.engineBehaviour()) }

    func testProperties() { assertSuite(GoldenChecks.properties()) }

}
