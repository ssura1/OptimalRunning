import XCTest
import ORModels
import ORPace
@testable import WatchSupport

/// The tier-equivalence test (T-036, AC-FR-K-1-2, design.md §16.4).
///
/// The claim being checked is narrow and important: **the Modern tier's adapter adds
/// nothing.** `Core`'s golden fixtures prove the engine judges a run correctly given a
/// stream of `EngineInput`. They say nothing about whether this tier *produces* that
/// stream faithfully — and a tier that quietly shifts, drops, or re-bases distance
/// would keep every `Core` test green while misbehaving on the wrist.
///
/// So each fixture is decomposed back into the raw per-source readings a real adapter
/// receives, pushed through the real `SensorPipeline`, and the resulting stream replayed
/// through `RunEngine`. The output must match the committed golden byte for byte.
///
/// This test is the reason the opening-tick bug in `DistanceFusion` mattered: the naive
/// re-anchor-always implementation shifted every fixture's distance by its first
/// reading, which no `Core` test could have seen.
final class TierEquivalenceTests: XCTestCase {

    /// design.md §8.2's priority order, as a rank. Lower wins.
    private func rank(_ source: DistanceSource) -> Int {
        switch source {
        case .healthKit: return 0
        case .location: return 1
        case .pedometer: return 2
        }
    }

    /// Rebuilds a fixture's `EngineInput` stream through this tier's adapter logic.
    ///
    /// `cumulativeDistance` from the fixture stands in for HealthKit's fused figure —
    /// the highest-priority source (design.md §8.2) and the one a Modern watch normally
    /// rides. Availability of the other two is varied per-case below.
    private func replayThroughAdapter(
        _ fixture: EngineFixture,
        activity: RunActivityKind = .outdoorRun,
        healthKitAvailable: (Int) -> Bool = { _ in true },
        locationFixUsable: (Int) -> Bool = { _ in true }
    ) -> [EngineInput] {
        var pipeline = SensorPipeline(activity: activity)

        return fixture.inputs.enumerated().map { index, input in
            // Availability is derived from the source the fixture *recorded*, so that
            // priority resolves to that same source.
            //
            // This replaced an earlier version that offered every source the fixture's
            // `cumulativeDistance` unconditionally, and the difference is not cosmetic.
            // `treadmill-indoor` declares `distanceSource: .pedometer`
            // (FixtureGenerator.swift:288); handing HealthKit a reading anyway let HealthKit
            // win on priority, so the reconstructed stream carried `.healthKit` and
            // `RunEngine` never inferred an indoor run — it reads "pedometer and no location"
            // as the indoor signal. The committed golden's `indoorRun` degradation was
            // therefore absent from this replay for the whole of Waves 2 and 3, and went
            // unnoticed because the assertion below compared five named fields and omitted
            // `degradations` entirely.
            //
            // Found by the Legacy tier's equivalent test (T-064), which compares the whole
            // `EngineGolden`. Both tiers now do.
            //
            // Sources *below* the declared one stay available on purpose: they are outranked
            // and cannot change the outcome, but their offsets keep refreshing every tick,
            // which is the switching stress this test exists to apply.
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

    // MARK: - The headline assertion

    /// All seven shared fixtures, through this tier's adapter, against the same
    /// goldens `Core` uses.
    func testEverySharedFixtureMatchesItsCommittedGoldenThroughTheAdapter() throws {
        for fixture in FixtureGenerator.standardFixtures() {
            let committed = try FixtureLocating.loadGolden(named: fixture.name)

            // Treadmill and tunnel fixtures describe indoor and GPS-less conditions;
            // the adapter must be told which, exactly as the app would from the run
            // type the user picked.
            let activity: RunActivityKind = fixture.name == "treadmill-indoor"
                ? .indoorRun : .outdoorRun

            let produced = golden(
                from: replayThroughAdapter(fixture, activity: activity),
                like: fixture
            )

            XCTAssertEqual(
                produced, committed,
                """
                \(fixture.name): the Modern adapter diverged from the committed golden.
                degraded: \(produced.degradations) vs \(committed.degradations)
                distance: \(produced.finalCumulativeDistance) vs \
                \(committed.finalCumulativeDistance)
                """
            )
        }
    }

    /// The same, with HealthKit dropping out every other second so the fusion layer is
    /// forced to switch sources roughly 1500 times in a single run.
    ///
    /// Because the sources agree, a correct re-anchoring implementation is invisible:
    /// the golden must still match exactly. An implementation that re-based on each
    /// switch, or that jumped, would diverge within the first few ticks.
    func testAlternatingSourceAvailabilityStillMatchesTheGolden() throws {
        let fixture = try XCTUnwrap(FixtureGenerator.fixture(named: "tempo-5mi-rolling"))
        let committed = try FixtureLocating.loadGolden(named: fixture.name)

        let produced = golden(
            from: replayThroughAdapter(fixture, healthKitAvailable: { $0 % 2 == 0 }),
            like: fixture
        )

        // Whole-golden equality, no tolerance. The 1e-6 accuracy this previously allowed on
        // `finalCumulativeDistance` turned out to be unnecessary — both tiers reach a
        // bit-identical result, because fusion recomputes each offset from the settled total
        // rather than folding per-tick error. Keeping a tolerance that nothing needs is how
        // Wave 3's `hasGradeAdjustment` bug happened: a comparison looser than the data's own
        // quantization, which then accepted everything including what it should have rejected.
        XCTAssertEqual(
            produced, committed,
            "alternating HealthKit availability diverged from the golden"
        )
    }

    /// The adapter is deterministic: two runs of the same raw readings agree.
    func testTheAdapterIsDeterministic() throws {
        for fixture in FixtureGenerator.standardFixtures() {
            let first = replayThroughAdapter(fixture)
            let second = replayThroughAdapter(fixture)
            XCTAssertEqual(first, second, "\(fixture.name): adapter output is not deterministic")
        }
    }

    // MARK: - Capability reporting

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
        XCTAssertEqual(input.cumulativeDistance, 100, accuracy: 1e-9)
    }

    /// Outdoors, a sustained fix drought hands distance to the pedometer (DEG-1).
    func testSustainedGPSLossFallsBackToThePedometerOutdoors() {
        var pipeline = SensorPipeline(activity: .outdoorRun, gpsTimeoutSeconds: 10)

        // Ten seconds of good fixes, HealthKit silent so location is the active source.
        for second in 0...10 {
            let input = pipeline.makeInput(from: RawSensorTick(
                timestamp: Double(second),
                locationDistance: Double(second) * 3,
                pedometerDistance: Double(second) * 3,
                isLocationFixUsable: true
            ))
            XCTAssertEqual(input.distanceSource, .location)
        }

        // Then the fixes stop. Inside the timeout, location is still trusted.
        let early = pipeline.makeInput(from: RawSensorTick(
            timestamp: 15, locationDistance: 45, pedometerDistance: 45, isLocationFixUsable: false
        ))
        XCTAssertEqual(early.distanceSource, .location, "a brief gap is not a loss")

        // Past it, the pedometer takes over.
        let late = pipeline.makeInput(from: RawSensorTick(
            timestamp: 25, locationDistance: 75, pedometerDistance: 75, isLocationFixUsable: false
        ))
        XCTAssertEqual(late.distanceSource, .pedometer)
    }
}
