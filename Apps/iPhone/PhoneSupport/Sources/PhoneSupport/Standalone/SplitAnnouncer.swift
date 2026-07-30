import Foundation
import ORModels
import ORPace

/// Distance and time progress announcements (S-042, AC-FR-S-D-1-5).
///
/// **Deliberately not routed through `AlertPolicy`** (ADR-S-05). A mile split is not an
/// alert: it is not a correction, it carries no direction, and it must not consume an
/// alert's cooldown — a runner who crosses mile three while drifting fast needs both the
/// split and the "ease off", and a shared cooldown would silently drop one of them.
///
/// The whole channel is this file, and its state is two counters. That is the argument for
/// keeping it separate stated as code: nothing here needs dwell, hysteresis or priority,
/// so folding it into the machinery that does would have added a case to a state machine
/// whose simplicity is the reason "does it nag?" is answerable.
public struct SplitAnnouncer: Sendable {

    private let unit: UnitPreference
    private let distanceEnabled: Bool
    private let timeIntervalSeconds: TimeInterval?

    /// Splits already announced. Not a distance threshold — a counter — so a run that
    /// briefly loses and regains distance cannot announce mile three twice.
    private var lastSplitIndex = 0
    private var lastTimeAnnouncement: TimeInterval = 0
    /// Distance and time at the last split boundary, for the split's own pace.
    private var lastSplitDistance = 0.0
    private var lastSplitElapsed = 0.0

    public init(profile: RunnerProfile) {
        self.unit = profile.units
        self.distanceEnabled = profile.splitAnnouncementsEnabled
        self.timeIntervalSeconds = profile.timeAnnouncementIntervalSeconds
    }

    /// Evaluates one tick and returns whatever should be said, in order.
    ///
    /// Returns an array rather than an optional because a distance split and a time
    /// announcement can genuinely fall on the same second, and dropping one of them
    /// silently is worse than saying two sentences.
    public mutating func tick(
        cumulativeDistance: Double,
        activeElapsed: TimeInterval,
        averagePace: Pace?
    ) -> [SpokenCue] {
        var cues: [SpokenCue] = []

        if distanceEnabled, cumulativeDistance.isFinite, cumulativeDistance > 0 {
            let boundary = unit.metresPerUnit
            let reached = Int(cumulativeDistance / boundary)
            // A loop rather than an `if`, because a GNSS re-anchor after a long outage can
            // legitimately advance cumulative distance past more than one boundary in a
            // single tick. Announcing only the latest would silently skip a mile.
            while reached > lastSplitIndex {
                lastSplitIndex += 1
                let splitDistance = Double(lastSplitIndex) * boundary
                // The split's own pace comes from the stretch since the previous boundary,
                // interpolated to the boundary itself rather than measured to wherever the
                // tick happened to land. Without that, a tick that overshoots by 15 m
                // reports a pace for 1.01 units and calls it a mile.
                let splitSeconds = interpolatedElapsed(
                    toDistance: splitDistance,
                    currentDistance: cumulativeDistance,
                    currentElapsed: activeElapsed)
                let splitPace = Pace(
                    distanceMetres: splitDistance - lastSplitDistance,
                    seconds: splitSeconds - lastSplitElapsed)
                cues.append(SpokenCue(
                    kind: .split(index: lastSplitIndex),
                    phrase: StandaloneStrings.splitCue(
                        index: lastSplitIndex,
                        unit: unit,
                        splitPace: ORFormat.pace(splitPace, in: unit),
                        averagePace: ORFormat.pace(averagePace, in: unit))))
                lastSplitDistance = splitDistance
                lastSplitElapsed = splitSeconds
            }
        }

        if let interval = timeIntervalSeconds, interval > 0,
            activeElapsed - lastTimeAnnouncement >= interval
        {
            lastTimeAnnouncement = activeElapsed
            cues.append(SpokenCue(
                kind: .timeProgress,
                phrase: StandaloneStrings.timeCue(
                    elapsed: ORFormat.duration(activeElapsed),
                    distance: ORFormat.distance(cumulativeDistance, in: unit),
                    unit: unit,
                    averagePace: ORFormat.pace(averagePace, in: unit))))
        }

        return cues
    }

    /// Linear interpolation back to the boundary from the tick that crossed it.
    ///
    /// Assumes constant speed across one second, which at running pace is a few metres and
    /// therefore an error of well under a second in the reported split — a good deal
    /// smaller than the error from reporting the tick's own elapsed time.
    private func interpolatedElapsed(
        toDistance target: Double, currentDistance: Double, currentElapsed: TimeInterval
    ) -> TimeInterval {
        let coveredSinceLast = currentDistance - lastSplitDistance
        guard coveredSinceLast > 0 else { return currentElapsed }
        let fraction = (target - lastSplitDistance) / coveredSinceLast
        guard fraction.isFinite, fraction > 0, fraction <= 1 else { return currentElapsed }
        return lastSplitElapsed + fraction * (currentElapsed - lastSplitElapsed)
    }
}
