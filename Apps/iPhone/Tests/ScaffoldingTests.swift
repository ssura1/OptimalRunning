import XCTest
import ORModels
@testable import OptimalRunner

/// T-005 scaffolding: proves the test target builds and links `Core`. Replaced by
/// real view-model and repository tests as Wave 3 features land.
final class ScaffoldingTests: XCTestCase {
    func testCoreLinks() {
        XCTAssertEqual(RunType.allCases.count, 5)
    }
}
