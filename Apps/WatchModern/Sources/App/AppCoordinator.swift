import Foundation
import Observation
import ORModels
import WatchSupport

/// Owns what survives between runs: settings, the sample store, and the orphan check
/// (T-046, T-047, T-038).
///
/// `RunSessionModel` is created per run and discarded with it — a run's engine state must
/// not be able to leak into the next run, and the cleanest way to guarantee that is for
/// the object holding it to be short-lived. This coordinator is what persists.
@MainActor
@Observable
final class AppCoordinator {

    private(set) var settings: SettingsStore
    private(set) var start: StartScreenModel
    /// Non-nil exactly while a run is in progress.
    private(set) var run: RunSessionModel?
    private(set) var orphan: SampleStore.OrphanedRun?
    /// Set when a run is refused before it starts, so the UI can say why (DEG-6).
    private(set) var startFailure: RunStartRefusal?

    let configuration: PaceEngineConfiguration
    private let store: SampleStore

    init(
        configuration: PaceEngineConfiguration = .default,
        backing: KeyValueStoring = UserDefaultsKeyValueStore(),
        directory: URL? = nil
    ) {
        self.configuration = configuration

        let settings = SettingsStore(backing: backing)
        self.settings = settings
        self.start = StartScreenModel(profile: settings.profile, configuration: configuration)

        let directory = directory ?? Self.defaultDirectory()
        self.store = SampleStore(directory: directory)

        // Checked once, at launch, before any run can start — FR-D-6. Deferring it until
        // the runner tries to start would mean discovering the orphan at the worst
        // possible moment, standing at the trailhead.
        self.orphan = store.detectOrphan()
    }

    // MARK: - Run lifecycle

    func startRun(_ runType: RunType) async {
        startFailure = nil

        let model = RunSessionModel(
            plan: start.plan(for: runType),
            // Today's adjustment, if any — the stored profile is untouched (FR-A-7).
            profile: start.runProfile(for: runType),
            configuration: configuration,
            feed: LiveSensorFeed(configuration: configuration),
            store: store,
            session: WorkoutSessionController(backend: HealthKitWorkoutBackend()),
            haptics: WatchHapticPlayer()
        )

        do {
            try await model.start(activity: .outdoorRun)
            run = model
        } catch let refusal as RunStartRefusal {
            startFailure = refusal
        } catch {
            // A HealthKit session that will not start is not a reason to refuse the run:
            // AC-FR-D-1-7 records locally instead. The controller has already moved to a
            // local-only mode by this point, so the run is kept.
            run = model
        }
    }

    func endRun() async {
        guard let run else { return }
        _ = try? await run.end()
        self.run = nil
        // The adjustment was for today's run, which is now over.
        start.resetAdjustment(for: run.plan.runType)
        orphan = store.detectOrphan()
    }

    // MARK: - Orphan recovery

    func recoverOrphan() {
        guard let orphan else { return }
        // Wave 3 owns turning recovered samples into a synced `RunEnvelope` (T-048). Until
        // that exists, "save" can only mean "keep the file", so the orphan is left on disk
        // and cleared from the prompt rather than being silently dropped. Deleting it here
        // to make the UI tidy would destroy the very data the requirement is about.
        _ = store.loadOrphan(runID: orphan.runID)
        self.orphan = nil
    }

    func discardOrphan() {
        guard let orphan else { return }
        store.discardOrphan(runID: orphan.runID)
        self.orphan = nil
    }

    // MARK: - Settings

    /// Keeps the start screen's copy of the profile in step with settings edits.
    func settingsDidChange() {
        start.update(profile: settings.profile)
        run?.apply(profile: settings.profile)
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Runs", isDirectory: true)
    }
}

/// `UserDefaults` behind the two-call settings protocol.
final class UserDefaultsKeyValueStore: KeyValueStoring {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

    func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
