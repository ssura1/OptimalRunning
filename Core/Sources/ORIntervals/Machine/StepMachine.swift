import Foundation
import ORModels

// MARK: - Transition

/// A step boundary that just occurred.
public struct StepTransition: Sendable, Hashable {
    public let from: ResolvedStep
    /// `nil` when the workout has no further steps.
    public let to: ResolvedStep?
    /// True when a goal was met; false when the runner advanced by hand.
    public let wasAutomatic: Bool
    public let completedDistanceMetres: Double
    public let completedActiveSeconds: TimeInterval
    public let atActiveElapsed: TimeInterval

    public init(
        from: ResolvedStep,
        to: ResolvedStep?,
        wasAutomatic: Bool,
        completedDistanceMetres: Double,
        completedActiveSeconds: TimeInterval,
        atActiveElapsed: TimeInterval
    ) {
        self.from = from
        self.to = to
        self.wasAutomatic = wasAutomatic
        self.completedDistanceMetres = completedDistanceMetres
        self.completedActiveSeconds = completedActiveSeconds
        self.atActiveElapsed = atActiveElapsed
    }
}

// MARK: - State

/// Live state of the current step.
public struct StepState: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable, Codable {
        case idle
        case running
        /// Every step is done but the runner has not ended the workout yet
        /// (AC-FR-C-2-5).
        case awaitingEnd
        case finished
    }

    public let phase: Phase
    public let step: ResolvedStep?
    public let stepDistanceMetres: Double
    public let stepActiveSeconds: TimeInterval
    /// Metres left in a distance goal; `nil` for open or time goals.
    public let distanceRemainingMetres: Double?
    /// Seconds left in a time goal; `nil` for open or distance goals.
    public let timeRemainingSeconds: TimeInterval?
    /// True inside the final stretch of a work step, so the UI can count down
    /// (AC-FR-C-2-7).
    public let isCountingDown: Bool
    /// True only for open goals. A tap during a closed goal is ignored, which is the
    /// guard that makes full-screen tap-to-advance safe (AC-FR-C-3-4).
    public let canAdvanceManually: Bool
    public let isUndoAvailable: Bool

    public static let idle = StepState(
        phase: .idle, step: nil, stepDistanceMetres: 0, stepActiveSeconds: 0,
        distanceRemainingMetres: nil, timeRemainingSeconds: nil,
        isCountingDown: false, canAdvanceManually: false, isUndoAvailable: false
    )

    public init(
        phase: Phase,
        step: ResolvedStep?,
        stepDistanceMetres: Double,
        stepActiveSeconds: TimeInterval,
        distanceRemainingMetres: Double?,
        timeRemainingSeconds: TimeInterval?,
        isCountingDown: Bool,
        canAdvanceManually: Bool,
        isUndoAvailable: Bool
    ) {
        self.phase = phase
        self.step = step
        self.stepDistanceMetres = stepDistanceMetres
        self.stepActiveSeconds = stepActiveSeconds
        self.distanceRemainingMetres = distanceRemainingMetres
        self.timeRemainingSeconds = timeRemainingSeconds
        self.isCountingDown = isCountingDown
        self.canAdvanceManually = canAdvanceManually
        self.isUndoAvailable = isUndoAvailable
    }
}

// MARK: - Machine

/// Drives progression through a workout's resolved steps (design.md §6.2).
///
/// Pure: the same tick sequence always produces the same transitions, which is what
/// makes `intervals-4x1000.json` a meaningful regression test.
public struct StepMachine: Sendable {

    /// Where a step's measurement begins.
    private struct Origin: Sendable {
        var distance: Double
        var activeSeconds: TimeInterval
    }

    private let steps: [ResolvedStep]
    private let config: IntervalConfiguration

    private var index: Int = 0
    private var origin = Origin(distance: 0, activeSeconds: 0)
    private var phase: StepState.Phase = .idle

    /// One step of history, for undo (FR-C-6).
    private var undoSnapshot: (index: Int, origin: Origin, atActiveSeconds: TimeInterval)?

    public init(steps: [ResolvedStep], config: IntervalConfiguration) {
        self.steps = steps
        self.config = config
    }

    public var resolvedSteps: [ResolvedStep] { steps }

