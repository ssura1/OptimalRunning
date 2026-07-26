import Foundation
import ORModels

/// Locates the shared `Fixtures/` directory from inside this package's tests.
///
/// Deliberately a small duplicate of `Core`'s `TestSupport.FixtureLocator` rather than
/// a dependency on it: `TestSupport` is a target inside the `Core` package with no
/// exported product, so it is unreachable from here, and exporting it would publish
/// test scaffolding as part of `Core`'s public API. The only thing duplicated is the
/// `#filePath` walk — the *files* being read are the same ones, which is the whole
/// point of AC-FR-K-1-2.
enum FixtureLocating {

    /// `<repo>/Apps/WatchModern/WatchSupport/Tests/WatchSupportTests/…` → `<repo>`.
    static let repositoryRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WatchSupportTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // WatchSupport
            .deletingLastPathComponent()   // WatchModern
            .deletingLastPathComponent()   // Apps
            .deletingLastPathComponent()   // repo root
    }()

    static var goldenDirectory: URL {
        repositoryRoot
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("golden", isDirectory: true)
    }

    static func loadGolden(named name: String) throws -> EngineGolden {
        let url = goldenDirectory.appendingPathComponent("\(name).golden.json")
        return try FixtureCoder.makeDecoder().decode(EngineGolden.self, from: Data(contentsOf: url))
    }

    /// The rendered-presentation golden, shared with the Legacy tier (AC-FR-K-1-2).
    ///
    /// A distinct `.presentation.json` suffix rather than a second key inside the engine golden:
    /// the engine golden is also read by `Core`'s own tests and by `ORConformance`, neither of
    /// which knows anything about a watch screen, and widening that file's schema for a tier
    /// concern would push presentation into Core's contract.
    static func presentationGoldenURL(named name: String) -> URL {
        goldenDirectory.appendingPathComponent("\(name).presentation.json")
    }

    static func loadPresentationGolden(named name: String) throws -> PresentationGolden {
        try FixtureCoder.makeDecoder().decode(
            PresentationGolden.self,
            from: Data(contentsOf: presentationGoldenURL(named: name))
        )
    }
}
