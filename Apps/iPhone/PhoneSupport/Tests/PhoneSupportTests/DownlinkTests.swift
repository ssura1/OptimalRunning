import XCTest
import ORIntervals
import ORModels
import SwiftData
@testable import PhoneSupport

/// A context transport the test inspects.
final class FakeContextTransport: ContextTransporting {
    private(set) var sent: [[String: Any]] = []
    var shouldFail = false

    func send(context: [String: Any]) throws {
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        sent.append(context)
    }

    /// The decoded contexts, which is what the watch would actually see.
    var decoded: [PhoneContext] {
        sent.compactMap(PhoneContext.init(context:))
    }
}

/// T-050 — the phone → watch downlink (profile now, plans when Wave 5 generates them).
final class DownlinkTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try RunStoreContainer.inMemory())
    }

    private func profile(tempo: Double) -> RunnerProfile {
        RunnerProfile(
            tempoPace: Pace(minutesPerMile: tempo),
            easyPace: Pace(minutesPerMile: tempo + 1.5),
            longPace: Pace(minutesPerMile: tempo + 1),
            units: .kilometres,
            palette: .colorVisionDeficiency,
            paceHapticsEnabled: false
        )
    }

    // MARK: - A profile edit reaches the watch

    func testAProfileEditIsPublishedToTheWatch() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        let publisher = PhoneContextPublisher(transport: transport, context: context)

        try ProfileRepository(context: context).save(profile(tempo: 7.5))
        try publisher.publish()

        let sent = try XCTUnwrap(transport.decoded.last)
        let received = try XCTUnwrap(sent.profile)

        XCTAssertEqual(received.tempoPace?.minutesPerMile ?? 0, 7.5, accuracy: 1e-9)
        XCTAssertEqual(received.units, .kilometres)
        XCTAssertEqual(received.palette, .colorVisionDeficiency)
        XCTAssertFalse(received.paceHapticsEnabled)
    }

    /// The whole point of the channel: an edit made later supersedes the earlier value.
    func testASubsequentEditSupersedesTheEarlierProfile() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        let publisher = PhoneContextPublisher(transport: transport, context: context)
        let profiles = ProfileRepository(context: context)

        try profiles.save(profile(tempo: 8.0))
        try publisher.publish()
        try profiles.save(profile(tempo: 7.0))
        try publisher.publish()

        XCTAssertEqual(transport.decoded.count, 2)
        XCTAssertEqual(
            transport.decoded.last?.profile?.tempoPace?.minutesPerMile ?? 0, 7.0, accuracy: 1e-9
        )
        // Sequences advance, so the watch can tell which is newer.
        XCTAssertGreaterThan(
            try XCTUnwrap(transport.decoded.last).sequence,
            try XCTUnwrap(transport.decoded.first).sequence
        )
    }

    /// Before onboarding there is no profile, and the context must say so rather than inventing
    /// defaults the watch would then adopt as though the user had chosen them.
    func testWithNoStoredProfileTheContextCarriesNone() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()

        try PhoneContextPublisher(transport: transport, context: context).publish()

        XCTAssertNil(try XCTUnwrap(transport.decoded.last).profile)
    }

    /// The context survives the plist encoding `WCSession` imposes.
    func testTheContextRoundTripsThroughItsTransportEncoding() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        try ProfileRepository(context: context).save(profile(tempo: 7.25))

        let published = try PhoneContextPublisher(transport: transport, context: context).publish()
        let received = try XCTUnwrap(PhoneContext(context: try XCTUnwrap(transport.sent.last)))

        XCTAssertEqual(received, published, "the context changed in transit")
    }

    func testAFailedSendDoesNotAdvanceTheSequence() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        let publisher = PhoneContextPublisher(transport: transport, context: context)

        try publisher.publish()
        let afterFirst = try XCTUnwrap(publisher.lastSent).sequence

        transport.shouldFail = true
        XCTAssertThrowsError(try publisher.publish())
        XCTAssertEqual(publisher.lastSent?.sequence, afterFirst, "a failed send was recorded")

        transport.shouldFail = false
        let resumed = try publisher.publish()
        XCTAssertEqual(resumed.sequence, afterFirst + 1, "the sequence skipped a number")
    }

    // MARK: - The acknowledgement window

    /// Acknowledgements ride the same context, because there is only one.
    func testAcknowledgementsAndProfileTravelInTheSameContext() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        let publisher = PhoneContextPublisher(transport: transport, context: context)
        try ProfileRepository(context: context).save(profile(tempo: 7.5))

        let runID = UUID()
        publisher.record(.accepted(runID: runID))
        let sent = try publisher.publish()

        XCTAssertEqual(sent.acknowledgement.acked, [runID])
        XCTAssertNotNil(sent.profile, "the profile was lost when an acknowledgement was added")
    }

    /// A watch that missed several contexts catches up in one delivery — the reason the window is
    /// a set rather than a single runID.
    func testTheWindowCarriesEveryRecentlyProcessedRun() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        let publisher = PhoneContextPublisher(transport: transport, context: context)

        let ids = (0..<20).map { _ in UUID() }
        for id in ids { publisher.record(.accepted(runID: id)) }

        XCTAssertEqual(try publisher.publish().acknowledgement.acked, ids)
    }

    /// Bounded, so a phone that has ingested thousands of runs does not try to send them all.
    func testTheWindowIsBounded() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        let publisher = PhoneContextPublisher(transport: transport, context: context)

        let ids = (0..<200).map { _ in UUID() }
        for id in ids { publisher.record(.accepted(runID: id)) }

        let acked = try publisher.publish().acknowledgement.acked
        XCTAssertEqual(acked.count, PhoneContextPublisher.acknowledgementWindow)
        // The *most recent* are kept — the oldest are the ones the watch has most likely already
        // acted on.
        XCTAssertEqual(acked, ids.suffix(PhoneContextPublisher.acknowledgementWindow))
    }

    /// The window is at least as large as the watch's queue limit, so a watch holding a full
    /// queue can be cleared in a single reconnect.
    func testTheWindowCoversAFullWatchQueue() {
        XCTAssertGreaterThanOrEqual(
            PhoneContextPublisher.acknowledgementWindow,
            SyncConfiguration().maxPendingRuns,
            "a watch at its queue limit could not be fully acknowledged in one context"
        )
    }

    /// A re-delivered run occupies one slot, not several — otherwise a retry storm would push
    /// genuine acknowledgements out of the window.
    func testAReDeliveredRunOccupiesOneWindowSlot() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        let publisher = PhoneContextPublisher(transport: transport, context: context)

        let runID = UUID()
        for _ in 0..<10 { publisher.record(.accepted(runID: runID)) }

        XCTAssertEqual(try publisher.publish().acknowledgement.acked, [runID])
    }

    /// A rejection replaces an earlier acceptance of the same run, so the watch is never handed
    /// two contradictory verdicts to reconcile.
    func testTheNewestVerdictForARunWins() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        let publisher = PhoneContextPublisher(transport: transport, context: context)

        let runID = UUID()
        publisher.record(.accepted(runID: runID))
        publisher.record(.rejected(
            nack: SyncNack(runID: runID, reason: .unsupportedSchema), message: "nope"
        ))

        let sent = try publisher.publish().acknowledgement
        XCTAssertTrue(sent.acked.isEmpty, "the run is both acknowledged and rejected")
        XCTAssertEqual(sent.nacked.map(\.runID), [runID])
    }

    // MARK: - Planned workouts

    /// The wire format carries a planned workout when one exists, so Wave 5 has nothing to change
    /// in the channel.
    func testAStoredPlannedWorkoutIsPublished() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        let publisher = PhoneContextPublisher(transport: transport, context: context)

        let plan = WorkoutPresets.intervals(reps: 5, workMetres: 800, recoveryMetres: 400)
        let scheduledFor = Date().addingTimeInterval(3_600)
        context.insert(PlannedWorkoutRecord(
            id: UUID(),
            scheduledFor: scheduledFor,
            planData: try RunEnvelopeCoder.makeEncoder().encode(plan),
            notes: "5 × 800"
        ))
        try context.save()

        let sent = try publisher.publish()
        let descriptor = try XCTUnwrap(sent.plannedWorkouts.first)

        XCTAssertEqual(descriptor.plan, plan)
        XCTAssertEqual(descriptor.notes, "5 × 800")
        XCTAssertEqual(sent.plannedWorkout(on: scheduledFor)?.id, descriptor.id)
    }

    /// And with nothing stored — today's real state, since plan generation is Wave 5 — the list is
    /// empty rather than fabricated.
    func testWithNoPlansStoredNoPlannedWorkoutsArePublished() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()

        let sent = try PhoneContextPublisher(transport: transport, context: context).publish()
        XCTAssertTrue(sent.plannedWorkouts.isEmpty)
    }

    /// Past workouts are not sent — the watch's start screen shows today's, and offering a
    /// workout the runner already missed would be worse than offering none.
    func testPastPlannedWorkoutsAreNotPublished() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        let now = Date()

        let plan = WorkoutPresets.vo2Max4x1000()
        let data = try RunEnvelopeCoder.makeEncoder().encode(plan)
        context.insert(PlannedWorkoutRecord(
            id: UUID(), scheduledFor: now.addingTimeInterval(-2 * 86_400), planData: data
        ))
        context.insert(PlannedWorkoutRecord(
            id: UUID(), scheduledFor: now.addingTimeInterval(86_400), planData: data
        ))
        try context.save()

        let sent = try PhoneContextPublisher(transport: transport, context: context)
            .publish(now: now)
        XCTAssertEqual(sent.plannedWorkouts.count, 1, "a past workout was published")
    }

    /// Workouts beyond the horizon are not sent either — the watch has no use for next month's
    /// plan and the context is a small, latest-value-wins payload.
    func testPlannedWorkoutsBeyondTheHorizonAreNotPublished() throws {
        let context = try makeContext()
        let transport = FakeContextTransport()
        let now = Date()

        context.insert(PlannedWorkoutRecord(
            id: UUID(),
            scheduledFor: now.addingTimeInterval(30 * 86_400),
            planData: try RunEnvelopeCoder.makeEncoder().encode(WorkoutPresets.vo2Max4x1000())
        ))
        try context.save()

        let sent = try PhoneContextPublisher(transport: transport, context: context)
            .publish(now: now)
        XCTAssertTrue(sent.plannedWorkouts.isEmpty)
    }

    // MARK: - Profile storage

    func testTheProfileRepositoryUpsertsRatherThanDuplicating() throws {
        let context = try makeContext()
        let profiles = ProfileRepository(context: context)

        try profiles.save(profile(tempo: 8.0))
        try profiles.save(profile(tempo: 7.0))

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RunnerProfileRecord>()), 1)
        XCTAssertEqual(
            try profiles.profile()?.tempoPace?.minutesPerMile ?? 0, 7.0, accuracy: 1e-9
        )
    }

    /// R-6 — the disclaimer gate is stored, not assumed.
    func testTheDisclaimerAcknowledgementPersists() throws {
        let context = try makeContext()
        let profiles = ProfileRepository(context: context)
        try profiles.save(profile(tempo: 8.0))

        XCTAssertFalse(try profiles.hasAcknowledgedDisclaimer())
        try profiles.acknowledgeDisclaimer()
        XCTAssertTrue(try profiles.hasAcknowledgedDisclaimer())
    }
}
