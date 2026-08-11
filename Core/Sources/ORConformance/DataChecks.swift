import Foundation
import ORColor
import ORModels
import ORStats

/// Assertions for units, configuration, packing, timeline, envelope, colour and
/// statistics (T-007 … T-009, T-022 … T-029, T-055).
public enum DataChecks {

    public static func all() -> [CheckSuite] {
        [units(), configuration(), packing(), timeline(), envelope(),
         colorScience(), palettes(), personalBests(), aggregates(), downsample()]
    }

    // MARK: - T-007 units

    public static func units() -> CheckSuite {
        suite("Units", covers: ["AC-FR-A-1-4", "ADR-003", "NFR-24"]) { c in
            // The load-bearing convention. If percentages ever silently become
            // percentages of *speed*, nothing crashes — every runner is just
            // mis-classified by a few percent, in a direction that varies with pace.
            c.expectEqual("12.5% slower is exactly 1.125", PaceRatio(percentSlower: 12.5).value, 1.125)

            let eight = Pace(secondsPerMile: 480)
            let nine = Pace(secondsPerMile: 540)
            c.expectClose("540 s/mi is 12.5% slower than 480 s/mi",
                          nine.percentSlower(than: eight), 12.5, accuracy: 1e-9)
            c.expectClose("the ratio is 1.125", nine.ratio(to: eight).value, 1.125, accuracy: 1e-12)
            // The inverse is deliberately not -12.5%.
            c.expectClose("the inverse is not symmetric",
                          eight.percentSlower(than: nine), -11.111, accuracy: 1e-3)
            c.expectClose("scaling by the ratio lands on 9:00",
                          eight.scaled(by: PaceRatio(percentSlower: 12.5)).secondsPerMile,
                          540, accuracy: 1e-9)
            c.expectEqual("and formats as 9:00",
                          ORFormat.pace(eight.scaled(by: PaceRatio(percentSlower: 12.5)), in: .miles), "9:00")

            // Round trips.
            var roundTrips = true
            for minutes in stride(from: 4.0, through: 20.0, by: 0.25) {
                if abs(Pace(minutesPerMile: minutes).minutesPerMile - minutes) > 1e-9 { roundTrips = false }
                if abs(Pace(minutesPerKilometre: minutes).minutesPerKilometre - minutes) > 1e-9 { roundTrips = false }
            }
            c.expect("pace conversions round-trip within 1e-9", roundTrips)
            c.expectClose("a mile is 1.609344 km",
                          eight.secondsPerMile / eight.secondsPerKilometre, 1.609344, accuracy: 1e-9)

            // Degenerate construction is refused rather than producing infinity.
            c.expectNil("zero distance yields no pace", Pace(distanceMetres: 0, seconds: 10))
            c.expectNil("zero time yields no pace", Pace(distanceMetres: 100, seconds: 0))
            c.expectNil("NaN distance yields no pace", Pace(distanceMetres: .nan, seconds: 10))
            c.expect("zero pace is invalid", !Pace(secondsPerMetre: 0).isValid)
            c.expect("NaN pace is invalid", !Pace(secondsPerMetre: .nan).isValid)

            // Ordering follows pace, so smaller is faster.
            c.expect("comparable orders by slowness",
                     Pace(minutesPerMile: 6) < Pace(minutesPerMile: 10))
            c.expect("isFaster agrees",
                     Pace(minutesPerMile: 6).isFaster(than: Pace(minutesPerMile: 10)))

            // Signed deltas.
            c.expectClose("slower yields a positive delta",
                          Pace(secondsPerMile: 495).signedDelta(from: eight, in: .miles), 15, accuracy: 1e-9)
            c.expect("faster yields a negative delta",
                     Pace(secondsPerMile: 470).signedDelta(from: eight, in: .miles) < 0)

            // Formatting.
            c.expectEqual("duration under a minute", ORFormat.duration(59), "0:59")
            c.expectEqual("duration over an hour", ORFormat.duration(3725), "1:02:05")
            c.expectEqual("negative duration", ORFormat.duration(-90), "-1:30")
            c.expectEqual("non-finite duration", ORFormat.duration(.nan), "--")
            c.expectEqual("metric pace", ORFormat.pace(Pace(minutesPerMile: 8), in: .kilometres), "4:58")
            c.expectEqual("nil pace", ORFormat.pace(nil, in: .miles), "--")
            c.expectEqual("positive delta carries its sign", ORFormat.signedSeconds(12), "+12")
            c.expectEqual("negative delta carries its sign", ORFormat.signedSeconds(-8), "-8")
            c.expectEqual("distance in miles", ORFormat.distance(1609.344, in: .miles), "1.00")
            c.expectEqual("distance in kilometres", ORFormat.distance(5000, in: .kilometres, fractionDigits: 1), "5.0")
            c.expectEqual("mile symbol", ORFormat.paceSymbol(.miles), "/mi")
            c.expectEqual("kilometre symbol", ORFormat.paceSymbol(.kilometres), "/km")

            // Ratio arithmetic.
            c.expectClose("ratios compose",
                          PaceRatio(percentSlower: 10).multiplied(by: PaceRatio(percentSlower: 10)).value,
                          1.21, accuracy: 1e-12)
            c.expectClose("ratios clamp", PaceRatio(value: 2).clamped(to: 0.9...1.3).value, 1.3, accuracy: 1e-12)
            c.expect("identity is neither faster nor slower",
                     !PaceRatio.identity.isSlower && !PaceRatio.identity.isFaster)
        }
    }

    // MARK: - T-008 / T-009 configuration and domain

