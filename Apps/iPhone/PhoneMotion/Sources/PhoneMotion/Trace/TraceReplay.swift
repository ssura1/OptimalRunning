import Foundation
import ORModels

/// Replays a recorded trace through the estimator and reports what happened.
///
/// The analogue of the core track's `FixtureReplay`, and the thing that makes "how
/// accurate is it today" answerable without writing code (AC-FR-S-F-2-5).
public enum TraceReplay {

    /// Everything a golden asserts, and everything the CLI prints.
    public struct Result: Codable, Sendable, Hashable {
        public let trace: String
        /// Total distance the fusion reported, metres.
        public let fusedDistanceMetres: Double
        /// The motion leg's own total, whether or not it was in use — the series a trace
        /// is actually scored against.
        public let motionOnlyDistanceMetres: Double
        /// GNSS distance over the same span, from the trace's own fixes.
        public let gnssDistanceMetres: Double
        public let measuredMetres: Double
        public let estimatedMetres: Double
        public let stepCount: Int
        /// Steps the impact detector located, as opposed to phase-locked fill-ins — the
        /// number that says whether §10.4's first open question is answered yes.
        public let impactDetectedSteps: Int
        public let phaseLockedSteps: Int
        public let medianCadenceStepsPerMinute: Double?
        public let cadenceSamples: [CadencePoint]
        public let flags: [String]
        public let calibrationScale: Double?
        public let calibrationObservations: Int
        public let isConverged: Bool

        public struct CadencePoint: Codable, Sendable, Hashable {
            public let atSeconds: Double
            public let stepsPerMinute: Double?
            public let confidence: Double
        }
    }

    /// Runs a trace end to end.
    ///
    /// - Parameters:
    ///   - trace: the recording.
    ///   - configuration: estimator tunables.
    ///   - calibration: any persisted calibration to start from.
    ///   - suppressLocationAfter: drop every fix after this timestamp, to simulate a
    ///     GNSS outage over real motion data. This is a legitimate substitute for
    ///     recording a tunnel *because the motion underneath is real* — it is the
    ///     opposite of a synthetic signal, and it is how NFR-S-10 gets tested without a
    ///     dedicated recording session (implementation.md S-024).
    public static func run(
        trace: MotionTrace,
        configuration: MotionEstimationConfiguration = .default,
        calibration: CalibrationState = .init(),
        suppressLocationAfter: TimeInterval? = nil
    ) -> Result {
        var estimator = MotionEstimator(
            configuration: configuration,
            carryPosition: trace.header.carryPosition,
            runnerHeightMetres: trace.header.runnerHeightMetres,
            calibration: calibration)

        let samples = trace.motion.samples()
        let fixes = trace.locations
            .filter { fix in
                guard let cutoff = suppressLocationAfter else { return true }
                return fix.timestamp <= cutoff
            }
            .sorted { $0.timestamp < $1.timestamp }

        var fixIndex = 0
        var nextTick = samples.first?.timestamp ?? 0
        var cadencePoints: [Result.CadencePoint] = []
        var cadenceValues: [Double] = []
        var impactSteps = 0
        var phaseLocked = 0
        var lastEstimate: MotionEstimate?

        for sample in samples {
            // Fixes are interleaved by timestamp so the estimator sees the same ordering
            // it would live. Feeding all fixes first would let calibration converge
            // against motion evidence that had not happened yet.
            while fixIndex < fixes.count, fixes[fixIndex].timestamp <= sample.timestamp {
                estimator.ingest(fixes[fixIndex].fix)
                fixIndex += 1
            }
            for event in estimator.ingest(sample) {
                switch event.origin {
                case .impactPeak: impactSteps += 1
                case .phaseLocked: phaseLocked += 1
                }
            }
            if sample.timestamp >= nextTick {
                let estimate = estimator.tick(at: sample.timestamp)
                lastEstimate = estimate
                cadencePoints.append(Result.CadencePoint(
                    atSeconds: sample.timestamp,
                    stepsPerMinute: estimate.cadenceStepsPerMinute,
                    confidence: estimate.cadenceConfidence))
                if let spm = estimate.cadenceStepsPerMinute { cadenceValues.append(spm) }
                nextTick += 1
            }
        }

        let gnss = (trace.locations.last?.cumulativeDistanceMetres ?? 0)
            - (trace.locations.first?.cumulativeDistanceMetres ?? 0)

        return Result(
            trace: trace.header.name,
            fusedDistanceMetres: lastEstimate?.cumulativeDistanceMetres ?? 0,
            motionOnlyDistanceMetres: estimator.motionOnlyMetres,
            gnssDistanceMetres: gnss,
            measuredMetres: lastEstimate?.measuredMetres ?? 0,
            estimatedMetres: lastEstimate?.estimatedMetres ?? 0,
            stepCount: lastEstimate?.stepCount ?? 0,
            impactDetectedSteps: impactSteps,
            phaseLockedSteps: phaseLocked,
            medianCadenceStepsPerMinute: median(cadenceValues),
            cadenceSamples: cadencePoints,
            flags: (lastEstimate?.flags ?? []).map(\.rawValue).sorted(),
            calibrationScale: estimator.calibration.scale,
            calibrationObservations: estimator.calibration.observationCount,
            isConverged: estimator.isConverged)
    }

    /// Median rather than mean, because a cadence series contains genuine zeros and
    /// dropouts at the start and end of a run and a mean would be dragged by them.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
