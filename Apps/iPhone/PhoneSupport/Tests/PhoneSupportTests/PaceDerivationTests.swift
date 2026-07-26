import XCTest
import ORModels
import ORStats
@testable import PhoneSupport

/// T-062 — deriving training paces from a performance (AC-FR-I-1-2/3/5, design.md §14.1).
final class PaceDerivationTests: XCTestCase {

    /// Riegel against a worked example: a 20:00 5 k normalises to about 41:40 for 10 k.
    ///
    /// `2^1.06 ≈ 2.085`, so 1 200 s × 2.085 ≈ 2 502 s. Checked against the arithmetic rather than
    /// against whatever the implementation happens to return.
    func testRiegelNormalisationMatchesTheFormula() throws {
        let fiveK = RaceResult(distanceMetres: 5_000, seconds: 20 * 60)
        let tenK = try XCTUnwrap(
            PaceDerivation.equivalentTime(for: 10_000, from: fiveK)
        )

        XCTAssertEqual(tenK, 1_200 * pow(2, 1.06), accuracy: 0.5)
        XCTAssertEqual(tenK, 2_502, accuracy: 5, "a 20:00 5 k should normalise to about 41:42")
    }

    /// Normalising to the same distance is the identity — the degenerate case a wrong exponent
    /// sign would break.
    func testNormalisingToTheSameDistanceReturnsTheSameTime() throws {
        let result = RaceResult(distanceMetres: 10_000, seconds: 2_400)
        XCTAssertEqual(
            try XCTUnwrap(PaceDerivation.equivalentTime(for: 10_000, from: result)),
            2_400, accuracy: 1e-6
        )
    }

    /// Longer distances are slower per unit, which is the whole content of Riegel.
    func testLongerDistancesNormaliseToSlowerPaces() throws {
        let fiveK = RaceResult(distanceMetres: 5_000, seconds: 1_200)

        let tenKTime = try XCTUnwrap(PaceDerivation.equivalentTime(for: 10_000, from: fiveK))
        let halfTime = try XCTUnwrap(PaceDerivation.equivalentTime(for: 21_097.5, from: fiveK))

        let fiveKPace = try XCTUnwrap(fiveK.pace)
        let tenKPace = try XCTUnwrap(Pace(distanceMetres: 10_000, seconds: tenKTime))
        let halfPace = try XCTUnwrap(Pace(distanceMetres: 21_097.5, seconds: halfTime))

        XCTAssertTrue(tenKPace.isSlower(than: fiveKPace))
        XCTAssertTrue(halfPace.isSlower(than: tenKPace))
    }

    func testDegenerateResultsDeriveNothingRatherThanProducingInfinities() {
        XCTAssertNil(PaceDerivation.equivalentTime(
            for: 10_000, from: RaceResult(distanceMetres: 0, seconds: 1_200)
        ))
        XCTAssertNil(PaceDerivation.equivalentTime(
            for: 10_000, from: RaceResult(distanceMetres: 5_000, seconds: 0)
        ))
        XCTAssertNil(PaceDerivation.derive(
            from: RaceResult(distanceMetres: 0, seconds: 0)
        ))
    }

    // MARK: - Derived paces

    /// The three derived paces must be ordered — tempo fastest, long next, easy slowest — and all
    /// valid. An ordering inversion would have the runner doing their easy days at tempo effort.
    func testDerivedPacesAreOrderedTempoThenLongThenEasy() throws {
        let derived = try XCTUnwrap(
            PaceDerivation.derive(from: RaceResult(distanceMetres: 5_000, seconds: 1_200))
        )

        XCTAssertTrue(derived.tempo.isValid)
        XCTAssertTrue(derived.long.isSlower(than: derived.tempo))
        XCTAssertTrue(derived.easy.isSlower(than: derived.long))
    }

    /// Sanity against a real runner: a 20:00 5 k is a fit club runner, and their easy pace should
    /// land in a plausible range rather than somewhere absurd.
    func testDerivedPacesForAKnownRunnerArePlausible() throws {
        let derived = try XCTUnwrap(
            PaceDerivation.derive(from: RaceResult(distanceMetres: 5_000, seconds: 1_200))
        )

        // Equivalent 10 k ≈ 41:42, so ≈ 6:42/mi. Tempo a little slower than that.
        XCTAssertEqual(derived.tempo.minutesPerMile, 7.1, accuracy: 0.5)
        // Easy substantially slower — around 8:40/mi for this runner.
        XCTAssertEqual(derived.easy.minutesPerMile, 8.7, accuracy: 0.7)
        XCTAssertEqual(derived.long.minutesPerMile, 8.2, accuracy: 0.7)
    }

