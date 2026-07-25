import Foundation
import ORIntervals
import ORModels

/// Accumulates one `StepSummary` per completed step of a structured workout (AC-FR-F-2-6).
///
/// Fed the same `EngineOutput` stream the run screen renders, so the per-rep table the
/// phone eventually shows is built from exactly what the engine decided at the time — not
/// re-derived later by re-segmenting the sample series against the plan, which would be a
/// second implementation of step boundaries able to disagree with the first.
///
/// **Why heart rate and elevation are accumulated here rather than sliced out later.**
/// `StepTransition` reports the completed step's distance and active time, but not its
/// heart rate or climb; those need the samples *within* the step, and the only place that
/// knows where a step began is the thing watching the transitions go by. Reconstructing
/// the boundaries afterwards from timestamps would work until a manual advance or an undo
/// moved one, at which point the table would quietly attribute a rep's heart rate to its
/// neighbour.
public struct StepSummaryAccumulator: Sendable {

    public private(set) var completed: [StepSummary] = []

    /// Samples seen since the current step began.
    private var heartRates: [Double] = []
    private var altitudes: [Double] = []

    public init() {}

    /// Folds in one tick. Call once per `RunEngine.tick`, in order.
    public mutating func ingest(_ output: EngineOutput) {
        if let heartRate = output.heartRate, heartRate.isFinite, heartRate > 0 {
            heartRates.append(heartRate)
        }
        if let altitude = output.sample.relativeAltitude, altitude.isFinite {
            altitudes.append(altitude)
        }

        // A transition means the step named in `from` has just ended, and this tick's
        // accumulated samples belong to it. Close it out, then reset for the next.
        guard let transition = output.stepTransition else { return }

        completed.append(StepSummary(
            index: transition.from.index,
            kind: transition.from.kind,
            repIndex: transition.from.repIndex,
            repCount: transition.from.repCount,
            distanceMetres: transition.completedDistanceMetres,
            activeSeconds: transition.completedActiveSeconds,
            averagePace: Pace(
                distanceMetres: transition.completedDistanceMetres,
                seconds: transition.completedActiveSeconds
            ),
            averageHeartRate: heartRates.isEmpty
                ? nil : heartRates.reduce(0, +) / Double(heartRates.count),
            maxHeartRate: heartRates.max(),
            elevationChangeMetres: (altitudes.last ?? 0) - (altitudes.first ?? 0)
        ))

        heartRates.removeAll(keepingCapacity: true)
        altitudes.removeAll(keepingCapacity: true)
    }

    /// Closes out a step that was still running when the workout ended.
    ///
    /// A run stopped mid-rep produces no transition for that rep, so without this the
    /// final — often most interesting — interval would be missing from the table entirely.
    /// It is reported with the distance and time actually completed, which is what lets the
    /// phone label it partial (AC-FR-F-2-5) rather than pretending it was a full rep.
    public mutating func finish(with output: EngineOutput?) {
        guard let output, let step = output.step.step, output.stepTransition == nil else { return }
        guard output.step.stepDistanceMetres > 0 || output.step.stepActiveSeconds > 0 else { return }

        completed.append(StepSummary(
            index: step.index,
            kind: step.kind,
            repIndex: step.repIndex,
            repCount: step.repCount,
            distanceMetres: output.step.stepDistanceMetres,
            activeSeconds: output.step.stepActiveSeconds,
            averagePace: Pace(
                distanceMetres: output.step.stepDistanceMetres,
                seconds: output.step.stepActiveSeconds
            ),
            averageHeartRate: heartRates.isEmpty
                ? nil : heartRates.reduce(0, +) / Double(heartRates.count),
            maxHeartRate: heartRates.max(),
            elevationChangeMetres: (altitudes.last ?? 0) - (altitudes.first ?? 0)
        ))
    }
}
