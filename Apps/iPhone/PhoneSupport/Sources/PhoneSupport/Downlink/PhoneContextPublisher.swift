import Foundation
import ORModels
import SwiftData

/// Sends the application context to the watch. Implemented over `WCSession` in the app target.
public protocol ContextTransporting: AnyObject {
    func send(context: [String: Any]) throws
}

/// Publishes the phone's state to the watch (T-050, T-049's acknowledgement half).
///
/// **One publisher, because there is one channel.** `WCSession.updateApplicationContext` replaces
/// the stored context wholesale rather than merging, so acknowledgements and the profile downlink
/// cannot be sent independently — whichever wrote last would erase the other. Everything the
/// phone tells the watch is therefore assembled here into a single `PhoneContext` and sent once.
/// See the note on `PhoneContext` and the design.md §10 correction.
///
/// The acknowledgement window is the other half of the same problem. The channel is
/// latest-value-wins, so any context the watch misses while asleep is simply gone; naming only
/// the run just processed would strand every run acknowledged during that window on the watch,
/// filling its eviction budget with payloads the phone already holds. The window is bounded so
/// the context cannot grow without limit.
public final class PhoneContextPublisher {

    /// How many recently-processed runs travel in each context.
    ///
    /// Sized against the watch's own queue limit (`SyncConfiguration.maxPendingRuns`, 50): a
    /// window at least that large can acknowledge everything the watch could possibly be holding
    /// in one delivery, which is what makes a watch that has been away for weeks recover in a
    /// single reconnect rather than a slow drip.
    public static let acknowledgementWindow = 64

    private let transport: ContextTransporting
    private let context: ModelContext

    /// Monotonic, so the watch can discard an out-of-order redelivery.
    private var sequence: Int
    private var recentlyAcked: [UUID] = []
    private var recentlyNacked: [SyncNack] = []

    public init(transport: ContextTransporting, context: ModelContext, startingSequence: Int = 0) {
        self.transport = transport
        self.context = context
        self.sequence = startingSequence
    }

    /// The most recent context sent, for tests and diagnostics.
    public private(set) var lastSent: PhoneContext?

    // MARK: - Recording outcomes

    /// Folds an ingest outcome into the rolling window.
    public func record(_ outcome: IngestOutcome) {
        switch outcome {
        case let .accepted(runID):
            // Deduplicated: a re-delivered run would otherwise occupy several slots in the
            // window and push older acknowledgements out early.
            recentlyAcked.removeAll { $0 == runID }
            recentlyAcked.append(runID)
            recentlyNacked.removeAll { $0.runID == runID }

        case let .rejected(nack, _):
            recentlyNacked.removeAll { $0.runID == nack.runID }
            recentlyNacked.append(nack)
            // A run that was previously accepted and is now refused is a contradiction the
            // watch should not have to reconcile; the newest verdict wins.
            recentlyAcked.removeAll { $0 == nack.runID }
        }

        trim()
    }

    private func trim() {
        if recentlyAcked.count > Self.acknowledgementWindow {
            recentlyAcked.removeFirst(recentlyAcked.count - Self.acknowledgementWindow)
        }
        if recentlyNacked.count > Self.acknowledgementWindow {
            recentlyNacked.removeFirst(recentlyNacked.count - Self.acknowledgementWindow)
        }
    }

    // MARK: - Publishing

    /// Assembles and sends the current context.
    ///
    /// The sequence advances only on a successful send. Advancing it on a failure would leave a
    /// gap the watch reads as "a context I missed", and since the watch only compares
    /// sequences — it cannot request a resend — that gap is harmless but the accounting is
    /// clearer if the number means "contexts actually published".
    @discardableResult
    public func publish(now: Date = Date()) throws -> PhoneContext {
        let profile = try storedProfile()
        let planned = try upcomingPlannedWorkouts(from: now)

        let payload = PhoneContext(
            sequence: sequence + 1,
            acknowledgement: SyncAcknowledgement(acked: recentlyAcked, nacked: recentlyNacked),
            profile: profile,
            plannedWorkouts: planned
        )

        try transport.send(context: try payload.encoded())
        sequence = payload.sequence
        lastSent = payload
        return payload
    }

    // MARK: - Reading what to send

    private func storedProfile() throws -> RunnerProfile? {
        let id = RunnerProfileRecord.singletonID
        var descriptor = FetchDescriptor<RunnerProfileRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1

        guard let record = try context.fetch(descriptor).first else { return nil }
        return try? RunEnvelopeCoder.makeDecoder().decode(
            RunnerProfile.self, from: record.profileData
        )
    }

    /// Today's and the next few days' planned workouts.
    ///
    /// Returns an empty array today, and will keep doing so until Wave 5 generates plans. That
    /// is deliberate: the wire format is carried early because retrofitting a field into a
    /// latest-value-wins channel that older builds already parse is far more awkward than
    /// reserving it, but fabricating a planned workout to demonstrate the channel would put a
    /// feature on the watch's start screen that the product does not have.
    private func upcomingPlannedWorkouts(from now: Date) throws -> [PlannedWorkoutDescriptor] {
        let horizon = now.addingTimeInterval(7 * 86_400)
        let descriptor = FetchDescriptor<PlannedWorkoutRecord>(
            predicate: #Predicate { $0.scheduledFor >= now && $0.scheduledFor <= horizon },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )

        let decoder = RunEnvelopeCoder.makeDecoder()
        return try context.fetch(descriptor).compactMap { record in
            guard let plan = try? decoder.decode(WorkoutPlan.self, from: record.planData) else {
                return nil
            }
            return PlannedWorkoutDescriptor(
                id: record.id,
                scheduledFor: record.scheduledFor,
                plan: plan,
                notes: record.notes
            )
        }
    }
}

// MARK: - Profile storage

/// Reads and writes the runner profile (T-062's storage half).
public struct ProfileRepository {

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func profile() throws -> RunnerProfile? {
        try record().flatMap {
            try? RunEnvelopeCoder.makeDecoder().decode(RunnerProfile.self, from: $0.profileData)
        }
    }

    public func record() throws -> RunnerProfileRecord? {
        let id = RunnerProfileRecord.singletonID
        var descriptor = FetchDescriptor<RunnerProfileRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @discardableResult
    public func save(_ profile: RunnerProfile, now: Date = Date()) throws -> RunnerProfileRecord {
        let data = try RunEnvelopeCoder.makeEncoder().encode(profile)

        if let existing = try record() {
            existing.profileData = data
            existing.updatedAt = now
            try context.save()
            return existing
        }

        let record = RunnerProfileRecord(profileData: data, updatedAt: now)
        context.insert(record)
        try context.save()
        return record
    }

    /// R-6 — plan generation stays unreachable until the disclaimer is acknowledged.
    public func acknowledgeDisclaimer(at date: Date = Date()) throws {
        guard let record = try record() else { return }
        record.disclaimerAcknowledgedAt = date
        try context.save()
    }

    public func hasAcknowledgedDisclaimer() throws -> Bool {
        try record()?.disclaimerAcknowledgedAt != nil
    }
}
