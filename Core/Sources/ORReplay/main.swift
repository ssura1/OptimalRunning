import Foundation
import ORIntervals
import ORModels
import ORPace

// Golden-fixture replay CLI (T-010).
//
// Regenerating a golden is a deliberate act, not a way to make a red test go green.
// `--update-goldens` therefore prints exactly what changed before writing, so the diff
// a reviewer sees in the PR has already been stated in the console.
//
//   swift run --package-path Core ORReplay generate
//   swift run --package-path Core ORReplay verify
//   swift run --package-path Core ORReplay verify --update-goldens
//   swift run --package-path Core ORReplay timeline --fixture tempo-5mi-rolling

// MARK: - Paths

/// `<repo>/Core/Sources/ORReplay/main.swift` → `<repo>`.
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let fixturesDirectory = repositoryRoot.appendingPathComponent("Fixtures", isDirectory: true)
let goldenDirectory = fixturesDirectory.appendingPathComponent("golden", isDirectory: true)

func fixtureURL(_ name: String) -> URL {
    fixturesDirectory.appendingPathComponent("\(name).json")
}

func goldenURL(_ name: String) -> URL {
    goldenDirectory.appendingPathComponent("\(name).golden.json")
}

// MARK: - Arguments

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "verify"
let updateGoldens = arguments.contains("--update-goldens")
let requestedFixture: String? = arguments.firstIndex(of: "--fixture").flatMap { index in
    index + 1 < arguments.count ? arguments[index + 1] : nil
}

func selectedFixtures() -> [EngineFixture] {
    let all = FixtureGenerator.standardFixtures()
    guard let requestedFixture else { return all }
    return all.filter { $0.name == requestedFixture }
}

func ensureDirectories() throws {
    try FileManager.default.createDirectory(at: goldenDirectory, withIntermediateDirectories: true)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

// MARK: - Commands

func generateFixtures() throws {
    try ensureDirectories()
    let encoder = FixtureCoder.makeFixtureEncoder()
    for fixture in selectedFixtures() {
        let data = try encoder.encode(fixture)
        try data.write(to: fixtureURL(fixture.name), options: .atomic)
        print("wrote Fixtures/\(fixture.name).json  (\(fixture.inputs.count) samples, \(data.count) bytes)")
    }
}

func describe(_ golden: EngineGolden) -> String {
    "\(golden.zoneTimeline.count) zone spans, \(golden.alerts.count) alerts, "
        + "\(golden.transitions.count) transitions, \(Int(golden.finalCumulativeDistance)) m"
}

func verifyGoldens() throws -> Bool {
    try ensureDirectories()
    let encoder = FixtureCoder.makeEncoder()
    let decoder = FixtureCoder.makeDecoder()
    var allMatched = true

    for fixture in selectedFixtures() {
        let result = FixtureReplay.run(fixture)
        let url = goldenURL(fixture.name)

        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try decoder.decode(EngineGolden.self, from: Data(contentsOf: url))
            if existing == result.golden {
                print("ok      \(pad(fixture.name, 24)) \(describe(result.golden))")
                continue
            }
            allMatched = false
            print("CHANGED \(fixture.name)")
            print("        was: \(describe(existing))")
            print("        now: \(describe(result.golden))")
            if !updateGoldens {
                print("        run with --update-goldens to accept, and justify it in the PR body")
                continue
            }
        } else {
            allMatched = false
            print("NEW     \(pad(fixture.name, 24)) \(describe(result.golden))")
            if !updateGoldens {
                print("        run with --update-goldens to create")
                continue
            }
        }

        try encoder.encode(result.golden).write(to: url, options: .atomic)
        print("        wrote Fixtures/golden/\(fixture.name).golden.json")
    }

    return allMatched
}

func printTimeline() {
    for fixture in selectedFixtures() {
        let result = FixtureReplay.run(fixture)
        print("=== \(fixture.name) ===")
        print(fixture.describes)
        print("run type: \(fixture.runType.rawValue), \(fixture.inputs.count) samples")
        print("")
        print("zone timeline:")
        for span in result.golden.zoneTimeline {
            print("  \(pad(ORFormat.duration(span.startSeconds), 8)) \(pad("\(span.zone)", 14)) \(Int(span.durationSeconds))s")
        }
        print("")
        print("alerts: \(result.golden.alerts.count)")
        for alert in result.golden.alerts {
            print("  \(pad(ORFormat.duration(alert.atSeconds), 8)) \(alert.kind)")
        }
        print("")
        print("transitions: \(result.golden.transitions.count)")
        for transition in result.golden.transitions {
            let mode = transition.wasAutomatic ? "auto  " : "manual"
            let to = transition.toIndex.map(String.init) ?? "end"
            print("  \(pad(ORFormat.duration(transition.atSeconds), 8)) \(mode) "
                + "step \(transition.fromIndex) -> \(to)  "
                + "\(Int(transition.completedDistanceMetres)) m")
        }
        print("")
    }
}

// MARK: - Entry point

do {
    switch command {
    case "generate":
        try generateFixtures()
    case "verify":
        let matched = try verifyGoldens()
        if !matched && !updateGoldens {
            print("")
            print("Goldens differ. This is either a real regression or an intended change.")
            exit(1)
        }
    case "timeline":
        printTimeline()
    default:
        print("""
        ORReplay — golden fixture harness

        USAGE
          generate                       regenerate Fixtures/*.json from the generator
          verify [--update-goldens]      replay fixtures and compare against goldens
          timeline [--fixture <name>]    print the zone/alert/transition timeline

        OPTIONS
          --fixture <name>               restrict to one fixture
          --update-goldens               accept differences and rewrite goldens
        """)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
