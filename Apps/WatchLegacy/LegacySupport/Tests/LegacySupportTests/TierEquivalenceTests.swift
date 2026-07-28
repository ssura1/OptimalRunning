import XCTest
import ORModels
import ORPace
@testable import LegacySupport

/// **T-064 — the load-bearing test of Wave 4** (AC-FR-K-1-2, design.md §16.4, R-7).
///
/// ## What failure this exists to prevent
///
/// A sensor bug on one tier produces a wrong number that a runner notices. A *divergence*
/// between tiers produces two numbers that each look entirely plausible in isolation, and
/// surfaces only as "my two watches disagreed about my pace" — with no way to tell which one was
/// right. AC-FR-K-1-4 forbids the two tiers from sharing any file outside `Core`, which is the
/// correct call for removability (CON-2), but it means **nothing prevents the two
/// implementations drifting apart except a test that actively compares them.** This is that
/// test.
///
/// ## How it compares them without either tier depending on the other
///
/// Not by importing `WatchSupport` — that would create exactly the cross-tier build dependency
/// AC-FR-K-1-4 prohibits and Tools/check-tier-isolation.sh now fails on. Instead both tiers
/// assert against **the same committed golden files**, and equality with a shared third party is
/// transitive: if Legacy matches `Fixtures/golden/*.golden.json` exactly and Modern matches the
/// same files exactly, the two tiers agree exactly. No separately generated "Legacy golden"
/// exists, and creating one would defeat the entire purpose.
///
/// ## Exact equality, deliberately, with no tolerance anywhere
///
/// Each assertion compares the whole `EngineGolden` with `==` — every zone span, every alert,
/// every step transition, the sample count, the final distance, the final active elapsed, and
/// the degradation set — rather than checking fields individually against an accuracy budget.
/// `EngineGolden` is `Hashable`, so this costs nothing and is strictly stronger than a
/// field-by-field comparison.
///
/// This is a deliberate choice and worth stating, because the Modern tier's equivalent test
/// compares `finalCumulativeDistance` with `accuracy: 1e-6`. A tolerance is how Wave 3's
/// `hasGradeAdjustment` bug happened — a comparison looser than the data's own quantization,
/// which then passed for every run including ones it should have rejected. Here the tolerance
/// turns out to be unnecessary: both tiers perform the same arithmetic in the same order, so the
/// results are bit-identical, and asserting that directly means any future reordering of
/// `DistanceFusion`'s operations fails loudly instead of being absorbed into an error budget.
///
/// **This runs on the macOS host.** It cannot, by itself, establish that Series 3's armv7k
/// floating-point unit reaches the same results — see `testTheFusionArithmeticIsOrderStable`
/// below and the hardware note in Apps/WatchLegacy/README.md.
final class TierEquivalenceTests: XCTestCase {

    /// design.md §8.2's priority order, as a rank. Lower wins.
    ///
    /// `.motionModel` ranks last and is unreachable on this tier: it is the standalone
    /// phone tier's step-length model (standalone/design.md ADR-S-02), and no watch
    /// fixture declares it. It is listed so this switch stays exhaustive rather than
    /// falling through a `default:` that would silently absorb a genuinely new source.
    private func rank(_ source: DistanceSource) -> Int {
        switch source {
        case .healthKit: return 0
        case .location: return 1
        case .pedometer: return 2
        case .motionModel: return 3
        }
    }

