import Foundation
import ORIntervals
import ORModels

/// Builds the project's standard fixtures deterministically (T-030, design.md §16.2).
///
/// Generated rather than hand-recorded so a contributor with no watch can reproduce
/// them exactly, and so the traces carry realistic sensor character — GPS jitter,
/// heart-rate drift, barometric noise — instead of the impossibly clean data that lets
/// a broken estimator look correct.
///
/// Lives in `ORPace`, the top of the Core dependency graph, so it can build real
/// workout plans via `WorkoutPresets` *and* drive the real `GradeModel`. Duplicating
/// either into the fixture layer would let the fixture and the engine drift apart,
/// which is precisely what fixtures exist to catch.
public enum FixtureGenerator {

    /// Every standard fixture, in a stable order.
    public static func standardFixtures() -> [EngineFixture] {
        [
            tempo5MileRolling(),
            intervals4x1000(),
            hilly10k(),
            gpsDropoutTunnel(),
            treadmillIndoor(),
            stopStartTraffic(),
            boundaryOscillation(),
        ]
    }

    public static func fixture(named name: String) -> EngineFixture? {
        standardFixtures().first { $0.name == name }
    }

    // MARK: - Builder

    /// Walks a pace programme forward at 1 Hz, accumulating distance.
    ///
    /// `paceAt` returns seconds-per-metre as a function of elapsed seconds and
    /// distance covered, or `nil` to mean stopped.
    private static func build(
        name: String,
        describes: String,
        runType: RunType,
        profile: RunnerProfile,
        plan: WorkoutPlan,
        seconds: Int,
        seed: UInt64,
        gpsAccuracy: (Int) -> Double? = { _ in 5.0 },
        altitudeAt: ((Int, Double) -> Double)? = nil,
        distanceSource: DistanceSource = .location,
        paceAt: (Int, Double) -> Double?
    ) -> EngineFixture {
        var random = DeterministicRandom(seed: seed)
        var distance = 0.0
        var inputs: [EngineInput] = []
        inputs.reserveCapacity(seconds)

        for second in 0..<seconds {
            if let secondsPerMetre = paceAt(second, distance), secondsPerMetre > 0 {
                // Per-second speed jitter: a real runner is never metronomic, and the
                // estimator must stay stable in spite of it.
                let jitter = 1 + random.noise(0.03)
                distance += (1.0 / secondsPerMetre) * jitter
            }

            let altitude: Double?
            if let altitudeAt {
                altitude = altitudeAt(second, distance) + random.noise(0.15)
            } else {
                altitude = nil
            }

            let accuracy = gpsAccuracy(second)
            let location: LocationSample?
            if let accuracy {
                location = LocationSample(
                    timestamp: Double(second),
                    // Positions are placeholders: nothing in the engine reads them,
                    // only the accuracy field gates the pace window.
                    latitude: 51.5 + distance / 1_000_000,
                    longitude: -0.12,
                    altitudeMetres: altitude ?? 0,
                    horizontalAccuracy: accuracy,
                    verticalAccuracy: accuracy
                )
            } else {
                location = nil
            }

            // Warm-up curve plus cardiac drift, so heart-rate handling is exercised
            // rather than fed a constant.
            let heartRate = 140 + 30 * (1 - exp(-Double(second) / 240))
                + Double(second) / 400 + random.noise(2)

            inputs.append(EngineInput(
                timestamp: Double(second),
                cumulativeDistance: distance,
                location: location,
                relativeAltitude: altitude,
                heartRate: heartRate,
                isPaused: false,
                manualAdvanceRequested: false,
                distanceSource: distanceSource
            ))
        }

        return EngineFixture(
            name: name,
            describes: describes,
            runType: runType,
            profile: profile,
            plan: plan,
            inputs: inputs
        )
    }

    private static let eightMinuteMile = Pace(minutesPerMile: 8)

    private static func standardProfile() -> RunnerProfile {
        RunnerProfile(
            tempoPace: eightMinuteMile,
            easyPace: Pace(minutesPerMile: 9.5),
            longPace: Pace(minutesPerMile: 9.0)
        )
    }

    // MARK: - Fixtures

