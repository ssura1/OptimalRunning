import Foundation
import ORModels

/// Why a workout plan cannot be run.
public enum PlanValidationError: Error, Equatable, Sendable {
    case empty
    case emptyRepeatBlock
    case repeatCountOutOfRange(count: Int, permitted: ClosedRange<Int>)
    case stepDistanceOutOfRange(metres: Double, permitted: ClosedRange<Double>)
    case nonPositiveTimeGoal(seconds: Double)
    /// A structured run whose every step is open-goal can never advance on its own,
    /// which makes the auto-advance promise meaningless.
    case noClosedGoalInStructuredPlan
}

extension WorkoutPlan {

    /// Expands repeat blocks into a linear step list (design.md §6.1).
    ///
    /// The runtime walks this, never the tree. Flattening once at start means the step
    /// machine has no recursion, `O(1)` step lookup, and a natural index to persist —
    /// and it is what lets the UI say "rep 3 of 4" without re-deriving position.
    public func resolvedSteps() -> [ResolvedStep] {
        var resolved: [ResolvedStep] = []
        WorkoutPlan.flatten(elements, into: &resolved, repIndex: 1, repCount: 1)
        return resolved
    }

    private static func flatten(
        _ elements: [PlanElement],
        into output: inout [ResolvedStep],
        repIndex: Int,
        repCount: Int
    ) {
        for element in elements {
            switch element {
            case .step(let step):
                output.append(ResolvedStep(
                    index: output.count,
                    kind: step.kind,
                    goal: step.goal,
                    target: step.target,
                    repIndex: repIndex,
                    repCount: repCount
                ))
            case .repeatBlock(let count, let inner):
                // Nested blocks report the innermost rep position, which is the one
                // the runner is actually counting.
                for iteration in 1...max(count, 1) {
                    flatten(inner, into: &output, repIndex: iteration, repCount: count)
                }
            }
        }
    }

    /// Validates against the configured bounds (AC-FR-C-1-4, T-018).
    public func validate(config: IntervalConfiguration) throws {
        guard !elements.isEmpty else { throw PlanValidationError.empty }
        try WorkoutPlan.validate(elements, config: config)

        if runType.isStructured {
            let steps = resolvedSteps()
            guard steps.contains(where: { !$0.goal.isOpen }) else {
                throw PlanValidationError.noClosedGoalInStructuredPlan
            }
        }
    }

    private static func validate(_ elements: [PlanElement], config: IntervalConfiguration) throws {
        for element in elements {
            switch element {
            case .step(let step):
                try validate(step.goal, config: config)
            case .repeatBlock(let count, let inner):
                guard config.repeatCountRange.contains(count) else {
                    throw PlanValidationError.repeatCountOutOfRange(
                        count: count, permitted: config.repeatCountRange
                    )
                }
                guard !inner.isEmpty else { throw PlanValidationError.emptyRepeatBlock }
                try validate(inner, config: config)
            }
        }
    }

    private static func validate(_ goal: StepGoal, config: IntervalConfiguration) throws {
        switch goal {
        case .open:
            break
        case .distance(let metres):
            guard metres.isFinite, config.stepDistanceRange.contains(metres) else {
                throw PlanValidationError.stepDistanceOutOfRange(
                    metres: metres, permitted: config.stepDistanceRange
                )
            }
        case .time(let seconds):
            guard seconds.isFinite, seconds > 0 else {
                throw PlanValidationError.nonPositiveTimeGoal(seconds: seconds)
            }
        }
    }

    /// Sum of all closed distance goals — the planned distance for a structured run.
    /// Open steps contribute nothing, since their length is not known in advance.
    public var totalPlannedDistanceMetres: Double? {
        if let explicit = plannedDistanceMetres { return explicit }
        let steps = resolvedSteps()
        let total = steps.compactMap { $0.goal.distanceMetres }.reduce(0, +)
        return total > 0 ? total : nil
    }
}

extension ResolvedStep {
    /// Whether this step ends on its own when a distance or time goal is met.
    public var advancesAutomatically: Bool { !goal.isOpen }
}