    /// Rebuilds a fixture's `EngineInput` stream through *this tier's* adapter logic.
    ///
    /// ## Why availability is derived from the fixture's own declared source
    ///
    /// The obvious decomposition — offer every source the fixture's `cumulativeDistance` and let
    /// priority pick — is subtly unfaithful, and the first version of this test did exactly that.
    /// `treadmill-indoor` declares `distanceSource: .pedometer`, because a treadmill run *is* a
    /// pedometer run (FixtureGenerator.swift:288). Feeding HealthKit a reading anyway makes
    /// HealthKit win on priority, so the reconstructed stream carries `.healthKit`, and
    /// `RunEngine` — which infers an indoor run from "pedometer source and no location" — never
    /// raises the `indoorRun` degradation the committed golden contains.
    ///
    /// So each source is available only if it does not outrank the source the fixture recorded:
    /// if the fixture says the pedometer was active, then HealthKit and CoreLocation *had
    /// nothing to say*, which is the honest reading of what that fixture describes. Sources
    /// *below* the declared one stay available deliberately — they are outranked and cannot
    /// change the result, but their offsets keep being refreshed every tick, which preserves the
    /// switching stress this test is here to apply.
    ///
    /// This was found only because this test compares the whole `EngineGolden`. The Modern
    /// tier's equivalent compares five fields and omits `degradations`, so the same unfaithful
    /// decomposition sat there undetected — see the note in implementation.md under T-064.
    private func replayThroughAdapter(
        _ fixture: EngineFixture,
        activity: RunActivityKind = .outdoorRun,
        healthKitAvailable: (Int) -> Bool = { _ in true },
        locationFixUsable: (Int) -> Bool = { _ in true }
    ) -> [EngineInput] {
        var pipeline = SensorPipeline(activity: activity)

        return fixture.inputs.enumerated().map { index, input in
            let declared = rank(input.distanceSource)
            return pipeline.makeInput(from: RawSensorTick(
                timestamp: input.timestamp,
                healthKitDistance: rank(.healthKit) >= declared && healthKitAvailable(index)
                    ? input.cumulativeDistance : nil,
                locationDistance: rank(.location) >= declared ? input.cumulativeDistance : nil,
                pedometerDistance: rank(.pedometer) >= declared
                    ? input.cumulativeDistance : nil,
                location: input.location.map {
                    RawLocationReading(
                        timestamp: $0.timestamp,
                        latitude: $0.latitude,
                        longitude: $0.longitude,
                        altitudeMetres: $0.altitudeMetres,
                        horizontalAccuracy: $0.horizontalAccuracy,
                        verticalAccuracy: $0.verticalAccuracy
                    )
                },
                isLocationFixUsable: input.location != nil && locationFixUsable(index),
                relativeAltitude: input.relativeAltitude,
                heartRate: input.heartRate,
                isPaused: input.isPaused,
                manualAdvanceRequested: input.manualAdvanceRequested
            ))
        }
    }

    private func golden(from inputs: [EngineInput], like fixture: EngineFixture) -> EngineGolden {
        FixtureReplay.run(EngineFixture(
            name: fixture.name,
            describes: fixture.describes,
            runType: fixture.runType,
            profile: fixture.profile,
            plan: fixture.plan,
            inputs: inputs
        )).golden
    }

    /// The treadmill fixture is the one that must be told it is indoors, exactly as the app
    /// would be from the run type the user picked. Deriving this from the fixture name rather
    /// than hardcoding a list keeps it honest if a fixture is added.
    private func activity(for fixture: EngineFixture) -> RunActivityKind {
        fixture.name == "treadmill-indoor" ? .indoorRun : .outdoorRun
    }

    // MARK: - The headline assertion

    /// All seven shared fixtures, through this tier's adapter, against the same committed
    /// goldens `Core` and the Modern tier use — compared in full, with no tolerance.
    func testEverySharedFixtureMatchesItsCommittedGoldenExactly() throws {
        let fixtures = FixtureGenerator.standardFixtures()

        // Guards against the whole test silently passing because the fixture set came back
        // empty — a vacuous green is the failure mode a loop-over-collection test invites.
        XCTAssertEqual(fixtures.count, 7, "expected seven shared fixtures")

        for fixture in fixtures {
            let committed = try FixtureLocating.loadGolden(named: fixture.name)
            let produced = golden(
                from: replayThroughAdapter(fixture, activity: activity(for: fixture)),
                like: fixture
            )

            XCTAssertEqual(
                produced, committed,
                """
                \(fixture.name): the Legacy adapter diverged from the committed golden.
                This is an AC-FR-K-1-2 failure — the two watch tiers no longer agree.
                Do NOT regenerate the golden to make this pass: the golden is shared with
                Core and the Modern tier, and rewriting it hides the divergence instead of
                resolving it.
                zone spans:  \(produced.zoneTimeline.count) vs \(committed.zoneTimeline.count)
                alerts:      \(produced.alerts.count) vs \(committed.alerts.count)
                transitions: \(produced.transitions.count) vs \(committed.transitions.count)
                samples:     \(produced.sampleCount) vs \(committed.sampleCount)
                distance:    \(produced.finalCumulativeDistance) vs \
                \(committed.finalCumulativeDistance)
                active:      \(produced.finalActiveElapsed) vs \(committed.finalActiveElapsed)
                degraded:    \(produced.degradations) vs \(committed.degradations)
                """
            )
        }
    }

