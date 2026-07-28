// swift-tools-version: 6.0
//
// PhoneMotion — the standalone tier's motion estimation, as pure arithmetic.
//
// Raw motion samples in; step events, cadence, step lengths and fused distance out.
// This package imports ONLY the Swift standard library, cross-platform Foundation, and
// `ORModels`. No CoreMotion, no CoreLocation, no SwiftUI, no SwiftData — enforced by
// Tools/check-core-imports.sh, which scans this package's sources alongside Core's.
//
// Why it exists at all, rather than living in the app target (standalone/design.md
// ADR-S-03): the iOS Simulator has no accelerometer and no gyroscope, and unlike GPS
// there is no GPX-equivalent to fake them (CON-S-1). Estimation code in the app target
// would be verifiable only by hand, on a phone — which for a numerical algorithm is not
// verification. Here it is `swift test` on Linux in seconds.
//
// Why not in `Core`: `Core`'s entire value is being tier-agnostic, and a step-length
// model for a hand-held phone is the opposite of that. ADR-012 already kept the watch
// tiers' fusion out of `Core` for the same reason.
//
// Why not in `PhoneSupport`: that package declares a macOS 14 floor so `swift test` can
// host SwiftData and the Observation macro (ADR-013). This is arithmetic over arrays of
// doubles and should not inherit that floor — it belongs in the fast Linux lane.
//
// There are deliberately NO external dependencies, matching Core.

import PackageDescription

// Floors inherited from `Core`, not chosen.
//
// This manifest originally declared none, on the principle that nothing here needs a
// macro, a database or a framework, so there is no floor to state. SwiftPM disagrees, and
// it is right to: `Core` declares `.macOS(.v13)` (added in the core track's Wave 4 so a
// watchOS 8 target would compile `RunSensorFeed`'s `async` methods), and a package cannot
// depend on a product with a *higher* floor than its own —
//
//   error: the library 'PhoneMotion' requires macos 10.13, but depends on the product
//   'ORModels' which requires macos 13.0
//
// So these are restated from the dependency rather than asserted about deployment. What
// actually mattered — the fast Linux lane — is unaffected either way: SwiftPM ignores
// `platforms:` on Linux entirely, which is the whole reason ADR-S-03 puts the estimator
// here rather than in `PhoneSupport`, whose macOS 14 floor comes with SwiftData attached.
let package = Package(
    name: "PhoneMotion",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PhoneMotion", targets: ["PhoneMotion"]),
    ],
    dependencies: [
        .package(path: "../../../Core"),
    ],
    targets: [
        .target(
            name: "PhoneMotion",
            dependencies: [
                // Pace, PaceRatio, DistanceSource, CarryPosition. Depending on ORModels
                // rather than redeclaring them keeps one definition of pace in a project
                // whose units convention is load-bearing (design.md §4, ADR-003) — a
                // conversion layer between two identical `Pace` types is exactly where a
                // factor of 1609.344 goes missing. ORModels imports nothing and builds
                // on Linux, so the dependency costs nothing this package protects.
                .product(name: "ORModels", package: "Core"),
            ]
        ),

        // Offline replay of a recorded motion trace (S-021). The analogue of Core's
        // ORReplay, and the only way to ask "how accurate is it today" without writing
        // code. Excluded from the coverage gate: argument parsing over library code that
        // is itself covered.
        .executableTarget(
            name: "motionreplay",
            dependencies: ["PhoneMotion"]
        ),

        .testTarget(
            name: "PhoneMotionTests",
            dependencies: ["PhoneMotion"]
        ),
    ]
)
