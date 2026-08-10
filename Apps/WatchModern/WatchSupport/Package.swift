// swift-tools-version: 6.2
//
// 6.2, not 6.0, and only because `SupportedPlatform.WatchOSVersion.v26` is annotated
// `@available(_PackageDescription 6.2)` — the watchOS 26 floor ADR-014 requires cannot
// be spelled by an older manifest. Deliberately the *minimum* version that can express
// it rather than the newest available: the tools version is a floor on every toolchain
// that has to build this package, and raising it further buys nothing here.
//
// It is not free. It rules out Swift 6.0/6.1 toolchains for this package, which is why
// `apps.yml`'s WatchSupport job runs on a runner whose default Xcode is 26.x — the
// `macos-15` default is Xcode 16.4 (Swift 6.1) and cannot parse this manifest at all.
// Core is untouched and keeps its lower tools version, so the Linux lane in `core.yml`
// is unaffected.
//
// WatchSupport — framework-free logic specific to the Modern watch tier.
//
// Not part of Core: ADR-001 scopes Core to engine judgement logic shared by every
// tier, not to how any one tier orchestrates its sensors. Not app-target source
// either: a confirmed Xcode limitation means neither `@testable import
// OptimalRunnerWatch` nor a plain `import OptimalRunnerWatch` resolves from the
// unhosted watchOS test target (see Apps/WatchModern/README.md). A local package
// dependency resolves fine, the same way Core already does — so this is where
// anything worth unit-testing in this tier lives.
//
// Depends on Core exactly the way the app target does, and imports no Apple
// framework of its own — everything here is pure Swift over Foundation, testable
// with `swift test` directly, no simulator required.
import PackageDescription

// Platforms are declared, unlike Core's, and the reason is `@Observable`.
//
// The view models here are observed directly by SwiftUI in the app target, so they
// carry the `Observable` macro, which requires watchOS 10 / macOS 14. Without a
// declared floor SwiftPM assumes macOS 10.13 and the macro fails to compile — and
// the compiler's suggested fix, an `@available` attribute, is exactly what CON-3
// and Tools/check-no-availability.sh exist to keep out of this tree. Raising the
// floor states the truth instead: this package serves one deployment target, and
// the macOS floor exists only so `swift test` can host it.
//
// The watchOS floor tracks the app target's, which is **watchOS 26** as of
// ADR-014 — not the watchOS 10 the `Observable` macro would settle for. The two
// must agree: a package floor below the app's would let this package compile
// against an API set the app does not have, and the mismatch would surface as a
// link error at app-build time rather than here, where it belongs.
//
// macOS 14 is a *test-host* requirement, not a product one, and is deliberately
// left where it is — it bounds which macOS can run `swift test`, and there is no
// reason for a watchOS decision to raise it. Core stays platform-unconstrained and
// Linux-testable; only this tier-specific package needs a modern host.
let package = Package(
    name: "WatchSupport",
    platforms: [
        .watchOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "WatchSupport", targets: ["WatchSupport"]),
    ],
    dependencies: [
        .package(path: "../../../Core"),
    ],
    targets: [
        .target(
            name: "WatchSupport",
            dependencies: [
                .product(name: "ORModels", package: "Core"),
                // For ActiveClock — the paused-time accounting the workout
                // session controller needs is exactly what it already does.
                // Reused, not reimplemented.
                .product(name: "ORPace", package: "Core"),
                // AlertCommand, for the haptic mapping.
                .product(name: "ORAlerts", package: "Core"),
                // StepState/ResolvedStep and RunTypeSemantics, for interval
                // presentation. The watch reads these; it never re-decides them.
                .product(name: "ORIntervals", package: "Core"),
                // Palettes and the redundant-encoding affordances. Note this is the
                // colour *science and data*, not UI — the SwiftUI `Color` bridge is
                // the app target's job (T-039).
                .product(name: "ORColor", package: "Core"),
                // RunSummaryBuilder, for the envelope's denormalized totals (T-048).
                .product(name: "ORStats", package: "Core"),
            ]
        ),
        .testTarget(
            name: "WatchSupportTests",
            dependencies: ["WatchSupport"]
        ),
    ]
)
