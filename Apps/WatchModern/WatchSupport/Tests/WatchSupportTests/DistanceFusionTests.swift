import XCTest
import ORModels
@testable import WatchSupport

final class DistanceFusionTests: XCTestCase {

    private func reading(_ source: DistanceSource, _ distance: Double, available: Bool = true) -> DistanceReading {
        DistanceReading(source: source, cumulativeDistance: distance, isAvailable: available)
    }

    func testPrefersHealthKitOverLocationOverPedometer() {
        var fusion = DistanceFusion()
        let result = fusion.fuse(
            healthKit: reading(.healthKit, 100),
            location: reading(.location, 90),
            pedometer: reading(.pedometer, 80)
        )
        XCTAssertEqual(result.activeSource, .healthKit)
        XCTAssertEqual(result.cumulativeDistance, 100, accuracy: 1e-9)
    }

    func testFallsBackToLocationWhenHealthKitUnavailable() {
        var fusion = DistanceFusion()
        let result = fusion.fuse(
            healthKit: reading(.healthKit, 100, available: false),
            location: reading(.location, 90),
            pedometer: reading(.pedometer, 80)
        )
        XCTAssertEqual(result.activeSource, .location)
        XCTAssertEqual(result.cumulativeDistance, 90, accuracy: 1e-9)
    }

    func testFallsBackToPedometerWhenOnlyItIsAvailable() {
        var fusion = DistanceFusion()
        let result = fusion.fuse(
            healthKit: reading(.healthKit, 100, available: false),
            location: reading(.location, 90, available: false),
            pedometer: reading(.pedometer, 80)
        )
        XCTAssertEqual(result.activeSource, .pedometer)
        XCTAssertEqual(result.cumulativeDistance, 80, accuracy: 1e-9)
    }

    func testHoldsLastValueWhenNothingIsAvailable() {
        var fusion = DistanceFusion()
        _ = fusion.fuse(healthKit: reading(.healthKit, 50), location: nil, pedometer: nil)
        let result = fusion.fuse(
            healthKit: reading(.healthKit, 50, available: false), location: nil, pedometer: nil
        )
        XCTAssertEqual(result.cumulativeDistance, 50, accuracy: 1e-9)
    }

    /// A source switch must never move the fused output by more than 5 m — in
    /// this implementation, by exactly 0 m, since the new source is re-anchored to
    /// the fused value at the instant of the switch.
    func testSourceSwitchProducesNoJump() {
        var fusion = DistanceFusion()
        _ = fusion.fuse(healthKit: reading(.healthKit, 500), location: reading(.location, 480), pedometer: nil)
        let beforeSwitch = fusion.fuse(
            healthKit: reading(.healthKit, 510), location: reading(.location, 490), pedometer: nil
        ).cumulativeDistance

        // HealthKit drops out; location becomes active. Location's raw reading
        // (490) has nothing to do with the fused total (510) — the offset must
        // absorb that entire gap.
        let afterSwitch = fusion.fuse(
            healthKit: reading(.healthKit, 510, available: false),
            location: reading(.location, 490),
            pedometer: nil
        )

        XCTAssertEqual(afterSwitch.activeSource, .location)
        XCTAssertLessThanOrEqual(abs(afterSwitch.cumulativeDistance - beforeSwitch), 5.0)
        XCTAssertEqual(afterSwitch.cumulativeDistance, beforeSwitch, accuracy: 1e-9)
    }

    func testMonotonicNonDecreasingUnderRandomSourceSwitching() {
        var fusion = DistanceFusion()
        var generator = SystemRandomNumberGenerator()
        var previous = -Double.infinity
        var hk = 0.0, loc = 0.0, ped = 0.0

        for _ in 0..<2000 {
            hk += Double.random(in: 0...3, using: &generator)
            loc += Double.random(in: 0...3, using: &generator)
            ped += Double.random(in: 0...3, using: &generator)

            let hkAvailable = Bool.random(using: &generator)
            let locAvailable = Bool.random(using: &generator)
            let pedAvailable = Bool.random(using: &generator)

            let result = fusion.fuse(
                healthKit: reading(.healthKit, hk, available: hkAvailable),
                location: reading(.location, loc, available: locAvailable),
                pedometer: reading(.pedometer, ped, available: pedAvailable)
            )

            XCTAssertGreaterThanOrEqual(
                result.cumulativeDistance, previous,
                "fused distance regressed from \(previous) to \(result.cumulativeDistance)"
            )
            previous = result.cumulativeDistance
        }
    }