    /// Proof that the assertion above is not vacuous.
    ///
    /// A loop comparing produced-to-committed passes trivially if both sides are somehow the
    /// same object, or if the goldens happen to be interchangeable between fixtures. So: assert
    /// that a golden from one fixture does *not* match another fixture's committed golden. If
    /// this fails, the headline test is not discriminating and its green means nothing.
    func testTheGoldenComparisonActuallyDiscriminatesBetweenFixtures() throws {
        let tempo = try XCTUnwrap(FixtureGenerator.fixture(named: "tempo-5mi-rolling"))
        let intervals = try FixtureLocating.loadGolden(named: "intervals-4x1000")

        let produced = golden(from: replayThroughAdapter(tempo), like: tempo)

        XCTAssertNotEqual(
            produced, intervals,
            "the tempo replay matched the intervals golden, so equality is not discriminating"
        )
    }

    /// The same seven fixtures with HealthKit dropping out every other second, so the fusion
    /// layer is forced to switch sources roughly 1 500 times in a single run.
    ///
    /// Because the sources agree, a correct re-anchoring implementation is *invisible* — the
    /// golden must still match exactly. This is the case that caught the Modern tier's
    /// alternating-source freeze in Wave 2: an implementation refreshing only the active
    /// source's offset holds distance at its opening value for the whole run, and an
    /// implementation re-anchoring on every switch loses a metre per switch. Either way this
    /// diverges within the first few ticks.
    func testAlternatingSourceAvailabilityStillMatchesEveryGoldenExactly() throws {
        for fixture in FixtureGenerator.standardFixtures() {
            let committed = try FixtureLocating.loadGolden(named: fixture.name)
            let produced = golden(
                from: replayThroughAdapter(
                    fixture,
                    activity: activity(for: fixture),
                    healthKitAvailable: { $0 % 2 == 0 }
                ),
                like: fixture
            )

            XCTAssertEqual(
                produced, committed,
                "\(fixture.name): alternating HealthKit availability diverged from the golden"
            )
        }
    }

    /// The adapter is deterministic: the same raw readings twice give the same stream.
    func testTheAdapterIsDeterministic() {
        for fixture in FixtureGenerator.standardFixtures() {
            let first = replayThroughAdapter(fixture, activity: activity(for: fixture))
            let second = replayThroughAdapter(fixture, activity: activity(for: fixture))
            XCTAssertEqual(first, second, "\(fixture.name): adapter output is not deterministic")
        }
    }

    // MARK: - The architecture question this test cannot answer on a Mac

    /// Establishes that fusion's result depends only on the *values* it is given, not on how
    /// many ticks it took to reach them — the property that would break first if armv7k's
    /// floating-point behaviour differed from arm64's.
    ///
    /// This is honest about its own limits. It runs on the host's arm64 FPU, so it cannot prove
    /// anything about Series 3's armv7k unit; the watchOS 8 *simulator* could not either, since
    /// no such runtime exists for Xcode 26 and a simulator would run on the host's architecture
    /// regardless. What it does prove is that the algorithm contains no accumulation of
    /// per-tick rounding error — every offset is recomputed from the settled total rather than
    /// folded incrementally — which is the structural property that makes a cross-architecture
    /// divergence *possible to rule out* on hardware with a single fixture replay, rather than
    /// something that could hide in the 1 500th tick.
    ///
    /// The on-device replay itself is the first item on the hardware-verification list.
    func testTheFusionArithmeticIsOrderStable() {
        var coarse = DistanceFusion()
        var fine = DistanceFusion()

        // The same 1 000 m covered in 10 ticks and in 1 000 ticks.
        for step in stride(from: 100.0, through: 1_000.0, by: 100.0) {
            _ = coarse.fuse(
                healthKit: DistanceReading(
                    source: .healthKit, cumulativeDistance: step, isAvailable: true
                ),
                location: nil, pedometer: nil
            )
        }
        var fineResult = 0.0
        for step in stride(from: 1.0, through: 1_000.0, by: 1.0) {
            fineResult = fine.fuse(
                healthKit: DistanceReading(
                    source: .healthKit, cumulativeDistance: step, isAvailable: true
                ),
                location: nil, pedometer: nil
            ).cumulativeDistance
        }

        let coarseResult = coarse.fuse(
            healthKit: DistanceReading(
                source: .healthKit, cumulativeDistance: 1_000, isAvailable: true
            ),
            location: nil, pedometer: nil
        ).cumulativeDistance

        XCTAssertEqual(
            coarseResult, fineResult,
            "fusion accumulates per-tick error, so tick rate changes the answer"
        )
        XCTAssertEqual(fineResult, 1_000)
    }

