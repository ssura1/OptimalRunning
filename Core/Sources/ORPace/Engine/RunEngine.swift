import Foundation
import ORAlerts
import ORIntervals
import ORModels

// MARK: - Output

/// Everything the UI shows and everything the run records, for one tick
/// (design.md §5.7).
public struct EngineOutput: Sendable {
    public let zone: PaceZone
    public let rollingPace: Pace?
    public let averagePace: Pace?
    /// Target from the curve alone, before grade adjustment.
    public let rawTarget: Pace?
    /// Target actually judged against — the curve times the grade factor.
    public let effectiveTarget: Pace?
    public let gradeFactor: PaceRatio
    public let smoothedGrade: Double
    /// Whether the hill indicator should be shown (AC-FR-A-4-7).
    public let isGradeSignificant: Bool
    public let isGradeAvailable: Bool
    public let isGPSDegraded: Bool
    public let isStationary: Bool
    public let isSettling: Bool
    public let progress: Double
    public let activeElapsed: TimeInterval
    public let cumulativeDistance: Double
    public let heartRate: Double?
    public let step: StepState
    public let stepTransition: StepTransition?
    public let alert: AlertCommand?
    public let degradations: Set<DegradationFlag>
    public let sample: RunSample

    /// Memberwise initializer, made public for the app tiers.
    ///
    /// During a run only `RunEngine.tick` produces these, and nothing else should. But
    /// a tier's presentation layer has to be checkable against a specific zone — "does
    /// every zone render a glyph?", "does VO2 max stay neutral at `tooFast`?" — and
    /// SwiftUI previews need a value with no engine behind them at all. Reaching those
    /// states by driving a real engine would mean searching for input that lands on each
    /// zone, which tests presentation through the engine's own correctness rather than
    /// independently of it.
    public init(
        zone: PaceZone,
        rollingPace: Pace?,
        averagePace: Pace?,
        rawTarget: Pace?,
        effectiveTarget: Pace?,
        gradeFactor: PaceRatio,
        smoothedGrade: Double,
        isGradeSignificant: Bool,
        isGradeAvailable: Bool,
        isGPSDegraded: Bool,
        isStationary: Bool,
        isSettling: Bool,
        progress: Double,
        activeElapsed: TimeInterval,
        cumulativeDistance: Double,
        heartRate: Double?,
        step: StepState,
        stepTransition: StepTransition?,
        alert: AlertCommand?,
        degradations: Set<DegradationFlag>,
        sample: RunSample
    ) {
        self.zone = zone
        self.rollingPace = rollingPace
        self.averagePace = averagePace
        self.rawTarget = rawTarget
        self.effectiveTarget = effectiveTarget
        self.gradeFactor = gradeFactor
        self.smoothedGrade = smoothedGrade
        self.isGradeSignificant = isGradeSignificant
        self.isGradeAvailable = isGradeAvailable
        self.isGPSDegraded = isGPSDegraded
        self.isStationary = isStationary
        self.isSettling = isSettling
        self.progress = progress
        self.activeElapsed = activeElapsed
        self.cumulativeDistance = cumulativeDistance
        self.heartRate = heartRate
        self.step = step
        self.stepTransition = stepTransition
        self.alert = alert
        self.degradations = degradations
        self.sample = sample
    }

    /// Signed difference from target in seconds per the given unit — the delta the
    /// run screen renders alongside the zone glyph (AC-FR-J-1-2).
    public func signedDelta(in unit: UnitPreference) -> Double? {
        guard let rollingPace, let effectiveTarget else { return nil }
        return rollingPace.signedDelta(from: effectiveTarget, in: unit)
    }
}

// MARK: - Engine

/// The single entry point for everything the product decides during a run
/// (design.md §5.7).
///
/// Pure with respect to its inputs: the same `EngineInput` sequence always yields the
/// same `EngineOutput` sequence. No wall clock, no randomness, no I/O. That is what
/// lets a recorded run be replayed as a regression test, and what lets a bug report
/// become a fixture.
public struct RunEngine: Sendable {

    private let config: PaceEngineConfiguration
    private let plan: WorkoutPlan
    private let profile: RunnerProfile
    private let semantics: RunTypeSemantics
    private let curve: TargetPaceCurve

    private var rollingPace: RollingPaceEstimator
    private var gradeEstimator: GradeEstimator
    private let gradeModel: GradeModel
    private let classifier: ZoneClassifier
    private let settling: SettlingWindow
    private var stepMachine: StepMachine
    private var alertPolicy: AlertPolicy
    private var clock = ActiveClock()

    private var previousZone: PaceZone = .neutral
    private var degradations: Set<DegradationFlag> = []
    private var lastHeartRate: Double?
    private var lastHeartRateAt: TimeInterval?
    private var started = false

