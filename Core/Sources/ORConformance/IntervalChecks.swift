import Foundation
import ORAlerts
import ORIntervals
import ORModels

/// Assertions for the interval engine and alert policy (T-018 … T-021).
public enum IntervalChecks {

    public static func all() -> [CheckSuite] {
        [plan(), stepMachine(), vo2Max(), alertPolicy()]
    }

    // MARK: - T-018 plan model

    public static func plan() -> CheckSuite {
        suite("WorkoutPlan", covers: ["FR-C-1", "AC-FR-C-1-1", "AC-FR-C-1-3",
                                      "AC-FR-C-1-4", "AC-FR-C-1-5"]) { c in
            let config = IntervalConfiguration()
            let canonical = WorkoutPresets.vo2Max4x1000()
            let steps = canonical.resolvedSteps()

            // The memo's canonical session: warmup + 4×(work, recovery) + cooldown.
            c.expectEqual("canonical plan flattens to 10 steps", steps.count, 10)
            c.expectEqual("first step is the warmup", steps[0].kind, .warmup)
            c.expectEqual("warmup is open-goal", steps[0].goal.isOpen, true)
            c.expectEqual("last step is the cooldown", steps[9].kind, .cooldown)
            c.expectEqual("cooldown is open-goal", steps[9].goal.isOpen, true)

            let work = steps.filter { $0.kind == .work }
            let recovery = steps.filter { $0.kind == .recovery }
            c.expectEqual("four work steps", work.count, 4)
            c.expectEqual("four recovery steps", recovery.count, 4)
            c.expectEqual("rep indices run 1…4", work.map(\.repIndex), [1, 2, 3, 4])
            c.expect("every interval step reports 4 reps", work.allSatisfy { $0.repCount == 4 })
            c.expect("every interval step is 1000 m",
                     work.allSatisfy { $0.goal.distanceMetres == 1000 })
            c.expect("indices are sequential", steps.map(\.index) == Array(0..<10))
            c.expect("warmup is not marked as repeated", !steps[0].isRepeated)
            c.expect("work steps are marked as repeated", work.allSatisfy(\.isRepeated))

            // Every VO2 max step carries no target — that is what produces the
            // no-colour screen from data rather than from a special case.
            c.expect("no VO2 max step carries a target", steps.allSatisfy { $0.target == nil })

            // Total planned distance is the sum of closed goals.
            c.expectClose("planned distance is 8000 m",
                          canonical.totalPlannedDistanceMetres ?? 0, 8000, accuracy: 1e-9)

            // Validation.
            var validated = true
            do { try canonical.validate(config: config) } catch { validated = false }
            c.expect("canonical plan validates", validated)

            func rejects(_ plan: WorkoutPlan, _ name: String) {
                do {
                    try plan.validate(config: config)
                    c.expect(name, false, "expected validation to reject")
                } catch {
                    c.expect(name, true)
                }
            }
            rejects(WorkoutPlan(runType: .interval, elements: []), "rejects an empty plan")
            rejects(WorkoutPlan(runType: .interval, elements: [
                .repeatBlock(count: 0, elements: [.step(WorkoutStep(kind: .work, goal: .distance(metres: 400)))]),
            ]), "rejects a zero repeat count")
            rejects(WorkoutPlan(runType: .interval, elements: [
                .repeatBlock(count: 99, elements: [.step(WorkoutStep(kind: .work, goal: .distance(metres: 400)))]),
            ]), "rejects a repeat count above 40")
            rejects(WorkoutPlan(runType: .interval, elements: [
                .step(WorkoutStep(kind: .work, goal: .distance(metres: 50))),
            ]), "rejects a step under 100 m")
            rejects(WorkoutPlan(runType: .interval, elements: [
                .step(WorkoutStep(kind: .work, goal: .distance(metres: 50_000))),
            ]), "rejects a step over 42195 m")
            rejects(WorkoutPlan(runType: .interval, elements: [
                .repeatBlock(count: 4, elements: []),
            ]), "rejects an empty repeat block")
            rejects(WorkoutPlan(runType: .interval, elements: [
                .step(WorkoutStep(kind: .work, goal: .time(seconds: 0))),
            ]), "rejects a zero time goal")
            rejects(WorkoutPlan(runType: .vo2max, elements: [
                .step(WorkoutStep(kind: .warmup, goal: .open)),
                .step(WorkoutStep(kind: .cooldown, goal: .open)),
            ]), "rejects a structured plan with no closed goal")

            // Bounds are inclusive at both ends.
            var accepted = true
            do {
                try WorkoutPresets.intervals(reps: 40, workMetres: 100, recoveryMetres: 42195)
                    .validate(config: config)
            } catch { accepted = false }
            c.expect("accepts the extremes of the permitted ranges", accepted)

            // JSON round-trip preserves structure.
            do {
                let data = try JSONEncoder().encode(canonical)
                let decoded = try JSONDecoder().decode(WorkoutPlan.self, from: data)
                c.expectEqual("plan round-trips through JSON", decoded, canonical)
                c.expectEqual("round-tripped plan flattens identically",
                              decoded.resolvedSteps().count, 10)
            } catch {
                c.expect("plan round-trips through JSON", false, "\(error)")
            }
        }
    }

