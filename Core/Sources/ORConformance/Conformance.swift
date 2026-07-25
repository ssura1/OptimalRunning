import Foundation

/// The full conformance suite for `Core`.
///
/// Consumed two ways, from one definition:
///
/// - `swift run ORSelfCheck` — a plain executable, so the engine is verifiable on any
///   machine with a Swift toolchain. XCTest ships with Xcode, not with the Command
///   Line Tools, and a contributor should not need a 10 GB download to check that the
///   pace maths is right.
/// - The XCTest targets — thin wrappers that give CI per-suite granularity and
///   coverage instrumentation.
///
/// Both run the same assertions, so they cannot disagree.
public enum Conformance {

    /// - Parameter goldenDirectory: where committed goldens live. Pass `nil` to skip
    ///   golden comparison and check determinism only.
    public static func allSuites(goldenDirectory: URL? = nil) -> [CheckSuite] {
        DataChecks.all()
            + EngineChecks.all()
            + IntervalChecks.all()
            + GoldenChecks.all(goldenDirectory: goldenDirectory)
    }

    /// Resolves `<repo>/Fixtures/golden` from this file's location, so the suite works
    /// without any build-system configuration on either macOS or Linux.
    public static var defaultGoldenDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ORConformance
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("golden", isDirectory: true)
    }
}
