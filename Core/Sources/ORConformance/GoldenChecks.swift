import Foundation
import ORAlerts
import ORIntervals
import ORModels
import ORPace
import ORStats

/// Golden-replay and whole-engine assertions (T-031), plus the cross-cutting
/// invariants (T-032).
public enum GoldenChecks {

    public static func all(goldenDirectory: URL?) -> [CheckSuite] {
        [goldenReplay(goldenDirectory: goldenDirectory), engineBehaviour(), properties()]
    }

    // MARK: - T-031 golden replay

    /// Replays every fixture and compares against its committed golden.
    ///
    /// These are the highest-value tests in the project: they assert the *sequence* of
    /// zones and alerts a real run produces, which is the thing users actually
    /// experience and the thing a subtle regression silently changes.
    public static func goldenReplay(goldenDirectory: URL?) -> CheckSuite {
        suite("GoldenReplay", covers: ["AC-FR-A-1-6", "FR-A-3", "FR-B-1", "FR-C-2"]) { c in
            let decoder = FixtureCoder.makeDecoder()

            for fixture in FixtureGenerator.standardFixtures() {
                let result = FixtureReplay.run(fixture)

                // Determinism: replaying the same fixture must produce identical
                // output, or nothing downstream can be trusted.
                let again = FixtureReplay.run(fixture)
                c.expectEqual("\(fixture.name) replays deterministically", again.golden, result.golden)

                guard let goldenDirectory else { continue }
                let url = goldenDirectory.appendingPathComponent("\(fixture.name).golden.json")
                guard let data = try? Data(contentsOf: url),
                      let golden = try? decoder.decode(EngineGolden.self, from: data) else {
                    c.expect("\(fixture.name) has a committed golden", false,
                             "missing \(url.lastPathComponent) — run: swift run ORReplay verify --update-goldens")
                    continue
                }

                c.expectEqual("\(fixture.name) zone timeline matches golden",
                              result.golden.zoneTimeline, golden.zoneTimeline)
                c.expectEqual("\(fixture.name) alert sequence matches golden",
                              result.golden.alerts, golden.alerts)
                c.expectEqual("\(fixture.name) transitions match golden",
                              result.golden.transitions, golden.transitions)
                c.expectEqual("\(fixture.name) sample count matches golden",
                              result.golden.sampleCount, golden.sampleCount)
            }
        }
    }

    // MARK: - Whole-engine behaviour

