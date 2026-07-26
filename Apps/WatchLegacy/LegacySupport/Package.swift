// swift-tools-version: 6.0
//
// LegacySupport — framework-free logic specific to the Legacy (Series 3, watchOS 8) tier.
//
// A deliberate, complete duplicate of the role `WatchSupport` plays for the Modern tier, and
// **not** a dependency on it. ADR-002 and AC-FR-K-1-4 forbid sharing any source file between
// the two watch app targets other than through `Core`, so every type here is its own file with
// its own implementation. Tools/check-tier-isolation.sh enforces that mechanically.
//
// The duplication is the point, not an accident: what is duplicated is orchestration
// (which sensor wins, how a screen is laid out), and what is *not* duplicated is every
// judgement — zone, target, grade, alert timing, interval state — all of which lives in Core
// and is called from both tiers. R-7's mitigation is that the shared fixtures and goldens
// assert both tiers produce identical output (AC-FR-K-1-2), which is what
// TierEquivalenceTests does.
//
// ## Why this package carries more of the tier than WatchSupport does
//
// There is no watchOS 8 simulator runtime for Xcode 26 — the only installed watchOS runtime
// is 26.5, and Apple ships no watchOS 8 runtime for this Xcode. So unlike the Modern tier,
// which has a working simulator lane in CI, **`swift test` on the macOS host is the only
// automated verification this tier has.** Anything left in the app/extension target is
// verifiable on Series 3 hardware and nowhere else. That moves the boundary: this package
// holds everything that is not a literal framework call, and the extension target is kept as
// thin a shell over HealthKit/CoreLocation/CoreMotion/WatchKit as it can be.
import PackageDescription

// Platforms, and why these numbers.
//
// watchOS 8 is the product floor — Series 3's terminal OS version (CON-2). Unlike
// WatchSupport, this package must NOT be raised to watchOS 10: `@Observable` is unavailable
// here, which is exactly why the tier matrix in design.md §8.1 records `ObservableObject` +
// `@Published` as the Legacy observation mechanism. The floor is not a limitation being
// worked around, it is the tier's defining constraint.
//
// macOS 13 exists only so `swift test` can host this package on the development machine and
// in CI. It is a test-host floor, not a product claim — nothing in this package is shipped
// to a Mac.
let package = Package(
    name: "LegacySupport",
    platforms: [
        .watchOS(.v8),
        .macOS(.v13),
    ],
    products: [
        .library(name: "LegacySupport", targets: ["LegacySupport"]),
    ],
    dependencies: [
        .package(path: "../../../Core"),
    ],
    targets: [
        .target(
            name: "LegacySupport",
            dependencies: [
                .product(name: "ORModels", package: "Core"),
                // ActiveClock, RunEngine, EngineOutput — the engine this tier feeds and the
                // paused-time accounting it reuses rather than reimplements.
                .product(name: "ORPace", package: "Core"),
                // AlertCommand, for the haptic mapping.
                .product(name: "ORAlerts", package: "Core"),
                // StepState/ResolvedStep/RunTypeSemantics. The watch reads these; both tiers
                // are forbidden from re-deciding them.
                .product(name: "ORIntervals", package: "Core"),
                // Palette data and the redundant-encoding affordances — colour science, not UI.
                .product(name: "ORColor", package: "Core"),
                // RunSummaryBuilder, for the envelope's denormalized totals.
                .product(name: "ORStats", package: "Core"),
            ]
        ),
        // A capture process that exists to be killed, so FR-D-6's "loses at most one flush
        // interval" can be proved by actually crashing rather than by asserting that the
        // interval constant is 30. See Sources/legacy-capture-harness/main.swift and
        // Tests/LegacySupportTests/CrashRecoveryTests.swift.
        //
        // Not shipped: it is an executable target of a package the watch app consumes by
        // *product*, and the only product declared above is the `LegacySupport` library. So the
        // app target never links this, while `swift test` still builds it.
        .executableTarget(
            name: "legacy-capture-harness",
            dependencies: [
                "LegacySupport",
                .product(name: "ORModels", package: "Core"),
            ]
        ),
        .testTarget(
            name: "LegacySupportTests",
            dependencies: ["LegacySupport"]
        ),
    ]
)
