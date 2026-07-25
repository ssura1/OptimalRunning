import Foundation
import ORModels

/// Built-in workout plans (AC-FR-C-1-5).
public enum WorkoutPresets {

    /// The product memo's canonical session, and the reference case for the whole
    /// interval engine:
    ///
    ///   open warmup → 4 × (1000 m hard / 1000 m jog) → open cooldown
    ///
    /// Every step carries `target: nil`, which is what makes the screen stay neutral.
    /// A VO2 max session is a *test of capability*, so prescribing a pace would
    /// contaminate the measurement (FR-C-4). The no-colour behaviour therefore falls
    /// out of the data, not out of a special case in the view.
    ///
    /// Flattens to exactly 10 resolved steps.
    public static func vo2Max4x1000() -> WorkoutPlan {
        WorkoutPlan(
            runType: .vo2max,
            elements: [
                .step(WorkoutStep(kind: .warmup, goal: .open)),
                .repeatBlock(count: 4, elements: [
                    .step(WorkoutStep(kind: .work, goal: .distance(metres: 1000))),
                    .step(WorkoutStep(kind: .recovery, goal: .distance(metres: 1000))),
                ]),
                .step(WorkoutStep(kind: .cooldown, goal: .open)),
            ]
        )
    }

    /// A generic repeated interval session with an optional pace target on the work
    /// steps. Unlike VO2 max, interval steps *may* be judged (FR-C-5).
    public static func intervals(
        reps: Int,
        workMetres: Double,
        recoveryMetres: Double,
        workTarget: StepTarget? = nil,
        recoveryTarget: StepTarget? = nil
    ) -> WorkoutPlan {
        WorkoutPlan(
            runType: .interval,
            elements: [
                .step(WorkoutStep(kind: .warmup, goal: .open)),
                .repeatBlock(count: reps, elements: [
                    .step(WorkoutStep(kind: .work, goal: .distance(metres: workMetres), target: workTarget)),
                    .step(WorkoutStep(
                        kind: .recovery,
                        goal: .distance(metres: recoveryMetres),
                        target: recoveryTarget
                    )),
                ]),
                .step(WorkoutStep(kind: .cooldown, goal: .open)),
            ]
        )
    }

    /// A single continuous effort — tempo, easy, or long.
    ///
    /// Modelled as a one-step plan rather than as a separate code path, so the engine
    /// has exactly one shape of run to reason about.
    public static func continuousRun(
        runType: RunType,
        plannedDistanceMetres: Double? = nil,
        plannedDurationSeconds: Double? = nil
    ) -> WorkoutPlan {
        let goal: StepGoal
        if let metres = plannedDistanceMetres {
            goal = .distance(metres: metres)
        } else if let seconds = plannedDurationSeconds {
            goal = .time(seconds: seconds)
        } else {
            goal = .open
        }
        return WorkoutPlan(
            runType: runType,
            elements: [.step(WorkoutStep(kind: .work, goal: goal))],
            plannedDistanceMetres: plannedDistanceMetres,
            plannedDurationSeconds: plannedDurationSeconds
        )
    }
}
