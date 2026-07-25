// swift-tools-version: 6.0
//
// PhoneSupport — the iPhone tier's logic, testable without a simulator.
//
// The same reasoning as `WatchSupport` (ADR-012), reaching a different conclusion for a
// different reason. On watchOS the app target is literally unreachable from its own test
// bundle; on iOS a hosted test target imports the app fine. What makes this package
// worthwhile here is instead the *nature of the work*: ingest, persistence, backfill and
// analysis are where a bug silently corrupts a run's history rather than showing a wrong
// number on a screen, and that class of code deserves a test loop measured in seconds
// rather than one that boots a simulator.
//
// SwiftData works in a package tested on the macOS host — verified before this package was
// created rather than assumed — so the store, the repositories and the ingest path all get
// that fast loop. What stays in the app target is what genuinely cannot come here:
// WatchConnectivity and HealthKit (no macOS equivalents worth faking at this level, so both
// sit behind protocols), and everything SwiftUI, Charts, or MapKit.
import PackageDescription

// iOS 17 matches the app's deployment target. macOS 14 is a *test-host* floor only —
// SwiftData and the Observation macro both need it — and exists so `swift test` can run
// here. No product ships for macOS.
let package = Package(
    name: "PhoneSupport",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PhoneSupport", targets: ["PhoneSupport"]),
    ],
    dependencies: [
        .package(path: "../../../Core"),
    ],
    targets: [
        .target(
            name: "PhoneSupport",
            dependencies: [
                .product(name: "ORModels", package: "Core"),
                // EngineOutput and FixtureReplay — the latter is what lets the analysis
                // tests run Wave 1's recorded traces end to end rather than inventing
                // synthetic envelopes per screen.
                .product(name: "ORPace", package: "Core"),
                .product(name: "ORIntervals", package: "Core"),
                // AggregateCache, PersonalBestSweep, Downsample, RunSummaryBuilder.
                .product(name: "ORStats", package: "Core"),
                // Palette data for zone-coloured charts and the route overlay. Colour
                // science, not UI.
                .product(name: "ORColor", package: "Core"),
            ]
        ),
        .testTarget(
            name: "PhoneSupportTests",
            dependencies: ["PhoneSupport"]
        ),
    ]
)
