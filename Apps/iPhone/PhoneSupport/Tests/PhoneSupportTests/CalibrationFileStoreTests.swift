import Foundation
import ORModels
import XCTest

@testable import PhoneSupport

/// Keeping a calibration between runs (S-052, AC-FR-S-C-2-2, AC-FR-S-C-2-8).
///
/// The store's entire contract is that it moves bytes and asks no questions about them —
/// which is what lets `CalibrationStoring` be declared in `ORModels` over `Data` while the
/// encoded shape stays the estimator's business (and changes when S-064 lands). So these
/// tests use bytes that are deliberately *not* a calibration: if any of them started
/// depending on the payload's structure, the store would have grown an opinion it must not
/// have.
final class CalibrationFileStoreTests: XCTestCase {

    private var directory: URL!
    private var store: CalibrationFileStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        store = CalibrationFileStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAPayloadRoundTripsByteForByte() {
        let payload = Data((0..<512).map { UInt8($0 % 256) })
        store.saveCalibration(payload, for: .handHeld)
        XCTAssertEqual(store.loadCalibration(for: .handHeld), payload)
    }

    func testNothingIsStoredBeforeAnythingIsSaved() {
        XCTAssertNil(store.loadCalibration(for: .handHeld))
        XCTAssertFalse(store.hasCalibration(for: .handHeld))
    }

    func testSavingNilResetsRatherThanWritingEmptyBytes() {
        // AC-FR-S-C-2-8's reset. The distinction matters: `CalibrationBridge` reads
        // unreadable bytes as "no calibration", so an empty file would *work* — by
        // accident. A later change to that decoder would then quietly resurrect a
        // calibration the runner had reset.
        store.saveCalibration(Data("something".utf8), for: .handHeld)
        XCTAssertTrue(store.hasCalibration(for: .handHeld))

        store.saveCalibration(nil, for: .handHeld)

        XCTAssertNil(store.loadCalibration(for: .handHeld))
        XCTAssertFalse(
            store.hasCalibration(for: .handHeld),
            "a reset must remove the file, not leave an empty one")
    }

    func testResettingWhenNothingIsStoredIsHarmless() {
        store.saveCalibration(nil, for: .handHeld)
        XCTAssertNil(store.loadCalibration(for: .handHeld))
    }

    func testEachCarryPositionKeepsItsOwnCalibration() throws {
        // ADR-S-04: a calibration learned hand-held says nothing about a pocketed phone —
        // the two are different mechanical systems, not different settings. With one case
        // in the enum today this is a structural guarantee rather than an observable
        // behaviour, so it is asserted on the filename, which is the thing that would have
        // to change to break it.
        store.saveCalibration(Data("hand".utf8), for: .handHeld)

        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(
            files.first?.lastPathComponent, "handHeld.calibration",
            "the carry position must be in the filename, or a second position would "
                + "silently inherit the first's calibration")
    }

    func testAStoreSurvivesBeingRecreatedOverTheSameDirectory() {
        // The real usage: a fresh `CalibrationFileStore` is built on every launch, and the
        // runner's second run must start calibrated.
        store.saveCalibration(Data("learned".utf8), for: .handHeld)

        let nextLaunch = CalibrationFileStore(directory: directory)
        XCTAssertEqual(nextLaunch.loadCalibration(for: .handHeld), Data("learned".utf8))
    }

    func testASavedPayloadOverwritesThePreviousOneCompletely() {
        // A shorter payload replacing a longer one must not leave the tail of the old one
        // behind — the failure mode of a non-atomic write into an existing file.
        store.saveCalibration(Data(repeating: 0xAB, count: 4096), for: .handHeld)
        store.saveCalibration(Data("short".utf8), for: .handHeld)
        XCTAssertEqual(store.loadCalibration(for: .handHeld), Data("short".utf8))
    }
}