    public static func configuration() -> CheckSuite {
        suite("Configuration", covers: ["NFR-21", "AC-FR-A-2-8", "AC-FR-A-3-4", "AC-FR-I-1-1"]) { c in
            let config = PaceEngineConfiguration.default
            var valid = true
            do { try config.validate() } catch { valid = false }
            c.expect("the shipped defaults validate", valid)

            // Documented defaults are actually the defaults.
            c.expectClose("rolling window is 200 m", config.rollingPace.windowMetres, 200, accuracy: 1e-12)
            c.expectClose("window floor is 20 s", config.rollingPace.minWindowSeconds, 20, accuracy: 1e-12)
            c.expectClose("window ceiling is 60 s", config.rollingPace.maxWindowSeconds, 60, accuracy: 1e-12)
            c.expectClose("accuracy limit is 20 m", config.rollingPace.maxHorizontalAccuracyMetres, 20, accuracy: 1e-12)
            c.expectClose("hysteresis is 0.5%", config.zones.hysteresis, 0.005, accuracy: 1e-12)
            c.expectClose("dwell is 20 s", config.alerts.dwellSeconds, 20, accuracy: 1e-12)
            c.expectClose("cooldown is 60 s", config.alerts.cooldownSeconds, 60, accuracy: 1e-12)
            c.expectClose("settling distance is 400 m", config.settling.runDistanceMetres, 400, accuracy: 1e-12)
            c.expectClose("settling time is 90 s", config.settling.runSeconds, 90, accuracy: 1e-12)
            c.expectClose("step settling is 100 m", config.settling.stepDistanceMetres, 100, accuracy: 1e-12)
            c.expectClose("uphill attenuation is 0.90", config.grade.lambdaUp, 0.90, accuracy: 1e-12)
            c.expectClose("downhill attenuation is 0.50", config.grade.lambdaDown, 0.50, accuracy: 1e-12)
            c.expectClose("sample interval is 1 Hz", config.capture.sampleIntervalSeconds, 1, accuracy: 1e-12)
            c.expectClose("flush interval is 30 s", config.capture.flushIntervalSeconds, 30, accuracy: 1e-12)
            c.expectEqual("pending run cap is 50", config.sync.maxPendingRuns, 50)

            // Every run type resolves a band and a curve.
            for runType in RunType.allCases {
                c.expect("\(runType.rawValue) has a well-formed band", config.band(for: runType).isWellFormed)
                c.expect("\(runType.rawValue) has a well-formed curve", config.curve(for: runType).isWellFormed)
            }

            // Out-of-range values are rejected with a specific error.
            func rejects(_ name: String, _ mutate: (inout PaceEngineConfiguration) -> Void) {
                var broken = PaceEngineConfiguration.default
                mutate(&broken)
                do {
                    try broken.validate()
                    c.expect(name, false, "expected validation to reject")
                } catch {
                    c.expect(name, true)
                }
            }
            rejects("rejects a 10 m rolling window") { $0.rollingPace.windowMetres = 10 }
            rejects("rejects a 900 m rolling window") { $0.rollingPace.windowMetres = 900 }
            rejects("rejects an inverted window range") { $0.rollingPace.minWindowSeconds = 90 }
            rejects("rejects a smoothing factor above 1") { $0.rollingPace.smoothingAlpha = 5 }
            rejects("rejects an out-of-range hysteresis") { $0.zones.hysteresis = 5 }
            rejects("rejects an attenuation above 1") { $0.grade.lambdaUp = 2 }
            rejects("rejects a negative dwell") { $0.alerts.dwellSeconds = -1 }
            rejects("rejects an inverted repeat range") { $0.intervals.maxRepeatCount = 0 }
            rejects("rejects a malformed band") {
                $0.bands[.tempo] = PaceBand(fastNear: 0.5, fastFar: 0.1, slowNear: 0.2, slowFar: 0.1)
            }
            rejects("rejects a malformed curve") {
                $0.curves[.tempo] = TargetPaceCurve(openingOffset: 0, closingOffset: 0, rampStart: 2)
            }
            rejects("rejects a non-positive pending byte cap") { $0.sync.maxPendingBytes = 0 }

            // Restoring defaults is a single action.
            var edited = PaceEngineConfiguration.default
            edited.bands[.tempo] = PaceBand(fastNearPercent: 9, fastFarPercent: 12,
                                            slowNearPercent: 9, slowFarPercent: 12)
            edited.restoreDefaults(for: .tempo)
            c.expectEqual("restoring defaults resets the band", edited.band(for: .tempo), PaceBand.tempo)
            c.expectEqual("restoring defaults resets the curve", edited.curve(for: .tempo), TargetPaceCurve.tempo)

            // JSON round-trip, including the run-type-keyed dictionaries.
            do {
                let data = try JSONEncoder().encode(config)
                let decoded = try JSONDecoder().decode(PaceEngineConfiguration.self, from: data)
                c.expectEqual("configuration round-trips through JSON", decoded, config)
            } catch {
                c.expect("configuration round-trips through JSON", false, "\(error)")
            }

            // Domain model coverage.
            c.expectEqual("six zones exist", PaceZone.allCases.count, 6)
            c.expect("far-off zones are the two extremes",
                     PaceZone.allCases.filter(\.isFarOff) == [.tooFast, .tooSlow])
            c.expect("fast-side flags", PaceZone.tooFast.isFastSide && PaceZone.slightlyFast.isFastSide)
            c.expect("slow-side flags", PaceZone.tooSlow.isSlowSide && PaceZone.slightlySlow.isSlowSide)
            c.expect("neutral is neither side", !PaceZone.neutral.isFastSide && !PaceZone.neutral.isSlowSide)

            // Raw values are persisted, so they must not move.
            c.expectEqual("tooFast raw value is stable", PaceZone.tooFast.rawValue, 0)
            c.expectEqual("neutral raw value is stable", PaceZone.neutral.rawValue, 5)

            // Profile lookups.
            let profile = RunnerProfile(tempoPace: Pace(minutesPerMile: 7),
                                        easyPace: Pace(minutesPerMile: 9),
                                        longPace: Pace(minutesPerMile: 8.5))
            c.expectEqual("tempo pace resolves", profile.basePace(for: .tempo), Pace(minutesPerMile: 7))
            c.expectEqual("easy pace resolves", profile.basePace(for: .easy), Pace(minutesPerMile: 9))
            c.expectNil("interval has no run-level pace", profile.basePace(for: .interval))
            c.expectNil("vo2max has no run-level pace", profile.basePace(for: .vo2max))
            c.expectEqual("default units are miles", RunnerProfile().units, .miles)
            c.expectEqual("default palette is standard", RunnerProfile().palette, .standard)
            c.expect("pace haptics default on", RunnerProfile().paceHapticsEnabled)

            // Location acceptance.
            func fix(_ accuracy: Double) -> LocationSample {
                LocationSample(timestamp: 0, latitude: 0, longitude: 0, altitudeMetres: 0,
                               horizontalAccuracy: accuracy, verticalAccuracy: accuracy)
            }
            c.expect("a good fix is acceptable", fix(5).isAcceptable(maxHorizontalAccuracy: 20))
            c.expect("a poor fix is not", !fix(50).isAcceptable(maxHorizontalAccuracy: 20))
            c.expect("a negative accuracy is not", !fix(-1).isAcceptable(maxHorizontalAccuracy: 20))
        }
    }