    public init(configuration: PaceEngineConfiguration, plan: WorkoutPlan, profile: RunnerProfile) {
        self.config = configuration
        self.plan = plan
        self.profile = profile
        self.semantics = RunTypeSemantics(runType: plan.runType)
        self.curve = configuration.curve(for: plan.runType)

        self.rollingPace = RollingPaceEstimator(config: configuration.rollingPace)
        self.gradeEstimator = GradeEstimator(config: configuration.grade)
        self.gradeModel = GradeModel(config: configuration.grade)
        self.classifier = ZoneClassifier(config: configuration.zones)
        self.settling = SettlingWindow(config: configuration.settling)
        self.stepMachine = StepMachine(
            steps: plan.resolvedSteps(),
            config: configuration.intervals
        )
        self.alertPolicy = AlertPolicy(config: configuration.alerts)

        if plan.runType.isStructured == false, profile.basePace(for: plan.runType) == nil {
            degradations.insert(.noTargetPace)
        }
    }

    public var resolvedSteps: [ResolvedStep] { stepMachine.resolvedSteps }

    /// Advances the engine by one tick.
    public mutating func tick(_ input: EngineInput) -> EngineOutput {
        if !started {
            stepMachine.start(cumulativeDistance: input.cumulativeDistance, activeElapsed: 0)
            started = true
        }

        clock.advance(to: input.timestamp, paused: input.isPaused)
        let activeElapsed = clock.activeElapsed

        // 1. Rolling pace. A fix that fails the accuracy test still advances distance
        //    but must not anchor the window.
        //
        //    With no fix at all, whether the distance still counts as trusted depends on
        //    *why* there is no fix. A treadmill run has none and never will, and calling
        //    it permanently GPS-degraded would widen the band for the whole session and
        //    record a degradation that describes nothing (DEG-10 is the honest flag
        //    there). An outdoor run whose fixes have stopped arriving is a different
        //    situation with the same shape, and AC-FR-S-C-3-2 requires it to widen the
        //    band by 50% for exactly as long as the distance is inferred.
        //
        //    The sources are what separate them. `.pedometer` and `.healthKit` with no
        //    fix mean indoors; `.motionModel` means this project's own model is carrying
        //    an outdoor run through a GNSS outage (DEG-S-1). Neither watch tier ever emits
        //    `.motionModel`, so their behaviour under this line is unchanged — which
        //    AC-FR-S-A-3-4 requires and the tier-equivalence goldens check.
        let trusted = input.location.map {
            $0.isAcceptable(maxHorizontalAccuracy: config.rollingPace.maxHorizontalAccuracyMetres)
        } ?? (input.distanceSource == .pedometer || input.distanceSource == .healthKit)

        let paceResult = rollingPace.ingest(DistanceSample(
            timestamp: input.timestamp,
            cumulativeDistance: input.cumulativeDistance,
            isTrusted: trusted
        ))
        if paceResult.isGPSDegraded { degradations.insert(.gpsDegraded) }
        if input.distanceSource == .pedometer && input.location == nil {
            degradations.insert(.indoorRun)
        }

        // 2. Grade.
        let grade = gradeEstimator.ingest(
            cumulativeDistance: input.cumulativeDistance,
            relativeAltitude: input.relativeAltitude,
            timestamp: input.timestamp
        )
        if !grade.isAvailable { degradations.insert(.altimeterUnavailable) }
        let gradeFactor = grade.isAvailable ? gradeModel.factor(at: grade.appliedGrade) : .identity

        // 3. Step machine.
        let (stepState, transition) = stepMachine.tick(
            cumulativeDistance: input.cumulativeDistance,
            activeElapsed: activeElapsed,
            manualAdvanceRequested: input.manualAdvanceRequested
        )

        // 4. Target for the step in force.
        let defaultBand = config.band(for: plan.runType)
        let target = semantics.effectiveTarget(
            for: stepState.step,
            profileBasePace: profile.basePace(for: plan.runType),
            defaultBand: defaultBand
        )

        let progress = ProgressCalculator.progress(
            distanceCovered: input.cumulativeDistance,
            activeElapsed: activeElapsed,
            plannedDistanceMetres: plan.plannedDistanceMetres,
            plannedDurationSeconds: plan.plannedDurationSeconds
        )

        let rawTarget = target.map { curve.targetPace(base: $0.pace, progress: progress) }
        let effectiveTarget = rawTarget?.scaled(by: gradeFactor)

        // 5. Heart rate, with staleness. A stale reading is worse than none — it looks
        //    live and is not (AC-FR-A-6-4).
        let heartRate = resolveHeartRate(input: input)

        // 6. Zone.
        let isSettling = settling.isSettling(
            distanceCovered: input.cumulativeDistance,
            activeElapsed: activeElapsed,
            stepDistance: stepState.step.map { _ in stepState.stepDistanceMetres },
            isStructured: plan.runType.isStructured
        )

        var band = target?.band ?? defaultBand
        if paceResult.isGPSDegraded {
            band = band.widened(by: config.degradation.degradedBandWideningFactor)
        }

        let zone = resolveZone(
            paceResult: paceResult,
            effectiveTarget: effectiveTarget,
            band: band,
            isSettling: isSettling,
            isPaused: input.isPaused
        )
        previousZone = zone

        // 7. Alerts. A step transition outranks a pace warning, and suppressing the
        //    pace policy on that tick keeps a single haptic from arriving as two.
        let alert = resolveAlert(
            transition: transition,
            zone: zone,
            now: activeElapsed,
            isSettling: isSettling,
            isPaused: input.isPaused,
            currentPace: paceResult.pace,
            targetPace: effectiveTarget
        )

        let sample = RunSample(
            timestamp: input.timestamp,
            cumulativeDistance: input.cumulativeDistance,
            rollingPace: paceResult.pace,
            heartRate: heartRate,
            relativeAltitude: input.relativeAltitude,
            smoothedGrade: grade.smoothedGrade,
            gradeFactor: gradeFactor,
            rawTarget: rawTarget,
            effectiveTarget: effectiveTarget,
            zone: zone
        )

        return EngineOutput(
            zone: zone,
            rollingPace: paceResult.pace,
            averagePace: Pace(distanceMetres: input.cumulativeDistance, seconds: activeElapsed),
            rawTarget: rawTarget,
            effectiveTarget: effectiveTarget,
            gradeFactor: gradeFactor,
            smoothedGrade: grade.smoothedGrade,
            isGradeSignificant: grade.isAvailable && gradeModel.isSignificant(gradeFactor),
            isGradeAvailable: grade.isAvailable,
            isGPSDegraded: paceResult.isGPSDegraded,
            isStationary: paceResult.isStationary,
            isSettling: isSettling,
            progress: progress,
            activeElapsed: activeElapsed,
            cumulativeDistance: input.cumulativeDistance,
            heartRate: heartRate,
            step: stepState,
            stepTransition: transition,
            alert: alert,
            degradations: degradations,
            sample: sample
        )
    }