    func testNoJumpGreaterThan5mAcrossManySwitches() {
        var fusion = DistanceFusion()
        var generator = SystemRandomNumberGenerator()
        var previous: Double?
        var hk = 0.0, loc = 0.0, ped = 0.0
        var lastSource: DistanceSource?

        for _ in 0..<2000 {
            hk += Double.random(in: 0...3, using: &generator)
            loc += Double.random(in: 0...3, using: &generator)
            ped += Double.random(in: 0...3, using: &generator)

            let result = fusion.fuse(
                healthKit: reading(.healthKit, hk, available: Bool.random(using: &generator)),
                location: reading(.location, loc, available: Bool.random(using: &generator)),
                pedometer: reading(.pedometer, ped, available: true)
            )

            if let previous, lastSource != nil, lastSource != result.activeSource {
                XCTAssertLessThanOrEqual(
                    result.cumulativeDistance - previous, 5.0,
                    "switch from \(lastSource!) to \(result.activeSource) jumped by "
                        + "\(result.cumulativeDistance - previous) m"
                )
            }
            previous = result.cumulativeDistance
            lastSource = result.activeSource
        }
    }

    /// Regression: a source that alternates availability every tick must not freeze
    /// cumulative distance.
    ///
    /// This is the failure mode of anchoring only the switched-to source. HealthKit's
    /// live builder publishes on its own schedule, so "available on even ticks" is a
    /// realistic pattern, not a contrived one — and under the naive implementation the
    /// runner's distance stopped at its opening value and never moved again, while
    /// every single-switch test kept passing.
    func testAlternatingAvailabilityDoesNotFreezeDistance() {
        var fusion = DistanceFusion()
        var truth = 0.0

        for tick in 0..<600 {
            truth += 3
            let result = fusion.fuse(
                healthKit: reading(.healthKit, truth, available: tick % 2 == 0),
                location: reading(.location, truth),
                pedometer: reading(.pedometer, truth)
            )
            XCTAssertEqual(
                result.cumulativeDistance, truth, accuracy: 1e-9,
                "tick \(tick): fused distance drifted from the agreed truth"
            )
        }
    }

    /// The realistic degraded shape: the pedometer is always there, while HealthKit and
    /// GPS come and go independently.
    ///
    /// This — not the no-overlap case below — is what a watch actually does. `CMPedometer`
    /// does not stop reporting because a tunnel arrived, so there is always at least one
    /// source whose offset is fresh, and the fused total tracks the truth exactly.
    func testContinuousPedometerWithFlappingOtherSourcesTracksTruthExactly() {
        var fusion = DistanceFusion()
        var truth = 0.0

        for tick in 0..<900 {
            truth += 2.8
            let result = fusion.fuse(
                healthKit: reading(.healthKit, truth, available: tick % 2 == 0),
                location: reading(.location, truth, available: (tick / 7) % 2 == 0),
                pedometer: reading(.pedometer, truth)
            )
            XCTAssertEqual(result.cumulativeDistance, truth, accuracy: 1e-9, "tick \(tick)")
        }
    }