    // MARK: - T-019 step machine

    /// Drives the machine at 1 Hz at a fixed speed, returning every transition.
    private static func drive(
        steps: [ResolvedStep],
        metresPerSecond: Double,
        seconds: Int,
        config: IntervalConfiguration = .init(),
        manualAt: Set<Int> = [],
        pausedDuring: Range<Int>? = nil
    ) -> (machine: StepMachine, transitions: [StepTransition], finalState: StepState, distance: Double) {
        var machine = StepMachine(steps: steps, config: config)
        machine.start(cumulativeDistance: 0, activeElapsed: 0)

        var transitions: [StepTransition] = []
        var distance = 0.0
        var active = 0.0
        var state = StepState.idle

        for second in 0..<seconds {
            let paused = pausedDuring?.contains(second) ?? false
            distance += metresPerSecond
            if !paused { active += 1 }
            let result = machine.tick(
                cumulativeDistance: distance,
                activeElapsed: active,
                manualAdvanceRequested: manualAt.contains(second)
            )
            state = result.state
            if let transition = result.transition { transitions.append(transition) }
        }
        return (machine, transitions, state, distance)
    }

    public static func stepMachine() -> CheckSuite {
        suite("StepMachine", covers: ["FR-C-2", "FR-C-3", "FR-C-6", "AC-FR-C-2-1", "AC-FR-C-2-3",
                                      "AC-FR-C-2-4", "AC-FR-C-2-5", "AC-FR-C-3-1", "AC-FR-C-3-4",
                                      "NFR-9", "NFR-10"]) { c in
            let steps = WorkoutPresets.vo2Max4x1000().resolvedSteps()

            // Warmup ends by hand at t=200; the eight closed steps then auto-advance.
            let run = drive(steps: steps, metresPerSecond: 4.0, seconds: 3000, manualAt: [200])
            c.expectEqual("nine transitions in the canonical session", run.transitions.count, 9)
            c.expectEqual("the first transition is manual", run.transitions.first?.wasAutomatic, false)
            c.expect("the remaining eight are automatic",
                     run.transitions.dropFirst().allSatisfy(\.wasAutomatic))

            // No accumulated rounding: each rep measures 1000 m to within 0.1%,
            // and so does their sum. Anchoring the next step to the *ideal* boundary
            // rather than the runner's actual position is what makes this hold.
            let closed = run.transitions.dropFirst()
            let total = closed.reduce(0.0) { $0 + $1.completedDistanceMetres }
            c.expectClose("eight closed steps sum to 8000 m within 0.1%",
                          total, 8000, accuracy: 8.0)
            for (index, transition) in closed.enumerated() {
                c.expectClose("rep \(index + 1) measures 1000 m within 0.1%",
                              transition.completedDistanceMetres, 1000, accuracy: 1.0)
            }

            // Auto-advance is within one tick, so within one second of travel.
            c.expect("advances within one tick of the goal",
                     closed.allSatisfy { $0.completedDistanceMetres < 1000 + 4.0 + 1e-6 })

            // Ends holding at the cooldown, waiting for a manual end.
            c.expectEqual("holds on the final open step", run.finalState.step?.kind, .cooldown)
            c.expectEqual("final step is manually advanceable", run.finalState.canAdvanceManually, true)

            // A tap during a closed goal is ignored — the guard that makes
            // full-screen tap-to-advance safe.
            let tapped = drive(steps: steps, metresPerSecond: 4.0, seconds: 600,
                               manualAt: Set(200...400))
            let duringRep = tapped.transitions.filter { !$0.wasAutomatic }
            c.expectEqual("only the open warmup accepts a manual advance", duringRep.count, 1)

            // Countdown appears in the final 100 m of a work step.
            var countdownSeen = false
            var machine = StepMachine(steps: steps, config: IntervalConfiguration())
            machine.start(cumulativeDistance: 0, activeElapsed: 0)
            var distance = 0.0
            for second in 0..<1200 {
                distance += 4.0
                let result = machine.tick(cumulativeDistance: distance,
                                          activeElapsed: Double(second),
                                          manualAdvanceRequested: second == 100)
                if result.state.step?.kind == .work, result.state.isCountingDown {
                    countdownSeen = true
                    if let remaining = result.state.distanceRemainingMetres {
                        c.expect("countdown only inside the final 100 m", remaining <= 100)
                    }
                }
            }
            c.expect("countdown appears before a work step ends", countdownSeen)

            // Undo restores the previous step exactly.
            var undoable = StepMachine(steps: steps, config: IntervalConfiguration())
            undoable.start(cumulativeDistance: 0, activeElapsed: 0)
            var undoDistance = 0.0
            for second in 0..<100 {
                undoDistance += 4.0
                _ = undoable.tick(cumulativeDistance: undoDistance,
                                  activeElapsed: Double(second), manualAdvanceRequested: false)
            }
            let before = undoable.tick(cumulativeDistance: undoDistance,
                                       activeElapsed: 100, manualAdvanceRequested: false).state
            _ = undoable.tick(cumulativeDistance: undoDistance, activeElapsed: 101,
                              manualAdvanceRequested: true)
            let advanced = undoable.tick(cumulativeDistance: undoDistance, activeElapsed: 102,
                                         manualAdvanceRequested: false).state
            c.expectEqual("manual advance moved to the work step", advanced.step?.kind, .work)
            c.expect("undo is offered", advanced.isUndoAvailable)
            let undone = undoable.undo(atActiveElapsed: 103)
            c.expect("undo succeeds inside the window", undone)
            let restored = undoable.tick(cumulativeDistance: undoDistance, activeElapsed: 104,
                                         manualAdvanceRequested: false).state
            c.expectEqual("undo restores the warmup", restored.step?.kind, .warmup)
            c.expectClose("undo restores accumulated distance",
                          restored.stepDistanceMetres, before.stepDistanceMetres, accuracy: 1e-9)

            // Undo expires.
            var expiring = StepMachine(steps: steps, config: IntervalConfiguration())
            expiring.start(cumulativeDistance: 0, activeElapsed: 0)
            _ = expiring.tick(cumulativeDistance: 10, activeElapsed: 1, manualAdvanceRequested: true)
            c.expect("undo expires after the window", !expiring.undo(atActiveElapsed: 100))

            // The *affordance* expires on the same clock as the action (AC-FR-C-6-1).
            //
            // The check above only proved that taking undo late fails. It passed while
            // `isUndoAvailable` was defined as "a snapshot exists", so the flag stayed true for the
            // remainder of the step and the UI kept a dead control on screen — 231 s of it on the
            // `intervals-4x1000` fixture. Asserting the flag's *lifetime*, not just its onset, is
            // what closes that.
            var window = StepMachine(steps: steps, config: IntervalConfiguration())
            window.start(cumulativeDistance: 0, activeElapsed: 0)
            _ = window.tick(cumulativeDistance: 10, activeElapsed: 1, manualAdvanceRequested: true)

            let insideWindow = window.tick(
                cumulativeDistance: 14, activeElapsed: 3, manualAdvanceRequested: false
            ).state
            c.expect("the undo affordance is offered inside the window", insideWindow.isUndoAvailable)

            let pastWindow = window.tick(
                cumulativeDistance: 200, activeElapsed: 40, manualAdvanceRequested: false
            ).state
            c.expect(
                "the undo affordance is withdrawn once the window closes",
                !pastWindow.isUndoAvailable
            )
            c.expect(
                "the withdrawn affordance agrees with the action",
                pastWindow.isUndoAvailable == window.isUndoAvailable(atActiveElapsed: 40)
            )

            // An automatic advance is not undoable — it was earned by running it.
            var auto = StepMachine(steps: steps, config: IntervalConfiguration())
            auto.start(cumulativeDistance: 0, activeElapsed: 0)
            var autoDistance = 0.0
            var sawAuto = false
            for second in 0..<1000 {
                autoDistance += 4.0
                let result = auto.tick(cumulativeDistance: autoDistance,
                                       activeElapsed: Double(second),
                                       manualAdvanceRequested: second == 10)
                if let transition = result.transition, transition.wasAutomatic {
                    sawAuto = true
                    c.expect("automatic advance is not undoable", !result.state.isUndoAvailable)
                    break
                }
            }
            c.expect("an automatic advance occurred", sawAuto)

            // Pause freezes step time but not distance.
            let paused = drive(steps: steps, metresPerSecond: 4.0, seconds: 400,
                               manualAt: [10], pausedDuring: 100..<300)
            c.expect("pause does not stall distance", paused.distance > 1500)

            // Ending is terminal.
            var ending = StepMachine(steps: steps, config: IntervalConfiguration())
            ending.start(cumulativeDistance: 0, activeElapsed: 0)
            ending.end()
            c.expect("machine reports finished", ending.isFinished)
            let afterEnd = ending.tick(cumulativeDistance: 9999, activeElapsed: 9999,
                                       manualAdvanceRequested: true)
            c.expectNil("no transitions after end", afterEnd.transition)
            c.expectEqual("phase stays finished", afterEnd.state.phase, .finished)

            // An empty plan goes straight to awaiting-end rather than trapping.
            var empty = StepMachine(steps: [], config: IntervalConfiguration())
            empty.start(cumulativeDistance: 0, activeElapsed: 0)
            c.expectEqual("empty plan awaits end",
                          empty.tick(cumulativeDistance: 0, activeElapsed: 0,
                                     manualAdvanceRequested: false).state.phase, .awaitingEnd)

            // A time-goal step advances on time.
            let timed = [ResolvedStep(index: 0, kind: .work, goal: .time(seconds: 60),
                                      target: nil, repIndex: 1, repCount: 1),
                         ResolvedStep(index: 1, kind: .cooldown, goal: .open,
                                      target: nil, repIndex: 1, repCount: 1)]
            let timedRun = drive(steps: timed, metresPerSecond: 3.0, seconds: 120)
            c.expectEqual("time goal advances once", timedRun.transitions.count, 1)
            c.expectClose("time goal advances at 60 s",
                          timedRun.transitions.first?.completedActiveSeconds ?? 0, 60, accuracy: 1.5)
        }
    }