    /// Begins the workout at the given position.
    public mutating func start(cumulativeDistance: Double, activeElapsed: TimeInterval) {
        index = 0
        origin = Origin(distance: cumulativeDistance, activeSeconds: activeElapsed)
        phase = steps.isEmpty ? .awaitingEnd : .running
        undoSnapshot = nil
    }

    /// Advances the machine by one tick.
    ///
    /// `activeElapsed` already excludes paused time, so a paused runner accrues no
    /// step time — but `cumulativeDistance` is not frozen, because movement recorded
    /// while paused really happened.
    public mutating func tick(
        cumulativeDistance: Double,
        activeElapsed: TimeInterval,
        manualAdvanceRequested: Bool
    ) -> (state: StepState, transition: StepTransition?) {

        guard phase == .running, let current = currentStep else {
            return (makeState(cumulativeDistance: cumulativeDistance, activeElapsed: activeElapsed), nil)
        }

        let stepDistance = cumulativeDistance - origin.distance
        let stepSeconds = activeElapsed - origin.activeSeconds

        // Automatic advance takes precedence: if the goal is met on the same tick the
        // runner happens to tap, the goal is what actually ended the step.
        if let goalMetres = current.goal.distanceMetres, stepDistance >= goalMetres {
            let transition = advance(
                from: current,
                automatic: true,
                // The step is credited with exactly its goal, not with the overshoot.
                // At 1 Hz a runner covers several metres per tick, so the goal is
                // always crossed slightly late — but the next step's origin is the
                // *ideal* boundary, so that overshoot is already counted as distance
                // run in the next step. Reporting it here too would count it twice,
                // and eight reps would sum to ~8013 m instead of 8000 m
                // (AC-FR-C-2-4).
                completedDistance: goalMetres,
                completedSeconds: stepSeconds,
                // Ideal boundary, not actual position — see `advance`.
                nextOriginDistance: origin.distance + goalMetres,
                nextOriginSeconds: activeElapsed,
                atActiveElapsed: activeElapsed
            )
            return (makeState(cumulativeDistance: cumulativeDistance, activeElapsed: activeElapsed), transition)
        }

        if let goalSeconds = current.goal.timeSeconds, stepSeconds >= goalSeconds {
            let transition = advance(
                from: current,
                automatic: true,
                completedDistance: stepDistance,
                // Same reasoning as the distance goal above: the time origin of the
                // next step is the ideal boundary, so the overrun belongs to it.
                completedSeconds: goalSeconds,
                nextOriginDistance: cumulativeDistance,
                nextOriginSeconds: origin.activeSeconds + goalSeconds,
                atActiveElapsed: activeElapsed
            )
            return (makeState(cumulativeDistance: cumulativeDistance, activeElapsed: activeElapsed), transition)
        }

        // Manual advance is accepted only for open goals. Refusing it during a rep is
        // what lets the metrics page be one big tap target without risking a
        // truncated 1000 m interval.
        if manualAdvanceRequested, current.goal.isOpen {
            let transition = advance(
                from: current,
                automatic: false,
                completedDistance: stepDistance,
                completedSeconds: stepSeconds,
                nextOriginDistance: cumulativeDistance,
                nextOriginSeconds: activeElapsed,
                atActiveElapsed: activeElapsed
            )
            return (makeState(cumulativeDistance: cumulativeDistance, activeElapsed: activeElapsed), transition)
        }

        return (makeState(cumulativeDistance: cumulativeDistance, activeElapsed: activeElapsed), nil)
    }

    /// Whether an undo would succeed if taken right now (AC-FR-C-6-1).
    ///
    /// The single definition of "undo is available", read by both `undo` and the `StepState` the UI
    /// renders from. They disagreed until Wave 4: the action enforced the window, the state flag
    /// only checked that a snapshot existed. One predicate makes that class of drift impossible
    /// rather than merely fixed.
    public func isUndoAvailable(atActiveElapsed: TimeInterval) -> Bool {
        guard let snapshot = undoSnapshot else { return false }
        return atActiveElapsed - snapshot.atActiveSeconds <= config.undoWindowSeconds
    }

    /// Reverts the most recent manual advance, restoring the previous step with its
    /// accumulated distance and time intact (AC-FR-C-6-2).
    @discardableResult
    public mutating func undo(atActiveElapsed: TimeInterval) -> Bool {
        guard isUndoAvailable(atActiveElapsed: atActiveElapsed), let snapshot = undoSnapshot
        else { return false }

        index = snapshot.index
        origin = snapshot.origin
        phase = .running
        undoSnapshot = nil
        return true
    }