    /// A realistic tempo run with the memo's observed shape: opening faster than
    /// target, drifting slower, crossing the target near halfway.
    ///
    /// The point of this fixture is that the drift is *tolerated*. A correctly tuned
    /// band leaves the runner on target for most of the run rather than oscillating
    /// between warnings — that is ADR-005's claim, and this is what tests it.
    public static func tempo5MileRolling() -> EngineFixture {
        let base = eightMinuteMile.secondsPerMetre
        let total = 2400
        return build(
            name: "tempo-5mi-rolling",
            describes: "Tempo run opening ~1.5% fast and closing ~2% slow — the memo's observed shape.",
            runType: .tempo,
            profile: standardProfile(),
            plan: WorkoutPresets.continuousRun(runType: .tempo, plannedDistanceMetres: 8047),
            seconds: total,
            seed: 0xA11CE,
            altitudeAt: { _, _ in 0 }
        ) { second, _ in
            let progress = Double(second) / Double(total)
            return base * (0.985 + 0.035 * progress)
        }
    }

    /// The canonical VO2 max session: open warmup, 4 × (1000 m / 1000 m), open
    /// cooldown. The reference case for the whole interval engine.
    ///
    /// Built by hand rather than via `build` because it needs a manual advance at a
    /// specific moment and a pace programme that follows the step structure.
    public static func intervals4x1000() -> EngineFixture {
        let hard = Pace(minutesPerMile: 6.2).secondsPerMetre
        let jog = Pace(minutesPerMile: 10.5).secondsPerMetre
        let easy = Pace(minutesPerMile: 9.5).secondsPerMetre

        var random = DeterministicRandom(seed: 0xBEEF)
        var distance = 0.0
        var inputs: [EngineInput] = []
        var repsCompleted = 0
        var inWork = true
        var nextBoundary: Double?

        for second in 0..<3000 {
            let warmupDone = second >= 300
            let secondsPerMetre: Double

            if !warmupDone {
                secondsPerMetre = easy
            } else if repsCompleted >= 4 {
                secondsPerMetre = easy                      // cooldown
            } else {
                if nextBoundary == nil { nextBoundary = distance + 1000 }
                if let boundary = nextBoundary, distance >= boundary {
                    if !inWork { repsCompleted += 1 }
                    inWork.toggle()
                    nextBoundary = distance + 1000
                }
                secondsPerMetre = inWork ? hard : jog
            }

            distance += (1.0 / secondsPerMetre) * (1 + random.noise(0.03))

            inputs.append(EngineInput(
                timestamp: Double(second),
                cumulativeDistance: distance,
                location: LocationSample(
                    timestamp: Double(second), latitude: 51.5, longitude: -0.12,
                    altitudeMetres: 0, horizontalAccuracy: 5, verticalAccuracy: 5
                ),
                relativeAltitude: 0,
                heartRate: 150 + (warmupDone && inWork && repsCompleted < 4 ? 30 : 0)
                    + random.noise(3),
                isPaused: false,
                // Exactly one manual advance, ending the open warmup.
                manualAdvanceRequested: second == 300,
                distanceSource: .location
            ))
        }

        return EngineFixture(
            name: "intervals-4x1000",
            describes: "Canonical VO2 max session: open warmup, 4 × (1000 m / 1000 m), open cooldown.",
            runType: .vo2max,
            profile: standardProfile(),
            plan: WorkoutPresets.vo2Max4x1000(),
            inputs: inputs
        )
    }

    /// Rolling terrain to roughly ±8%, exercising grade estimation and the attenuated
    /// adjustment end to end.
    public static func hilly10k() -> EngineFixture {
        let base = Pace(minutesPerMile: 9.0).secondsPerMetre
        // 25 m amplitude over a 2 km wavelength gives a peak grade of
        // 25·2π/2000 ≈ 7.9%. The wavelength matters: these climbs last long enough to
        // clear the 15 s persistence gate, whereas a short bump deliberately does not.
        let amplitude = 25.0
        let wavelength = 2000.0
        return build(
            name: "hilly-10k",
            describes: "Rolling terrain reaching ±8% grade; exercises grade estimation and adjustment.",
            runType: .long,
            profile: standardProfile(),
            plan: WorkoutPresets.continuousRun(runType: .long, plannedDistanceMetres: 10_000),
            seconds: 3300,
            seed: 0x41111,
            altitudeAt: { _, distance in
                amplitude * sin(distance / wavelength * 2 * Double.pi)
            }
        ) { second, distance in
            let grade = amplitude * cos(distance / wavelength * 2 * Double.pi)
                * 2 * Double.pi / wavelength
            // This runner holds *steady effort*, so their pace tracks the same
            // attenuated cost curve the engine prescribes — slowing a lot uphill,
            // gaining only a little downhill. That is the whole claim of FR-A-4: a
            // runner who paces by effort should read as on-target on a hilly course,
            // not be told off for the terrain. A ±1.5% wobble keeps it honest.
            let factor = gradeModel.factor(at: grade).value
            let wobble = 1 + 0.015 * sin(Double(second) / 37)
            return base * factor * wobble
        }
    }