    // MARK: - T-020 VO2 max semantics

    public static func vo2Max() -> CheckSuite {
        suite("RunTypeSemantics", covers: ["FR-C-4", "FR-C-5", "AC-FR-C-4-1", "AC-FR-C-4-2",
                                           "AC-FR-C-4-4", "AC-FR-C-5-1", "AC-FR-C-5-3"]) { c in
            let band = PaceBand.interval
            let pace = Pace(minutesPerMile: 6)
            let targetedStep = ResolvedStep(index: 0, kind: .work, goal: .distance(metres: 1000),
                                            target: StepTarget(pace: pace), repIndex: 1, repCount: 4)
            let bareStep = ResolvedStep(index: 1, kind: .recovery, goal: .distance(metres: 1000),
                                        target: nil, repIndex: 1, repCount: 4)

            // VO2 max refuses colour and pace haptics unconditionally — even when a
            // target has somehow been attached to a step. The run type decides, not
            // the data, so this cannot collapse into Interval by accident.
            let vo2 = RunTypeSemantics(runType: .vo2max)
            c.expect("VO2 max never permits colouring", !vo2.permitsColouring)
            c.expect("VO2 max never permits pace haptics", !vo2.permitsPaceHaptics)
            c.expect("VO2 max still permits transition haptics", vo2.permitsTransitionHaptics)
            c.expectNil("VO2 max ignores a step target",
                        vo2.effectiveTarget(for: targetedStep, profileBasePace: pace, defaultBand: band))
            c.expectNil("VO2 max ignores a profile pace",
                        vo2.effectiveTarget(for: bareStep, profileBasePace: pace, defaultBand: band))

            // Interval judges only the steps that carry a target.
            let interval = RunTypeSemantics(runType: .interval)
            c.expect("interval permits colouring", interval.permitsColouring)
            c.expectNotNil("interval judges a targeted step",
                           interval.effectiveTarget(for: targetedStep, profileBasePace: nil, defaultBand: band))
            c.expectNil("interval leaves an untargeted step neutral",
                        interval.effectiveTarget(for: bareStep, profileBasePace: pace, defaultBand: band))

            // Continuous runs fall back to the profile pace.
            let tempo = RunTypeSemantics(runType: .tempo)
            let fromProfile = tempo.effectiveTarget(for: nil, profileBasePace: pace, defaultBand: band)
            c.expectNotNil("tempo uses the profile pace", fromProfile)
            c.expectEqual("tempo adopts the default band", fromProfile?.band, band)
            c.expectNil("no profile pace means no judgement",
                        tempo.effectiveTarget(for: nil, profileBasePace: nil, defaultBand: band))

            // A per-step target overrides the profile for one session.
            let override = tempo.effectiveTarget(for: targetedStep,
                                                 profileBasePace: Pace(minutesPerMile: 9),
                                                 defaultBand: band)
            c.expectEqual("a step target overrides the profile", override?.pace, pace)

            // The run-type flags themselves.
            c.expect("vo2max does not apply colouring", !RunType.vo2max.appliesZoneColouring)
            c.expect("vo2max does not fire pace haptics", !RunType.vo2max.firesPaceHaptics)
            c.expect("vo2max is structured", RunType.vo2max.isStructured)
            c.expect("interval is structured", RunType.interval.isStructured)
            c.expect("tempo is not structured", !RunType.tempo.isStructured)
            c.expect("all continuous types colour",
                     [RunType.tempo, .easy, .long].allSatisfy(\.appliesZoneColouring))
        }
    }

