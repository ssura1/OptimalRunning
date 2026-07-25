import Foundation
import ORModels
import ORPace

/// Assertions for the pace pipeline: rolling pace, curve, progress, grade, zones,
/// settling (T-011 … T-017).
public enum EngineChecks {

    public static func all() -> [CheckSuite] {
        [rollingPace(), targetCurve(), progress(), gradeModel(), gradeEstimator(), zones(), settling()]
    }

    // MARK: - T-011 rolling pace

    /// Feeds a constant pace at 1 Hz and returns the final estimate.
    private static func steadyRun(
        secondsPerMetre: Double,
        seconds: Int,
        accuracy: @escaping (Int) -> Double = { _ in 5 },
        config: RollingPaceConfiguration = .init()
    ) -> (estimator: RollingPaceEstimator, result: RollingPaceResult) {
        var estimator = RollingPaceEstimator(config: config)
        var distance = 0.0
        var result = RollingPaceResult(pace: nil, isGPSDegraded: false, isStationary: false)
        for second in 0..<seconds {
            distance += 1.0 / secondsPerMetre
            result = estimator.ingest(DistanceSample(
                timestamp: Double(second),
                cumulativeDistance: distance,
                isTrusted: accuracy(second) <= config.maxHorizontalAccuracyMetres
            ))
        }
        return (estimator, result)
    }

    public static func rollingPace() -> CheckSuite {
        suite("RollingPace", covers: ["FR-A-1", "AC-FR-A-1-1", "AC-FR-A-1-2", "AC-FR-A-1-3",
                                      "AC-FR-A-1-5", "AC-FR-A-1-6", "ADR-004"]) { c in
            let eight = Pace(minutesPerMile: 8).secondsPerMetre

            // Converges on a constant pace.
            let steady = steadyRun(secondsPerMetre: eight, seconds: 120)
            c.expectNotNil("converges on a steady run", steady.result.pace)
            if let pace = steady.result.pace {
                c.expectClose("within 1 s/mi of 8:00", pace.secondsPerMile, 480, accuracy: 1.0)
            }

            // Converges within 30 s.
            let quick = steadyRun(secondsPerMetre: eight, seconds: 30)
            if let pace = quick.result.pace {
                c.expectClose("converges within 30 s", pace.secondsPerMile, 480, accuracy: 5.0)
            } else {
                c.expect("converges within 30 s", false, "no pace after 30 s")
            }

            // Determinism: identical input sequences give identical output.
            let a = steadyRun(secondsPerMetre: eight, seconds: 200).result.pace
            let b = steadyRun(secondsPerMetre: eight, seconds: 200).result.pace
            c.expectEqual("deterministic across runs", a, b)

            // Poor fixes must not move the estimate. Run 120 s clean, snapshot, then
            // feed 60 s of 50 m-accuracy fixes carrying a wildly different pace.
            var estimator = RollingPaceEstimator(config: .init())
            var distance = 0.0
            var clean: Pace?
            for second in 0..<120 {
                distance += 1.0 / eight
                clean = estimator.ingest(DistanceSample(
                    timestamp: Double(second), cumulativeDistance: distance, isTrusted: true
                )).pace
            }
            // Stay inside the degradation timeout: after it, admitting untrusted
            // samples is the *required* pedometer fallback, tested separately below.
            var polluted: Pace?
            for second in 120..<128 {
                distance += 1.0 / (eight * 2)   // half pace — would be obvious if accepted
                polluted = estimator.ingest(DistanceSample(
                    timestamp: Double(second), cumulativeDistance: distance, isTrusted: false
                )).pace
            }
            c.expectEqual("untrusted fixes do not move pace before degradation", polluted, clean)

            // After the degradation timeout the fallback engages: untrusted samples are
            // admitted, because cumulative distance is still real (AC-FR-A-1-3).
            let dropout = steadyRun(secondsPerMetre: eight, seconds: 200,
                                    accuracy: { $0 >= 100 ? 80 : 5 })
            c.expect("reports GPS degraded after the timeout", dropout.result.isGPSDegraded)
            c.expectNotNil("still reports a pace while degraded", dropout.result.pace)

            // Stationary detection: a stop yields undefined, not a huge number.
            var stopper = RollingPaceEstimator(config: .init())
            var stopDistance = 0.0
            var stopResult = RollingPaceResult(pace: nil, isGPSDegraded: false, isStationary: false)
            for second in 0..<120 {
                stopDistance += 1.0 / eight
                stopResult = stopper.ingest(DistanceSample(
                    timestamp: Double(second), cumulativeDistance: stopDistance, isTrusted: true
                ))
            }
            var stationaryTicks = 0
            for second in 120..<160 {
                stopResult = stopper.ingest(DistanceSample(
                    timestamp: Double(second), cumulativeDistance: stopDistance, isTrusted: true
                ))
                if stopResult.isStationary { stationaryTicks += 1 }
                // Detection cannot precede evidence: a stop is only knowable once the
                // runner has been still for `stationarySeconds`. Allow that latency,
                // then require silence.
                if second >= 126, stopResult.pace != nil {
                    c.expect("reports undefined pace while stopped", false, "got a pace at t=\(second)")
                }
            }
            c.expect("detects a stop", stopResult.isStationary)
            c.expect("stationarity is reported continuously, not intermittently",
                     stationaryTicks >= 30, "only \(stationaryTicks)/40 ticks flagged")
            c.expectNil("reports undefined pace while stopped", stopResult.pace)

            // On resumption the window restarts, so the stop does not linger inside it
            // and produce a spurious "far too slow" for the next minute.
            var resumed: Pace?
            for second in 160..<200 {
                stopDistance += 1.0 / eight
                resumed = stopper.ingest(DistanceSample(
                    timestamp: Double(second), cumulativeDistance: stopDistance, isTrusted: true
                )).pace
            }
            if let resumed {
                c.expectClose("pace recovers correctly after a stop",
                              resumed.secondsPerMile, 480, accuracy: 15)
            } else {
                c.expect("pace recovers after a stop", false, "still undefined 40 s after resuming")
            }

            // Fewer than two samples cannot define a window.
            var fresh = RollingPaceEstimator(config: .init())
            let first = fresh.ingest(DistanceSample(timestamp: 0, cumulativeDistance: 0, isTrusted: true))
            c.expectNil("no pace from a single sample", first.pace)

            // Reset clears state.
            var resettable = steadyRun(secondsPerMetre: eight, seconds: 120).estimator
            resettable.reset()
            let afterReset = resettable.ingest(DistanceSample(
                timestamp: 0, cumulativeDistance: 0, isTrusted: true
            ))
            c.expectNil("reset clears the window", afterReset.pace)
        }
    }

