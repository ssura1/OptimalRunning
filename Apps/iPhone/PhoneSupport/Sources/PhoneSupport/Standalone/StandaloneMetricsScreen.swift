import Foundation
import ORColor
import ORIntervals
import ORModels
import ORPace

/// Everything the standalone run screen renders, resolved from one `EngineOutput` and one
/// `MotionTelemetry` (S-044, design.md §9.4).
///
/// **The screen is the tertiary channel** (FR-S-D-3), and this type is where that decision
/// stops being a slogan: it is a value with no SwiftUI in it, so the requirements that
/// matter are testable without a simulator — that a glyph and a signed delta accompany
/// every colour (AC-FR-S-D-3-2), that no new colour value is ever introduced
/// (AC-FR-S-D-3-1), that the layout does not reflow between zones (AC-FR-S-D-3-3), and
/// that an indoor run states its suppression rather than showing blanks (DEG-S-6).
///
/// It carries no `PhoneMotion` type and could not: the cadence and provenance it shows
/// arrive as `ORModels.MotionTelemetry`, which is what lets S-063's exponent change move
/// the numbers on this screen without this file being opened.
public struct StandaloneMetricsScreen: Sendable, Hashable {

    // MARK: Colour and its redundant channels

    public let background: SRGBColor
    public let textColour: SRGBColor
    /// SF Symbol name. Never empty — colour is never the only channel (FR-J-1).
    public let glyphSymbolName: String
    public let zoneCaption: String
    /// `+12` / `-8` seconds per preferred unit, whenever the zone expresses a direction.
    public let signedDeltaText: String?
    /// False in VO2 max, where the fill stays neutral at every pace (FR-C-4).
    public let appliesZoneColour: Bool
    public let zone: PaceZone

    // MARK: The metric stack
    //
    // Every one of these is non-optional and formats to `--` when absent rather than
    // disappearing. AC-FR-S-D-3-3 requires the layout to be stable so glance targets do
    // not move, and a field that vanishes when its value does is exactly how a layout
    // reflows at the worst moment.

    /// The one metric sized for arm's length in motion (AC-FR-S-D-3-3). Rolling pace,
    /// because it is the number the whole product is about.
    public let primaryMetricText: String
    public let primaryMetricCaption: String
    public let elapsedText: String
    public let distanceText: String
    public let averagePaceText: String
    public let targetPaceText: String
    /// Cadence, first-class on this tier because it is directly measured rather than
    /// derived (AC-FR-S-E-2-2).
    public let cadenceText: String
    public let paceSuffix: String
    public let distanceSuffix: String
    /// The effective target has diverged from the raw one because of grade
    /// (AC-FR-A-4-8).
    public let isTargetGradeAdjusted: Bool

    // MARK: Structured workouts

    /// `Work · Rep 3/4 · 340 m to go`.
    public let stepHeaderText: String?
    public let isCountingDown: Bool
    /// Whether a tap on the screen would advance the step (AC-FR-C-3, AC-FR-S-D-3-4).
    public let tapAdvancesStep: Bool

    // MARK: Honesty

    /// A short banner when distance is currently being estimated (AC-FR-S-C-3-3) or the
    /// run is indoors and has no distance at all (DEG-S-6). `nil` when nothing is wrong.
    public let statusNotice: String?
    /// True while the pace band is widened because distance is inferred, so the screen can
    /// show the band differently rather than implying the same precision (AC-FR-S-C-3-2).
    public let isPaceEstimated: Bool
    /// Indoor: distance and pace are suppressed, and **stated** as suppressed rather than
    /// rendered as zero (DEG-S-6, CON-S-8).
    public let isTimedOnly: Bool

    // MARK: - Construction