    /// Assertions about what each fixture *means*, independent of the golden bytes.
    ///
    /// A golden proves "nothing changed". These prove "the thing it does is right" —
    /// so a regression that was accepted into a golden by mistake still fails here.
    public static func engineBehaviour() -> CheckSuite {
        suite("EngineBehaviour", covers: ["FR-A-4", "FR-A-5", "FR-C-2", "FR-C-4",
                                          "AC-FR-C-2-4", "DEG-1", "DEG-2", "DEG-10"]) { c in
            func replay(_ name: String) -> FixtureReplay.Result? {
                FixtureGenerator.fixture(named: name).map { FixtureReplay.run($0) }
            }

            // Every run opens neutral — the settling window is what stops the first
            // thing the app says from being wrong.
            for fixture in FixtureGenerator.standardFixtures() {
                let result = FixtureReplay.run(fixture)
                c.expectEqual("\(fixture.name) opens neutral", result.outputs.first?.zone, .neutral)
                c.expect("\(fixture.name) settles at the start", result.outputs.first?.isSettling ?? false)
            }

            // Tempo: the memo's observed drift shape stays inside the band. This is
            // ADR-005's claim — that tolerating a fast opening beats prescribing one —
            // stated as a measurement rather than an opinion.
            if let tempo = replay("tempo-5mi-rolling") {
                let judged = tempo.outputs.filter { !$0.isSettling }
                let onTarget = judged.filter { $0.zone == .onTarget }.count
                let share = Double(onTarget) / Double(max(judged.count, 1))
                c.expect("tempo run spends ≥90% of judged time on target",
                         share >= 0.90, "\(Int(share * 100))%")
                c.expectEqual("a well-paced tempo run fires no pace alerts",
                              tempo.golden.alerts.filter { $0.kind.hasPrefix("pace") }.count, 0)
            }

            // VO2 max: never coloured, never a pace haptic — at any pace, in any step.
            if let vo2 = replay("intervals-4x1000") {
                c.expect("VO2 max is neutral for the entire run",
                         vo2.outputs.allSatisfy { $0.zone == .neutral })
                c.expectEqual("VO2 max fires no pace alerts",
                              vo2.golden.alerts.filter { $0.kind.hasPrefix("pace") }.count, 0)
                c.expectEqual("VO2 max fires nine step transitions",
                              vo2.golden.alerts.filter { $0.kind == "stepTransition" }.count, 9)

                // Each closed rep measures 1000 m, and the error does not compound.
                let closed = vo2.golden.transitions.filter(\.wasAutomatic)
                c.expectEqual("eight closed reps", closed.count, 8)
                for (index, transition) in closed.enumerated() {
                    c.expectClose("rep \(index + 1) measures 1000 m within 0.5%",
                                  transition.completedDistanceMetres, 1000, accuracy: 5)
                }
                let total = closed.reduce(0.0) { $0 + $1.completedDistanceMetres }
                c.expectClose("eight reps total 8000 m within 0.1%", total, 8000, accuracy: 8)
            }

            // Hills: a runner holding steady effort reads as on target. That is the
            // entire point of grade adjustment — measure effort, not speed.
            if let hilly = replay("hilly-10k") {
                let judged = hilly.outputs.filter { !$0.isSettling }
                let onTarget = judged.filter { $0.zone == .onTarget }.count
                let share = Double(onTarget) / Double(max(judged.count, 1))
                c.expect("steady effort on hills reads as on target ≥80% of the time",
                         share >= 0.80, "\(Int(share * 100))%")
                c.expectEqual("a steady hilly run fires no pace alerts",
                              hilly.golden.alerts.filter { $0.kind.hasPrefix("pace") }.count, 0)
                c.expect("grade adjustment is active on hills",
                         hilly.outputs.contains { $0.isGradeSignificant })
                c.expect("the applied factor stays inside its clamp",
                         hilly.outputs.allSatisfy { $0.gradeFactor.value >= 0.90 && $0.gradeFactor.value <= 1.30 })
                c.expect("the effective target diverges from the raw target on hills",
                         hilly.outputs.contains { output in
                             guard let raw = output.rawTarget, let effective = output.effectiveTarget else { return false }
                             return abs(raw.secondsPerMetre - effective.secondsPerMetre) > 1e-6
                         })
            }

            // GPS dropout: the run is flagged degraded and keeps producing a pace
            // rather than freezing.
            if let tunnel = replay("gps-dropout-tunnel") {
                c.expect("a tunnel flags GPS degradation",
                         tunnel.outputs.last?.degradations.contains(.gpsDegraded) ?? false)
                let duringTunnel = tunnel.outputs.filter { (620...680).contains(Int($0.activeElapsed)) }
                c.expect("pace stays available through the tunnel",
                         duringTunnel.allSatisfy { $0.rollingPace != nil })
            }

            // Treadmill: no GPS and no altimeter, so grade adjustment is off and the
            // run is flagged indoor — but it still records and still judges pace.
            if let treadmill = replay("treadmill-indoor") {
                let flags = treadmill.outputs.last?.degradations ?? []
                c.expect("an indoor run is flagged", flags.contains(.indoorRun))
                c.expect("no altimeter is flagged", flags.contains(.altimeterUnavailable))
                c.expect("grade adjustment is disabled indoors",
                         treadmill.outputs.allSatisfy { $0.gradeFactor.value == 1.0 })
                c.expect("an indoor run is still judged",
                         treadmill.outputs.contains { $0.zone == .onTarget })
            }

            // Traffic stops read as neutral, and never as "far too slow" — buzzing a
            // runner for standing at a red light is the failure mode this prevents.
            if let traffic = replay("stop-start-traffic") {
                c.expect("stops read as neutral", traffic.outputs.contains { $0.isStationary })
                c.expectEqual("stops fire no pace alerts",
                              traffic.golden.alerts.filter { $0.kind.hasPrefix("pace") }.count, 0)
                c.expect("no pace is reported while stopped",
                         traffic.outputs.filter(\.isStationary).allSatisfy { $0.rollingPace == nil })
                c.expect("stopped ticks are neutral",
                         traffic.outputs.filter(\.isStationary).allSatisfy { $0.zone == .neutral })
            }

            // Hysteresis: a pace parked on a boundary settles instead of flickering.
            if let boundary = replay("boundary-oscillation") {
                var changes = 0
                for (previous, next) in zip(boundary.outputs, boundary.outputs.dropFirst())
                where previous.zone != next.zone {
                    changes += 1
                }
                c.expect("a boundary-hugging pace produces few zone changes",
                         changes <= 6, "observed \(changes) changes over \(boundary.outputs.count) ticks")
            }
        }
    }