    /// A faster result derives faster paces, monotonically. A derivation that inverted anywhere
    /// would suggest slower training to a runner who had improved.
    func testAFasterResultDerivesFasterPaces() throws {
        let slower = try XCTUnwrap(
            PaceDerivation.derive(from: RaceResult(distanceMetres: 5_000, seconds: 1_500))
        )
        let faster = try XCTUnwrap(
            PaceDerivation.derive(from: RaceResult(distanceMetres: 5_000, seconds: 1_200))
        )

        XCTAssertTrue(faster.tempo.isFaster(than: slower.tempo))
        XCTAssertTrue(faster.easy.isFaster(than: slower.easy))
        XCTAssertTrue(faster.long.isFaster(than: slower.long))
    }

    func testStructuredRunTypesGetNoDerivedPace() throws {
        let derived = try XCTUnwrap(
            PaceDerivation.derive(from: RaceResult(distanceMetres: 5_000, seconds: 1_200))
        )
        XCTAssertNil(derived.pace(for: .interval))
        XCTAssertNil(derived.pace(for: .vo2max))
        XCTAssertNotNil(derived.pace(for: .tempo))
    }

    // MARK: - Choosing an effort from history

    /// The effort *nearest* 10 km wins, not the fastest per-metre.
    ///
    /// Constructed so the two criteria disagree: the 5 k best is much faster in pace terms, but
    /// the 10 k best is the reference distance itself. Riegel degrades with extrapolation, so the
    /// nearer effort is the better evidence — and picking by speed would derive easy paces far too
    /// quick, which is the failure that injures people.
    func testTheEffortNearestTheReferenceDistanceWinsOverTheFasterOne() throws {
        var cache = AggregateCache()
        cache.apply(
            summary: RunSummary(
                distanceMetres: 10_000, activeSeconds: 2_700, averagePace: nil,
                averageHeartRate: nil, maxHeartRate: nil, elevationGainMetres: 0,
                timeInZoneSeconds: []
            ),
            startedAt: Date(),
            bestEfforts: [
                // 5 k at 3:40/km — considerably faster per metre.
                .fiveKilometres: BestEffort(
                    distance: .fiveKilometres, seconds: 1_100, startDistanceMetres: 0
                ),
                // 10 k at 4:30/km — slower, but exactly the reference distance.
                .tenKilometres: BestEffort(
                    distance: .tenKilometres, seconds: 2_700, startDistanceMetres: 0
                ),
            ]
        )

        let chosen = try XCTUnwrap(PaceDerivation.bestRecentEffort(in: cache))
        XCTAssertEqual(
            chosen.distanceMetres, 10_000, accuracy: 1,
            "the faster 5 k was chosen over the 10 k, which needs no extrapolation at all"
        )
        XCTAssertEqual(chosen.seconds, 2_700, accuracy: 1)
    }

    /// And with only distances either side of the reference, the nearer one is used.
    func testTheNearerOfTwoExtrapolationsIsUsed() throws {
        var cache = AggregateCache()
        cache.apply(
            summary: RunSummary(
                distanceMetres: 21_097, activeSeconds: 5_400, averagePace: nil,
                averageHeartRate: nil, maxHeartRate: nil, elevationGainMetres: 0,
                timeInZoneSeconds: []
            ),
            startedAt: Date(),
            bestEfforts: [
                // 5 km is 5 000 m from the reference; a half is 11 097 m from it.
                .fiveKilometres: BestEffort(
                    distance: .fiveKilometres, seconds: 1_200, startDistanceMetres: 0
                ),
                .halfMarathon: BestEffort(
                    distance: .halfMarathon, seconds: 5_400, startDistanceMetres: 0
                ),
            ]
        )

        let chosen = try XCTUnwrap(PaceDerivation.bestRecentEffort(in: cache))
        XCTAssertEqual(
            chosen.distanceMetres, 5_000, accuracy: 1,
            "the half was chosen despite being twice as far from the reference distance"
        )
    }

