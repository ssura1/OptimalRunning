import Foundation
import ORModels

/// Fuses GNSS-measured and motion-estimated distance, and calibrates the latter from the
/// former (standalone/design.md §6).
///
/// The standalone analogue of the watch tiers' priority-ordered fusion (design.md §8.2),
/// with one structural addition: the motion leg is not merely a fallback, it is
/// **continuously computed and continuously compared**, which is what makes it both
/// calibratable and able to sanity-check GNSS.
public struct DistanceFusion: Sendable {

    /// The largest step change a source handover may introduce, metres.
    ///
    /// **Deliberately not in `MotionEstimationConfiguration`.** NFR-S-19 governs
    /// *tunables* — values a runner, a profile or a deployment might legitimately vary.
    /// This is a correctness bound the specification fixes (NFR-S-12), and exposing it
    /// as configuration would imply a supported 50 m jump setting. Declared once, in the
    /// type that enforces it, exactly as the watch tiers' `maxSwitchJumpMetres` is.
    ///
    /// In practice the bound is satisfied by construction — the fusion accumulates
    /// *deltas* and re-anchors on handover, so a switch contributes zero — and the clamp
    /// below is the belt to that braces.
    public static let maxSwitchJumpMetres = 5.0

    private let config: MotionFusionConfiguration
    /// The calibration window length. Lives on `CalibrationConfiguration` — the
    /// calibrator's own notion of what a usable window is — but the fusion layer is what
    /// *closes* the window, so it is passed in rather than duplicated as a second
    /// number in a second struct that could drift.
    private let calibrationWindowMetres: Double
    /// Fraction of a window's steps that must have carried a confident cadence
    /// (`CalibrationConfiguration.minimumConfidentStepFraction`).
    private let minimumConfidentStepFraction: Double
    private var calibrator: Calibrator

    // Fused output.
    public private(set) var cumulativeMetres = 0.0
    public private(set) var measuredMetres = 0.0
    public private(set) var estimatedMetres = 0.0
    public private(set) var source: DistanceSource = .location
    public private(set) var flags: Set<MotionFlag> = []

    /// The motion leg's own running total, computed whether or not it is in use, so a
    /// trace always carries both series for comparison.
    public private(set) var motionOnlyMetres = 0.0

    // GNSS tracking.
    private var locationAnchor: Double?
    private var lastUsableFixTime: TimeInterval?
    private var needsReanchor = true
    private var hasEverHadUsableFix = false
    private var justSwitched = false

    // Calibration window.
    private var windowReferenceMetres = 0.0
    private var windowUnscaledSum = 0.0
    private var windowMotionMetres = 0.0
    private var windowCadenceSum = 0.0
    private var windowCadenceCount = 0
    private var windowStepCount = 0
    private var windowIsQualified = true
    private var suspendedWindows = 0

    // Disagreement window.
    private var comparisonReferenceMetres = 0.0
    private var comparisonMotionMetres = 0.0

    public init(
        configuration: MotionFusionConfiguration,
        calibration: CalibrationConfiguration,
        calibrator: Calibrator
    ) {
        config = configuration
        calibrationWindowMetres = calibration.minimumWindowMetres
        minimumConfidentStepFraction = calibration.minimumConfidentStepFraction
        self.calibrator = calibrator
    }

    public var calibration: CalibrationState { calibrator.state }
    public var isCalibrated: Bool { calibrator.isCalibrated }
    public var isConverged: Bool { calibrator.isConverged }

    public func gain(forStepsPerMinute spm: Double) -> Double {
        calibrator.gain(forStepsPerMinute: spm)
    }

    public var scale: Double? { calibrator.state.scale }

    // MARK: - GNSS

    public mutating func ingest(fix: LocationFix) {
        guard fix.timestamp.isFinite, fix.cumulativeDistanceMetres.isFinite else { return }
        guard fix.isUsable(maxHorizontalAccuracy: config.maxHorizontalAccuracyMetres) else {
            // An unusable fix is not evidence of anything: it neither advances distance
            // nor resets the dropout timer. Treating a 200 m-accurate fix as "GPS is
            // working" is how a run keeps reporting confident pace inside a building.
            return
        }
        lastUsableFixTime = fix.timestamp
        hasEverHadUsableFix = true
        switchToLocationIfNeeded()

        guard source == .location else { return }
        guard let anchor = locationAnchor, !needsReanchor else {
            locationAnchor = fix.cumulativeDistanceMetres
            needsReanchor = false
            return
        }
        var delta = fix.cumulativeDistanceMetres - anchor
        locationAnchor = fix.cumulativeDistanceMetres
        guard delta.isFinite else { return }
        // Monotonicity: a backwards-moving cumulative from the adapter is a bug upstream,
        // and propagating it would make the fused figure non-monotonic (AC-FR-S-C-1-1).
        delta = max(0, delta)
        if justSwitched {
            delta = min(delta, Self.maxSwitchJumpMetres)
            justSwitched = false
        }
        cumulativeMetres += delta
        measuredMetres += delta
        windowReferenceMetres += delta
        comparisonReferenceMetres += delta
        closeWindowsIfDue()
    }

    // MARK: - Motion