    /// Reverts the most recent manual advance (FR-C-6).
    @discardableResult
    public mutating func undoManualAdvance() -> Bool {
        stepMachine.undo(atActiveElapsed: clock.activeElapsed)
    }

    public mutating func end() {
        stepMachine.end()
    }

    // MARK: - Private

    private mutating func resolveHeartRate(input: EngineInput) -> Double? {
        if let hr = input.heartRate, hr.isFinite, hr > 0 {
            lastHeartRate = hr
            lastHeartRateAt = input.timestamp
            return hr
        }
        guard let at = lastHeartRateAt,
              input.timestamp - at <= config.capture.heartRateStaleSeconds
        else {
            if lastHeartRateAt != nil { degradations.insert(.heartRateDropout) }
            return nil
        }
        return lastHeartRate
    }

    /// The neutral overrides, in the order they take precedence. Each is a case where
    /// the app has nothing honest to say about pace, and saying nothing is correct.
    private func resolveZone(
        paceResult: RollingPaceResult,
        effectiveTarget: Pace?,
        band: PaceBand,
        isSettling: Bool,
        isPaused: Bool
    ) -> PaceZone {
        guard !isPaused else { return .neutral }
        guard !isSettling else { return .neutral }
        guard let target = effectiveTarget, target.isValid else { return .neutral }
        guard let pace = paceResult.pace, pace.isValid, !paceResult.isStationary else {
            return .neutral
        }
        let ratio = pace.ratio(to: target).value
        return classifier.classify(ratio: ratio, band: band, previous: previousZone)
    }

    private mutating func resolveAlert(
        transition: StepTransition?,
        zone: PaceZone,
        now: TimeInterval,
        isSettling: Bool,
        isPaused: Bool,
        currentPace: Pace?,
        targetPace: Pace?
    ) -> AlertCommand? {
        let suppressed = isSettling
            || isPaused
            || transition != nil
            || !semantics.permitsPaceHaptics
            || !profile.paceHapticsEnabled

        let paceAlert = alertPolicy.evaluate(
            zone: zone,
            now: now,
            suppressed: suppressed,
            currentPace: currentPace,
            targetPace: targetPace
        )

        if let transition {
            guard semantics.permitsTransitionHaptics else { return paceAlert }
            return transition.to == nil ? .workoutComplete : .stepTransition(transition)
        }
        return paceAlert
    }
}
