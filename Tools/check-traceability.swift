#!/usr/bin/env swift
//
// Requirement ↔ task traceability gate (T-004, requirements.md §12).
//
//   swift Tools/check-traceability.swift
//
// Fails when either direction of the trace breaks:
//
//   * a P0 requirement exists that no task claims to satisfy — scope silently lost;
//   * a task cites a requirement ID that does not exist — usually a typo, which makes
//     the coverage report claim something it does not deliver.
//
// Both failure modes are invisible in review and obvious to a script.

import Foundation

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let docs = root.appendingPathComponent("docs")

func read(_ name: String) -> String {
    guard let text = try? String(contentsOf: docs.appendingPathComponent(name), encoding: .utf8) else {
        FileHandle.standardError.write(Data("error: cannot read docs/\(name)\n".utf8))
        exit(1)
    }
    return text
}

let requirements = read("requirements.md")
let design = read("design.md")
let implementation = read("implementation.md")

/// Matches every requirement identifier the project uses.
let idPattern = "\\b(?:AC-FR-[A-K]-\\d+-\\d+|FR-[A-K]-\\d+|NFR-\\d+|DEG-\\d+|CON-\\d+)\\b"
let regex = try! NSRegularExpression(pattern: idPattern)

func ids(in text: String) -> Set<String> {
    let range = NSRange(text.startIndex..., in: text)
    return Set(regex.matches(in: text, range: range).compactMap {
        Range($0.range, in: text).map { String(text[$0]) }
    })
}

let defined = ids(in: requirements)
let citedByTasks = ids(in: implementation)
let citedByDesign = ids(in: design)

var failures: [String] = []

// Direction 1: every task citation must name a real requirement.
for orphan in (citedByTasks.union(citedByDesign)).subtracting(defined).sorted() {
    failures.append("cited but not defined in requirements.md: \(orphan)")
}

// Direction 2: every top-level requirement must be covered by some task.
// AC-level identifiers are intentionally not required to be cited individually — a
// task that satisfies FR-A-1 covers its acceptance criteria.
func topLevel(_ set: Set<String>) -> Set<String> {
    set.filter { id in
        id.hasPrefix("NFR-") || id.hasPrefix("DEG-") || id.hasPrefix("CON-")
            || (id.hasPrefix("FR-") && !id.hasPrefix("AC-"))
    }
}

for uncovered in topLevel(defined).subtracting(citedByTasks).sorted() {
    failures.append("defined but no task satisfies it: \(uncovered)")
}

let taskRegex = try! NSRegularExpression(pattern: "^### (T-\\d{3}) — ", options: .anchorsMatchLines)
let taskRange = NSRange(implementation.startIndex..., in: implementation)
let taskCount = taskRegex.numberOfMatches(in: implementation, range: taskRange)

if failures.isEmpty {
    print("ok: \(topLevel(defined).count) top-level requirements, \(defined.count) identifiers, "
        + "\(taskCount) tasks — traceability intact")
} else {
    print("::error::traceability check failed")
    for failure in failures { print("  \(failure)") }
    exit(1)
}
