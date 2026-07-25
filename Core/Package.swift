// swift-tools-version: 6.0
//
// OptimalRunner — Core
//
// ADR-001: this package imports ONLY the Swift standard library and cross-platform
// Foundation. No HealthKit, CoreLocation, CoreMotion, WatchKit, SwiftUI, or UIKit.
// That constraint is what lets the entire engine build and test on Linux in seconds,
// and it is enforced mechanically by Tools/check-core-imports.sh on every push.
//
// There are deliberately NO external dependencies. A contributor should be able to
// clone and `swift test` with no network access.

import PackageDescription

let package = Package(
    name: "OptimalRunnerCore",
    products: [
        .library(name: "ORModels", targets: ["ORModels"]),
        .library(name: "ORPace", targets: ["ORPace"]),
        .library(name: "ORIntervals", targets: ["ORIntervals"]),
        .library(name: "ORAlerts", targets: ["ORAlerts"]),
        .library(name: "ORStats", targets: ["ORStats"]),
        .library(name: "ORColor", targets: ["ORColor"]),
    ],
    targets: [
        // MARK: - Libraries

        // Value types, units, configuration, wire DTOs. Depends on nothing.
        .target(name: "ORModels"),

        // Workout plan model and the step state machine.
        .target(name: "ORIntervals", dependencies: ["ORModels"]),

        // Dwell/cooldown alert policy. Needs ResolvedStep for transition commands.
        .target(name: "ORAlerts", dependencies: ["ORModels", "ORIntervals"]),

        // Rolling pace, target curve, grade, zones, and the RunEngine that composes
        // them with the interval machine and the alert policy.
        .target(name: "ORPace", dependencies: ["ORModels", "ORIntervals", "ORAlerts"]),

        // Aggregates, personal bests, downsampling.
        .target(name: "ORStats", dependencies: ["ORModels"]),

        // Palette data plus contrast and colour-vision-deficiency maths. No UI.
        .target(name: "ORColor", dependencies: ["ORModels"]),

        // MARK: - Conformance suite

        // Executable assertions, as a library rather than as test files.
        //
        // Two reasons this is not simply an XCTest target. First, AC-FR-K-1-2 requires
        // both watch tiers to be checked against the *same* suite, and an app test
        // target can only import a library. Second, it makes the engine verifiable
        // with a plain `swift run` on a machine with no Xcode — XCTest ships with
        // Xcode, not with the Command Line Tools.
        //
        // Excluded from the coverage gate: it is test infrastructure, not product code.
        .target(
            name: "ORConformance",
            dependencies: ["ORModels", "ORPace", "ORIntervals", "ORAlerts", "ORStats", "ORColor"]
        ),

        // MARK: - Executable

        // Golden-fixture replay CLI (T-010). Excluded from the coverage gate: it is a
        // thin argument-parsing shell over library code that is itself covered.
        .executableTarget(name: "ORSelfCheck", dependencies: ["ORConformance"]),

        .executableTarget(
            name: "ORReplay",
            dependencies: ["ORModels", "ORPace", "ORIntervals", "ORAlerts", "ORColor"]
        ),

        // MARK: - Test support

        // Locates Fixtures/ relative to the source tree so both this package and the
        // app test targets can read the same recorded traces. Not coverage-gated.
        .target(name: "TestSupport", dependencies: ["ORModels"], path: "Tests/TestSupport"),

        // MARK: - Tests

        .testTarget(name: "ORModelsTests", dependencies: ["ORModels", "ORConformance", "TestSupport"]),
        .testTarget(name: "ORPaceTests", dependencies: ["ORPace", "ORConformance", "TestSupport"]),
        .testTarget(name: "ORIntervalsTests", dependencies: ["ORIntervals", "ORConformance", "TestSupport"]),
        .testTarget(name: "ORAlertsTests", dependencies: ["ORAlerts", "ORConformance", "TestSupport"]),
        .testTarget(name: "ORStatsTests", dependencies: ["ORStats", "ORConformance", "TestSupport"]),
        .testTarget(name: "ORColorTests", dependencies: ["ORColor", "ORConformance", "TestSupport"]),
        .testTarget(
            name: "PropertyTests",
            dependencies: ["ORConformance", "TestSupport"]
        ),
    ]
)
