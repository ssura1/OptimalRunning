import XCTest

import ORModels

@testable import PhoneMotion

final class TraceTests: XCTestCase {

    private func makeTrace(samples: [MotionSample], name: String = "unit") -> MotionTrace {
        MotionTrace(
            header: MotionTrace.Header(
                name: name,
                describes: "a synthetic trace used to exercise the format itself",
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
                deviceModel: "iPhone15,2",
                systemVersion: "17.5",
                appVersion: "1.0",
                nominalSampleRateHz: 100,
                carryPosition: .handHeld,
                runnerHeightMetres: 1.78,
                references: []),
            motion: MotionTrace.MotionColumns(samples: samples))
    }

    // MARK: - Round trip

    func testRoundTripsLosslessly() throws {
        let signal = SyntheticGaitSignal.make(stepsPerMinute: 176, duration: 5)
        let trace = makeTrace(samples: signal.samples)
        let decoded = try MotionTrace.decode(from: trace.encoded())
        XCTAssertEqual(decoded.motion.count, signal.samples.count)
        for (a, b) in zip(decoded.motion.samples(), signal.samples) {
            XCTAssertEqual(a.timestamp, b.timestamp, accuracy: 1e-9)
            XCTAssertEqual(a.userAcceleration.z, b.userAcceleration.z, accuracy: 1e-9)
            XCTAssertEqual(a.gravity.z, b.gravity.z, accuracy: 1e-9)
        }
    }

    func testHeaderSurvivesTheRoundTrip() throws {
        let trace = makeTrace(samples: [], name: "named")
        let decoded = try MotionTrace.decode(from: trace.encoded())
        XCTAssertEqual(decoded.header.name, "named")
        XCTAssertEqual(decoded.header.carryPosition, .handHeld)
        XCTAssertEqual(decoded.header.runnerHeightMetres ?? .nan, 1.78, accuracy: 1e-9)
    }

    /// A trace written by a newer build must be refused with a message, never crash —
    /// the same treatment `RunEnvelope` gives an unknown schema (AC-FR-E-1-4).
    func testANewerSchemaIsRefusedWithATypedError() throws {
        var json = try JSONSerialization.jsonObject(
            with: makeTrace(samples: []).encoded()) as? [String: Any] ?? [:]
        json["schemaVersion"] = MotionTrace.currentSchemaVersion + 1
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try MotionTrace.decode(from: data)) { error in
            guard case MotionTraceError.unsupportedSchema = error else {
                return XCTFail("expected a typed schema error, got \(error)")
            }
            XCTAssertTrue(String(describing: error).contains("newer than this build"))
        }
    }

    /// A capture killed mid-flush can leave one column an entry short. Losing 10 ms of a
    /// 60-minute trace is a far better outcome than losing the trace, so the decoder
    /// returns the shortest consistent prefix rather than trapping.
    func testRaggedColumnsDecodeToTheShortestConsistentPrefix() throws {
        let signal = SyntheticGaitSignal.make(stepsPerMinute: 176, duration: 2)
        var json = try JSONSerialization.jsonObject(
            with: makeTrace(samples: signal.samples).encoded()) as? [String: Any] ?? [:]
        var motion = json["motion"] as? [String: Any] ?? [:]
        var gravityZ = motion["gravityZ"] as? [Double] ?? []
        gravityZ.removeLast(3)
        motion["gravityZ"] = gravityZ
        json["motion"] = motion

        let decoded = try MotionTrace.decode(
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.motion.samples().count, signal.samples.count - 3)
    }

    // MARK: - References

    /// AC-FR-S-F-2-4 — a trace states what it can validate. A trace with no reference can
    /// exercise the pipeline but cannot back an accuracy claim (CON-S-7), and the format
    /// makes that visible rather than leaving it to be assumed.
    func testAReferenceCarriesItsOwnAccuracy() throws {
        var trace = makeTrace(samples: [])
        trace = MotionTrace(
            header: MotionTrace.Header(
                name: trace.header.name,
                describes: trace.header.describes,
                recordedAt: trace.header.recordedAt,
                deviceModel: trace.header.deviceModel,
                systemVersion: trace.header.systemVersion,
                appVersion: trace.header.appVersion,
                nominalSampleRateHz: trace.header.nominalSampleRateHz,
                carryPosition: trace.header.carryPosition,
                runnerHeightMetres: trace.header.runnerHeightMetres,
                references: [
                    MotionTrace.Reference(
                        kind: .surveyedDistance, value: 400, unit: "m",
                        referenceAccuracyFraction: 0.0025),
                    MotionTrace.Reference(
                        kind: .countedSteps, value: 96, unit: "steps",
                        fromMarkIndex: 2, toMarkIndex: 3,
                        referenceAccuracyFraction: 0),
                ]),
            motion: trace.motion)

        let decoded = try MotionTrace.decode(from: trace.encoded())
        XCTAssertEqual(decoded.header.references.count, 2)
        XCTAssertEqual(decoded.header.references[1].kind, .countedSteps)
        XCTAssertEqual(
            decoded.header.references[1].referenceAccuracyFraction, 0,
            "a counted-step reference is exact — that is why it is worth asking for")
    }

    // MARK: - Replay

    /// The replay path must run end to end on a trace with no fixes at all, which is the
    /// shape of a capture taken indoors or with location denied.
    func testReplayRunsOnATraceWithNoFixes() {
        let signal = SyntheticGaitSignal.make(stepsPerMinute: 176, duration: 30)
        let result = TraceReplay.run(trace: makeTrace(samples: signal.samples))
        XCTAssertEqual(result.trace, "unit")
        XCTAssertGreaterThan(result.stepCount, 0)
        // No GNSS ever means no scale was learned, and ADR-S-06 forbids inventing one.
        XCTAssertNil(result.calibrationScale)
        XCTAssertFalse(result.isConverged)
    }

    /// The GNSS-outage substitute of S-024: real motion data with the fixes truncated.
    /// Legitimate precisely because the motion underneath is real — it is the opposite of
    /// a synthetic signal.
    func testSuppressingFixesAfterATimeProducesAnEstimatedTail() {
        let signal = SyntheticGaitSignal.make(stepsPerMinute: 176, duration: 120)
        var trace = makeTrace(samples: signal.samples)
        var fixes: [MotionTrace.RecordedFix] = []
        var distance = 0.0
        for second in 0...120 {
            distance += 3
            fixes.append(MotionTrace.RecordedFix(
                timestamp: Double(second),
                latitude: 0, longitude: 0, altitudeMetres: 0,
                horizontalAccuracy: 5, verticalAccuracy: 5,
                speedMetresPerSecond: 3,
                cumulativeDistanceMetres: distance))
        }
        trace = MotionTrace(header: trace.header, motion: trace.motion, locations: fixes)

        let full = TraceReplay.run(trace: trace)
        let truncated = TraceReplay.run(trace: trace, suppressLocationAfter: 60)

        XCTAssertEqual(full.estimatedMetres, 0, accuracy: 1e-6, "GNSS throughout")
        XCTAssertGreaterThan(
            truncated.estimatedMetres, 0,
            "with fixes suppressed the motion leg must carry the tail")
        XCTAssertNotNil(truncated.calibrationScale, "the first 60 s should have calibrated it")
    }
}