    /// Feeds one step's worth of motion evidence.
    ///
    /// - Parameters:
    ///   - metres: the calibrated step length, or `nil` when the model has no scale.
    ///   - unscaled: the model's unscaled length for this step, for calibration.
    ///   - stepsPerMinute: cadence at this step, for banding.
    ///   - cadenceIsConfident: whether the cadence behind those numbers is trustworthy.
    public mutating func ingestStep(
        metres: Double?,
        unscaled: Double?,
        stepsPerMinute: Double,
        cadenceIsConfident: Bool
    ) {
        if let unscaled, unscaled.isFinite, unscaled > 0 {
            windowUnscaledSum += unscaled
        }
        windowStepCount += 1
        if cadenceIsConfident, stepsPerMinute.isFinite, stepsPerMinute > 0 {
            windowCadenceSum += stepsPerMinute
            windowCadenceCount += 1
        }

        guard let metres, metres.isFinite, metres > 0 else { return }
        motionOnlyMetres += metres
        comparisonMotionMetres += metres
        windowMotionMetres += metres

        guard source == .motionModel else { return }
        var delta = metres
        if justSwitched {
            delta = min(delta, Self.maxSwitchJumpMetres)
            justSwitched = false
        }
        cumulativeMetres += delta
        estimatedMetres += delta
        flags.insert(.distanceEstimated)
    }

    // MARK: - Clock

    /// Advances the source state machine. Called once per output tick.
    public mutating func tick(at now: TimeInterval) {
        guard now.isFinite else { return }
        guard let last = lastUsableFixTime else {
            // No fix has ever arrived. The motion leg is all there is — which is only
            // usable at all if a calibration was persisted from a previous run, and the
            // estimator reports nothing otherwise (ADR-S-06).
            if hasEverHadUsableFix == false, source != .motionModel {
                source = .motionModel
                justSwitched = true
                invalidateWindows()
            }
            return
        }
        if now - last > config.gnssDropoutSeconds {
            if source != .motionModel {
                source = .motionModel
                justSwitched = true
                invalidateWindows()
            }
        }
    }

    private mutating func switchToLocationIfNeeded() {
        guard source != .location else { return }
        source = .location
        needsReanchor = true
        justSwitched = true
        invalidateWindows()
    }

    // MARK: - Windows

    /// A source change makes any window in flight uninterpretable — half its reference
    /// came from one leg and half from the other — so it is discarded rather than
    /// applied.
    private mutating func invalidateWindows() {
        resetCalibrationWindow()
        comparisonReferenceMetres = 0
        comparisonMotionMetres = 0
    }

    private mutating func resetCalibrationWindow() {
        windowReferenceMetres = 0
        windowUnscaledSum = 0
        windowMotionMetres = 0
        windowCadenceSum = 0
        windowCadenceCount = 0
        windowStepCount = 0
        windowIsQualified = true
    }

    private mutating func closeWindowsIfDue() {
        if comparisonReferenceMetres >= config.disagreementWindowMetres {
            evaluateDisagreement()
        }
        if windowReferenceMetres >= calibrationWindowMetres {
            closeCalibrationWindow()
        }
    }

    private mutating func evaluateDisagreement() {
        defer {
            comparisonReferenceMetres = 0
            comparisonMotionMetres = 0
        }
        guard comparisonReferenceMetres > 0, comparisonMotionMetres > 0 else { return }
        let relative = abs(comparisonMotionMetres - comparisonReferenceMetres)
            / comparisonReferenceMetres
        guard relative > config.disagreementFraction else { return }
        // Flag and suspend learning — but **do not override GNSS**. On an open course
        // GNSS is good to roughly 1–3%; an uncalibrated motion model is 4–9% at best and
        // unvalidated for running (CON-S-5). Letting the weaker estimator veto the
        // stronger one on disagreement would make the system's accuracy a function of its
        // worst component. What the check buys is that the calibrator refuses to learn
        // from evidence it cannot trust, which is where the damage would be permanent.
        flags.insert(.sourceDisagreement)
        suspendedWindows = max(suspendedWindows, config.disagreementSuspensionWindows)
        windowIsQualified = false
    }

    private mutating func closeCalibrationWindow() {
        defer { resetCalibrationWindow() }
        guard suspendedWindows == 0 else {
            suspendedWindows -= 1
            return
        }
        guard windowIsQualified, windowCadenceCount > 0, windowUnscaledSum > 0 else { return }

        // A window with too few confident steps teaches the wrong thing.
        let confidentFraction = windowStepCount > 0
            ? Double(windowCadenceCount) / Double(windowStepCount)
            : 0
        guard confidentFraction >= minimumConfidentStepFraction else { return }

        // **The disagreement check runs here, on the calibration window itself, before
        // anything is applied.** It originally lived only on the separate 200 m
        // comparison window, which is twice as long — so the first 100 m calibration
        // window closed and was *applied* before the first disagreement window had even
        // been evaluated. `testCalibrationDoesNotMoveWhileDisagreementIsSuspended` caught
        // it: with GNSS reporting double the motion leg, the scale still moved the full
        // per-window cap before the flag fired. Suspension after the fact is no use when
        // the damage is already in the persisted state.
        if windowMotionMetres > 0, windowReferenceMetres > 0 {
            let relative = abs(windowMotionMetres - windowReferenceMetres) / windowReferenceMetres
            if relative > config.disagreementFraction {
                flags.insert(.sourceDisagreement)
                suspendedWindows = max(suspendedWindows, config.disagreementSuspensionWindows)
                return
            }
        }

        calibrator.apply(CalibrationObservation(
            referenceMetres: windowReferenceMetres,
            unscaledSum: windowUnscaledSum,
            meanStepsPerMinute: windowCadenceSum / Double(windowCadenceCount)))
    }

    /// Marks the window in flight as unusable — for conditions the fusion layer cannot
    /// see, such as a carry-position change detected upstream.
    public mutating func disqualifyCurrentWindow() {
        windowIsQualified = false
    }

    public mutating func insert(flag: MotionFlag) {
        flags.insert(flag)
    }
}
