import XCTest
import ORColor
import ORIntervals
import ORModels
import ORPace
@testable import WatchSupport

/// T-039, T-040, T-045 — what the metrics page resolves to, and the two rules about it
/// that are easy to break silently: colour is never alone, and VO2 max never colours.
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

    private func profile(palette: PaletteChoice = .standard) -> RunnerProfile {
        RunnerProfile(tempoPace: Pace(minutesPerMile: 8), units: .miles, palette: palette)
    }

    // MARK: - FR-J-1: colour is never the only channel

    /// The full cross-product: every zone, both palettes, both luminance states must
    /// carry a glyph. This is the automated half of AC-FR-J-1-1 for this tier.
    func testEveryZoneAndPaletteAndLuminanceCarriesADirectionGlyph() {
        for palette in PaletteChoice.allCases {
            for zone in PaceZone.allCases {
                for luminance in LuminanceState.allCases {
                    let screen = MetricsScreen.make(
                        output: output(zone: zone),
                        runType: .tempo,
                        profile: profile(palette: palette),
                        luminance: luminance
                    )
                    XCTAssertFalse(
                        screen.glyphSymbolName.isEmpty,
                        "\(palette)/\(zone)/\(luminance) rendered colour with no glyph"
                    )
                    XCTAssertFalse(
                        screen.zoneCaption.isEmpty,
                        "\(palette)/\(zone)/\(luminance) rendered colour with no caption"
                    )
                }
            }
        }
    }

    /// AC-FR-J-1-2 — a signed delta accompanies every zone that expresses a direction.
    ///
    /// The four off-target zones are the ones whose colour is telling the runner to
    /// change something, and those are exactly the ones where a number must say how
    /// much. `onTarget` and `neutral` deliberately show none: there is no correction to
    /// quantify, and a `+0` would invite chasing noise.
    func testOffTargetZonesRenderASignedDelta() {
        let directional: [PaceZone] = [.tooFast, .slightlyFast, .slightlySlow, .tooSlow]

        for palette in PaletteChoice.allCases {
            for zone in directional {
                let screen = MetricsScreen.make(
                    output: output(
                        zone: zone,
                        rollingPace: Pace(minutesPerMile: 7.5),
                        target: Pace(minutesPerMile: 8)
                    ),
                    runType: .tempo,
                    profile: profile(palette: palette),
                    luminance: .normal
                )
                let delta = try? XCTUnwrap(screen.signedDeltaText)
                XCTAssertNotNil(delta, "\(palette)/\(zone) has colour but no signed delta")
                XCTAssertTrue(
                    screen.signedDeltaText?.hasPrefix("+") == true
                        || screen.signedDeltaText?.hasPrefix("-") == true,
                    "the delta must be explicitly signed, got \(screen.signedDeltaText ?? "nil")"
                )
            }
        }
    }

    func testOnTargetShowsNoDelta() {
        let screen = MetricsScreen.make(
            output: output(zone: .onTarget),
            runType: .tempo,
            profile: profile(),
            luminance: .normal
        )
        XCTAssertNil(screen.signedDeltaText)
    }

    /// AC-FR-J-1-3 restated at the tier: whatever swatch the screen resolves to, its
    /// text clears 4.5:1. `Core` asserts this over its palette tables; this asserts the
    /// screen actually uses those tables rather than substituting a colour of its own.
    func testResolvedSwatchAlwaysClears45To1() {
        for palette in PaletteChoice.allCases {
            for zone in PaceZone.allCases {
                for luminance in LuminanceState.allCases {
                    let screen = MetricsScreen.make(
                        output: output(zone: zone),
                        runType: .tempo,
                        profile: profile(palette: palette),
                        luminance: luminance
                    )
                    let ratio = screen.background.contrastRatio(against: screen.textColour)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(palette)/\(zone)/\(luminance) resolved to \(ratio):1"
                    )
                }
            }
        }
    }

    // MARK: - FR-C-4: VO2 max never colours

    /// AC-FR-C-4-2 — the neutral background holds at every pace the engine could
    /// report, including the two extremes that would be the most vivid colours in any
    /// other mode.
    func testVO2MaxRendersTheNeutralSwatchAtEveryZone() {
        for palette in PaletteChoice.allCases {
            let neutral = ZonePalette.palette(for: palette).swatch(for: .neutral)

            for zone in PaceZone.allCases {
                let screen = MetricsScreen.make(
                    output: output(zone: zone),
                    runType: .vo2max,
                    profile: profile(palette: palette),
                    luminance: .normal
                )
                XCTAssertFalse(screen.appliesZoneColour, "VO2 max claimed to apply colour")
                XCTAssertEqual(
                    screen.background, neutral.background,
                    "VO2 max showed a \(zone) colour under \(palette)"
                )
                XCTAssertEqual(screen.zone, .neutral)
            }
        }
    }

    /// Interval mode *does* colour — the guard above must not have collapsed the two
    /// structured types into one behaviour, which is the specific mistake FR-C-4 warns
    /// against.
    func testIntervalModeStillColoursUnlikeVO2Max() {
        let interval = MetricsScreen.make(
            output: output(zone: .tooFast), runType: .interval,
            profile: profile(), luminance: .normal
        )
        let vo2 = MetricsScreen.make(
            output: output(zone: .tooFast), runType: .vo2max,
            profile: profile(), luminance: .normal
        )

        XCTAssertTrue(interval.appliesZoneColour)
        XCTAssertFalse(vo2.appliesZoneColour)
        XCTAssertNotEqual(interval.background, vo2.background)
    }

    /// AC-FR-C-4-3 / AC-FR-C-4-5 — VO2 max keeps the *full* metric stack plus step
    /// context. Stripping colour must not strip information.
    func testVO2MaxKeepsTheFullMetricStackAndStepContext() {
        let step = StepState(
            phase: .running,
            step: ResolvedStep(
                index: 2, kind: .work, goal: .distance(metres: 1_000),
                target: nil, repIndex: 2, repCount: 4
            ),
            stepDistanceMetres: 660,
            stepActiveSeconds: 150,
            distanceRemainingMetres: 340,
            timeRemainingSeconds: nil,
            isCountingDown: false,
            canAdvanceManually: false,
            isUndoAvailable: false
        )

        let screen = MetricsScreen.make(
            output: output(zone: .neutral, step: step),
            runType: .vo2max,
            profile: profile(),
            luminance: .normal
        )

        XCTAssertEqual(screen.elapsedText, "25:00")
        XCTAssertEqual(screen.heartRateText, "158")
        XCTAssertNotEqual(screen.rollingPaceText, "--")
        XCTAssertNotEqual(screen.averagePaceText, "--")
        XCTAssertEqual(screen.distanceText, "3.11")
        XCTAssertEqual(screen.stepHeaderText, "WORK · REP 3/4 · 340 m to go")
    }

    // MARK: - The metric stack

    /// AC-FR-A-6-4 — a dropped heart rate reads `--`, never a stale number. `RunEngine`
    /// decides staleness; this asserts the screen renders its `nil` rather than holding
    /// the last value itself.
    func testHeartRateRendersDashesWhenTheEngineReportsNone() {
        let screen = MetricsScreen.make(
            output: output(zone: .onTarget, heartRate: nil),
            runType: .tempo, profile: profile(), luminance: .normal
        )
        XCTAssertEqual(screen.heartRateText, "--")
    }

    func testMetricsRenderInTheRunnersOwnUnits() {
        var metric = profile()
        metric.units = .kilometres

        let screen = MetricsScreen.make(
            output: output(zone: .onTarget, distance: 5_000),
            runType: .tempo, profile: metric, luminance: .normal
        )
        XCTAssertEqual(screen.distanceText, "5.00")
        XCTAssertEqual(screen.distanceSuffix, "km")
        XCTAssertEqual(screen.paceSuffix, "/km")
    }

    /// AC-FR-A-4-8 — the hill indicator appears only when grade actually moved the
    /// target, not merely because the ground is not perfectly flat.
    func testHillIndicatorTracksAnActualTargetAdjustment() {
        let flat = MetricsScreen.make(
            output: output(zone: .onTarget), runType: .tempo,
            profile: profile(), luminance: .normal
        )
        XCTAssertFalse(flat.isTargetGradeAdjusted)

        let climbing = MetricsScreen.make(
            output: output(
                zone: .onTarget,
                gradeFactor: PaceRatio(value: 1.12),
                isGradeSignificant: true
            ),
            runType: .tempo, profile: profile(), luminance: .normal
        )
        XCTAssertTrue(climbing.isTargetGradeAdjusted)
    }

    // MARK: - Always-on

    /// AC-FR-A-6-6 — dimming changes the swatch and the secondary opacity, and nothing
    /// else. Elapsed and rolling pace must read identically, because they are the two
    /// things a runner glances at without raising their wrist.
    func testDimmingChangesTheSwatchAndSecondaryOpacityOnly() {
        let normal = MetricsScreen.make(
            output: output(zone: .onTarget), runType: .tempo,
            profile: profile(), luminance: .normal
        )
        let dimmed = MetricsScreen.make(
            output: output(zone: .onTarget), runType: .tempo,
            profile: profile(), luminance: .dimmed
        )

        XCTAssertNotEqual(normal.background, dimmed.background, "dimmed must use its own variant")
        XCTAssertEqual(normal.secondaryOpacity, 1.0)
        XCTAssertEqual(dimmed.secondaryOpacity, 0.4, accuracy: 1e-9)
        XCTAssertEqual(normal.elapsedText, dimmed.elapsedText)
        XCTAssertEqual(normal.rollingPaceText, dimmed.rollingPaceText)
        XCTAssertEqual(normal.glyphSymbolName, dimmed.glyphSymbolName)
    }

    /// The opacity is a declared tunable (NFR-21), so overriding the configuration must
    /// change the screen — proving the value is read rather than hardcoded.
    func testSecondaryOpacityComesFromConfigurationNotALiteral() {
        var presentation = PresentationConfiguration()
        presentation.alwaysOnSecondaryOpacity = 0.15

        let screen = MetricsScreen.make(
            output: output(zone: .onTarget), runType: .tempo, profile: profile(),
            luminance: .dimmed, presentation: presentation
        )
        XCTAssertEqual(screen.secondaryOpacity, 0.15, accuracy: 1e-9)
    }

    // MARK: - Degradation

    func testIndoorAndGPSDegradationSurfaceANotice() {
        let indoor = MetricsScreen.make(
            output: output(zone: .onTarget, degradations: [.indoorRun]),
            runType: .tempo, profile: profile(), luminance: .normal
        )
        XCTAssertEqual(indoor.degradationNotice, "INDOOR")

        let gps = MetricsScreen.make(
            output: output(zone: .onTarget, degradations: [.gpsDegraded]),
            runType: .tempo, profile: profile(), luminance: .normal
        )
        XCTAssertEqual(gps.degradationNotice, "GPS")

        let clean = MetricsScreen.make(
            output: output(zone: .onTarget), runType: .tempo,
            profile: profile(), luminance: .normal
        )
        XCTAssertNil(clean.degradationNotice)
    }
}
