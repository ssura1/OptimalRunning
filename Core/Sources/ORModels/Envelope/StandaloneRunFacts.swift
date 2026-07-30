import Foundation

/// What a standalone run records that a watch run has no equivalent of (AC-FR-S-A-4-5,
/// FR-S-E-2).
///
/// **Additive and optional, so the schema version does not move.** `RunEnvelope`'s
/// synthesised `Codable` encodes an absent optional by omitting the key and decodes a
/// missing one as `nil`, so a payload written before this existed still decodes and a
/// payload written after it is still readable by a build that ignores it. That property is
/// checked by a test rather than assumed, because "adding an optional is safe" is true of
/// synthesised coding and false of several hand-written alternatives.
///
/// Everything here is a *fact about the recording*, never a prediction. AC-FR-S-E-2-5
/// forbids rewriting a stored run's distance when calibration later improves, and the
/// natural way to violate that is to store the inputs and re-derive the number on read.
/// Storing the derived totals is what makes the record a record.
public struct StandaloneRunFacts: Codable, Sendable, Hashable {

    /// Where the phone was declared to be (AC-FR-S-A-1-3). Recorded because the model is
    /// carry-specific and a run's numbers are uninterpretable without it.
    public let carryPosition: CarryPosition
    /// Metres observed from position fixes.
    public let measuredMetres: Double
    /// Metres inferred from the motion model.
    public let estimatedMetres: Double
    /// Steps detected over the whole run (FR-S-E-2-2 shows cadence as first-class because
    /// it is measured rather than derived).
    public let stepCount: Int
    /// Mean cadence over the ticks that had one, spm. `nil` when none ever did.
    public let averageCadenceStepsPerMinute: Double?
    /// The calibration as it stood when the run *ended* — the thing AC-FR-S-E-2-4 needs to
    /// say "this run was recorded before your calibration settled".
    public let calibration: CalibrationSummary
    public let flags: Set<MotionFlag>
    /// The stretches whose distance came from the motion model, as session-relative
    /// seconds.
    ///
    /// This is AC-FR-S-C-1-5's "per sample" requirement in the form that survives storage.
    /// A per-sample column in `PackedSamples` was the obvious reading and was rejected: it
    /// would change a columnar format the watch tiers' goldens are written against, to
    /// carry a value that is constant across minutes at a time. A run-length encoding of
    /// the same fact is exact, is a few dozen bytes, and lets the detail chart shade the
    /// estimated stretches — which the column would also have allowed and nothing else
    /// would.
    public let estimatedSpans: [EstimatedSpan]

    public struct EstimatedSpan: Codable, Sendable, Hashable {
        public let startSeconds: TimeInterval
        public let endSeconds: TimeInterval

        public init(startSeconds: TimeInterval, endSeconds: TimeInterval) {
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
        }

        public var durationSeconds: TimeInterval { max(0, endSeconds - startSeconds) }
    }

    public init(
        carryPosition: CarryPosition,
        measuredMetres: Double,
        estimatedMetres: Double,
        stepCount: Int,
        averageCadenceStepsPerMinute: Double?,
        calibration: CalibrationSummary,
        flags: Set<MotionFlag>,
        estimatedSpans: [EstimatedSpan]
    ) {
        self.carryPosition = carryPosition
        self.measuredMetres = measuredMetres
        self.estimatedMetres = estimatedMetres
        self.stepCount = stepCount
        self.averageCadenceStepsPerMinute = averageCadenceStepsPerMinute
        self.calibration = calibration
        self.flags = flags
        self.estimatedSpans = estimatedSpans
    }

    /// Fraction of the run's distance that was observed (AC-FR-S-E-2-1). `nil` over zero
    /// distance, so a timed indoor run shows nothing rather than a meaningless 100%.
    public var measuredFraction: Double? {
        let total = measuredMetres + estimatedMetres
        guard total > 0 else { return nil }
        return measuredMetres / total
    }

    /// Whether this run's distance should be presented as lower-confidence, and why
    /// (AC-FR-S-E-2-4, DEG-S-5).
    ///
    /// Two independent causes, deliberately both checked: a run recorded before the
    /// calibration converged, and a run that fell back to the published prior because there
    /// was never a calibration at all.
    public var isLowerConfidence: Bool {
        !calibration.isConverged && estimatedMetres > 0
            || flags.contains(.usingUncalibratedPrior)
    }
}
