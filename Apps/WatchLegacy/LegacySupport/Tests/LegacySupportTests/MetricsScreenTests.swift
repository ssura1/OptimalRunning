import XCTest
import ORColor
import ORIntervals
import ORModels
import ORPace
@testable import LegacySupport

/// T-066, T-067 — what the Series 3 metrics page resolves to.
///
/// Held to the same bar as the Modern tier's equivalent (T-039/T-040/T-045), which is the point:
/// "Legacy's screen looks reasonable" is a much weaker claim than "Legacy answers the same
/// questions the Modern tier is asked". The two rules that are easy to break silently — colour is
/// never alone, and VO2 max never colours — are checked here exactly as they are there.
///
/// The case-size matrix (T-067) is the addition. It is exhaustive rather than sampled, because a
/// truncation bug is precisely the kind that appears at one specific size/zone pairing.
final class MetricsScreenTests: XCTestCase {

    // MARK: - Fixtures

    private func output(
        zone: PaceZone,
        rollingPace: Pace? = Pace(minutesPerMile: 8),
        target: Pace? = Pace(minutesPerMile: 8),
        gradeFactor: PaceRatio = .identity,
        isGradeSignificant: Bool = false,
        heartRate: Double? = 158,
        distance: Double = 5_000,
        elapsed: TimeInterval = 1_500,
        step: StepState = .idle,
        degradations: Set<DegradationFlag> = []
    ) -> EngineOutput {
        let effective = target?.scaled(by: gradeFactor)
        return EngineOutput(
            zone: zone,
            rollingPace: rollingPace,
            averagePace: Pace(minutesPerMile: 8.05),
            rawTarget: target,
            effectiveTarget: effective,
            gradeFactor: gradeFactor,
            smoothedGrade: 0,
            isGradeSignificant: isGradeSignificant,
            isGradeAvailable: true,
            isGPSDegraded: degradations.contains(.gpsDegraded),
            isStationary: false,
            isSettling: false,
            progress: 0.5,
            activeElapsed: elapsed,
            cumulativeDistance: distance,
            heartRate: heartRate,
            step: step,
            stepTransition: nil,
            alert: nil,
            degradations: degradations,
            sample: RunSample(
                timestamp: elapsed, cumulativeDistance: distance, rollingPace: rollingPace,
                heartRate: heartRate, relativeAltitude: 0, smoothedGrade: 0,
                gradeFactor: gradeFactor, rawTarget: target, effectiveTarget: effective, zone: zone
            )
        )
    }

    private func profile(
        palette: PaletteChoice = .standard, units: UnitPreference = .miles
    ) -> RunnerProfile {
        RunnerProfile(tempoPace: Pace(minutesPerMile: 8), units: units, palette: palette)
    }

    // MARK: - FR-J-1: colour is never the only channel

    /// Every zone × both palettes carries a direction glyph. The automated half of AC-FR-J-1-1 for
    /// this tier.
    ///
    /// No luminance dimension, unlike the Modern tier's version of this test, and that absence is
    /// the T-066 divergence rather than a gap: Series 3 has no always-on hardware, so
    /// `LuminanceState` is not an input this tier can vary. design.md §8.1 records it.
    func testEveryZoneAndPaletteCarriesADirectionGlyph() {
        for palette in PaletteChoice.allCases {
            for zone in PaceZone.allCases {
                let screen = MetricsScreen.make(
                    output: output(zone: zone), runType: .tempo, profile: profile(palette: palette)
                )
                XCTAssertFalse(
                    screen.glyphSymbolName.isEmpty,
                    "\(palette)/\(zone) rendered colour with no glyph, so colour is the only channel"
                )
                XCTAssertFalse(screen.zoneCaption.isEmpty)
            }
        }
    }

    /// Every *directional* zone also carries a signed pace delta, on both palettes.
    ///
    /// `.onTarget` and `.neutral` are excluded because `ZoneAffordance` sets `showsDelta: false`
    /// for both, and correctly: on target there is nothing to correct, so a "+0" would be noise
    /// dressed as instruction. An earlier version of this test asserted every non-neutral zone
    /// carried a delta and failed on `.onTarget` — the test's premise was wrong, not the code.
    /// This is the same `directional` scoping the Modern tier's equivalent test uses.
    func testDirectionalZonesCarryASignedDelta() {
        let directional: [PaceZone] = [.tooFast, .slightlyFast, .slightlySlow, .tooSlow]

        for palette in PaletteChoice.allCases {
            for zone in directional {
                let screen = MetricsScreen.make(
                    output: output(zone: zone, rollingPace: Pace(minutesPerMile: 8.4)),
                    runType: .tempo,
                    profile: profile(palette: palette)
                )
                XCTAssertNotNil(
                    screen.signedDeltaText,
                    "\(palette)/\(zone) has no signed delta beside its colour"
                )
            }
        }
    }