    public static func make(
        output: EngineOutput,
        telemetry: MotionTelemetry,
        runType: RunType,
        profile: RunnerProfile,
        activity: RunActivityKind
    ) -> StandaloneMetricsScreen {
        let unit = profile.units
        let semantics = RunTypeSemantics(runType: runType)
        let palette = ZonePalette.palette(for: profile.palette)
        let isTimedOnly = activity == .indoorRun

        // Indoors there is no distance to judge, so there is no zone to colour. Rendering
        // the neutral swatch rather than no background keeps the screen a deliberate
        // design rather than a failure to load — the same call the watch makes for VO2
        // max, for the same reason.
        let colouringApplies = semantics.permitsColouring && !isTimedOnly
        let effectiveZone = colouringApplies ? output.zone : .neutral
        // The default (normal) luminance always: a phone has no always-on display, so
        // there is no dimmed variant to select and no `isLuminanceReduced` to read. The
        // feed reports `hasAlwaysOnDisplay: false` for the same reason.
        let swatch = palette.swatch(for: effectiveZone)
        let affordance = ZoneAffordance.affordance(for: effectiveZone)

        let delta = output.signedDelta(in: unit)
        let deltaText: String? = {
            guard affordance.showsDelta, let delta, delta.isFinite, !isTimedOnly else {
                return nil
            }
            return ORFormat.signedSeconds(delta)
        }()

        let gradeAdjusted: Bool = {
            guard let raw = output.rawTarget, let effective = output.effectiveTarget else {
                return false
            }
            return output.isGradeSignificant
                && abs(raw.secondsPerMetre - effective.secondsPerMetre) > 1e-9
        }()

        // Keyed on the engine's own degraded reading rather than on the telemetry flag,
        // and the difference is that one is current and the other is sticky.
        // `MotionFlag.distanceEstimated` means "at some point in this run distance was
        // estimated" — right for the run record, wrong for a live banner, which would then
        // stay up for the remaining forty minutes after a ten-second underpass.
        // `isGPSDegraded` is also the exact condition the band widening keys on
        // (AC-FR-S-C-3-2), so the screen and the judgement cannot disagree.
        let isEstimated = output.isGPSDegraded && !isTimedOnly

        return StandaloneMetricsScreen(
            background: swatch.background,
            textColour: swatch.text,
            glyphSymbolName: affordance.symbolName,
            zoneCaption: StandaloneStrings.zoneCaption(affordance.captionKey),
            signedDeltaText: deltaText,
            appliesZoneColour: colouringApplies,
            zone: effectiveZone,
            primaryMetricText: isTimedOnly
                ? ORFormat.duration(output.activeElapsed)
                : ORFormat.pace(output.rollingPace, in: unit),
            primaryMetricCaption: isTimedOnly ? "Elapsed" : "Pace",
            elapsedText: ORFormat.duration(output.activeElapsed),
            distanceText: isTimedOnly
                ? "--" : ORFormat.distance(output.cumulativeDistance, in: unit),
            averagePaceText: isTimedOnly ? "--" : ORFormat.pace(output.averagePace, in: unit),
            targetPaceText: isTimedOnly
                ? "--" : ORFormat.pace(output.effectiveTarget, in: unit),
            cadenceText: telemetry.cadenceStepsPerMinute
                .map { "\(Int($0.rounded()))" } ?? "--",
            paceSuffix: StandaloneStrings.paceSuffix(unit),
            distanceSuffix: StandaloneStrings.unitSuffix(unit),
            isTargetGradeAdjusted: gradeAdjusted,
            stepHeaderText: stepHeader(for: output.step, unit: unit),
            isCountingDown: output.step.isCountingDown,
            tapAdvancesStep: output.step.canAdvanceManually,
            statusNotice: notice(
                isTimedOnly: isTimedOnly, output: output, telemetry: telemetry),
            isPaceEstimated: isEstimated,
            isTimedOnly: isTimedOnly)
    }

    /// The one condition worth a word on the run screen, chosen by what the runner can act
    /// on — or, in the indoor case, by what they would otherwise assume is broken.
    ///
    /// A missing altimeter and a clamped step length change nothing the runner can do, so
    /// they stay in the post-run record where they inform an explanation rather than
    /// interrupting a run.
    private static func notice(
        isTimedOnly: Bool, output: EngineOutput, telemetry: MotionTelemetry
    ) -> String? {
        if isTimedOnly {
            return "Indoor run — timed only. Distance and pace need GPS."
        }
        if telemetry.flags.contains(.carryPositionChanged) {
            return "Hold the phone in your hand for pace"
        }
        if output.isGPSDegraded {
            return telemetry.calibration.isCalibrated
                ? "GPS lost — pace estimated" : "GPS lost — no distance"
        }
        if telemetry.flags.contains(.sampleStarvation) {
            return "Cadence unavailable"
        }
        return nil
    }

    /// `Work · Rep 3/4 · 340 m to go`, or `nil` for an unstructured run.
    ///
    /// Composed here rather than reused from the watch's `IntervalPresentation` because
    /// that lives in `WatchSupport` and the phone must not reach into another tier's
    /// package. The wording differs anyway — the phone has room for words the watch
    /// abbreviates.
    private static func stepHeader(for state: StepState, unit: UnitPreference) -> String? {
        guard let step = state.step else { return nil }
        var parts = [StandaloneStrings.stepKind(step.kind)]
        if step.isRepeated { parts.append("Rep \(step.repIndex)/\(step.repCount)") }
        if let remaining = state.distanceRemainingMetres, remaining.isFinite {
            parts.append("\(Int(remaining.rounded())) m to go")
        } else if let remaining = state.timeRemainingSeconds, remaining.isFinite {
            parts.append("\(ORFormat.duration(remaining)) to go")
        }
        return parts.joined(separator: " · ")
    }
}
