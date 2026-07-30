import ORModels
import PhoneSupport
import SwiftData
import SwiftUI

/// Assembles a standalone run from its parts, and puts the finished run in the hub (S-032,
/// S-034).
///
/// **Note what is not imported here.** This is the composition root for a standalone run —
/// it builds the feed, the store, the cue player, the haptic player and the workout writer
/// — and it does it all without naming a single `PhoneMotion` type. The estimator's
/// configuration is `StandaloneSensorFeed`'s default argument, resolved inside the adapter,
/// so the day S-063 changes the exponent nothing here notices.
///
/// That is the isolation boundary working rather than merely being declared:
/// `Tools/check-phonemotion-isolation.sh` would fail the build on an `import PhoneMotion`
/// in this directory, and it does not need to, because there is nothing here that wants one.
@MainActor
@Observable
final class StandaloneRunCoordinator {

    /// The run in progress, or `nil`.
    private(set) var controller: StandaloneRunController?
    /// The most recent run's ID, so the app can push its detail screen when it ends.
    private(set) var lastFinishedRunID: UUID?
    private(set) var lastError: String?

    private let modelContext: ModelContext
    private let calibrationStore: any CalibrationStoring
    private let appVersion: String

    init(
        modelContext: ModelContext,
        calibrationStore: any CalibrationStoring = CalibrationFileStore.inApplicationSupport(),
        appVersion: String = Bundle.main.appVersion
    ) {
        self.modelContext = modelContext
        self.calibrationStore = calibrationStore
        self.appVersion = appVersion
    }

    /// Builds and starts a run.
    func start(_ request: StandaloneRunRequest) async {
        guard controller == nil else { return }

        let carryPosition = CarryPosition.handHeld
        let feed = StandaloneSensorFeed(
            activity: request.activity,
            carryPosition: carryPosition,
            // The runner's own height where it is known, and a documented default where it
            // is not (AC-FR-S-B-4-6). Read from the profile rather than from HealthKit at
            // this point: the settings screen already offered to import it, and a
            // permission prompt at the start of a run is the thing AC-FR-S-A-1-2 is about.
            runnerHeightMetres: request.profile.heightMetres,
            calibration: calibrationStore.loadCalibration(for: carryPosition))

        let controller = StandaloneRunController(
            plan: request.plan,
            activity: request.activity,
            profile: request.profile,
            feed: feed,
            store: StandaloneSampleStore(directory: Self.captureDirectory),
            cues: SpeechCuePlayer(),
            haptics: PhoneHapticPlayer(),
            workout: StandaloneWorkoutWriter(),
            calibrationStore: calibrationStore,
            carryPosition: carryPosition,
            appVersion: appVersion)

        do {
            try await controller.start()
            self.controller = controller
        } catch let refusal as StandaloneRunRefusal {
            lastError = Self.message(for: refusal)
        } catch {
            lastError = "The run could not be started (\(error))."
        }
    }

    /// Files a finished run through the hub's existing ingest path (FR-S-E-1).
    ///
    /// No new store and no new ingest: the envelope goes through `RunLibrary` exactly as a
    /// watch payload does, which is what makes a standalone run land in the run list, the
    /// detail screen and the aggregates with nothing else changed.
    func finish(_ envelope: RunEnvelope?) {
        controller = nil
        guard let envelope else { return }
        do {
            let payload = try SyncPayloadCodec.encode(envelope)
            let outcome = RunLibrary(context: modelContext).ingest(payload: payload)
            switch outcome {
            case let .accepted(runID):
                lastFinishedRunID = runID
            case let .rejected(_, message):
                lastError = message
            }
        } catch {
            lastError = "The run finished but could not be saved (\(error))."
        }
    }

    /// The orphan a previous launch left behind, if any (AC-FR-S-A-2-4).
    func detectOrphan() -> StandaloneSampleStore.OrphanedRun? {
        StandaloneSampleStore(directory: Self.captureDirectory).detectOrphan()
    }

    func discardOrphan(runID: UUID) {
        StandaloneSampleStore(directory: Self.captureDirectory).discardOrphan(runID: runID)
    }

    // MARK: - Private

    /// Where in-progress runs are flushed.
    ///
    /// Application Support rather than Documents: `UIFileSharingEnabled` is on for the
    /// capture tool's traces (FR-S-F-1-7), which exposes Documents in the Files app — and a
    /// half-written run appearing there would be both confusing and a privacy surface
    /// (NFR-S-16).
    private static var captureDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("StandaloneRuns", isDirectory: true)
    }

    private static func message(for refusal: StandaloneRunRefusal) -> String {
        switch refusal {
        case let .insufficientStorage(bytes):
            let megabytes = Int(Double(bytes) / 1_000_000)
            return "There is not enough free space to record a run safely "
                + "(\(megabytes) MB needed). Free some space and try again."
        case .alreadyRunning:
            return "A run is already in progress."
        case .noSensorsAuthorized:
            return StandaloneAuthorization.explanation(for: .refused) ?? ""
        }
    }
}

extension Bundle {
    /// `1.0 (1)`. Recorded on every envelope so a run stays diagnosable years later.
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
