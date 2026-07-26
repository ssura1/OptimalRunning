import Foundation
import ORColor
import ORIntervals
import ORModels
import ORPace

/// The two Series 3 display sizes (T-067).
///
/// Point dimensions, not pixels: Series 3 is @2x, so the 38 mm panel's 272×340 px is 136×170 pt
/// and the 42 mm panel's 312×390 px is 156×195 pt. Layout budgets are in points because that is
/// what SwiftUI lays out in.
///
/// This enum exists at all — rather than the views simply using `GeometryReader` — because
/// "renders without truncation at 38 mm" (T-067) has to be *assertable*, and no test on this tier
/// can measure a rendered pixel: there is no watchOS 8 simulator for Xcode 26. Making the case
/// size an explicit input turns a visual property into a checkable one. See
/// `MetricsScreen.truncationRisks(at:)` for exactly how far that goes, and how far it does not.
public enum LegacyCaseSize: String, Sendable, Hashable, CaseIterable, Codable {
    case mm38
    case mm42

    /// Full panel width in points.
    public var widthPoints: Double {
        switch self {
        case .mm38: return 136
        case .mm42: return 156
        }
    }

    /// Usable width after the system's own horizontal insets.
    ///
    /// watchOS reserves roughly 8 pt each side on these panels. Rounded conservatively — the risk
    /// worth protecting against is over-estimating available room, since that is the direction
    /// that ships a truncated metric.
    public var contentWidthPoints: Double { widthPoints - 16 }

    /// How many characters of the primary metric font fit across `contentWidthPoints`.
    ///
    /// Derived from the font, not guessed: the primary metrics use a rounded-design semibold face
    /// at 30 pt on 38 mm and 34 pt on 42 mm, whose digit advance in SF Rounded is very close to
    /// 0.56 em. So 38 mm allows ⌊120 / (30 × 0.56)⌋ = 7 characters, and 42 mm allows
    /// ⌊140 / (34 × 0.56)⌋ = 7. Both land at 7, which is the useful finding: the larger panel buys
    /// a larger font rather than more characters, so a string that overflows at 38 mm generally
    /// overflows at 42 mm too, and the case-size matrix is guarding against a *layout* mistake
    /// rather than a character-count one.
    public var primaryMetricCharacterBudget: Int { 7 }

    /// The caption row — zone caption plus glyph plus signed delta — at 13 pt on 38 mm, 15 pt on
    /// 42 mm, with roughly 22 pt reserved for the glyph.
    public var captionCharacterBudget: Int {
        switch self {
        case .mm38: return Int(((contentWidthPoints - 22) / (13 * 0.55)).rounded(.down))
        case .mm42: return Int(((contentWidthPoints - 22) / (15 * 0.55)).rounded(.down))
        }
    }
}

/// One string that does not fit its row, with enough context to fix it.
public struct TruncationRisk: Sendable, Hashable, CustomStringConvertible {
    public let field: String
    public let text: String
    public let characters: Int
    public let budget: Int

    public var description: String {
        "\(field) = \"\(text)\" is \(characters) characters, budget \(budget)"
    }
}

/// Everything the metrics page renders, resolved from one `EngineOutput` — Legacy tier (T-067,
/// design.md §12.2).
///
/// A value type with no SwiftUI in sight, which is what makes the requirements that matter here
/// testable without a simulator — and on this tier "without a simulator" is not a preference but
/// the only option. That a glyph and a signed delta accompany every zone colour (FR-J-1), and that
/// VO2 max never colours at all (FR-C-4), are asserted directly against this struct.
///
/// ## The always-on divergence (T-066)
///
/// **No `luminance`, no `secondaryOpacity`, no `isDimmed`.** The Modern tier's `MetricsScreen`
/// carries all three because watchOS 10 hardware keeps the screen alive in a dimmed state and the
/// design dims secondary metrics while keeping elapsed and rolling pace at full weight. Series 3
/// has no always-on hardware at all: between wrist raises the display is *off*, not dimmed.
///
/// Modelling a luminance state here would therefore be modelling a state this hardware cannot
/// enter. The tempting alternative — keep the parameter and always pass `.normal` — would leave a
/// permanently dead branch in the tier that can least afford dead code, and would suggest to the
/// next reader that dimming is a thing Series 3 does. So it is removed, and the divergence is
/// recorded in design.md §8.1 rather than papered over.
///
/// The real consequence of no-AOD is a *timing* requirement instead of a rendering one: because
/// the screen comes back from fully off, the correct zone colour must be on screen within 500 ms
/// of a wrist raise (AC-FR-A-6-8). That is a view-layer and hardware concern — `MetricsScreen` is
/// a pure function and has no latency to measure — so it is on the hardware-verification list, not
/// asserted here.
public struct MetricsScreen: Sendable, Hashable {