    /// Exactly one source available per tick, rotating, with no two ever overlapping.
    ///
    /// Exact tracking is **impossible** here, and that is an information limit rather
    /// than a shortcoming to fix: with no tick on which two sources are both readable,
    /// nothing observes how far the runner moved between one source's reading and a
    /// different source's next one. Any implementation that appeared to get this right
    /// would be double-counting somewhere and would over-report distance on a real run
    /// — the worse failure, since it inflates every pace the runner is judged against.
    ///
    /// So this asserts the invariants that survive: monotonic, bounded per-switch jumps,
    /// and no regression. It also pins that the total is not *frozen*, which the naive
    /// re-anchoring implementation did.
    ///
    /// A watch never actually gets here — see the pedometer test above for the shape
    /// hardware really produces.
    func testNoOverlapRotationKeepsInvariantsWithoutFreezing() {
        var fusion = DistanceFusion()
        var truth = 0.0
        var previous = 0.0
        var previousSource: DistanceSource?

        for tick in 0..<600 {
            truth += 2.5
            let result = fusion.fuse(
                healthKit: reading(.healthKit, truth, available: tick % 3 == 0),
                location: reading(.location, truth, available: tick % 3 == 1),
                pedometer: reading(.pedometer, truth, available: tick % 3 == 2)
            )

            XCTAssertGreaterThanOrEqual(result.cumulativeDistance, previous, "tick \(tick) regressed")
            if let previousSource, previousSource != result.activeSource {
                XCTAssertLessThanOrEqual(
                    result.cumulativeDistance - previous,
                    DistanceFusion.maxSwitchJumpMetres,
                    "tick \(tick) jumped past the switch budget"
                )
            }
            previous = result.cumulativeDistance
            previousSource = result.activeSource

            // Never ahead of the truth: under-reporting on impossible input is
            // acceptable, over-reporting is not.
            XCTAssertLessThanOrEqual(result.cumulativeDistance, truth + 1e-9, "tick \(tick)")
        }

        XCTAssertGreaterThan(previous, 0, "the fused total froze at its opening value")
    }

    /// A source that has been away long enough for its offset to go stale must not be
    /// allowed to yank the total forward when it returns.
    func testAStaleSourceReturningIsClampedToTheSwitchBudget() {
        var fusion = DistanceFusion()

        // HealthKit establishes the run, then disappears.
        _ = fusion.fuse(healthKit: reading(.healthKit, 100), location: reading(.location, 100), pedometer: nil)

        // Two minutes on location alone; HealthKit keeps counting internally and ends
        // up 400 m ahead of where its offset says it should be.
        var fused = 100.0
        for second in 1...120 {
            fused = fusion.fuse(
                healthKit: reading(.healthKit, 100 + Double(second) * 6, available: false),
                location: reading(.location, 100 + Double(second) * 3),
                pedometer: nil
            ).cumulativeDistance
        }

        let beforeReturn = fused
        let afterReturn = fusion.fuse(
            healthKit: reading(.healthKit, 100 + 121 * 6),
            location: reading(.location, 100 + 121 * 3),
            pedometer: nil
        )

        XCTAssertEqual(afterReturn.activeSource, .healthKit)
        XCTAssertLessThanOrEqual(
            afterReturn.cumulativeDistance - beforeReturn,
            DistanceFusion.maxSwitchJumpMetres,
            "a stale source returning jumped the total"
        )
    }

    func testResetClearsState() {
        var fusion = DistanceFusion()
        _ = fusion.fuse(healthKit: reading(.healthKit, 500), location: nil, pedometer: nil)
        fusion.reset()
        let result = fusion.fuse(healthKit: reading(.healthKit, 10), location: nil, pedometer: nil)
        XCTAssertEqual(result.cumulativeDistance, 10, accuracy: 1e-9)
    }

    func testAllSourcesUnavailableFromTheStartHoldsZero() {
        var fusion = DistanceFusion()
        let result = fusion.fuse(
            healthKit: reading(.healthKit, 10, available: false),
            location: reading(.location, 10, available: false),
            pedometer: reading(.pedometer, 10, available: false)
        )
        XCTAssertEqual(result.cumulativeDistance, 0, accuracy: 1e-9)
    }

    func testNonFiniteReadingIsTreatedAsUnavailable() {
        var fusion = DistanceFusion()
        let result = fusion.fuse(
            healthKit: reading(.healthKit, .nan),
            location: reading(.location, 42),
            pedometer: nil
        )
        XCTAssertEqual(result.activeSource, .location)
        XCTAssertEqual(result.cumulativeDistance, 42, accuracy: 1e-9)
    }
}
