// Summarizes `llvm-cov export -summary-only` JSON into a per-target coverage table and
// enforces the NFR-18 floor.
//
// Usage: llvm-cov export … | swift Tools/coverage-summarize.swift <targets-regex> <minimum> [source-root]
//
// `source-root` defaults to `Core/Sources`. It is a parameter because the standalone
// track's `PhoneMotion` is gated on the same terms (NFR-S-21) and lives at a different
// path; hardcoding it here would have meant a second copy of this file.
//
// **Swift, not Python.** This was Python until it turned out the `swift:6.1` container CI
// runs `Core` in has no `python3` at all — so the coverage gate had never actually
// executed in CI, and the local macOS run that "verified" it proved only that macOS ships
// Python. Swift is the one interpreter a Swift project can assume exists, and
// `Tools/check-traceability.swift` already established the pattern of running a Swift file
// directly. `JSONDecoder` also parses the report properly, where an awk or sed pass over
// JSON would be a second fragile thing to get wrong.

import Foundation

// MARK: - Report shape

/// Only the fields the gate reads. `llvm-cov`'s export carries far more per file —
/// functions, regions, branches, instantiations — and decoding just `lines` keeps this
/// insensitive to llvm version changes in the parts nobody here looks at.
private struct Report: Decodable {
    struct Datum: Decodable {
        struct File: Decodable {
            struct Summary: Decodable {
                struct Lines: Decodable {
                    let count: Int
                    let covered: Int
                }
                let lines: Lines
            }
            let filename: String
            let summary: Summary
        }
        let files: [File]
    }
    let data: [Datum]
}

// MARK: - Arguments

let arguments = Array(CommandLine.arguments.dropFirst())
guard (2...3).contains(arguments.count), let minimum = Double(arguments[1]) else {
    FileHandle.standardError.write(Data(
        "usage: coverage-summarize.swift <targets-regex> <minimum-percent> [source-root]\n".utf8
    ))
    exit(2)
}
let targetsPattern = arguments[0]
let sourceRoot = arguments.count == 3 ? arguments[2] : "Core/Sources"
/// What to call this package in the pass/fail line. Derived from the source root so the
/// message names the package actually being gated rather than always saying "Core",
/// which it did once a second package started using this script.
let label = sourceRoot.split(separator: "/").first.map(String.init) ?? sourceRoot

// MARK: - Input

let input = FileHandle.standardInput.readDataToEndOfFile()
guard !input.isEmpty else {
    print("::error::no coverage report on stdin — llvm-cov produced nothing")
    exit(1)
}

private let report: Report
do {
    report = try JSONDecoder().decode(Report.self, from: input)
} catch {
    print("::error::could not parse the llvm-cov report: \(error)")
    exit(1)
}

// MARK: - Aggregate

/// Matches `…/<source-root>/<target>/…`, capturing the target name, so a file is
/// attributed to whichever product module it lives in. Anything outside the source root —
/// test targets, the CLIs, package checkouts — never matches and is therefore never
/// counted.
let regex = try NSRegularExpression(
    pattern: "/" + sourceRoot + "/(" + targetsPattern + ")/")

var perTarget: [String: (covered: Int, total: Int)] = [:]
var covered = 0
var total = 0

for file in report.data.first?.files ?? [] {
    let range = NSRange(file.filename.startIndex..., in: file.filename)
    guard let match = regex.firstMatch(in: file.filename, range: range),
          let targetRange = Range(match.range(at: 1), in: file.filename)
    else { continue }

    let target = String(file.filename[targetRange])
    let lines = file.summary.lines

    covered += lines.covered
    total += lines.count
    let running = perTarget[target] ?? (0, 0)
    perTarget[target] = (running.covered + lines.covered, running.total + lines.count)
}

guard total > 0 else {
    print("::error::no product files under \(sourceRoot) in the coverage report "
        + "(targets: \(targetsPattern))")
    exit(1)
}

// MARK: - Report

func pad(_ text: String, to width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func padLeft(_ text: String, to width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

/// One decimal place, without `String(format:)` — its behaviour differs between the macOS
/// and Linux Foundations, and this script has to produce the same table on both.
func percentString(_ value: Double) -> String {
    let tenths = (value * 10).rounded()
    let whole = Int(tenths) / 10
    let fraction = abs(Int(tenths) % 10)
    return "\(whole).\(fraction)%"
}

let header = pad("target", to: 14) + padLeft("covered", to: 9)
    + padLeft("lines", to: 8) + padLeft("pct", to: 8)
print(header)

for target in perTarget.keys.sorted() {
    let row = perTarget[target]!
    let percent = row.total > 0 ? 100.0 * Double(row.covered) / Double(row.total) : 100.0
    print(
        pad(target, to: 14) + padLeft("\(row.covered)", to: 9)
            + padLeft("\(row.total)", to: 8) + padLeft(percentString(percent), to: 8)
    )
}

let percent = 100.0 * Double(covered) / Double(total)
print(String(repeating: "-", count: header.count))
print(
    pad("TOTAL", to: 14) + padLeft("\(covered)", to: 9)
        + padLeft("\(total)", to: 8) + padLeft(percentString(percent), to: 8)
)

let minimumLabel = "\(Int(minimum.rounded()))"
if percent < minimum {
    print(
        "::error::\(label) coverage \(percentString(percent)) is below the required "
            + "\(minimumLabel)% (NFR-18)"
    )
    exit(1)
}
print("ok: \(label) coverage \(percentString(percent)) meets the \(minimumLabel)% gate")
