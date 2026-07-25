import Foundation
import ORModels

/// Locates the shared `Fixtures/` directory at the repository root.
///
/// Fixtures deliberately live outside the Swift package rather than being bundled as
/// SPM resources, because the watch and phone test targets read the *same* files —
/// that shared reading is what makes the tier-equivalence guarantee meaningful
/// (AC-FR-K-1-2). `#filePath` resolves the repository root without any build-system
/// configuration and works identically on macOS and Linux.
public enum FixtureLocator {

    /// `<repo>/Core/Tests/TestSupport/FixtureLocator.swift` → `<repo>`.
    public static let repositoryRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TestSupport
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repo root
    }()

    public static var fixturesDirectory: URL {
        repositoryRoot.appendingPathComponent("Fixtures", isDirectory: true)
    }

    public static var goldenDirectory: URL {
        fixturesDirectory.appendingPathComponent("golden", isDirectory: true)
    }

    public static func fixtureURL(named name: String) -> URL {
        fixturesDirectory.appendingPathComponent("\(name).json")
    }

    public static func goldenURL(named name: String) -> URL {
        goldenDirectory.appendingPathComponent("\(name).golden.json")
    }

    public static func loadFixture(named name: String) throws -> EngineFixture {
        let data = try Data(contentsOf: fixtureURL(named: name))
        return try FixtureCoder.makeDecoder().decode(EngineFixture.self, from: data)
    }

    public static func loadGolden(named name: String) throws -> EngineGolden {
        let data = try Data(contentsOf: goldenURL(named: name))
        return try FixtureCoder.makeDecoder().decode(EngineGolden.self, from: data)
    }

    public static func goldenExists(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: goldenURL(named: name).path)
    }

    /// Names of the standard fixtures, in the order the generator emits them.
    public static let standardNames = [
        "tempo-5mi-rolling",
        "intervals-4x1000",
        "hilly-10k",
        "gps-dropout-tunnel",
        "treadmill-indoor",
        "stop-start-traffic",
        "boundary-oscillation",
    ]
}