    // MARK: - T-021 alert policy

    /// Holds a zone for a span of seconds, returning every alert emitted.
    private static func hold(
        zone: PaceZone,
        seconds: Int,
        from start: Int = 0,
        policy: inout AlertPolicy,
        suppressed: Bool = false
    ) -> [AlertCommand] {
        var alerts: [AlertCommand] = []
        for second in start..<(start + seconds) {
            if let alert = policy.evaluate(
                zone: zone, now: Double(second), suppressed: suppressed,
                currentPace: Pace(minutesPerMile: 7), targetPace: Pace(minutesPerMile: 8)
            ) {
                alerts.append(alert)
            }
        }
        return alerts
    }

    public static func alertPolicy() -> CheckSuite {
        suite("AlertPolicy", covers: ["FR-B-1", "AC-FR-B-1-1", "AC-FR-B-1-2", "AC-FR-B-1-4",
                                      "AC-FR-B-1-5", "AC-FR-B-1-7", "AC-FR-B-1-8"]) { c in
            let config = AlertConfiguration()

            // Dwell: 20 s continuous fires exactly one alert.
            var policy = AlertPolicy(config: config)
            let fired = hold(zone: .tooFast, seconds: 25, policy: &policy)
            c.expectEqual("20 s in a far zone fires exactly one alert", fired.count, 1)

            // A 19 s excursion fires nothing.
            var brief = AlertPolicy(config: config)
            c.expectEqual("a 19 s excursion fires nothing",
                          hold(zone: .tooFast, seconds: 19, policy: &brief).count, 0)

            // Cooldown suppresses a repeat of the same direction.
            var sustained = AlertPolicy(config: config)
            let firstMinute = hold(zone: .tooFast, seconds: 50, policy: &sustained)
            c.expectEqual("first alert inside the cooldown window", firstMinute.count, 1)
            let secondMinute = hold(zone: .tooFast, seconds: 40, from: 50, policy: &sustained)
            c.expectEqual("a second alert once the cooldown expires", secondMinute.count, 1)

            // The opposite direction is not muted by the first direction's cooldown.
            var bidirectional = AlertPolicy(config: config)
            _ = hold(zone: .tooFast, seconds: 25, policy: &bidirectional)
            let other = hold(zone: .tooSlow, seconds: 25, from: 25, policy: &bidirectional)
            c.expectEqual("the opposite direction can still fire", other.count, 1)

            // Returning to target resets the dwell, so the next excursion starts fresh.
            var resetting = AlertPolicy(config: config)
            _ = hold(zone: .tooFast, seconds: 15, policy: &resetting)
            _ = hold(zone: .onTarget, seconds: 5, from: 15, policy: &resetting)
            let afterReturn = hold(zone: .tooFast, seconds: 15, from: 20, policy: &resetting)
            c.expectEqual("dwell resets on returning to target", afterReturn.count, 0)

            // AC-FR-B-1-8: an hour oscillating across the boundary every 25 s fires no
            // more than 60 haptics. The cooldown, not the dwell, is what bounds this.
            var oscillating = AlertPolicy(config: config)
            var count = 0
            for second in 0..<3600 {
                let zone: PaceZone = (second / 25) % 2 == 0 ? .tooFast : .onTarget
                if oscillating.evaluate(zone: zone, now: Double(second), suppressed: false,
                                        currentPace: Pace(minutesPerMile: 7),
                                        targetPace: Pace(minutesPerMile: 8)) != nil {
                    count += 1
                }
            }
            c.expect("an hour of 25 s oscillation fires at most 60 alerts",
                     count <= 60, "fired \(count)")

            // Faster oscillation never accumulates enough dwell to fire at all.
            var fast = AlertPolicy(config: config)
            var fastCount = 0
            for second in 0..<3600 {
                let zone: PaceZone = (second / 10) % 2 == 0 ? .tooFast : .onTarget
                if fast.evaluate(zone: zone, now: Double(second), suppressed: false,
                                 currentPace: Pace(minutesPerMile: 7),
                                 targetPace: Pace(minutesPerMile: 8)) != nil {
                    fastCount += 1
                }
            }
            c.expectEqual("sub-dwell oscillation never fires", fastCount, 0)

            // Suppression covers settling, pause, VO2 max, and the user setting.
            var suppressed = AlertPolicy(config: config)
            c.expectEqual("suppression blocks alerts entirely",
                          hold(zone: .tooFast, seconds: 200, policy: &suppressed, suppressed: true).count, 0)

            // Near zones never alert, however long they persist.
            var nearZone = AlertPolicy(config: config)
            c.expectEqual("slightlyFast never alerts",
                          hold(zone: .slightlyFast, seconds: 300, policy: &nearZone).count, 0)
            var neutral = AlertPolicy(config: config)
            c.expectEqual("neutral never alerts",
                          hold(zone: .neutral, seconds: 300, policy: &neutral).count, 0)

            // Missing pace or target cannot produce a command.
            var incomplete = AlertPolicy(config: config)
            var incompleteCount = 0
            for second in 0..<60 {
                if incomplete.evaluate(zone: .tooSlow, now: Double(second), suppressed: false,
                                       currentPace: nil, targetPace: nil) != nil {
                    incompleteCount += 1
                }
            }
            c.expectEqual("no alert without a pace and target", incompleteCount, 0)

            // Direction is carried correctly.
            var directional = AlertPolicy(config: config)
            let slow = hold(zone: .tooSlow, seconds: 25, policy: &directional)
            if case .paceTooSlow = slow.first {
                c.expect("tooSlow yields a speed-up command", true)
            } else {
                c.expect("tooSlow yields a speed-up command", false, "got \(String(describing: slow.first))")
            }

            // Presentation priority: transitions outrank pace warnings.
            let transitionStep = ResolvedStep(index: 0, kind: .work, goal: .open,
                                              target: nil, repIndex: 1, repCount: 1)
            let transition = AlertCommand.stepTransition(StepTransition(
                from: transitionStep, to: nil, wasAutomatic: true,
                completedDistanceMetres: 1000, completedActiveSeconds: 200, atActiveElapsed: 200
            ))
            let paceAlert = AlertCommand.paceTooFast(current: Pace(minutesPerMile: 7),
                                                     target: Pace(minutesPerMile: 8))
            c.expect("a transition outranks a pace warning",
                     transition.presentationPriority > paceAlert.presentationPriority)
            c.expect("workout completion outranks a transition",
                     AlertCommand.workoutComplete.presentationPriority > transition.presentationPriority)
            c.expect("pace alerts are identified as such", paceAlert.isPaceAlert)
            c.expect("transitions are not pace alerts", !transition.isPaceAlert)

            // Reset clears everything.
            var resettable = AlertPolicy(config: config)
            _ = hold(zone: .tooFast, seconds: 25, policy: &resettable)
            resettable.reset()
            c.expectEqual("reset clears the cooldown",
                          hold(zone: .tooFast, seconds: 25, from: 30, policy: &resettable).count, 1)
        }
    }
}
