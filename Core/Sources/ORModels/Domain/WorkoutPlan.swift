import Foundation

// MARK: - Step target

/// A pace prescription attached to an individual step (FR-C-5).
///
/// `nil` on a step means that step is not judged: neutral background, no pace haptics.
/// That is how a VO2 max workout is expressed — every step carries `nil`, so the
/// no-colour requirement (AC-FR-C-4-2) falls out of the data rather than out of a
/// special case in the view.
public struct StepTarget: Codable, Sendable, Hashable {
    public let pace: Pace
    /// Band override. `nil` uses the interval default from configuration.
    public let band: PaceBand?

    public init(pace: Pace, band: PaceBand? = nil) {
        self.pace = pace
        self.band = band
    }
}

// MARK: - Step

/// One phase of a structured workout (AC-FR-C-1-1).
public struct WorkoutStep: Codable, Sendable, Hashable {
    public let kind: StepKind
    public let goal: StepGoal
    public let target: StepTarget?

    public init(kind: StepKind, goal: StepGoal, target: StepTarget? = nil) {
        self.kind = kind
        self.goal = goal
        self.target = target
    }
}

// MARK: - Plan element

/// A step, or a repeated group of elements (AC-FR-C-1-3).
///
/// Recursive so `4 × (1000 m work + 1000 m recovery)` is expressible without listing
/// eight steps. The runtime never walks this tree — it walks the flattened form — so
/// the recursion costs nothing at 1 Hz.
public indirect enum PlanElement: Codable, Sendable, Hashable {
    case step(WorkoutStep)
    case repeatBlock(count: Int, elements: [PlanElement])
}

// MARK: - Workout plan

/// The full prescription for a run (design.md §6.1).
public struct WorkoutPlan: Codable, Sendable, Hashable {
    public let runType: RunType
    public let elements: [PlanElement]
    /// Planned total distance in metres, used for progress when the plan is a single
    /// continuous effort rather than a step list (AC-FR-A-2-5).
    public let plannedDistanceMetres: Double?
    /// Planned duration, used for progress when there is no planned distance
    /// (AC-FR-A-2-6).
    public let plannedDurationSeconds: Double?

    public init(
        runType: RunType,
        elements: [PlanElement],
        plannedDistanceMetres: Double? = nil,
        plannedDurationSeconds: Double? = nil
    ) {
        self.runType = runType
        self.elements = elements
        self.plannedDistanceMetres = plannedDistanceMetres
        self.plannedDurationSeconds = plannedDurationSeconds
    }
}

// MARK: - Resolved step

/// A step after repeat blocks have been expanded (design.md §6.1).
///
/// Carries its rep position so the UI can say "rep 3 of 4" without re-walking the
/// plan tree, and so the step machine never needs to recurse.
public struct ResolvedStep: Codable, Sendable, Hashable {
    /// Position in the flattened list, zero-based.
    public let index: Int
    public let kind: StepKind
    public let goal: StepGoal
    public let target: StepTarget?
    /// One-based rep number within its repeat block. 1 when not inside one.
    public let repIndex: Int
    /// Total reps in its repeat block. 1 when not inside one.
    public let repCount: Int

    public init(
        index: Int,
        kind: StepKind,
        goal: StepGoal,
        target: StepTarget?,
        repIndex: Int,
        repCount: Int
    ) {
        self.index = index
        self.kind = kind
        self.goal = goal
        self.target = target
        self.repIndex = repIndex
        self.repCount = repCount
    }

    /// Whether this step is part of a repeated block, and therefore worth showing a
    /// rep counter for.
    public var isRepeated: Bool { repCount > 1 }
}

// MARK: - Step summary

/// Per-step totals recorded for post-run analysis (AC-FR-D-2-2, AC-FR-F-2-5).
public struct StepSummary: Codable, Sendable, Hashable {
    public let index: Int
    public let kind: StepKind
    public let repIndex: Int
    public let repCount: Int
    public let distanceMetres: Double
    public let activeSeconds: Double
    public let averagePace: Pace?
    public let averageHeartRate: Double?
    public let maxHeartRate: Double?
    public let elevationChangeMetres: Double

    public init(
        index: Int,
        kind: StepKind,
        repIndex: Int,
        repCount: Int,
        distanceMetres: Double,
        activeSeconds: Double,
        averagePace: Pace?,
        averageHeartRate: Double?,
        maxHeartRate: Double?,
        elevationChangeMetres: Double
    ) {
        self.index = index
        self.kind = kind
        self.repIndex = repIndex
        self.repCount = repCount
        self.distanceMetres = distanceMetres
        self.activeSeconds = activeSeconds
        self.averagePace = averagePace
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.elevationChangeMetres = elevationChangeMetres
    }
}
