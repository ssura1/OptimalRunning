import Foundation
import ORIntervals
import ORModels
import ORStats
import LegacySupport

/// The coordinator's run actions, kept apart from its construction so the entry point stays readable.
///
/// Every method here is a thin bridge: it decides nothing, forwarding to `RunSessionModel` and
/// `LegacySupport`, both covered by `swift test` on the host. That split keeps the untestable surface
/// of this tier — everything under `Apps/WatchLegacy/Sources` — as small as it can be, which matters
/// because there is no watchOS 8 simulator to exercise any of it.
@MainActor
extension AppCoordinator {

    /// Starts a run of the chosen type.
    ///
    /// The plan comes from `WorkoutPresets` in `Core`, never assembled here — a tier that built its
    /// own plan would be a second definition of what "4×1000 m" means, and the shared goldens would
    /// not notice the difference.
    func startRun(type: RunType) {
        let plan: WorkoutPlan
        switch type {
        case .interval:
            plan = WorkoutPresets.intervals(
                reps: 4, workMetres: 1_000, recoveryMetres: 1_000
            )
        case .vo2max:
            plan = WorkoutPresets.vo2Max4x1000()
        case .tempo, .easy, .long:
            plan = WorkoutPresets.continuousRun(runType: type)
        }

        let activity: RunActivityKind = .outdoorRun

        Task { @MainActor in
            do {
                try await run.start(
                    plan: plan, profile: profile, activity: activity, now: 0
                )
                // Navigate only once the run has actually started. A refusal (DEG-6) leaves the
                // runner on the start screen with the reason visible, rather than on a run screen
                // that will never tick.
                guard run.phase == .running else { return }

                activePlan = plan
                feed.manualAdvanceRequested = { [weak self] in
                    self?.run.consumeManualAdvanceRequest() ?? false
                }
                feed.onSample = { [weak self] input in self?.run.ingest(input) }
                try feed.start(activity: activity)
                screen = .run
            } catch {
                screen = .start
            }
        }
    }

    /// Advances the current step, if `Core` permits it for this step (AC-FR-C-3).
    ///
    /// Tap and crown detent both land here. The request is latched and folded into the next tick
    /// rather than acted on directly, so `StepMachine` — not this tier — decides whether it is
    /// allowed. A distance-goal rep ends when the distance is covered, and a stray glove-tap must not
    /// end it early.
    func advanceStepIfPermitted() {
        run.requestManualAdvance()
    }

    func pauseRun() {
        Task { @MainActor in
            feed.pause()
            await run.pause(now: lastTickTime)
        }
    }

    func resumeRun() {
        Task { @MainActor in
            feed.resume()
            await run.resume(now: lastTickTime)
        }
    }

    /// Ends the run, builds the envelope, and queues it for the phone (T-071).
    func endRun() {
        Task { @MainActor in
            defer { screen = .start }
            do {
                _ = try await feed.stop()
                let finished = try await run.end(now: lastTickTime)
                queueEnvelope(summary: finished.summary, steps: finished.steps, degradations: [])
            } catch {
                // The run is already flushed to disk by this point, so a failure here loses the
                // *upload*, not the run: the queue retries on next reachability, and orphan recovery
                // is the backstop if the app died before this ran at all.
            }
        }
    }

    /// Saves a run recovered after a crash (DEG-7), on the same upload path a normal run takes.
    func saveOrphan() {
        guard let samples = run.recoverOrphan(), !samples.isEmpty,
              let plan = activePlan ?? lastKnownPlan
        else { return }

        // Rebuilt from the recovered samples rather than from live state, which is gone. Flagged
        // `.sessionInterrupted` so the phone knows the totals came from a capture that never
        // finished cleanly — real data, but not a completed run.
        let zones = samples.map(\.zone)
        let summary = RunSummaryBuilder.build(
            samples: samples,
            activeSeconds: samples.last?.timestamp ?? 0,
            zoneTimeline: ZoneTimeline.encode(zones: zones)
        )
        queueEnvelope(
            summary: summary, steps: [], degradations: [.sessionInterrupted],
            samples: samples, zones: zones, plan: plan
        )
    }

    /// Assembles the envelope and puts it on the durable queue.
    ///
    /// Queued rather than transmitted directly, and the distinction is the requirement: reachability
    /// is not something a run can wait for (AC-FR-E-1-2). The queue survives relaunch, so a run that
    /// gets this far is not lost even if the phone is hours away.
    private func queueEnvelope(
        summary: RunSummary,
        steps: [StepSummary],
        degradations: [DegradationFlag],
        samples: [RunSample]? = nil,
        zones: [PaceZone]? = nil,
        plan: WorkoutPlan? = nil
    ) {
        guard let plan = plan ?? activePlan,
              let runID = run.currentRunID
        else { return }

        let capturedSamples = samples ?? run.capturedSamples
        let capturedZones = zones ?? run.capturedZones
        let started = Date().addingTimeInterval(-(capturedSamples.last?.timestamp ?? 0))

        let envelope = RunEnvelopeBuilder.build(
            runID: runID,
            startedAt: started,
            endedAt: Date(),
            plan: plan,
            profile: profile,
            config: .default,
            healthKitWorkoutUUID: run.savedWorkoutID,
            samples: capturedSamples,
            zones: capturedZones,
            steps: steps,
            activeSeconds: summary.activeSeconds,
            route: nil,
            degradations: degradations,
            appVersion: appVersion
        )

        guard let payload = try? SyncPayloadCodec.encode(envelope) else { return }
        queue.enqueue(runID: runID, payload: payload)
        lastKnownPlan = plan
    }
}
