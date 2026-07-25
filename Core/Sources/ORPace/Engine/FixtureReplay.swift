import Foundation
import ORAlerts
import ORIntervals
import ORModels

/// Runs a fixture through the engine and reduces the result to its golden form
/// (design.md §16.2).
///
/// This is the single place that defines what a golden asserts, so the test harness
/// and the `--update-goldens` path can never disagree about it.
public enum FixtureReplay {

    public struct Result: Sendable {
        public let outputs: [EngineOutput]
        public let golden: EngineGolden
    }

    public static func run(
        _ fixture: EngineFixture,
        configuration: PaceEngineConfiguration = .default
    ) -> Result {
        var engine = RunEngine(
            configuration: configuration,
            plan: fixture.plan,
            profile: fixture.profile
        )

        var outputs: [EngineOutput] = []
        outputs.reserveCapacity(fixture.inputs.count)

        var alerts: [GoldenAlert] = []
        var transitions: [GoldenTransition] = []

        for input in fixture.inputs {
            let output = engine.tick(input)
            outputs.append(output)

            if let alert = output.alert {
                alerts.append(GoldenAlert(atSeconds: output.activeElapsed, kind: kind(of: alert)))
            }
            if let transition = output.stepTransition {
                transitions.append(GoldenTransition(
                    atSeconds: transition.atActiveElapsed,
                    atCumulativeDistance: output.cumulativeDistance,
                    fromIndex: transition.from.index,
                    toIndex: transition.to?.index,
                    wasAutomatic: transition.wasAutomatic,
                    completedDistanceMetres: transition.completedDistanceMetres
                ))
            }
        }

        let timeline = ZoneTimeline.encode(
            zones: outputs.map(\.zone),
            startSeconds: fixture.inputs.first?.timestamp ?? 0,
            intervalSeconds: configuration.capture.sampleIntervalSeconds
        )

        let golden = EngineGolden(
            fixture: fixture.name,
            zoneTimeline: timeline,
            alerts: alerts,
            transitions: transitions,
            sampleCount: outputs.count,
            finalCumulativeDistance: outputs.last?.cumulativeDistance ?? 0,
            finalActiveElapsed: outputs.last?.activeElapsed ?? 0,
            degradations: (outputs.last?.degradations ?? []).map(\.rawValue).sorted()
        )

        return Result(outputs: outputs, golden: golden)
    }

    private static func kind(of alert: AlertCommand) -> String {
        switch alert {
        case .paceTooFast: return "paceTooFast"
        case .paceTooSlow: return "paceTooSlow"
        case .stepTransition: return "stepTransition"
        case .workoutComplete: return "workoutComplete"
        }
    }
}