    /// The engine's own grade model, so the fixture cannot drift from it.
    private static let gradeModel = GradeModel(config: GradeConfiguration())

    /// Ninety seconds with no usable GPS fix, exercising DEG-1.
    public static func gpsDropoutTunnel() -> EngineFixture {
        let base = eightMinuteMile.secondsPerMetre
        return build(
            name: "gps-dropout-tunnel",
            describes: "90 s of unusable GPS mid-run; exercises degraded-accuracy handling (DEG-1).",
            runType: .tempo,
            profile: standardProfile(),
            plan: WorkoutPresets.continuousRun(runType: .tempo, plannedDistanceMetres: 5000),
            seconds: 1500,
            seed: 0x70EE1,
            gpsAccuracy: { second in
                // Accuracy collapses in the tunnel. Distance keeps advancing, because
                // the pedometer contribution to the fused figure is still real.
                (600...690).contains(second) ? 80 : 5
            },
            altitudeAt: { _, _ in 0 }
        ) { _, _ in base }
    }

    /// Treadmill: pedometer distance, no location, no altitude (DEG-10).
    public static func treadmillIndoor() -> EngineFixture {
        let base = Pace(minutesPerMile: 9.5).secondsPerMetre
        return build(
            name: "treadmill-indoor",
            describes: "Indoor run: pedometer distance only, no GPS and no altimeter (DEG-10).",
            runType: .easy,
            profile: standardProfile(),
            plan: WorkoutPresets.continuousRun(runType: .easy, plannedDistanceMetres: 5000),
            seconds: 1800,
            seed: 0x7EAD,
            gpsAccuracy: { _ in nil },
            altitudeAt: nil,
            distanceSource: .pedometer
        ) { _, _ in base }
    }

    /// Repeated traffic stops, exercising stationary detection.
    public static func stopStartTraffic() -> EngineFixture {
        let base = Pace(minutesPerMile: 9.5).secondsPerMetre
        return build(
            name: "stop-start-traffic",
            describes: "Repeated 40 s stops at junctions; exercises stationary handling.",
            runType: .easy,
            profile: standardProfile(),
            plan: WorkoutPresets.continuousRun(runType: .easy),
            seconds: 1500,
            seed: 0x570FF,
            altitudeAt: { _, _ in 0 }
        ) { second, _ in
            (second % 300) >= 260 ? nil : base
        }
    }

    /// Pace parked within the hysteresis margin of a zone boundary.
    ///
    /// If hysteresis regresses, this fixture produces a zone timeline with hundreds of
    /// spans instead of a handful — a failure that is unmissable in a golden diff.
    public static func boundaryOscillation() -> EngineFixture {
        let base = eightMinuteMile.secondsPerMetre
        // Tempo's slowNear threshold is 2%; oscillate ±0.4% around it, inside the
        // 0.5% hysteresis margin.
        let boundary = base * 1.02
        return build(
            name: "boundary-oscillation",
            describes: "Pace hovering within the hysteresis margin of a zone edge.",
            runType: .tempo,
            profile: standardProfile(),
            plan: WorkoutPresets.continuousRun(runType: .tempo, plannedDistanceMetres: 5000),
            seconds: 1500,
            seed: 0x05C11,
            gpsAccuracy: { _ in 3.0 },
            altitudeAt: { _, _ in 0 }
        ) { second, _ in
            boundary * (1 + 0.004 * sin(Double(second) / 6))
        }
    }
}