    // MARK: Colour and its redundant channels

    public let background: SRGBColor
    public let textColour: SRGBColor
    /// SF Symbol name for the direction glyph. Never empty — colour is never the only channel
    /// (FR-J-1), so there is always a shape to read.
    public let glyphSymbolName: String
    public let zoneCaption: String
    /// `+12` / `-8` seconds per preferred unit. Present whenever the zone expresses a direction.
    public let signedDeltaText: String?
    /// False in VO2 max mode, where the fill stays neutral at every pace (FR-C-4).
    public let appliesZoneColour: Bool
    public let zone: PaceZone

    // MARK: The five-metric stack

    public let elapsedText: String
    /// `--` after a 10 s dropout — staleness is decided by `RunEngine`, not here (AC-FR-A-6-4).
    public let heartRateText: String
    public let rollingPaceText: String
    public let targetPaceText: String?
    /// Drives the hill indicator: the effective target has diverged from the raw one because of
    /// grade (AC-FR-A-4-8). Live on this tier — Series 3 has the barometer (T-063).
    public let isTargetGradeAdjusted: Bool
    public let averagePaceText: String
    public let distanceText: String
    public let paceSuffix: String
    public let distanceSuffix: String

    // MARK: Structured-workout header

    /// `WORK · REP 3/4 · 340 m to go`. Replaces the zone caption line during a structured workout.
    public let stepHeaderText: String?
    /// The final-100 m countdown is up (AC-FR-C-4-5).
    public let isCountingDown: Bool
    /// The big countdown number, whole metres, no unit. Resolved here rather than in the view so the
    /// digits the runner sees are covered by the shared presentation golden.
    public let countdownText: String?

    /// Whether the app is degraded in a way the runner should be told about.
    public let degradationNotice: String?

    // MARK: - Construction