    // MARK: - T-032 properties

    /// Invariants that must hold for all inputs, not just the recorded ones.
    public static func properties() -> CheckSuite {
        suite("Properties", covers: ["FR-A-3", "FR-A-4", "FR-B-1", "FR-C-2", "AC-FR-A-1-4"]) { c in
            var random = DeterministicRandom(seed: 0x9017)

            // Pace round-trip under random input.
            var paceOK = true
            for _ in 0..<2000 {
                let minutes = 3 + random.unit() * 20
                if abs(Pace(minutesPerMile: minutes).minutesPerMile - minutes) > 1e-9 { paceOK = false }
            }
            c.expect("pace round-trips for arbitrary values", paceOK)

            // Grade factor is bounded and identity-at-zero for arbitrary input,
            // including values no altimeter would ever produce.
            let model = GradeModel(config: GradeConfiguration())
            var boundedOK = true
            for _ in 0..<5000 {
                let grade = (random.unit() * 4) - 2
                let value = model.factor(at: grade).value
                if value < 0.90 - 1e-12 || value > 1.30 + 1e-12 { boundedOK = false }
            }
            c.expect("the grade factor is bounded for arbitrary input", boundedOK)

            // Zone monotonicity under random bands.
            var monotonicOK = true
            for _ in 0..<500 {
                let band = PaceBand(
                    fastNear: 0.01 + random.unit() * 0.03,
                    fastFar: 0.05 + random.unit() * 0.05,
                    slowNear: 0.01 + random.unit() * 0.05,
                    slowFar: 0.10 + random.unit() * 0.05
                )
                guard band.isWellFormed else { continue }
                var last = PaceZone.tooFast
                for step in 0...400 {
                    let ratio = 0.8 + Double(step) / 400
                    let zone = ZoneClassifier.rawZone(ratio: ratio, band: band)
                    if zone.rawValue < last.rawValue { monotonicOK = false }
                    last = zone
                }
            }
            c.expect("zone is monotonic in pace ratio for arbitrary bands", monotonicOK)

            // Alert count is bounded by duration over cooldown, whatever the zone
            // sequence — the formal version of "it must not nag".
            var alertBoundOK = true
            for _ in 0..<200 {
                var policy = AlertPolicy(config: AlertConfiguration())
                var fired = 0
                let duration = 1800
                for second in 0..<duration {
                    let zone: PaceZone = random.unit() < 0.6 ? .tooFast : .onTarget
                    if policy.evaluate(zone: zone, now: Double(second), suppressed: false,
                                       currentPace: Pace(minutesPerMile: 7),
                                       targetPace: Pace(minutesPerMile: 8)) != nil {
                        fired += 1
                    }
                }
                if fired > duration / 60 + 1 { alertBoundOK = false }
            }
            c.expect("alert count never exceeds duration ÷ cooldown", alertBoundOK)

            // The step machine always terminates, whatever the input.
            var terminationOK = true
            for _ in 0..<200 {
                let reps = 1 + Int(random.unit() * 8)
                let plan = WorkoutPresets.intervals(reps: reps, workMetres: 200 + random.unit() * 800,
                                                    recoveryMetres: 200 + random.unit() * 800)
                var machine = StepMachine(steps: plan.resolvedSteps(), config: IntervalConfiguration())
                machine.start(cumulativeDistance: 0, activeElapsed: 0)
                var distance = 0.0
                for second in 0..<6000 {
                    distance += 2 + random.unit() * 4
                    _ = machine.tick(cumulativeDistance: distance, activeElapsed: Double(second),
                                     manualAdvanceRequested: random.unit() < 0.02)
                }
                machine.end()
                if !machine.isFinished { terminationOK = false }
            }
            c.expect("the step machine always reaches a terminal state", terminationOK)

            // Packed samples round-trip within their stated resolutions, for random
            // series rather than only the hand-built one.
            var packingOK = true
            for _ in 0..<20 {
                let samples = (0..<300).map { index in
                    RunSample(
                        timestamp: Double(index),
                        cumulativeDistance: Double(index) * (2 + random.unit() * 4),
                        rollingPace: random.unit() < 0.1 ? nil : Pace(minutesPerMile: 5 + random.unit() * 10),
                        heartRate: random.unit() < 0.1 ? nil : 120 + random.unit() * 80,
                        relativeAltitude: random.noise(50),
                        smoothedGrade: random.noise(0.12),
                        gradeFactor: PaceRatio(value: 0.90 + random.unit() * 0.4),
                        rawTarget: Pace(minutesPerMile: 8),
                        effectiveTarget: Pace(minutesPerMile: 8),
                        zone: PaceZone(rawValue: Int(random.unit() * 6)) ?? .neutral
                    )
                }
                guard let restored = PackedSamples(samples: samples).unpack() else {
                    packingOK = false
                    continue
                }
                for (original, back) in zip(samples, restored) {
                    if original.zone != back.zone { packingOK = false }
                    if abs(original.smoothedGrade - back.smoothedGrade) > PackedSamples.gradeResolution { packingOK = false }
                    if (original.rollingPace == nil) != (back.rollingPace == nil) { packingOK = false }
                }
            }
            c.expect("packed samples round-trip for arbitrary series", packingOK)

            // Zone timeline encode/decode is lossless for arbitrary sequences.
            var timelineOK = true
            for _ in 0..<100 {
                let zones = (0..<500).map { _ in PaceZone(rawValue: Int(random.unit() * 6)) ?? .neutral }
                if ZoneTimeline.decode(ZoneTimeline.encode(zones: zones)) != zones { timelineOK = false }
            }
            c.expect("the zone timeline is lossless for arbitrary sequences", timelineOK)

            // Downsampling never exceeds its threshold and always keeps the endpoints.
            var downsampleOK = true
            for _ in 0..<100 {
                let count = 50 + Int(random.unit() * 4000)
                let x = (0..<count).map(Double.init)
                let y = (0..<count).map { _ in random.noise(100) }
                let threshold = 10 + Int(random.unit() * 500)
                let indices = Downsample.largestTriangleThreeBuckets(x: x, y: y, threshold: threshold)
                if indices.count > max(threshold, 2) { downsampleOK = false }
                if indices.first != 0 || indices.last != count - 1 { downsampleOK = false }
            }
            c.expect("downsampling respects its threshold and keeps endpoints", downsampleOK)
        }
    }
}