    // MARK: - T-012 target curve

    public static func targetCurve() -> CheckSuite {
        suite("TargetPaceCurve", covers: ["FR-A-2", "AC-FR-A-2-1", "AC-FR-A-2-2",
                                          "AC-FR-A-2-3", "AC-FR-A-2-4", "ADR-005"]) { c in
            let base = Pace(minutesPerMile: 8)

            // Tempo: flat to halfway, +1.5% at the finish → 8:07.
            let tempo = TargetPaceCurve.tempo
            c.expectClose("tempo flat at start", tempo.targetPace(base: base, progress: 0).secondsPerMile, 480, accuracy: 0.01)
            c.expectClose("tempo flat at halfway", tempo.targetPace(base: base, progress: 0.5).secondsPerMile, 480, accuracy: 0.01)
            c.expectClose("tempo +1.5% at finish", tempo.targetPace(base: base, progress: 1).secondsPerMile, 487.2, accuracy: 0.5)

            // Easy: flat everywhere.
            let easy = TargetPaceCurve.easy
            for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
                c.expectClose("easy flat at \(progress)", easy.targetPace(base: base, progress: progress).secondsPerMile, 480, accuracy: 0.01)
            }

            // Long: flat to 0.6, +4% at the finish → 8:19.
            let long = TargetPaceCurve.long
            c.expectClose("long flat at 0.6", long.targetPace(base: base, progress: 0.6).secondsPerMile, 480, accuracy: 0.01)
            c.expectClose("long +4% at finish", long.targetPace(base: base, progress: 1).secondsPerMile, 499.2, accuracy: 0.5)

            // Drift is monotonic in progress for every preset.
            for (name, curve) in [("tempo", tempo), ("easy", easy), ("long", long)] {
                var previous = -Double.infinity
                var monotonic = true
                for step in 0...100 {
                    let value = curve.drift(at: Double(step) / 100)
                    if value < previous - 1e-12 { monotonic = false }
                    previous = value
                }
                c.expect("\(name) drift is monotonic in progress", monotonic)
            }

            // Progress outside [0,1] is clamped rather than extrapolated.
            c.expectEqual("progress clamps below 0", long.drift(at: -5), long.drift(at: 0))
            c.expectEqual("progress clamps above 1", long.drift(at: 5), long.drift(at: 1))

            // Presets resolve per run type.
            c.expectEqual("tempo preset resolves", TargetPaceCurve.standard(for: .tempo), .tempo)
            c.expectEqual("easy preset resolves", TargetPaceCurve.standard(for: .easy), .easy)
            c.expectEqual("long preset resolves", TargetPaceCurve.standard(for: .long), .long)
            c.expect("all presets are well formed",
                     [tempo, easy, long, TargetPaceCurve.flat].allSatisfy(\.isWellFormed))
        }
    }

    // MARK: - T-013 progress

    public static func progress() -> CheckSuite {
        suite("Progress", covers: ["AC-FR-A-2-5", "AC-FR-A-2-6", "AC-FR-A-2-7", "AC-FR-D-1-3"]) { c in
            c.expectClose("distance-based",
                          ProgressCalculator.progress(distanceCovered: 2500, activeElapsed: 600,
                                                      plannedDistanceMetres: 5000,
                                                      plannedDurationSeconds: nil),
                          0.5, accuracy: 1e-12)

            c.expectClose("time-based when no planned distance",
                          ProgressCalculator.progress(distanceCovered: 2500, activeElapsed: 900,
                                                      plannedDistanceMetres: nil,
                                                      plannedDurationSeconds: 1800),
                          0.5, accuracy: 1e-12)

            c.expectClose("distance wins over duration",
                          ProgressCalculator.progress(distanceCovered: 1000, activeElapsed: 1800,
                                                      plannedDistanceMetres: 5000,
                                                      plannedDurationSeconds: 1800),
                          0.2, accuracy: 1e-12)

            c.expectClose("zero when neither is planned",
                          ProgressCalculator.progress(distanceCovered: 5000, activeElapsed: 1800,
                                                      plannedDistanceMetres: nil,
                                                      plannedDurationSeconds: nil),
                          0, accuracy: 1e-12)

            c.expectClose("clamps above 1",
                          ProgressCalculator.progress(distanceCovered: 99_999, activeElapsed: 0,
                                                      plannedDistanceMetres: 5000,
                                                      plannedDurationSeconds: nil),
                          1, accuracy: 1e-12)

            c.expectClose("degenerate planned distance falls through to zero",
                          ProgressCalculator.progress(distanceCovered: 100, activeElapsed: 100,
                                                      plannedDistanceMetres: 0,
                                                      plannedDurationSeconds: nil),
                          0, accuracy: 1e-12)

            // Paused time is excluded from active elapsed.
            var clock = ActiveClock()
            for second in 0...100 { clock.advance(to: Double(second), paused: false) }
            let beforePause = clock.activeElapsed
            for second in 101...700 { clock.advance(to: Double(second), paused: true) }
            c.expectClose("pause freezes the clock", clock.activeElapsed, beforePause, accuracy: 1.001)
            for second in 701...800 { clock.advance(to: Double(second), paused: false) }
            c.expectClose("resume continues accruing", clock.activeElapsed, beforePause + 100, accuracy: 1.001)

            clock.reset()
            c.expectClose("reset zeroes the clock", clock.activeElapsed, 0, accuracy: 1e-12)
        }
    }

    // MARK: - T-015 grade model

    public static func gradeModel() -> CheckSuite {
        suite("GradeModel", covers: ["FR-A-4", "AC-FR-A-4-3", "AC-FR-A-4-4", "AC-FR-A-4-5",
                                     "AC-FR-A-4-9", "NFR-11", "CON-6", "ADR-006"]) { c in
            let model = GradeModel(config: GradeConfiguration())

            // The design.md §5.4 table, encoded verbatim.
            let table: [(grade: Double, factor: Double)] = [
                (-0.10, 0.900), (-0.06, 0.900), (-0.04, 0.902), (-0.03, 0.925),
                (-0.02, 0.949), (-0.01, 0.974), (0.00, 1.000), (0.01, 1.050),
                (0.02, 1.102), (0.03, 1.156), (0.04, 1.213), (0.06, 1.300), (0.10, 1.300),
            ]
            for row in table {
                c.expectClose("factor at \(Int(row.grade * 100))%",
                              model.factor(at: row.grade).value, row.factor, accuracy: 0.001)
            }

            // Level ground is exactly identity — anything else would mean a flat run
            // silently carried a grade adjustment.
            c.expectEqual("factor(0) is exactly 1.0", model.factor(at: 0).value, 1.0)
            c.expectClose("Minetti C(0) is 3.6", GradeModel.cost(at: 0), 3.6, accuracy: 1e-12)
            c.expectClose("raw ratio at 0 is 1", GradeModel.rawRatio(at: 0), 1.0, accuracy: 1e-12)

            // Monotonic non-decreasing across a wide range.
            var monotonic = true
            var previous = -Double.infinity
            for step in -500...500 {
                let value = model.factor(at: Double(step) / 1000).value
                if value < previous - 1e-12 { monotonic = false }
                previous = value
            }
            c.expect("monotonically non-decreasing in grade", monotonic)

            // Bounded for every real input, and identity for non-finite input.
            var bounded = true
            for step in -2000...2000 {
                let value = model.factor(at: Double(step) / 1000).value
                if value < 0.90 - 1e-12 || value > 1.30 + 1e-12 { bounded = false }
            }
            c.expect("clamped to [0.90, 1.30] for all real input", bounded)
            c.expectEqual("NaN grade yields identity", model.factor(at: .nan).value, 1.0)
            c.expectEqual("+infinity grade yields identity", model.factor(at: .infinity).value, 1.0)
            c.expectEqual("-infinity grade yields identity", model.factor(at: -.infinity).value, 1.0)

            // Direction: uphill prescribes a slower pace, downhill a faster one.
            let base = Pace(minutesPerMile: 8)
            c.expect("uphill slows the target", model.adjust(base, grade: 0.05).isSlower(than: base))
            c.expect("downhill quickens the target", model.adjust(base, grade: -0.05).isFaster(than: base))

            // Hill indicator threshold.
            c.expect("1% deviation is not significant", !model.isSignificant(PaceRatio(value: 1.005)))
            c.expect("3% deviation is significant", model.isSignificant(PaceRatio(value: 1.03)))

            // Calibration against published GAP behaviour in the band that matters.
            c.expectClose("matches published GAP at +2%", model.factor(at: 0.02).value, 1.10, accuracy: 0.05)
            c.expectClose("matches published GAP at -2%", model.factor(at: -0.02).value, 0.95, accuracy: 0.05)
        }
    }

    // MARK: - T-014 grade estimator

    public static func gradeEstimator() -> CheckSuite {
        suite("GradeEstimator", covers: ["AC-FR-A-4-1", "AC-FR-A-4-2", "AC-FR-A-4-6", "DEG-2"]) { c in
            let config = GradeConfiguration()

            // A sustained 4% climb converges.
            var estimator = GradeEstimator(config: config)
            var estimate = GradeEstimate.unavailable
            var distance = 0.0
            for second in 0..<400 {
                distance += 3.0
                estimate = estimator.ingest(
                    cumulativeDistance: distance,
                    relativeAltitude: distance * 0.04,
                    timestamp: Double(second)
                )
            }
            c.expect("altitude present means available", estimate.isAvailable)
            c.expectClose("converges on a 4% climb", estimate.smoothedGrade, 0.04, accuracy: 0.005)
            c.expectClose("applies the sustained grade", estimate.appliedGrade, 0.04, accuracy: 0.005)

            // A brief spike must not move the applied grade: the app responds to a
            // hill, not to a kerb.
            var spiky = GradeEstimator(config: config)
            var spikeDistance = 0.0
            var spikeEstimate = GradeEstimate.unavailable
            for second in 0..<300 {
                spikeDistance += 3.0
                // Flat ground, with a single 2 m step at one moment.
                let altitude = second == 250 ? 2.0 : 0.0
                spikeEstimate = spiky.ingest(
                    cumulativeDistance: spikeDistance,
                    relativeAltitude: altitude,
                    timestamp: Double(second)
                )
            }
            c.expectClose("a transient spike does not move the applied grade",
                          spikeEstimate.appliedGrade, 0, accuracy: 0.005)

            // No altitude at all means unavailable, not flat.
            var blind = GradeEstimator(config: config)
            var blindEstimate = GradeEstimate.unavailable
            var blindDistance = 0.0
            for second in 0..<200 {
                blindDistance += 3.0
                blindEstimate = blind.ingest(
                    cumulativeDistance: blindDistance,
                    relativeAltitude: nil,
                    timestamp: Double(second)
                )
            }
            c.expect("no altimeter reports unavailable, not zero grade", !blindEstimate.isAvailable)

            // Descent is reported with the correct sign.
            var descender = GradeEstimator(config: config)
            var descentEstimate = GradeEstimate.unavailable
            var descentDistance = 0.0
            for second in 0..<400 {
                descentDistance += 3.0
                descentEstimate = descender.ingest(
                    cumulativeDistance: descentDistance,
                    relativeAltitude: descentDistance * -0.06,
                    timestamp: Double(second)
                )
            }
            c.expectClose("converges on a 6% descent", descentEstimate.smoothedGrade, -0.06, accuracy: 0.006)

            // Reset clears state.
            descender.reset()
            let afterReset = descender.ingest(cumulativeDistance: 0, relativeAltitude: 0, timestamp: 0)
            c.expectClose("reset clears the applied grade", afterReset.appliedGrade, 0, accuracy: 1e-12)
        }
    }

    // MARK: - T-016 zones and hysteresis

    public static func zones() -> CheckSuite {
        suite("ZoneClassifier", covers: ["FR-A-3", "AC-FR-A-3-1", "AC-FR-A-3-4", "AC-FR-A-3-5",
                                         "AC-FR-A-3-6", "AC-FR-A-3-7"]) { c in
            let classifier = ZoneClassifier(config: ZoneConfiguration())
            let tempo = PaceBand.tempo

            // Raw classification across the five zones.
            c.expectEqual("far fast is tooFast", ZoneClassifier.rawZone(ratio: 0.90, band: tempo), .tooFast)
            c.expectEqual("near fast is slightlyFast", ZoneClassifier.rawZone(ratio: 0.97, band: tempo), .slightlyFast)
            c.expectEqual("on target", ZoneClassifier.rawZone(ratio: 1.00, band: tempo), .onTarget)
            c.expectEqual("near slow is slightlySlow", ZoneClassifier.rawZone(ratio: 1.03, band: tempo), .slightlySlow)
            c.expectEqual("far slow is tooSlow", ZoneClassifier.rawZone(ratio: 1.10, band: tempo), .tooSlow)
            c.expectEqual("non-finite ratio is neutral", ZoneClassifier.rawZone(ratio: .nan, band: tempo), .neutral)

            // Band edges match the documented defaults.
            c.expectClose("tempo fastNear", tempo.fastNear, 0.02, accuracy: 1e-12)
            c.expectClose("tempo slowFar", tempo.slowFar, 0.05, accuracy: 1e-12)
            c.expectClose("easy fast side is tight", PaceBand.easy.fastNear, 0.03, accuracy: 1e-12)
            c.expectClose("easy slow side is loose", PaceBand.easy.slowFar, 0.12, accuracy: 1e-12)
            c.expect("easy band is asymmetric", PaceBand.easy.slowFar > PaceBand.easy.fastFar)
            c.expect("tempo band is symmetric", PaceBand.tempo.slowFar == PaceBand.tempo.fastFar)
            c.expect("all default bands well formed",
                     RunType.allCases.allSatisfy { PaceBand.standard(for: $0).isWellFormed })

            // Every zone is reachable through the hysteresis path.
            var reached = Set<PaceZone>()
            var previous = PaceZone.neutral
            for ratio in stride(from: 0.80, through: 1.20, by: 0.001) {
                previous = classifier.classify(ratio: ratio, band: tempo, previous: previous)
                reached.insert(previous)
            }
            c.expectEqual("all five judged zones are reachable", reached.count, 5)

            // Hysteresis: oscillating within the margin of a boundary settles.
            let boundary = 1 + tempo.slowNear
            var zone = PaceZone.onTarget
            var changes = 0
            for tick in 0..<1000 {
                let ratio = boundary + 0.004 * sin(Double(tick) / 5)
                let next = classifier.classify(ratio: ratio, band: tempo, previous: zone)
                if next != zone { changes += 1 }
                zone = next
            }
            c.expect("oscillation inside the margin causes at most one change",
                     changes <= 1, "observed \(changes) zone changes")

            // A genuine excursion beyond the margin does change zone.
            let escaped = classifier.classify(ratio: boundary + 0.02, band: tempo, previous: .onTarget)
            c.expectEqual("a real excursion still changes zone", escaped, .slightlySlow)

            // Leaving neutral needs no hysteresis — it is imposed, not measured.
            c.expectEqual("neutral yields immediately",
                          classifier.classify(ratio: 1.0, band: tempo, previous: .neutral), .onTarget)

            // Zone monotonicity: increasing ratio never moves toward the fast end.
            var monotonic = true
            var last = PaceZone.tooFast
            for ratio in stride(from: 0.80, through: 1.30, by: 0.002) {
                let raw = ZoneClassifier.rawZone(ratio: ratio, band: tempo)
                if raw.rawValue < last.rawValue { monotonic = false }
                last = raw
            }
            c.expect("zone is monotonic in pace ratio", monotonic)

            // Band widening under degraded GPS keeps ordering intact.
            let wide = tempo.widened(by: 1.5)
            c.expectClose("widening scales thresholds", wide.slowFar, tempo.slowFar * 1.5, accuracy: 1e-12)
            c.expect("widened band stays well formed", wide.isWellFormed)
        }
    }

    // MARK: - T-017 settling

    public static func settling() -> CheckSuite {
        suite("SettlingWindow", covers: ["FR-A-5", "AC-FR-A-5-1", "AC-FR-A-5-2", "AC-FR-C-5-4"]) { c in
            let window = SettlingWindow(config: SettlingConfiguration())

            c.expect("settling at the start", window.isRunSettling(distanceCovered: 0, activeElapsed: 0))
            c.expect("still settling at 399 m and 80 s",
                     window.isRunSettling(distanceCovered: 399, activeElapsed: 80))
            c.expect("settled at 401 m", !window.isRunSettling(distanceCovered: 401, activeElapsed: 80))
            c.expect("settled at 91 s even if short of 400 m",
                     !window.isRunSettling(distanceCovered: 100, activeElapsed: 91))

            // Step-level window.
            c.expect("step settling under 100 m", window.isStepSettling(stepDistance: 99))
            c.expect("step settled at 101 m", !window.isStepSettling(stepDistance: 101))

            // Structured runs apply the step window after the run window has closed.
            c.expect("structured run settles at a new step",
                     window.isSettling(distanceCovered: 5000, activeElapsed: 1200,
                                       stepDistance: 50, isStructured: true))
            c.expect("structured run judges once the step has settled",
                     !window.isSettling(distanceCovered: 5000, activeElapsed: 1200,
                                        stepDistance: 150, isStructured: true))
            c.expect("continuous run ignores step distance",
                     !window.isSettling(distanceCovered: 5000, activeElapsed: 1200,
                                        stepDistance: 10, isStructured: false))
        }
    }
}
