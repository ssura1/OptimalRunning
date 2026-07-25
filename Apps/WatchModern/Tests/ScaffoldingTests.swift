import XCTest
import ORModels

/// T-005 scaffolding: proves the test target builds and links `Core`.
///
/// **Cannot `@testable import OptimalRunnerWatch`.** Tried it — an unhosted
/// watchOS single-target test bundle (see project.yml's note on
/// `OptimalRunnerWatchTests` for why it's unhosted) fails to resolve the app
/// module even as a link-only, non-embedded dependency ("Unable to resolve module
/// dependency"). This is a real Xcode/watchOS limitation, not a project.yml
/// misconfiguration. Practical consequence for Wave 2 and later: anything in
/// `Apps/WatchModern` that needs unit-level testing must be `public` and reachable
/// through a normal `import`, not `internal` behind `@testable`. Given ADR-001 —
/// the app target is meant to be a thin shell converting sensor events to `Core`
/// value types — this should rarely bind in practice; the judgement logic worth
/// testing in isolation already lives in `Core`, which has no such restriction.
final class ScaffoldingTests: XCTestCase {
    func testCoreLinks() {
        XCTAssertEqual(RunType.allCases.count, 5)
    }
}