    /// Short benchmarks are excluded entirely — a 1 km best says nothing dependable about a 10 k.
    func testShortBenchmarksAreNotUsedAsEvidence() {
        var cache = AggregateCache()
        cache.apply(
            summary: RunSummary(
                distanceMetres: 3_000, activeSeconds: 900, averagePace: nil,
                averageHeartRate: nil, maxHeartRate: nil, elevationGainMetres: 0,
                timeInZoneSeconds: []
            ),
            startedAt: Date(),
            bestEfforts: [
                .oneKilometre: BestEffort(
                    distance: .oneKilometre, seconds: 180, startDistanceMetres: 0
                ),
                .oneMile: BestEffort(distance: .oneMile, seconds: 300, startDistanceMetres: 0),
            ]
        )

        XCTAssertNil(
            PaceDerivation.bestRecentEffort(in: cache),
            "a 1 km best was used to extrapolate a 10 k estimate"
        )
    }

    func testAnEmptyHistoryYieldsNoEffort() {
        XCTAssertNil(PaceDerivation.bestRecentEffort(in: AggregateCache()))
    }

    // MARK: - Suggestions (AC-FR-I-1-5)

    /// Nothing is offered below five runs of the type.
    func testNoSuggestionBelowFiveRuns() {
        let paces = (0..<4).map { _ in Pace(minutesPerMile: 8) }
        XCTAssertNil(PaceDerivation.suggestTarget(
            for: .tempo, recentPaces: paces, currentTarget: Pace(minutesPerMile: 9)
        ))
    }

    func testASuggestionIsOfferedAtFiveRuns() throws {
        let paces = (0..<5).map { _ in Pace(minutesPerMile: 8) }
        let suggestion = try XCTUnwrap(PaceDerivation.suggestTarget(
            for: .tempo, recentPaces: paces, currentTarget: Pace(minutesPerMile: 9)
        ))

        XCTAssertEqual(suggestion.runType, .tempo)
        XCTAssertEqual(suggestion.sampleCount, 5)
        XCTAssertEqual(suggestion.suggested.minutesPerMile, 8, accuracy: 1e-6)
        XCTAssertEqual(suggestion.current?.minutesPerMile ?? 0, 9, accuracy: 1e-6)
    }

    /// The median, not the mean — so one run cut short by traffic does not drag the suggestion.
    func testTheSuggestionUsesTheMedianSoOneOutlierDoesNotDragIt() throws {
        let paces = [
            Pace(minutesPerMile: 8), Pace(minutesPerMile: 8.1), Pace(minutesPerMile: 8),
            Pace(minutesPerMile: 7.9), Pace(minutesPerMile: 14),   // a run cut short
        ]
        let suggestion = try XCTUnwrap(PaceDerivation.suggestTarget(
            for: .tempo, recentPaces: paces, currentTarget: Pace(minutesPerMile: 9)
        ))

        XCTAssertEqual(
            suggestion.suggested.minutesPerMile, 8.0, accuracy: 0.2,
            "the outlier moved the suggestion, so this is a mean rather than a median"
        )
    }

    /// A trivial change offers nothing. A prompt that fires every fifth run to move a target by
    /// two seconds teaches the runner to dismiss prompts.
    func testATrivialChangeOffersNoSuggestion() {
        let paces = (0..<6).map { _ in Pace(minutesPerMile: 8.0) }
        XCTAssertNil(PaceDerivation.suggestTarget(
            for: .tempo, recentPaces: paces, currentTarget: Pace(minutesPerMile: 8.01)
        ))
    }

    /// With no target set at all, any suggestion is meaningful — there is nothing to compare to.
    func testWithNoCurrentTargetASuggestionIsAlwaysOffered() throws {
        let paces = (0..<5).map { _ in Pace(minutesPerMile: 8) }
        let suggestion = try XCTUnwrap(
            PaceDerivation.suggestTarget(for: .easy, recentPaces: paces, currentTarget: nil)
        )
        XCTAssertNil(suggestion.current)
        XCTAssertTrue(suggestion.isMeaningful)
    }

    /// Deriving and suggesting are both pure — nothing in this type can change a stored profile,
    /// which is AC-FR-I-1-3 and AC-FR-I-1-5 at the type level rather than by convention.
    func testDerivationNeverMutatesAProfile() throws {
        var profile = RunnerProfile(tempoPace: Pace(minutesPerMile: 9))
        let before = profile

        _ = PaceDerivation.derive(from: RaceResult(distanceMetres: 5_000, seconds: 1_200))
        _ = PaceDerivation.suggestTarget(
            for: .tempo,
            recentPaces: (0..<5).map { _ in Pace(minutesPerMile: 7) },
            currentTarget: profile.tempoPace
        )

        XCTAssertEqual(profile, before)
        // And applying one is an explicit, separate act by the caller.
        profile.tempoPace = Pace(minutesPerMile: 7)
        XCTAssertNotEqual(profile, before)
    }
}
