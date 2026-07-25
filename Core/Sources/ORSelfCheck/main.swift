import Foundation
import ORConformance

// Runs the whole Core conformance suite without XCTest, so the engine is verifiable
// on any machine with a Swift toolchain:
//
//   swift run --package-path Core ORSelfCheck
//
// Exits non-zero on any failure, so it is usable as a CI step or a pre-commit hook.

let verbose = CommandLine.arguments.contains("--verbose")
let suites = Conformance.allSuites(goldenDirectory: Conformance.defaultGoldenDirectory)

var totalChecks = 0
var totalFailures = 0

for suite in suites {
    totalChecks += suite.results.count
    totalFailures += suite.failures.count

    let status = suite.passed ? "PASS" : "FAIL"
    let covers = suite.covers.isEmpty ? "" : "  [\(suite.covers.joined(separator: ", "))]"
    print("\(status)  \(suite.name)  \(suite.results.count) checks\(covers)")

    for failure in suite.failures {
        print("      ✗ \(failure.name): \(failure.failure ?? "failed")")
    }
    if verbose {
        for result in suite.results where result.passed {
            print("      ✓ \(result.name)")
        }
    }
}

print("")
print(String(repeating: "-", count: 60))
if totalFailures == 0 {
    print("\(suites.count) suites, \(totalChecks) checks — all passed")
} else {
    print("\(suites.count) suites, \(totalChecks) checks — \(totalFailures) FAILED")
}

exit(totalFailures == 0 ? 0 : 1)
