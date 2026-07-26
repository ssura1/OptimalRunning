import Foundation
import ORModels

/// Locates the shared `Fixtures/` directory from inside this package's tests.
///
/// A small duplicate of the same `#filePath` walk the Modern tier's tests use, for the same
/// reason: `Core`'s `TestSupport` target exports no product, so it is unreachable from here,
/// and exporting it would publish test scaffolding as part of Core's public API.
///
/// What is duplicated is only the directory walk. **The files being read are the same files** —
/// byte for byte, the same seven fixtures and the same seven goldens that `Core`'s own tests and
/// the Modern tier's tests read. That shared reading is the entire mechanism behind AC-FR-K-1-2:
/// if this tier and the Modern tier both match the same committed golden exactly, then they
/// match each other exactly, by transitivity — and neither tier needs to depend on the other's
/// code to establish it, which is what keeps AC-FR-K-1-4 satisfiable.
enum FixtureLocating {

    /// `<repo>/Apps/WatchLegacy/LegacySupport/Tests/LegacySupportTests/…` → `<repo>`.
    static let repositoryRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LegacySupportTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // LegacySupport
            .deletingLastPathComponent()   // WatchLegacy
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

    /// The rendered-presentation golden the Modern tier generates (AC-FR-K-1-2).
    ///
    /// Read-only from this tier by design — see `PresentationGolden` for why only the reference tier
    /// may write it.
    static func loadPresentationGolden(named name: String) throws -> PresentationGolden {
        let url = goldenDirectory.appendingPathComponent("\(name).presentation.json")
        return try FixtureCoder.makeDecoder().decode(
            PresentationGolden.self, from: Data(contentsOf: url)
        )
    }
}