    // MARK: - T-024 packing

    private static func sampleSeries(count: Int) -> [RunSample] {
        // Written as an explicit loop with annotated locals: the equivalent
        // `map` closure exceeds the type-checker's expression budget.
        var samples: [RunSample] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let timestamp = Double(index)
            let distance: Double = Double(index) * 3.4
            let pace: Pace? = index % 17 == 0
                ? nil : Pace(minutesPerMile: 8 + Double(index % 5) * 0.1)
            let heartRate: Double? = index % 23 == 0 ? nil : Double(150 + index % 20)
            let altitude: Double = Double(index % 40) - 20
            let grade: Double = Double(index % 20) / 200 - 0.05
            let factor = PaceRatio(value: 0.95 + Double(index % 30) / 100)
            let target: Pace? = index % 31 == 0 ? nil : Pace(minutesPerMile: 8.2)
            let zone: PaceZone = PaceZone(rawValue: index % 6) ?? .neutral

            samples.append(RunSample(
                timestamp: timestamp,
                cumulativeDistance: distance,
                rollingPace: pace,
                heartRate: heartRate,
                relativeAltitude: altitude,
                smoothedGrade: grade,
                gradeFactor: factor,
                rawTarget: Pace(minutesPerMile: 8),
                effectiveTarget: target,
                zone: zone
            ))
        }
        return samples
    }

    public static func packing() -> CheckSuite {
        suite("PackedSamples", covers: ["AC-FR-D-2-1", "AC-FR-D-2-4", "ADR-007"]) { c in
            let samples = sampleSeries(count: 5400)
            let packed = PackedSamples(samples: samples)

            c.expectEqual("count is preserved", packed.count, 5400)
            c.expect("a 90-minute run packs under 1 MB",
                     packed.byteCount < 1_048_576, "\(packed.byteCount) bytes")

            guard let unpacked = packed.unpack() else {
                c.expect("unpacks", false, "unpack returned nil")
                return
            }
            c.expectEqual("unpacks to the same length", unpacked.count, samples.count)

            var distanceOK = true, paceOK = true, hrOK = true, zoneOK = true
            var gradeOK = true, factorOK = true, targetOK = true
            for (original, restored) in zip(samples, unpacked) {
                if abs(original.cumulativeDistance - restored.cumulativeDistance) > 0.01 { distanceOK = false }
                if (original.rollingPace == nil) != (restored.rollingPace == nil) { paceOK = false }
                if let a = original.rollingPace, let b = restored.rollingPace,
                   abs(a.secondsPerMetre - b.secondsPerMetre) > 1e-6 { paceOK = false }
                if (original.heartRate == nil) != (restored.heartRate == nil) { hrOK = false }
                if let a = original.heartRate, let b = restored.heartRate, abs(a - b) > 0.5 { hrOK = false }
                if original.zone != restored.zone { zoneOK = false }
                if abs(original.smoothedGrade - restored.smoothedGrade) > PackedSamples.gradeResolution { gradeOK = false }
                if abs(original.gradeFactor.value - restored.gradeFactor.value) > PackedSamples.gradeFactorResolution { factorOK = false }
                if (original.effectiveTarget == nil) != (restored.effectiveTarget == nil) { targetOK = false }
            }
            c.expect("distance round-trips", distanceOK)
            c.expect("rolling pace round-trips, including undefined", paceOK)
            c.expect("heart rate round-trips, including missing", hrOK)
            c.expect("zone round-trips exactly", zoneOK)
            c.expect("grade round-trips within its stated resolution", gradeOK)
            c.expect("grade factor round-trips within its stated resolution", factorOK)
            c.expect("effective target round-trips, including absent", targetOK)

            // The raw target is recovered by dividing out the grade factor, so both
            // are available to post-run analysis without storing both columns.
            var rawOK = true
            for restored in unpacked {
                guard let effective = restored.effectiveTarget, let raw = restored.rawTarget else { continue }
                let expected = effective.secondsPerMetre / restored.gradeFactor.value
                if abs(raw.secondsPerMetre - expected) > 1e-9 { rawOK = false }
            }
            c.expect("raw target is recoverable from effective target and grade factor", rawOK)

            // An empty series is legal.
            let empty = PackedSamples(samples: [])
            c.expectEqual("an empty series packs", empty.count, 0)
            c.expectEqual("an empty series unpacks", empty.unpack()?.count, 0)

            // JSON round-trip.
            do {
                let data = try JSONEncoder().encode(packed)
                let decoded = try JSONDecoder().decode(PackedSamples.self, from: data)
                c.expectEqual("packed samples round-trip through JSON", decoded, packed)
            } catch {
                c.expect("packed samples round-trip through JSON", false, "\(error)")
            }
        }
    }

    // MARK: - T-025 timeline

    public static func timeline() -> CheckSuite {
        suite("ZoneTimeline", covers: ["AC-FR-D-2-3", "AC-FR-F-2-4"]) { c in
            // A constant run compresses to one span.
            let constant = [PaceZone](repeating: .onTarget, count: 3600)
            let oneSpan = ZoneTimeline.encode(zones: constant)
            c.expectEqual("a constant run is one span", oneSpan.count, 1)
            c.expectClose("that span covers the whole run", oneSpan[0].durationSeconds, 3600, accuracy: 1e-9)

            // Round-trip.
            var mixed: [PaceZone] = []
            for index in 0..<1000 { mixed.append(PaceZone(rawValue: (index / 37) % 6) ?? .neutral) }
            let spans = ZoneTimeline.encode(zones: mixed)
            c.expectEqual("decode reproduces the input", ZoneTimeline.decode(spans), mixed)

            // Spans are contiguous and ordered.
            var contiguous = true
            for (previous, next) in zip(spans, spans.dropFirst()) {
                if abs(previous.endSeconds - next.startSeconds) > 1e-9 { contiguous = false }
            }
            c.expect("spans are contiguous", contiguous)

            // Totals sum to the run duration — the property that makes time-in-zone
            // add up to 100% rather than falling one sample short.
            let totals = ZoneTimeline.timeInZone(spans)
            c.expectClose("time in zone sums to the run duration",
                          totals.reduce(0, +), 1000, accuracy: 1e-9)
            let fractions = ZoneTimeline.fractionInZone(spans)
            c.expectClose("fractions sum to 1", fractions.reduce(0, +), 1, accuracy: 1e-9)
            c.expectEqual("one entry per zone", totals.count, PaceZone.allCases.count)

            // Degenerate input.
            c.expectEqual("an empty series yields no spans", ZoneTimeline.encode(zones: []).count, 0)
            c.expect("fractions of nothing are all zero",
                     ZoneTimeline.fractionInZone([]).allSatisfy { $0 == 0 })
            c.expectEqual("a single sample yields one span", ZoneTimeline.encode(zones: [.tooFast]).count, 1)
        }
    }

    // MARK: - T-026 envelope

    public static func envelope() -> CheckSuite {
        suite("RunEnvelope", covers: ["AC-FR-E-1-3", "AC-FR-E-1-4", "NFR-13", "ADR-009"]) { c in
            let samples = sampleSeries(count: 600)
            let zones = samples.map(\.zone)
            let envelope = RunEnvelope(
                runID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!,
                deviceTier: .modern,
                appVersion: "1.0.0",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_003_600),
                runType: .tempo,
                plan: nil,
                profileSnapshot: RunnerProfile(tempoPace: Pace(minutesPerMile: 8)),
                configSnapshot: .default,
                healthKitWorkoutUUID: nil,
                summary: RunSummary(distanceMetres: 8000, activeSeconds: 2400,
                                    averagePace: Pace(minutesPerMile: 8),
                                    averageHeartRate: 160, maxHeartRate: 178,
                                    elevationGainMetres: 42,
                                    timeInZoneSeconds: ZoneTimeline.timeInZone(ZoneTimeline.encode(zones: zones))),
                steps: [],
                zoneTimeline: ZoneTimeline.encode(zones: zones),
                samples: PackedSamples(samples: samples),
                route: [RoutePoint(timestamp: 0, latitude: 51.5, longitude: -0.12, altitudeMetres: 10)],
                degradations: [.gpsDegraded]
            )

            c.expectEqual("schema version defaults to current",
                          envelope.schemaVersion, RunEnvelope.currentSchemaVersion)

            do {
                let data = try RunEnvelopeCoder.encode(envelope)
                let decoded = try RunEnvelopeCoder.decode(data)
                c.expectEqual("envelope round-trips", decoded, envelope)
                c.expectEqual("the run ID survives, so ingest can deduplicate",
                              decoded.runID, envelope.runID)
                c.expectEqual("the profile snapshot survives",
                              decoded.profileSnapshot, envelope.profileSnapshot)
                c.expectEqual("the configuration snapshot survives",
                              decoded.configSnapshot, envelope.configSnapshot)

                // Deterministic encoding, so payload equality is testable.
                let again = try RunEnvelopeCoder.encode(envelope)
                c.expectEqual("encoding is deterministic", data, again)
            } catch {
                c.expect("envelope round-trips", false, "\(error)")
            }

            // A future schema is refused with a typed error, never a crash.
            let future = """
            {"schemaVersion": 99, "runID": "00000000-0000-0000-0000-0000000000AB"}
            """.data(using: .utf8)!
            do {
                _ = try RunEnvelopeCoder.decode(future)
                c.expect("a future schema is refused", false, "decode unexpectedly succeeded")
            } catch let error as EnvelopeError {
                if case .unsupportedSchema(let found, let supported) = error {
                    c.expectEqual("reports the version it found", found, 99)
                    c.expectEqual("reports the version it supports", supported, 1)
                } else {
                    c.expect("a future schema reports unsupportedSchema", false, "\(error)")
                }
            } catch {
                c.expect("a future schema reports a typed error", false, "\(error)")
            }

            // Garbage is refused as malformed.
            do {
                _ = try RunEnvelopeCoder.decode(Data("not json".utf8))
                c.expect("garbage is refused", false, "decode unexpectedly succeeded")
            } catch let error as EnvelopeError {
                if case .malformed = error { c.expect("garbage is refused as malformed", true) }
                else { c.expect("garbage is refused as malformed", false, "\(error)") }
            } catch {
                c.expect("garbage is refused as malformed", false, "\(error)")
            }
        }
    }

    // MARK: - T-022 colour science

    public static func colorScience() -> CheckSuite {
        suite("ColorScience", covers: ["AC-FR-J-1-3", "AC-FR-J-2-2"]) { c in
            // WCAG reference values.
            c.expectClose("black on white is 21:1",
                          SRGBColor.black.contrastRatio(against: .white), 21.0, accuracy: 0.01)
            c.expectClose("white on white is 1:1",
                          SRGBColor.white.contrastRatio(against: .white), 1.0, accuracy: 1e-9)
            c.expectClose("white luminance is 1", SRGBColor.white.relativeLuminance, 1.0, accuracy: 1e-9)
            c.expectClose("black luminance is 0", SRGBColor.black.relativeLuminance, 0.0, accuracy: 1e-9)
            // Mid grey #777777 sits near 4.48:1 against white — a documented WCAG
            // borderline case, and a good canary for the transfer function.
            if let grey = SRGBColor(hex: "#777777") {
                c.expectClose("#777777 on white is ~4.48:1",
                              grey.contrastRatio(against: .white), 4.48, accuracy: 0.05)
            }

            // Hex parsing.
            c.expectEqual("parses with a hash", SRGBColor(hex: "#FF8000"),
                          SRGBColor(red: 255, green: 128, blue: 0))
            c.expectEqual("parses without a hash", SRGBColor(hex: "FF8000"),
                          SRGBColor(red: 255, green: 128, blue: 0))
            c.expectNil("rejects a short string", SRGBColor(hex: "#FFF"))
            c.expectNil("rejects a non-hex string", SRGBColor(hex: "#GGGGGG"))
            c.expectEqual("round-trips to hex", SRGBColor(hex: "#1B7F4C")?.hexString, "#1B7F4C")

            // Linearisation round-trip.
            var linearOK = true
            for value in stride(from: 0.0, through: 1.0, by: 0.05) {
                let back = SRGBColor.toEncoded(SRGBColor.toLinear(value))
                if abs(back - value) > 1e-9 { linearOK = false }
            }
            c.expect("sRGB transfer function round-trips", linearOK)

            // CIELAB.
            c.expectClose("identical colours have zero deltaE",
                          ColorScience.deltaE(.white, .white), 0, accuracy: 1e-9)
            c.expectClose("white has L* of 100", ColorScience.lab(of: .white).l, 100, accuracy: 0.1)
            c.expectClose("black has L* of 0", ColorScience.lab(of: .black).l, 0, accuracy: 0.1)
            c.expect("black and white are maximally distant",
                     ColorScience.deltaE(.black, .white) > 99)

            // Matrix maths.
            let identity = Matrix3([[1, 0, 0], [0, 1, 0], [0, 0, 1]])
            c.expectClose("identity determinant is 1", identity.determinant, 1, accuracy: 1e-12)
            c.expectNotNil("the LMS matrix is invertible", ColorVisionSimulation.rgbToLMS.inverse)
            c.expectNil("a singular matrix has no inverse",
                        Matrix3([[1, 2, 3], [2, 4, 6], [1, 1, 1]]).inverse)
            if let inverse = ColorVisionSimulation.rgbToLMS.inverse {
                let product = ColorVisionSimulation.rgbToLMS.multiply(inverse)
                var isIdentity = true
                for row in 0..<3 {
                    for column in 0..<3 {
                        let expected = row == column ? 1.0 : 0.0
                        if abs(product.m[row][column] - expected) > 1e-9 { isIdentity = false }
                    }
                }
                c.expect("matrix times its inverse is identity", isIdentity)
            }

            // CVD simulation demonstrably shifts a pure red under deuteranopia, and
            // leaves achromatic colours essentially alone.
            let red = SRGBColor(red: 255, green: 0, blue: 0)
            let simulated = ColorVisionSimulation.simulate(red, as: .deuteranopia)
            c.expect("deuteranopia shifts pure red", ColorScience.deltaE(red, simulated) > 5)
            let grey = SRGBColor(red: 128, green: 128, blue: 128)
            c.expect("grey is barely shifted",
                     ColorScience.deltaE(grey, ColorVisionSimulation.simulate(grey, as: .deuteranopia)) < 12)
            c.expectEqual("three deficiencies are modelled", ColorVisionDeficiency.allCases.count, 3)
        }
    }

    // MARK: - T-023 palettes

    public static func palettes() -> CheckSuite {
        suite("ZonePalette", covers: ["FR-J-1", "FR-J-2", "AC-FR-J-1-3", "AC-FR-J-1-4",
                                      "AC-FR-J-2-1", "AC-FR-J-2-2", "AC-FR-A-6-7", "CON-4"]) { c in
            // Contrast: all 24 pairings, asserted individually so a failure names the
            // offender rather than just saying "a colour is wrong".
            for choice in PaletteChoice.allCases {
                let palette = ZonePalette.palette(for: choice)
                for zone in PaceZone.allCases {
                    for luminance in LuminanceState.allCases {
                        let swatch = palette.swatch(for: zone, luminance: luminance)
                        c.expect(
                            "\(choice.rawValue)/\(zone)/\(luminance.rawValue) meets 4.5:1",
                            swatch.contrastRatio >= 4.5,
                            "\(swatch.background.hexString) is \(String(format: "%.2f", swatch.contrastRatio)):1"
                        )
                    }
                }
            }

            // The CVD palette must keep every zone pair separable under all three
            // dichromacies. The standard palette deliberately does not — that is why
            // the alternative exists.
            let cvd = ZonePalette.colorVisionDeficiency
            for luminance in LuminanceState.allCases {
                let threshold = luminance == .normal ? 20.0 : 15.0
                let colors = PaceZone.allCases.map { ($0, cvd.swatch(for: $0, luminance: luminance).background) }
                for deficiency in ColorVisionDeficiency.allCases {
                    var worst = Double.infinity
                    var worstPair = ""
                    for i in colors.indices {
                        for j in colors.indices where j > i {
                            let a = ColorVisionSimulation.simulate(colors[i].1, as: deficiency)
                            let b = ColorVisionSimulation.simulate(colors[j].1, as: deficiency)
                            let delta = ColorScience.deltaE(a, b)
                            if delta < worst {
                                worst = delta
                                worstPair = "\(colors[i].0) vs \(colors[j].0)"
                            }
                        }
                    }
                    c.expect(
                        "CVD/\(luminance.rawValue) survives \(deficiency.rawValue) (ΔE ≥ \(Int(threshold)))",
                        worst >= threshold,
                        "worst ΔE \(String(format: "%.1f", worst)) between \(worstPair)"
                    )
                }
            }

            // Dimmed variants of both palettes stay mutually distinguishable.
            for choice in PaletteChoice.allCases {
                let palette = ZonePalette.palette(for: choice)
                let colors = PaceZone.allCases.map { palette.swatch(for: $0, luminance: .dimmed).background }
                var worst = Double.infinity
                for i in colors.indices {
                    for j in colors.indices where j > i {
                        worst = min(worst, ColorScience.deltaE(colors[i], colors[j]))
                    }
                }
                c.expect("\(choice.rawValue) dimmed variants stay distinguishable",
                         worst >= 15, "worst ΔE \(String(format: "%.1f", worst))")
            }

            // Dimmed really is dimmer — otherwise always-on would burn the same power.
            for choice in PaletteChoice.allCases {
                let palette = ZonePalette.palette(for: choice)
                for zone in PaceZone.allCases {
                    let normal = palette.swatch(for: zone, luminance: .normal).background.relativeLuminance
                    let dimmed = palette.swatch(for: zone, luminance: .dimmed).background.relativeLuminance
                    c.expect("\(choice.rawValue)/\(zone) dims", dimmed < normal)
                }
            }

            // The work/recovery chip (T-104), on every background it can land on.
            //
            // Two different bars, deliberately: the fill is a non-text element and WCAG
            // 1.4.11 holds it to 3:1, while the letter drawn on it is text and takes the
            // usual 4.5:1. Splitting them is the whole reason the marker is a chip —
            // coloured letters directly on the zone fill cannot be done at all, because
            // `slightlySlow` at #238180 tops out at 4.64:1 against pure white.
            for choice in PaletteChoice.allCases {
                let palette = ZonePalette.palette(for: choice)
                for zone in PaceZone.allCases {
                    for luminance in LuminanceState.allCases {
                        let background = palette.swatch(for: zone, luminance: luminance).background
                        let label = "\(choice.rawValue)/\(zone)/\(luminance.rawValue)"

                        for kind in StepAccentKind.allCases {
                            let accent = StepAccent.accent(for: kind, on: background)
                            c.expect(
                                "\(kind.rawValue) chip reads on \(label) (3:1)",
                                accent.fillContrastRatio(against: background) >= 3.0,
                                "\(accent.fill.hexString) is "
                                    + String(format: "%.2f", accent.fillContrastRatio(against: background))
                                    + ":1 on \(background.hexString)")
                            c.expect(
                                "\(kind.rawValue) letter reads on its chip (4.5:1) at \(label)",
                                accent.letterContrastRatio >= 4.5,
                                String(format: "%.2f", accent.letterContrastRatio) + ":1")
                        }

                        // And the two are unmistakably different colours wherever they
                        // land — the point of the change.
                        let work = StepAccent.accent(for: .work, on: background).fill
                        let recovery = StepAccent.accent(for: .recovery, on: background).fill
                        c.expect(
                            "work and recovery chips differ at \(label) (ΔE ≥ 25)",
                            ColorScience.deltaE(work, recovery) >= 25,
                            "ΔE " + String(format: "%.1f", ColorScience.deltaE(work, recovery)))
                    }
                }
            }

            // Amber against cyan is the warm/cool axis, which is what survives red-green
            // dichromacy — the same reasoning that shapes the CVD palette. It is NOT
            // claimed to survive tritanopia, where blue-yellow is precisely the axis that
            // collapses. That is accepted rather than designed around, because the letter
            // W or R is the redundant channel FR-J-1 actually requires and it is unaffected
            // by any dichromacy. The colour is the fast channel; the letterform is the
            // reliable one.
            for deficiency in [ColorVisionDeficiency.protanopia, .deuteranopia] {
                let background = ZonePalette.standard.swatch(for: .neutral).background
                let work = ColorVisionSimulation.simulate(
                    StepAccent.accent(for: .work, on: background).fill, as: deficiency)
                let recovery = ColorVisionSimulation.simulate(
                    StepAccent.accent(for: .recovery, on: background).fill, as: deficiency)
                c.expect(
                    "work and recovery chips survive \(deficiency.rawValue)",
                    ColorScience.deltaE(work, recovery) >= 20,
                    "ΔE " + String(format: "%.1f", ColorScience.deltaE(work, recovery)))
            }

            // The brand red is documented as failing, which is why it is not used.
            if let brand = SRGBColor(hex: "#E63946") {
                c.expect("the brand red would fail the contrast bar",
                         brand.contrastRatio(against: .white) < 4.5)
            }
            c.expectEqual("tooFast uses the darker red",
                          ZonePalette.standard.swatch(for: .tooFast).background.hexString, "#C1121F")

            // Text colour is a property of (zone, luminance state), not of zone alone.
            c.expectEqual("amber takes black text at full brightness",
                          ZonePalette.standard.swatch(for: .slightlyFast, luminance: .normal).text, .black)
            c.expectEqual("and white text when dimmed",
                          ZonePalette.standard.swatch(for: .slightlyFast, luminance: .dimmed).text, .white)

            // Redundant encoding exists for every zone, in every palette.
            for zone in PaceZone.allCases {
                let affordance = ZoneAffordance.affordance(for: zone)
                c.expect("\(zone) has a glyph", !affordance.symbolName.isEmpty)
                c.expect("\(zone) has a caption key", affordance.captionKey.hasPrefix("zone."))
            }
            c.expect("far-off zones show a signed delta",
                     PaceZone.allCases.filter(\.isFarOff).allSatisfy { ZoneAffordance.affordance(for: $0).showsDelta })
            c.expect("on-target shows no delta", !ZoneAffordance.affordance(for: .onTarget).showsDelta)

            // Every glyph is distinct, or the redundant channel is not redundant.
            let glyphs = Set(PaceZone.allCases.map { ZoneAffordance.affordance(for: $0).symbolName })
            c.expectEqual("every zone has a distinct glyph", glyphs.count, PaceZone.allCases.count)
        }
    }

    // MARK: - T-028 personal bests

    public static func personalBests() -> CheckSuite {
        suite("PersonalBests", covers: ["AC-FR-F-3-4"]) { c in
            // A 10 km run containing a deliberately fast 5 km in the middle.
            var distances: [Double] = []
            var times: [TimeInterval] = []
            var distance = 0.0
            for second in 0..<3000 {
                // 4 m/s normally; 5 m/s between 1000 s and 2000 s.
                distance += (second >= 1000 && second < 2000) ? 5.0 : 4.0
                distances.append(distance)
                times.append(Double(second))
            }

            let best5k = PersonalBestSweep.bestEffort(distance: .fiveKilometres,
                                                      cumulativeDistance: distances, timestamps: times)
            c.expectNotNil("finds a 5 km effort inside a longer run", best5k)
            if let best = best5k {
                // The fastest 5 km must sit inside the fast segment, so it beats the
                // 1250 s a uniform 4 m/s would take.
                c.expect("the best 5 km uses the fast segment",
                         best.seconds < 1150, "took \(Int(best.seconds)) s")
                c.expectNotNil("the effort exposes a pace", best.pace)
            }

            // Benchmarks longer than the run report nothing.
            c.expectNil("a marathon is not found in a 12 km run",
                        PersonalBestSweep.bestEffort(distance: .marathon,
                                                     cumulativeDistance: distances, timestamps: times))

            // Degenerate inputs are refused rather than trapping.
            c.expectNil("mismatched array lengths yield nothing",
                        PersonalBestSweep.bestEffort(distance: .oneKilometre,
                                                     cumulativeDistance: [0, 1], timestamps: [0]))
            c.expectNil("an empty run yields nothing",
                        PersonalBestSweep.bestEffort(distance: .oneKilometre,
                                                     cumulativeDistance: [], timestamps: []))

            // A uniform run's best kilometre matches its overall pace.
            var uniform: [Double] = []
            var uniformTimes: [TimeInterval] = []
            for second in 0..<1000 {
                uniform.append(Double(second) * 4.0)
                uniformTimes.append(Double(second))
            }
            if let km = PersonalBestSweep.bestEffort(distance: .oneKilometre,
                                                     cumulativeDistance: uniform, timestamps: uniformTimes) {
                c.expectClose("a uniform run's best km is 250 s", km.seconds, 250, accuracy: 2)
            } else {
                c.expect("finds a kilometre in a 4 km run", false)
            }

            // The sweep finds every benchmark the run is long enough for.
            let all = PersonalBestSweep.allBestEfforts(cumulativeDistance: distances, timestamps: times)
            c.expect("finds 1 km, 1 mile, 5 km and 10 km",
                     all[.oneKilometre] != nil && all[.oneMile] != nil
                        && all[.fiveKilometres] != nil && all[.tenKilometres] != nil)
            c.expectNil("does not invent a half marathon", all[.halfMarathon])

            // Benchmark distances are correct.
            c.expectClose("marathon is 42195 m", BenchmarkDistance.marathon.metres, 42195, accuracy: 1e-9)
            c.expectClose("half marathon is 21097.5 m", BenchmarkDistance.halfMarathon.metres, 21097.5, accuracy: 1e-9)
            c.expectClose("a mile is 1609.344 m", BenchmarkDistance.oneMile.metres, 1609.344, accuracy: 1e-9)
        }
    }

    // MARK: - T-029 aggregates

    public static func aggregates() -> CheckSuite {
        suite("Aggregates", covers: ["FR-F-3", "AC-FR-F-3-1", "AC-FR-F-3-2", "AC-FR-F-3-5"]) { c in
            func summary(distance: Double, seconds: Double, gain: Double = 10) -> RunSummary {
                RunSummary(distanceMetres: distance, activeSeconds: seconds,
                           averagePace: Pace(distanceMetres: distance, seconds: seconds),
                           averageHeartRate: 155, maxHeartRate: 175,
                           elevationGainMetres: gain,
                           timeInZoneSeconds: [Double](repeating: 0, count: PaceZone.allCases.count))
            }

            let calendar = AggregateCache.isoCalendar
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let runs = (0..<1000).map { index -> (RunSummary, Date, [BenchmarkDistance: BestEffort]) in
                (summary(distance: 5000 + Double(index), seconds: 1500),
                 base.addingTimeInterval(Double(index) * 86_400),
                 [:])
            }

            var incremental = AggregateCache()
            for run in runs {
                incremental.apply(summary: run.0, startedAt: run.1, bestEfforts: run.2, calendar: calendar)
            }
            let rebuilt = AggregateCache.rebuild(
                from: runs.map { (summary: $0.0, startedAt: $0.1, bests: $0.2) }, calendar: calendar
            )

            // Incremental application must agree with a full recomputation, or the
            // statistics screen slowly drifts away from reality.
            c.expectEqual("incremental matches rebuild on run count",
                          incremental.lifetime.runCount, rebuilt.lifetime.runCount)
            c.expectClose("incremental matches rebuild on distance",
                          incremental.lifetime.distanceMetres, rebuilt.lifetime.distanceMetres, accuracy: 1e-6)
            c.expectClose("incremental matches rebuild on time",
                          incremental.lifetime.activeSeconds, rebuilt.lifetime.activeSeconds, accuracy: 1e-6)
            c.expectEqual("lifetime run count is 1000", incremental.lifetime.runCount, 1000)

            // Removal reverses a contribution.
            var removable = AggregateCache()
            removable.apply(summary: summary(distance: 5000, seconds: 1500), startedAt: base, calendar: calendar)
            removable.apply(summary: summary(distance: 8000, seconds: 2400), startedAt: base, calendar: calendar)
            removable.remove(summary: summary(distance: 8000, seconds: 2400), startedAt: base, calendar: calendar)
            c.expectEqual("removal decrements the count", removable.lifetime.runCount, 1)
            c.expectClose("removal subtracts the distance", removable.lifetime.distanceMetres, 5000, accuracy: 1e-9)

            // Totals never go negative even if a caller over-removes.
            removable.remove(summary: summary(distance: 99_999, seconds: 99_999), startedAt: base, calendar: calendar)
            c.expect("totals never go negative", removable.lifetime.distanceMetres >= 0)
            c.expect("counts never go negative", removable.lifetime.runCount >= 0)

            // Periodic buckets.
            let year = calendar.component(.year, from: base)
            c.expect("the year bucket is populated", incremental.totals(forYear: year).runCount > 0)
            c.expect("the month bucket is populated",
                     incremental.totals(for: base, granularity: .month, calendar: calendar).runCount > 0)
            c.expect("the week bucket is populated",
                     incremental.totals(for: base, granularity: .week, calendar: calendar).runCount > 0)

            // The weekly series has no gaps — a chart with missing weeks reads as a
            // bug even when the runner simply did not run.
            let series = incremental.weeklySeries(endingAt: base.addingTimeInterval(500 * 86_400),
                                                  weeks: 52, calendar: calendar)
            c.expectEqual("the weekly series has 52 entries", series.count, 52)

            // Average pace derives from the totals.
            c.expectNotNil("lifetime average pace is available", incremental.lifetime.averagePace)
            c.expectNil("an empty cache has no average pace", AggregateTotals.zero.averagePace)

            // Personal bests take the fastest.
            var bests = AggregateCache()
            let slow = BestEffort(distance: .fiveKilometres, seconds: 1300, startDistanceMetres: 0)
            let fast = BestEffort(distance: .fiveKilometres, seconds: 1200, startDistanceMetres: 0)
            bests.apply(summary: summary(distance: 5000, seconds: 1300), startedAt: base,
                        bestEfforts: [.fiveKilometres: slow], calendar: calendar)
            bests.apply(summary: summary(distance: 5000, seconds: 1200), startedAt: base,
                        bestEfforts: [.fiveKilometres: fast], calendar: calendar)
            c.expectClose("the faster effort wins", bests.bests[.fiveKilometres]?.seconds ?? 0, 1200, accuracy: 1e-9)
            bests.apply(summary: summary(distance: 5000, seconds: 1400), startedAt: base,
                        bestEfforts: [.fiveKilometres: slow], calendar: calendar)
            c.expectClose("a slower effort does not replace it",
                          bests.bests[.fiveKilometres]?.seconds ?? 0, 1200, accuracy: 1e-9)

            // Period keys order sensibly.
            c.expect("period keys are ordered", PeriodKey(year: 2024) < PeriodKey(year: 2025))
            c.expect("month keys are ordered within a year",
                     PeriodKey(year: 2025, month: 1) < PeriodKey(year: 2025, month: 2))
        }
    }

    // MARK: - T-055 downsampling

    public static func downsample() -> CheckSuite {
        suite("Downsample", covers: ["AC-FR-F-2-8", "NFR-4"]) { c in
            let count = 5400
            let x = (0..<count).map(Double.init)
            var y = (0..<count).map { sin(Double($0) / 100) }
            // A single sharp spike: naive decimation would drop it, and it is exactly
            // the kind of feature a runner opens the chart to see.
            y[2700] = 10

            let indices = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: 1000)
            c.expect("respects the threshold", indices.count <= 1000, "got \(indices.count)")
            c.expectEqual("keeps the first point", indices.first, 0)
            c.expectEqual("keeps the last point", indices.last, count - 1)
            c.expect("indices ascend", zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 })
            c.expect("preserves the spike", indices.contains(2700))

            // Short series pass through untouched.
            c.expectEqual("a short series is returned whole",
                          Downsample.largestTriangleThreeBuckets(x: [0, 1, 2], y: [0, 1, 2], threshold: 1000).count, 3)
            c.expectEqual("an empty series yields nothing",
                          Downsample.largestTriangleThreeBuckets(x: [], y: [], threshold: 100).count, 0)
            c.expectEqual("a single point survives",
                          Downsample.largestTriangleThreeBuckets(x: [0], y: [0], threshold: 100).count, 1)
            c.expectEqual("a threshold below 3 returns the endpoints",
                          Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: 2).count, 2)

            // NaN gaps must not crash or be selected as peaks.
            var gapped = y
            for index in 1000..<1100 { gapped[index] = .nan }
            let withGaps = Downsample.largestTriangleThreeBuckets(x: x, y: gapped, threshold: 500)
            c.expect("handles NaN gaps", withGaps.count <= 500 && withGaps.first == 0)

            // The convenience wrapper agrees with the index form.
            let pairs = Downsample.reduce(x: x, y: y, threshold: 100)
            c.expect("the pair form matches the index form", pairs.count <= 100)
            c.expectClose("the first pair is the first point", pairs.first?.x ?? -1, 0, accuracy: 1e-12)
        }
    }
}