    public mutating func end() {
        phase = .finished
        undoSnapshot = nil
    }

    public var isFinished: Bool { phase == .finished }

    // MARK: - Private

    private var currentStep: ResolvedStep? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    /// Moves to the next step.
    ///
    /// `nextOriginDistance` is the *ideal* boundary for a distance goal — the previous
    /// origin plus the goal — rather than the runner's actual position. At 1 Hz a
    /// runner overshoots each goal by several metres, and taking the actual position
    /// would compound that overshoot across every rep: four 1000 m reps would measure
    /// ~4020 m and fail AC-FR-C-2-4's 0.1% bound. Anchoring to the ideal boundary
    /// keeps the error per-step rather than cumulative, and still reports the overshoot
    /// honestly as distance already covered in the new step.
    private mutating func advance(
        from current: ResolvedStep,
        automatic: Bool,
        completedDistance: Double,
        completedSeconds: TimeInterval,
        nextOriginDistance: Double,
        nextOriginSeconds: TimeInterval,
        atActiveElapsed: TimeInterval
    ) -> StepTransition {

        // Only manual advances are undoable: an automatic one was earned by running
        // the distance, and undoing it would be undoing reality.
        undoSnapshot = automatic
            ? nil
            : (index: index, origin: origin, atActiveSeconds: atActiveElapsed)

        let nextIndex = index + 1
        let next: ResolvedStep? = steps.indices.contains(nextIndex) ? steps[nextIndex] : nil

        index = nextIndex
        origin = Origin(distance: nextOriginDistance, activeSeconds: nextOriginSeconds)
        phase = next == nil ? .awaitingEnd : .running

        return StepTransition(
            from: current,
            to: next,
            wasAutomatic: automatic,
            completedDistanceMetres: completedDistance,
            completedActiveSeconds: completedSeconds,
            atActiveElapsed: atActiveElapsed
        )
    }

    private func makeState(cumulativeDistance: Double, activeElapsed: TimeInterval) -> StepState {
        guard let step = currentStep, phase == .running else {
            return StepState(
                phase: phase,
                step: nil,
                stepDistanceMetres: 0,
                stepActiveSeconds: 0,
                distanceRemainingMetres: nil,
                timeRemainingSeconds: nil,
                isCountingDown: false,
                canAdvanceManually: false,
                isUndoAvailable: false
            )
        }

        let stepDistance = max(cumulativeDistance - origin.distance, 0)
        let stepSeconds = max(activeElapsed - origin.activeSeconds, 0)

        let distanceRemaining = step.goal.distanceMetres.map { max($0 - stepDistance, 0) }
        let timeRemaining = step.goal.timeSeconds.map { max($0 - stepSeconds, 0) }

        let countingDown = step.kind == .work
            && (distanceRemaining.map { $0 <= config.countdownDistanceMetres } ?? false)

        return StepState(
            phase: phase,
            step: step,
            stepDistanceMetres: stepDistance,
            stepActiveSeconds: stepSeconds,
            distanceRemainingMetres: distanceRemaining,
            timeRemainingSeconds: timeRemaining,
            isCountingDown: countingDown,
            canAdvanceManually: step.goal.isOpen,
            // The window is part of availability, not only of the action.
            //
            // This previously read `undoSnapshot != nil`, which is a different and weaker claim:
            // "a manual advance happened at some point during this step". `undo(atActiveElapsed:)`
            // has always enforced `config.undoWindowSeconds` correctly, so the *action* expired on
            // time while the *affordance* did not — leaving a visible, tappable undo control on
            // screen for the remainder of the step that silently did nothing after 5 s. On the
            // `intervals-4x1000` fixture the control stayed up for 231 s after a warmup advance.
            //
            // AC-FR-C-6-1 is explicit that the affordance is offered *for 5 s (tunable)*, so the
            // flag has to read the same clock the action does. Found by the shared presentation
            // golden added in Wave 4, which records `showsUndo` per tick; neither tier's UI tests
            // had covered how long the affordance persists, only whether it appeared.
            isUndoAvailable: isUndoAvailable(atActiveElapsed: activeElapsed)
        )
    }
}
