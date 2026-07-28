import Foundation
import PhoneMotion

// motionreplay — offline replay of a recorded motion trace (S-021).
//
// The analogue of Core's `replay` CLI, and the answer to "how accurate is it today"
// without writing code. Deliberately reports the *reference it used and that reference's
// own accuracy* alongside every number, because a claim tighter than its reference is
// the specific failure CON-S-7 exists to prevent.

func usage() -> Never {
    let text = """
    motionreplay — replay a recorded motion trace through the estimator

    USAGE
      motionreplay --trace <path.motion.json> [options]

    OPTIONS
      --trace <path>          the recording to replay (required)
      --golden <path>         compare against a committed golden, exit non-zero on mismatch
      --update-goldens        write the golden for this trace instead of comparing
      --suppress-gnss-after <seconds>
                              drop every fix after this timestamp, simulating an outage
                              over real motion data (implementation.md S-024)
      --print-cadence         print the full cadence series rather than a summary
      --json                  emit the result as JSON

    NOTE
      Accuracy figures printed here are only as good as the reference the trace carries.
      A trace with no declared reference can exercise the pipeline but cannot validate a
      bound; this tool says so rather than printing a number that reads like one.
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

struct Options {
    var tracePath: String?
    var goldenPath: String?
    var updateGoldens = false
    var suppressAfter: TimeInterval?
    var printCadence = false
    var json = false
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--trace": options.tracePath = arguments.first; arguments = Array(arguments.dropFirst())
    case "--golden": options.goldenPath = arguments.first; arguments = Array(arguments.dropFirst())
    case "--update-goldens": options.updateGoldens = true
    case "--suppress-gnss-after":
        options.suppressAfter = arguments.first.flatMap(Double.init)
        arguments = Array(arguments.dropFirst())
    case "--print-cadence": options.printCadence = true
    case "--json": options.json = true
    case "-h", "--help": usage()
    default:
        FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
        usage()
    }
}

guard let tracePath = options.tracePath else { usage() }

let traceURL = URL(fileURLWithPath: tracePath)
let trace: MotionTrace
do {
    trace = try MotionTrace.decode(from: Data(contentsOf: traceURL))
} catch {
    FileHandle.standardError.write(Data("error: cannot read trace: \(error)\n".utf8))
    exit(1)
}

let result = TraceReplay.run(trace: trace, suppressLocationAfter: options.suppressAfter)

// MARK: - Golden handling

let goldenURL = options.goldenPath.map { URL(fileURLWithPath: $0) }

if options.updateGoldens {
    guard let goldenURL else {
        FileHandle.standardError.write(Data("error: --update-goldens needs --golden\n".utf8))
        exit(2)
    }
    let encoder = JSONEncoder()
    // Sorted keys and pretty printing so `--update-goldens` produces a *reviewable*
    // diff rather than an opaque blob. That is what makes "never regenerate a golden to
    // make a test pass" an enforceable rule rather than an aspiration.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        try encoder.encode(result).write(to: goldenURL, options: .atomic)
        print("wrote golden: \(goldenURL.lastPathComponent)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: cannot write golden: \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - Report

func formatted(_ value: Double, _ places: Int = 1) -> String {
    String(format: "%.\(places)f", value)
}

if options.json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
} else {
    print("trace:            \(result.trace)")
    print("  \(trace.header.describes)")
    print("  recorded on     \(trace.header.deviceModel), \(trace.header.systemVersion)")
    print("  carry position  \(trace.header.carryPosition.rawValue)")
    print("")
    print("distance")
    print("  fused           \(formatted(result.fusedDistanceMetres)) m")
    print("    measured      \(formatted(result.measuredMetres)) m")
    print("    estimated     \(formatted(result.estimatedMetres)) m")
    print("  motion leg      \(formatted(result.motionOnlyDistanceMetres)) m")
    print("  trace GNSS      \(formatted(result.gnssDistanceMetres)) m")
    print("")
    print("steps")
    print("  total           \(result.stepCount)")
    print("    impact peaks  \(result.impactDetectedSteps)")
    print("    phase-locked  \(result.phaseLockedSteps)")
    if let cadence = result.medianCadenceStepsPerMinute {
        print("  median cadence  \(formatted(cadence)) spm")
    } else {
        print("  median cadence  none — no window was confident enough to report")
    }
    print("")
    print("calibration")
    if let scale = result.calibrationScale {
        print("  scale           \(formatted(scale, 4))")
        print("  observations    \(result.calibrationObservations)")
        print("  converged       \(result.isConverged)")
    } else {
        print("  none learned — no qualifying GNSS window, so no motion distance is claimed")
    }
    if !result.flags.isEmpty {
        print("")
        print("flags:            \(result.flags.joined(separator: ", "))")
    }

    print("")
    if trace.header.references.isEmpty {
        print("references:       NONE DECLARED")
        print("  This trace can exercise the pipeline but cannot validate an accuracy")
        print("  bound. Nothing printed above is a validated figure (CON-S-7).")
    } else {
        print("references")
        for reference in trace.header.references {
            let accuracy = reference.referenceAccuracyFraction * 100
            print("  \(reference.kind.rawValue): \(formatted(reference.value, 2)) "
                + "\(reference.unit) (±\(formatted(accuracy, 1))% reference error)")
            if reference.kind == .surveyedDistance
                || reference.kind == .companionGNSSDistance
                || reference.kind == .phoneGNSSDistance
            {
                let error = (result.motionOnlyDistanceMetres - reference.value) / reference.value
                print("    motion leg vs reference: \(formatted(error * 100, 2))% "
                    + "— cannot be claimed tighter than ±\(formatted(accuracy, 1))%")
            }
            if reference.kind == .countedSteps {
                let error = (Double(result.stepCount) - reference.value) / reference.value
                print("    step count vs reference: \(formatted(error * 100, 2))%")
            }
        }
    }

    if options.printCadence {
        print("")
        print("cadence series (s, spm, confidence)")
        for point in result.cadenceSamples {
            let spm = point.stepsPerMinute.map { formatted($0) } ?? "--"
            print("  \(formatted(point.atSeconds)) \(spm) \(formatted(point.confidence, 2))")
        }
    }
}

// MARK: - Comparison

if let goldenURL {
    do {
        let data = try Data(contentsOf: goldenURL)
        let golden = try JSONDecoder().decode(TraceReplay.Result.self, from: data)
        if golden == result {
            print("\ngolden: match")
        } else {
            FileHandle.standardError.write(Data("\ngolden: MISMATCH\n".utf8))
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("error: cannot read golden: \(error)\n".utf8))
        exit(1)
    }
}
