import Foundation
import ORModels
import PhoneSupport
import SwiftData
import XCTest

@testable import OptimalRunner

/// Background execution and permissions (S-035, FR-S-A-2, NFR-S-17).
///
/// Two very different things are checked here and they need different tools.
///
/// The **declarations** — background modes and usage descriptions — are static facts about
/// the built bundle, so they are read out of the running app's own `Info.plist` rather than
/// out of the source `project.yml`. That distinction matters: `project.yml` is the input to
/// `xcodegen`, and a project someone regenerated from a stale spec, or edited in Xcode and
/// forgot to regenerate, would pass a source-file check and ship without the keys.
///
/// The **laziness** — that a hub-only session asks for nothing — is a fact about behaviour,
/// and is checked by exercising the hub's paths and counting authorization requests.
///
/// What is *not* here: whether a run actually survives the screen locking. That needs a real
/// device and elapsed wall-clock time, and it is on the manual protocol (§12.2).
final class StandalonePermissionsTests: XCTestCase {

    private var info: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    // MARK: - Declarations (AC-FR-S-A-2-2, NFR-S-17)

    func testTheBundleDeclaresBothBackgroundModes() throws {
        let modes = try XCTUnwrap(
            info["UIBackgroundModes"] as? [String],
            "no UIBackgroundModes declared — a standalone run would stop the moment the "
                + "screen sleeps, with no error anywhere")

        // CON-S-4: there is no `workout-processing` mode on iOS and no live HKWorkoutSession
        // at this floor (CON-S-2), so background execution is earned by these two or not at
        // all.
        XCTAssertTrue(modes.contains("location"), "declared modes: \(modes)")
        XCTAssertTrue(modes.contains("audio"), "declared modes: \(modes)")
    }

    func testEveryUsageDescriptionIsPresentAndExplainsWhy() throws {
        // AC-FR-D-1-1's rule, applied to the standalone tier's four keys: a usage
        // description explains *why*, not just *that*. Checked mechanically as "long enough
        // to be a sentence and containing a reason", which is a weak proxy — but it does
        // catch the actual failure, which is a placeholder like "Needs location" shipping
        // because nobody read the plist.
        let required = [
            "NSLocationWhenInUseUsageDescription",
            "NSMotionUsageDescription",
            "NSHealthShareUsageDescription",
            // Added with S-033. Without it `requestAuthorization(toShare:)` traps rather
            // than returning denied, so this one is a crash, not a degradation.
            "NSHealthUpdateUsageDescription",
        ]

        for key in required {
            let value = try XCTUnwrap(info[key] as? String, "missing \(key)")
            XCTAssertGreaterThan(
                value.count, 40, "\(key) is too short to be explaining anything: \(value)")
        }
    }

    func testThePrivacyPromiseIsMadeInTheDescriptionsThemselves() throws {
        // NFR-S-17 requires the app to say, in its usage description, that location is used
        // to measure the run and never transmitted. It is the only place a user reads a
        // privacy claim before granting anything.
        let location = try XCTUnwrap(info["NSLocationWhenInUseUsageDescription"] as? String)
        XCTAssertTrue(
            location.lowercased().contains("never sent"),
            "the location description must state that the data does not leave the device: "
                + location)

        let motion = try XCTUnwrap(info["NSMotionUsageDescription"] as? String)
        XCTAssertTrue(
            motion.lowercased().contains("stays on your device"),
            "the motion description must make the same promise: \(motion)")
    }

    func testTheHealthWriteDescriptionStatesTheHeartRateExclusion() throws {
        // AC-FR-S-A-4-3 is a promise to the user as much as a rule for the code, and this
        // is the one place they see it before granting write access.
        let update = try XCTUnwrap(info["NSHealthUpdateUsageDescription"] as? String)
        XCTAssertTrue(
            update.lowercased().contains("heart rate"),
            "the write description must say no heart rate is written: \(update)")
    }

    // MARK: - Laziness (AC-FR-S-A-1-2)

    @MainActor
    func testAHubOnlySessionRequestsNoLocationOrMotionAuthorization() throws {
        // The requirement is about an *absence*, so something has to count. Every request
        // this app makes goes through `StandaloneAuthorization`, which is what makes the
        // count meaningful — a second call site would make this test pass while the
        // requirement failed.
        StandaloneAuthorization.resetRequestCountForTesting()

        // Everything a hub-only user does: open the app, read their history, look at the
        // statistics, change a setting. Driven through the real repositories rather than
        // the views, because a view test would need a host and this is a question about
        // what the *data* paths do.
        let container = try RunStoreContainer.inMemory()
        let context = ModelContext(container)
        let library = RunLibrary(context: context)

        _ = try library.runs.listItems()
        _ = try library.runs.count()
        _ = try library.aggregates.cache()
        _ = try library.rebuildAggregates()

        let profiles = ProfileRepository(context: context)
        try profiles.save(RunnerProfile(units: .kilometres))
        _ = try profiles.profile()

        XCTAssertEqual(
            StandaloneAuthorization.requestCount, 0,
            "a hub-only session must not ask for location or motion (AC-FR-S-A-1-2)")
    }

    @MainActor
    func testReadinessIsDerivedFromStatusAndNeedsNoPrompt() {
        // Reading the current readiness must not itself prompt — otherwise the start
        // screen could not show "reduced accuracy" without having already asked.
        StandaloneAuthorization.resetRequestCountForTesting()
        _ = StandaloneAuthorization().readiness
        XCTAssertEqual(StandaloneAuthorization.requestCount, 0)
    }

    @MainActor
    func testEveryReadinessStateExplainsItselfExceptTheGoodOne() {
        // AC-FR-S-A-1-4/5/6: each degraded state names its consequence, and the full state
        // says nothing — an app that congratulates a user for granting permissions is an
        // app that has confused itself with the point.
        XCTAssertNil(StandaloneAuthorization.explanation(for: .full))

        for readiness: StandaloneAuthorization.Readiness in [
            .motionOnly, .locationOnly, .refused,
        ] {
            let explanation = StandaloneAuthorization.explanation(for: readiness)
            XCTAssertNotNil(explanation, "\(readiness) must explain itself")
            XCTAssertGreaterThan(explanation?.count ?? 0, 40, "\(readiness)")
        }

        // And only the last one actually stops the run (AC-FR-S-A-1-4/5 permit it).
        XCTAssertTrue(StandaloneAuthorization.Readiness.motionOnly.permitsRun)
        XCTAssertTrue(StandaloneAuthorization.Readiness.locationOnly.permitsRun)
        XCTAssertFalse(StandaloneAuthorization.Readiness.refused.permitsRun)
    }
}
