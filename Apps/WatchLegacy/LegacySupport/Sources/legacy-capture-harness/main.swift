import Foundation
import ORModels
import LegacySupport

// A capture process that exists to be killed.
//
// `CrashRecoveryTests` needs to prove FR-D-6's bound — a crash mid-run loses at most
// `capture.flushIntervalSeconds` of samples — and the only honest way to prove it is to *crash*.
// Constructing a second `SampleStore` over the same directory and calling `detectOrphan` would
// exercise the recovery read but not durability: it leaves the writing process alive, its buffers
// flushed by ordinary means, and proves nothing about what survives an abrupt termination. So
// this target is a real executable the test launches and sends `SIGKILL` to. SIGKILL cannot be
// caught, blocked, or handled, and it skips `atexit`, buffer flushing, and any deinit — which is
// exactly the guarantee under test.
//
// Asserting `flushIntervalSeconds == 30` instead, as an earlier sketch of this test did, would
// have restated a constant from configuration and called it durability.
//
// Usage: legacy-capture-harness <directory> <runID> <sampleCount> <flushInterval>
//
// Writes one sample per simulated second, printing the count after each flush so the parent knows
// when a flush has definitely landed and can kill at a known point. Never calls `finalizeRun`:
// the run is meant to be interrupted, and the surviving `.inprogress` file is the artifact.

let arguments = CommandLine.arguments
guard arguments.count == 5,
      let runID = UUID(uuidString: arguments[2]),
      let sampleCount = Int(arguments[3]),
      let flushInterval = Double(arguments[4])
else {
    FileHandle.standardError.write(Data("usage: <dir> <runID> <count> <flushInterval>\n".utf8))
    exit(2)
}

let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let store = SampleStore(directory: directory)
store.startRun(runID: runID)

for second in 0..<sampleCount {
    let sample = RunSample(
        timestamp: Double(second),
        cumulativeDistance: Double(second) * 3,
        rollingPace: Pace(secondsPerMetre: 1.0 / 3.0),
        heartRate: 150,
        relativeAltitude: 0,
        smoothedGrade: 0,
        gradeFactor: .identity,
        rawTarget: nil,
        effectiveTarget: nil,
        zone: .onTarget
    )
    store.append(sample, flushIntervalSeconds: flushInterval)

    // Line-buffered progress the parent reads to synchronise the kill. Flushed explicitly
    // because stdout to a pipe is block-buffered, and a buffered "ready" the parent never sees
    // would make this test hang rather than fail.
    print("appended \(second + 1)")
    fflush(stdout)
}

// Reached only if the parent never killed us, which the test treats as a failure of its own
// setup rather than a pass.
print("completed-without-interruption")
fflush(stdout)