    // MARK: - FR-C-4: VO2 max never colours

    /// VO2 max renders the neutral swatch at every zone the engine could report, and keeps the
    /// full metric stack.
    ///
    /// The failure this guards is VO2 max collapsing into interval behaviour — the same thing
    /// Wave 2 was warned about for Modern. Checked at every zone rather than one, because a
    /// `permitsColouring` regression would show only at the zones that colour.
    func testVO2MaxNeverAppliesZoneColourAtAnyZone() {
        let neutral = ZonePalette.standard.swatch(for: .neutral, luminance: .normal)

        for zone in PaceZone.allCases {
            let screen = MetricsScreen.make(
                output: output(zone: zone), runType: .vo2max, profile: profile()
            )
            XCTAssertFalse(screen.appliesZoneColour, "VO2 max coloured at \(zone)")
            XCTAssertEqual(screen.zone, .neutral)
            XCTAssertEqual(
                screen.background, neutral.background,
                "VO2 max at \(zone) is not the neutral swatch"
            )
            // The full stack stays visible — VO2 max drops pace *judgement*, not the metrics.
            XCTAssertFalse(screen.elapsedText.isEmpty)
            XCTAssertFalse(screen.rollingPaceText.isEmpty)
            XCTAssertFalse(screen.averagePaceText.isEmpty)
            XCTAssertFalse(screen.distanceText.isEmpty)
        }
    }

    /// A paced run does colour, which is what makes the test above non-vacuous.
    func testAPacedRunDoesApplyZoneColour() {
        let screen = MetricsScreen.make(
            output: output(zone: .tooFast), runType: .tempo, profile: profile()
        )
        XCTAssertTrue(screen.appliesZoneColour)
        XCTAssertEqual(screen.zone, .tooFast)
        XCTAssertNotEqual(
            screen.background, ZonePalette.standard.swatch(for: .neutral, luminance: .normal)
                .background
        )
    }

    // MARK: - T-067: the case-size matrix

    /// **The full Cartesian product**: every zone × both palettes × both case sizes renders every
    /// metric within its row's budget.
    ///
    /// Exhaustive on purpose — T-067 asks for all of it, not a sample, because truncation shows up
    /// at one specific combination. 6 zones × 2 palettes × 2 case sizes = 24 screens.
    func testEveryZoneRendersWithoutTruncationAtBothCaseSizes() {
        for caseSize in LegacyCaseSize.allCases {
            for palette in PaletteChoice.allCases {
                for zone in PaceZone.allCases {
                    let screen = MetricsScreen.make(
                        output: output(zone: zone, rollingPace: Pace(minutesPerMile: 8.4)),
                        runType: .tempo,
                        profile: profile(palette: palette)
                    )
                    let risks = screen.truncationRisks(at: caseSize)
                    XCTAssertTrue(
                        risks.isEmpty,
                        "\(caseSize)/\(palette)/\(zone): \(risks.map(\.description).joined(separator: "; "))"
                    )
                }
            }
        }
    }

    /// The same matrix under the values that actually stress the layout, in both unit systems.
    ///
    /// A five-metric stack fits comfortably at typical values and overflows at realistic extremes,
    /// so testing only `8:00 /mi` at 5 km would prove nothing. These are the genuine worst cases:
    /// a run past four hours (`4:10:05` elapsed), a three-digit distance, and a walking-slow pace
    /// where minutes reach two digits.
    func testTheWorstCaseMetricValuesStillFitAtThirtyEightMillimetres() {
        let extremes: [(name: String, elapsed: TimeInterval, distance: Double, pace: Pace)] = [
            ("four hour ultra", 15_005, 42_195, Pace(minutesPerMile: 12.5)),
            ("very slow", 7_200, 8_000, Pace(minutesPerMile: 19.9)),
            ("fast 10k", 2_100, 10_000, Pace(minutesPerMile: 5.5)),
        ]

        for caseSize in LegacyCaseSize.allCases {
            for units in [UnitPreference.miles, .kilometres] {
                for extreme in extremes {
                    let screen = MetricsScreen.make(
                        output: output(
                            zone: .onTarget,
                            rollingPace: extreme.pace,
                            target: extreme.pace,
                            distance: extreme.distance,
                            elapsed: extreme.elapsed
                        ),
                        runType: .tempo,
                        profile: profile(units: units)
                    )
                    let risks = screen.truncationRisks(at: caseSize)
                    XCTAssertTrue(
                        risks.isEmpty,
                        "\(caseSize)/\(units)/\(extreme.name): "
                            + risks.map(\.description).joined(separator: "; ")
                    )
                }
            }
        }
    }

