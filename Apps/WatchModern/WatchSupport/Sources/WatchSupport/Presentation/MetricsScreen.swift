import Foundation
import ORColor
import ORIntervals
import ORModels
import ORPace

/// Everything the metrics page renders, resolved from one `EngineOutput` (T-040,
/// design.md §12.2).
///
/// A value type with no SwiftUI in sight, which is what makes the requirements that
/// matter here testable without a simulator: that a glyph and a signed delta accompany
/// every zone colour (FR-J-1), that VO2 max never colours at all (FR-C-4), and that
/// dimming changes the swatch rather than the layout (AC-FR-A-6-6).
public struct MetricsScreen: Sendable, Hashable {

    // MARK: Colour and its redundant channels

    public let background: SRGBColor
    public let textColour: SRGBColor
    /// SF Symbol name for the direction glyph. Never empty — colour is never the only
    /// channel (FR-J-1), so there is always a shape to read.
    public let glyphSymbolName: String
    public let zoneCaption: String
    /// `+12` / `-8` seconds per preferred unit. Present whenever the zone expresses a
    /// direction, i.e. whenever the colour is saying "correct something".
    public let signedDeltaText: String?
    /// False in VO2 max mode, where the fill stays neutral at every pace (FR-C-4).
    public let appliesZoneColour: Bool
    public let zone: PaceZone

    // MARK: The five-metric stack

    public let elapsedText: String
    /// `--` after a 10 s dropout — staleness is decided by `RunEngine`, not here
    /// (AC-FR-A-6-4).
    public let heartRateText: String
    public let rollingPaceText: String
    public let targetPaceText: String?
    /// Drives the hill indicator: the effective target has diverged from the raw one
    /// because of grade (AC-FR-A-4-8).
    public let isTargetGradeAdjusted: Bool
    public let averagePaceText: String
    public let distanceText: String
    public let paceSuffix: String
    public let distanceSuffix: String

    // MARK: Structured-workout header

    /// `WORK · REP 3/4 · 340 m to go`. Replaces the zone caption line during a
    /// structured workout (design.md §12.2).
    public let stepHeaderText: String?
    /// The final-100 m countdown is up (AC-FR-C-4-5).
    public let isCountingDown: Bool

    // MARK: Always-on

    /// Secondary metrics dim while elapsed and rolling pace stay at full weight
    /// (design.md §12.2). The fraction comes from
    /// `PresentationConfiguration.alwaysOnSecondaryOpacity` — NFR-21 puts every
    /// tunable in exactly one configuration type, and this one is already declared
    /// there, so it must not be re-typed as a literal here.
    public let secondaryOpacity: Double
    public let isDimmed: Bool

    /// Whether the app is degraded in a way the runner should be told about.
    public let degradationNotice: String?

    // MARK: - Construction

    public static func make(
        output: EngineOutput,
        runType: RunType,
        profile: RunnerProfile,
        luminance: LuminanceState,
        presentation: PresentationConfiguration = PresentationConfiguration()
    ) -> MetricsScreen {
        let unit = profile.units
        let semantics = RunTypeSemantics(runType: runType)
        let palette = ZonePalette.palette(for: profile.palette)

        // VO2 max renders the neutral swatch at every pace. Not "a dimmer green" and
        // not "no background" — the neutral swatch, so the screen still reads as a
        // deliberate design rather than a failure to load (FR-C-4).
        let colouringApplies = semantics.permitsColouring
        let effectiveZone = colouringApplies ? output.zone : .neutral
        let swatch = palette.swatch(for: effectiveZone, luminance: luminance)

        // The glyph and caption track the *judged* zone even when colouring is off,
        // so an interval runner still gets direction information — just not through
        // colour. In VO2 max the engine reports `.neutral` anyway, so this collapses
        // to the neutral glyph without a special case.
        let affordance = ZoneAffordance.affordance(for: effectiveZone)

        let delta = output.signedDelta(in: unit)
        let deltaText: String? = {
            guard affordance.showsDelta, let delta, delta.isFinite else { return nil }
            return ORFormat.signedSeconds(delta)
        }()

        let gradeAdjusted: Bool = {
            guard let raw = output.rawTarget, let effective = output.effectiveTarget else {
                return false
            }
            return output.isGradeSignificant
                && abs(raw.secondsPerMetre - effective.secondsPerMetre) > 1e-9
        }()

        return MetricsScreen(
            background: swatch.background,
            textColour: swatch.text,
            glyphSymbolName: affordance.symbolName,
            zoneCaption: RunStrings.zoneCaption(affordance.captionKey),
            signedDeltaText: deltaText,
            appliesZoneColour: colouringApplies,
            zone: effectiveZone,
            elapsedText: ORFormat.duration(output.activeElapsed),
            heartRateText: output.heartRate.map { "\(Int($0.rounded()))" } ?? "--",
            rollingPaceText: ORFormat.pace(output.rollingPace, in: unit),
            targetPaceText: output.effectiveTarget.map { ORFormat.pace($0, in: unit) },
            isTargetGradeAdjusted: gradeAdjusted,
            averagePaceText: ORFormat.pace(output.averagePace, in: unit),
            distanceText: ORFormat.distance(output.cumulativeDistance, in: unit),
            paceSuffix: RunStrings.paceSuffix(unit),
            distanceSuffix: RunStrings.unitSuffix(unit),
            stepHeaderText: IntervalPresentation.stepHeader(for: output.step, unit: unit),
            isCountingDown: output.step.isCountingDown,
            secondaryOpacity: luminance == .dimmed ? presentation.alwaysOnSecondaryOpacity : 1.0,
            isDimmed: luminance == .dimmed,
            degradationNotice: Self.notice(for: output.degradations)
        )
    }

    /// The one degradation worth a word on the run screen, chosen by what the runner
    /// can act on. "GPS" tells them the pace is estimated and the band is wider;
    /// "INDOOR" explains a missing route. A missing altimeter changes nothing they can
    /// do about it, so it stays in the post-run record rather than on the screen.
    private static func notice(for flags: Set<DegradationFlag>) -> String? {
        if flags.contains(.indoorRun) { return "INDOOR" }
        if flags.contains(.gpsDegraded) { return "GPS" }
        return nil
    }
}
