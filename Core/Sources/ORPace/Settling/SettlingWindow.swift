import Foundation
import ORModels

/// Suppresses zone judgement at the start of a run and at each interval step
/// (FR-A-5, AC-FR-C-5-4).
///
/// This exists because of what happens without it: every run opens with a solid red
/// screen. The runner is accelerating from a standstill, GPS has not converged, and
/// the pace window has not filled — so the app's very first statement is wrong. A
/// product whose core mechanic is "trust the colour" cannot afford to be wrong in the
/// first thirty seconds, because that is precisely when the user decides whether the
/// colour means anything.
///
/// Metrics keep rendering normally throughout (AC-FR-A-5-3). Only the *judgement* is
/// withheld.
public struct SettlingWindow: Sendable {

    private let config: SettlingConfiguration

    public init(config: SettlingConfiguration) {
        self.config = config
    }

    /// Whether the run-level window is still open.
    ///
    /// Either threshold ends it: a fast runner clears 400 m before 90 s, and a slow
    /// one clears 90 s before 400 m. Requiring both would leave a walker neutral for
    /// several minutes.
    public func isRunSettling(distanceCovered: Double, activeElapsed: TimeInterval) -> Bool {
        distanceCovered < config.runDistanceMetres && activeElapsed < config.runSeconds
    }

    /// Whether the per-step window is still open. Distance only: a recovery jog step
    /// has no meaningful time floor.
    public func isStepSettling(stepDistance: Double) -> Bool {
        stepDistance < config.stepDistanceMetres
    }

    /// Combined gate used by the engine.
    ///
    /// A structured run applies the step window at every step boundary, including the
    /// first; the run window still applies at the very start, so the opening warmup
    /// gets the longer of the two.
    public func isSettling(
        distanceCovered: Double,
        activeElapsed: TimeInterval,
        stepDistance: Double?,
        isStructured: Bool
    ) -> Bool {
        if isRunSettling(distanceCovered: distanceCovered, activeElapsed: activeElapsed) {
            return true
        }
        guard isStructured, let stepDistance else { return false }
        return isStepSettling(stepDistance: stepDistance)
    }
}