    /// The 38 mm panel stacks the signed delta; the 42 mm panel does not.
    ///
    /// Pins the layout decision the matrix above forced, so a future "simplification" back to a
    /// single row fails here with the reason attached rather than shipping a truncated caption.
    func testTheThirtyEightMillimetrePanelStacksTheSignedDelta() {
        let fast = MetricsScreen.make(
            output: output(zone: .slightlyFast, rollingPace: Pace(minutesPerMile: 7.6)),
            runType: .tempo, profile: profile()
        )
        XCTAssertNotNil(fast.signedDeltaText, "no delta to place, so this proves nothing")
        XCTAssertEqual(fast.zoneCaption, "A BIT FAST")

        XCTAssertTrue(
            fast.placesDeltaOnItsOwnRow(at: .mm38),
            "38 mm must stack the delta — 'A BIT FAST +24' does not fit one row"
        )
        XCTAssertFalse(
            fast.placesDeltaOnItsOwnRow(at: .mm42),
            "42 mm has room for both on one row; stacking there wastes a row"
        )

        // On target there is no delta, so there is nothing to stack at either size.
        let onTarget = MetricsScreen.make(
            output: output(zone: .onTarget), runType: .tempo, profile: profile()
        )
        XCTAssertNil(onTarget.signedDeltaText)
        XCTAssertFalse(onTarget.placesDeltaOnItsOwnRow(at: .mm38))
    }

    /// The truncation check is not vacuous — it fires on a string that genuinely does not fit.
    ///
    /// Without this, `truncationRisks` returning `[]` unconditionally would make every assertion
    /// above pass while checking nothing. This is the Wave 2 `XCTAssertTrue` lesson applied to a
    /// helper rather than to a test.
    func testTheTruncationCheckActuallyFiresOnAnOverlongString() {
        let screen = MetricsScreen.make(
            output: output(zone: .onTarget), runType: .tempo, profile: profile()
        )
        // Rebuild with a deliberately absurd elapsed string by going through the real formatter at
        // a value no run reaches: 1 000 hours.
        let absurd = MetricsScreen.make(
            output: output(zone: .onTarget, elapsed: 3_600_000), runType: .tempo, profile: profile()
        )

        XCTAssertTrue(screen.truncationRisks(at: .mm38).isEmpty, "the control case should fit")
        let risks = absurd.truncationRisks(at: .mm38)
        XCTAssertFalse(
            risks.isEmpty,
            "a 1000-hour elapsed time (\(absurd.elapsedText)) was reported as fitting 38 mm"
        )
        XCTAssertEqual(risks.first?.field, "elapsed")
    }

    // MARK: - Degradation notice and grade

    func testIndoorAndGPSDegradationsSurfaceTheRightNotice() {
        let indoor = MetricsScreen.make(
            output: output(zone: .neutral, degradations: [.indoorRun]),
            runType: .tempo, profile: profile()
        )
        XCTAssertEqual(indoor.degradationNotice, "INDOOR")

        let gps = MetricsScreen.make(
            output: output(zone: .onTarget, degradations: [.gpsDegraded]),
            runType: .tempo, profile: profile()
        )
        XCTAssertEqual(gps.degradationNotice, "GPS")

        // An absent altimeter is deliberately silent on the run screen — there is nothing the
        // runner can do about it mid-run.
        let altimeter = MetricsScreen.make(
            output: output(zone: .onTarget, degradations: [.altimeterUnavailable]),
            runType: .tempo, profile: profile()
        )
        XCTAssertNil(altimeter.degradationNotice)
    }

    /// Grade adjustment surfaces on this tier — Series 3 has the barometer (T-063), so the hill
    /// indicator is real here and not a Modern-only affordance.
    func testGradeAdjustmentSurfacesTheHillIndicator() {
        let uphill = MetricsScreen.make(
            output: output(
                zone: .onTarget, gradeFactor: PaceRatio(value: 1.08), isGradeSignificant: true
            ),
            runType: .tempo, profile: profile()
        )
        XCTAssertTrue(
            uphill.isTargetGradeAdjusted,
            "a significant grade did not surface, so Series 3's altimeter is going unused"
        )

        let flat = MetricsScreen.make(
            output: output(zone: .onTarget), runType: .tempo, profile: profile()
        )
        XCTAssertFalse(flat.isTargetGradeAdjusted)
    }
}