    public static func make(
        output: EngineOutput,
        runType: RunType,
        profile: RunnerProfile
    ) -> MetricsScreen {
        let unit = profile.units
        let semantics = RunTypeSemantics(runType: runType)
        let palette = ZonePalette.palette(for: profile.palette)

        // VO2 max renders the neutral swatch at every pace. Not "a dimmer green" and not "no
        // background" — the neutral swatch, so the screen still reads as a deliberate design
        // rather than a failure to load (FR-C-4).
        let colouringApplies = semantics.permitsColouring
        let effectiveZone = colouringApplies ? output.zone : .neutral

        // `.normal` unconditionally: this hardware has no dimmed state to ask about. The palette
        // API takes a luminance because the Modern tier needs it; passing the only value that can
        // occur here is not a stub, it is the whole truth about Series 3.
        let swatch = palette.swatch(for: effectiveZone, luminance: .normal)

        // The glyph and caption track the *judged* zone even when colouring is off, so an interval
        // runner still gets direction information — just not through colour. In VO2 max the engine
        // reports `.neutral` anyway, so this collapses to the neutral glyph without a special case.
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
            countdownText: IntervalPresentation.countdownText(for: output.step),
            degradationNotice: Self.notice(for: output.degradations)
        )
    }

    // MARK: - Layout budget (T-067)

    /// Which of this screen's strings exceed their row's character budget at a given case size.
    ///
    /// **What this is and is not.** It is a character-count check against a budget derived from the
    /// real font metrics in `LegacyCaseSize`. It is *not* a pixel measurement, and it cannot be:
    /// measuring real truncation needs a rendered view, and no watchOS 8 simulator exists for
    /// Xcode 26 to render one in. So this catches the failure mode that actually happens — a
    /// metric string growing longer than the layout was designed for, such as a pace crossing into
    /// three digits of minutes, or `10:23:45` elapsed on a long run — and it does not catch a font
    /// substitution or a Dynamic Type setting that inflates glyph advance.
    ///
    /// The residual risk is on the hardware list, where it belongs. This function is what makes the
    /// all-zones × both-case-sizes matrix in `MetricsScreenTests` mean something rather than merely
    /// constructing 12 structs and asserting they are non-nil.
    /// Whether the signed delta needs its own row rather than sitting beside the caption.
    ///
    /// **True at 38 mm, and this was found by test rather than by inspection.** The exhaustive
    /// case-size matrix in `MetricsScreenTests` reported `"A BIT FAST +24"` at 14 characters
    /// against a 13-character budget on the 38 mm panel — so the two widest captions
    /// (`A BIT FAST`, `A BIT SLOW`) overflow whenever a delta is present, which for those zones is
    /// always. Four of the twelve zone/palette pairings were affected, and only at 38 mm.
    ///
    /// The three ways out were: shorten the captions, shrink the caption font, or give the delta
    /// its own row. Shortening loses cross-tier string equality — the shared presentation golden
    /// pins these strings for both tiers, and "A BIT FAST" on a 42 mm Series 3 beside "BIT FAST" on
    /// a 38 mm one is a visible inconsistency for no benefit. Shrinking the font fights FR-J-1's
    /// legibility intent on the smallest screen in the product. Stacking costs one row of vertical
    /// space, which this layout has, and keeps every string and every channel intact.
    ///
    /// The view layer reads this same property, so the layout and the budget check cannot disagree
    /// — which matters, because a test asserting a budget the view does not honour would be
    /// theatre.
    public func placesDeltaOnItsOwnRow(at caseSize: LegacyCaseSize) -> Bool {
        caseSize == .mm38 && signedDeltaText != nil
    }

    public func truncationRisks(at caseSize: LegacyCaseSize) -> [TruncationRisk] {
        var risks: [TruncationRisk] = []

        func check(_ field: String, _ text: String?, budget: Int) {
            guard let text, text.count > budget else { return }
            risks.append(
                TruncationRisk(field: field, text: text, characters: text.count, budget: budget)
            )
        }

        let primary = caseSize.primaryMetricCharacterBudget
        check("elapsed", elapsedText, budget: primary)
        check("rollingPace", rollingPaceText, budget: primary)
        check("averagePace", averagePaceText, budget: primary)
        check("distance", distanceText, budget: primary)
        check("heartRate", heartRateText, budget: primary)
        check("targetPace", targetPaceText, budget: primary)

        // The caption row carries the glyph alongside the caption, and — where there is room for
        // it — the signed delta too. At 38 mm the delta is stacked beneath instead, so the two are
        // budgeted separately.
        if placesDeltaOnItsOwnRow(at: caseSize) {
            check("captionRow", zoneCaption, budget: caseSize.captionCharacterBudget)
            check("deltaRow", signedDeltaText, budget: caseSize.captionCharacterBudget)
        } else {
            let captionRow = zoneCaption + (signedDeltaText.map { " \($0)" } ?? "")
            check("captionRow", captionRow, budget: caseSize.captionCharacterBudget)
        }

        // The step header is allowed to be long — it is the one row the design wraps — so it is
        // checked against double the caption budget, which is the two-line allowance.
        check("stepHeader", stepHeaderText, budget: caseSize.captionCharacterBudget * 2)

        return risks
    }

    /// The one degradation worth a word on the run screen, chosen by what the runner can act on.
    /// "GPS" tells them the pace is estimated and the band is wider; "INDOOR" explains a missing
    /// route. A missing altimeter changes nothing they can do, so it stays in the post-run record.
    private static func notice(for flags: Set<DegradationFlag>) -> String? {
        if flags.contains(.indoorRun) { return "INDOOR" }
        if flags.contains(.gpsDegraded) { return "GPS" }
        return nil
    }
}
