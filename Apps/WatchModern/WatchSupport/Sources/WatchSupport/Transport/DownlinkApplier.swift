import Foundation
import Observation
import ORModels

/// Applies the phone's application context to the watch (T-050).
///
/// **The guarantee that matters is what happens when the phone is off.** AC-FR-I-1-6 requires the
/// watch to keep operating on the last-synced profile, which means a synced profile has to be
/// *persisted* on arrival rather than held in memory — otherwise a watch that reboots on a run
/// with the phone at home falls back to defaults, and the runner is judged against an 8:00 target
/// they never set. So this writes through `SettingsStore` immediately, and nothing here needs the
/// phone to be reachable afterwards.
///
/// Acknowledgements are handled by `SyncCoordinator`; this owns the profile and plan halves of the
/// same context. Both are driven from one `PhoneContext` because `WCSession` has one channel.
@MainActor
@Observable
public final class DownlinkApplier {

    /// The planned workouts the phone last sent, newest context wins.
    ///
    /// Not persisted, deliberately: a plan is only meaningful for the days it names, and a stale
    /// list surviving a reboot would offer the runner yesterday's workout as though it were
    /// today's. The profile is different — it has no expiry, so it *is* persisted.
    public private(set) var plannedWorkouts: [PlannedWorkoutDescriptor] = []

    /// Highest sequence applied, so an out-of-order redelivery cannot roll the profile back.
    public private(set) var lastAppliedSequence: Int = -1
    public private(set) var lastAppliedAt: Date?

    private let settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Applies a context. Returns whether it was applied, or `false` if discarded as stale.
    @discardableResult
    public func apply(_ context: PhoneContext, now: Date = Date()) -> Bool {
        guard context.sequence > lastAppliedSequence else { return false }
        lastAppliedSequence = context.sequence
        lastAppliedAt = now

        if let profile = context.profile {
            // Written through to storage, not just held — see the type note.
            settings.apply(synced: profile)
        }
        // A context with no profile leaves the stored one alone rather than clearing it. `nil`
        // means "the phone has not completed onboarding", not "the runner has no settings", and
        // wiping a working profile because the phone had nothing to say would be the worst
        // possible reading.

        plannedWorkouts = context.plannedWorkouts
        return true
    }

    /// Today's planned workout, for the start screen (AC-FR-A-7-4).
    public func plannedWorkout(on date: Date = Date(), calendar: Calendar = .current) -> PlannedWorkoutDescriptor? {
        plannedWorkouts.first { calendar.isDate($0.scheduledFor, inSameDayAs: date) }
    }

    /// The profile the watch is operating on — synced or defaulted.
    public var activeProfile: RunnerProfile { settings.profile }
}