    // MARK: - Capability reporting (T-063)

    /// The indoor path must exclude CoreLocation outright (DEG-10), which is what makes
    /// `RunEngine` recognise the run as indoor: a pedometer source with no location.
    func testIndoorActivityForwardsNoLocationAndUsesThePedometer() {
        var pipeline = SensorPipeline(activity: .indoorRun)
        let input = pipeline.makeInput(from: RawSensorTick(
            timestamp: 1,
            healthKitDistance: nil,
            locationDistance: 500,
            pedometerDistance: 100,
            location: RawLocationReading(
                timestamp: 1, latitude: 51.5, longitude: -0.12,
                altitudeMetres: 0, horizontalAccuracy: 5, verticalAccuracy: 5
            ),
            isLocationFixUsable: true,
            relativeAltitude: 12
        ))

        XCTAssertNil(input.location, "indoors, a stray fix must not be forwarded")
        XCTAssertNil(input.relativeAltitude, "indoors, grade must be disabled not assumed flat")
        XCTAssertEqual(input.distanceSource, .pedometer)
        XCTAssertEqual(input.cumulativeDistance, 100)
    }

    /// Outdoors, a sustained fix drought hands distance to the pedometer (DEG-1).
    func testSustainedGPSLossFallsBackToThePedometerOutdoors() {
        var pipeline = SensorPipeline(activity: .outdoorRun, gpsTimeoutSeconds: 10)

        for second in 0...10 {
            let input = pipeline.makeInput(from: RawSensorTick(
                timestamp: Double(second),
                locationDistance: Double(second) * 3,
                pedometerDistance: Double(second) * 3,
                isLocationFixUsable: true
            ))
            XCTAssertEqual(input.distanceSource, .location)
        }

        let early = pipeline.makeInput(from: RawSensorTick(
            timestamp: 15, locationDistance: 45, pedometerDistance: 45, isLocationFixUsable: false
        ))
        XCTAssertEqual(early.distanceSource, .location, "a brief gap is not a loss")

        let late = pipeline.makeInput(from: RawSensorTick(
            timestamp: 25, locationDistance: 75, pedometerDistance: 75, isLocationFixUsable: false
        ))
        XCTAssertEqual(late.distanceSource, .pedometer)
    }

    /// Series 3's capability set, asserted rather than assumed (T-063).
    ///
    /// `hasAltimeter` is the one worth a test: the plausible-but-wrong assumption is that the
    /// oldest supported watch lacks the barometer, and acting on it would silently disable grade
    /// adjustment on hardware that supports it.
    func testSeriesThreeReportsItsRealCapabilities() {
        let capabilities = LegacyCapabilities.seriesThree

        XCTAssertTrue(
            capabilities.hasAltimeter,
            "Series 3 has the barometric altimeter, so grade adjustment must not no-op"
        )
        XCTAssertTrue(capabilities.hasGPS)
        XCTAssertFalse(capabilities.hasAlwaysOnDisplay, "no AOD hardware before Series 5")
        XCTAssertFalse(
            capabilities.supportsNativeActivitySegmentation,
            "beginNewActivity is watchOS 9+; this tier uses HKWorkoutEvent(.segment)"
        )
        XCTAssertFalse(capabilities.supportsDoubleTap, "Double Tap is Series 9+ hardware")
    }

    /// Grade adjustment is genuinely live on this tier, driven through the real pipeline rather
    /// than asserted from the capability flag.
    ///
    /// The capability test above proves the flag says "altimeter present". This proves the
    /// altitude actually reaches `EngineInput` outdoors — a tier could report the capability and
    /// still drop the reading, which is precisely the silent no-op T-063 warns about.
    func testGradeAdjustmentReachesTheEngineOutdoorsOnThisTier() {
        var pipeline = SensorPipeline(activity: .outdoorRun)
        let input = pipeline.makeInput(from: RawSensorTick(
            timestamp: 1,
            healthKitDistance: 10,
            isLocationFixUsable: true,
            relativeAltitude: 7.5
        ))

        XCTAssertEqual(
            input.relativeAltitude, 7.5,
            "the altimeter reading was dropped, so grade adjustment silently no-ops"
        )
    }
}
