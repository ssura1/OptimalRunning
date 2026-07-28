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

// MARK: - The standalone track
//
// A second, independent identifier space (docs/standalone/). It gets its own pass rather
// than being merged into the one above for two reasons: the two tracks must not be able
// to satisfy each other's requirements by accident, and a standalone document referring to
// a core requirement — which it does constantly, by design — must not be mistaken for a
// task covering it.

let standaloneDirectory = root.appendingPathComponent("docs/standalone")

func readStandalone(_ name: String) -> String? {
    try? String(
        contentsOf: standaloneDirectory.appendingPathComponent(name), encoding: .utf8)
}

if let standaloneRequirements = readStandalone("requirements.md"),
   let standaloneDesign = readStandalone("design.md"),
   let standaloneImplementation = readStandalone("implementation.md")
{
    // Mirrors the core pattern with the mandatory `S` segment. `FR-S-A-1` cannot collide
    // with `FR-A-1`: the core pattern requires a letter in A–K immediately after `FR-`,
    // and `S` is outside that range, so neither pattern can match the other's IDs.
    let standalonePattern =
        "\\b(?:AC-FR-S-[A-Z]-\\d+-\\d+|FR-S-[A-Z]-\\d+|NFR-S-\\d+|DEG-S-\\d+|CON-S-\\d+|R-S-\\d+)\\b"
    let standaloneRegex = try! NSRegularExpression(pattern: standalonePattern)

    func standaloneIDs(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..., in: text)
        return Set(standaloneRegex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }

    let sDefined = standaloneIDs(in: standaloneRequirements)
    let sCitedByTasks = standaloneIDs(in: standaloneImplementation)
    let sCitedByDesign = standaloneIDs(in: standaloneDesign)

    var standaloneFailures: [String] = []

    for orphan in sCitedByTasks.union(sCitedByDesign).subtracting(sDefined).sorted() {
        standaloneFailures.append(
            "cited but not defined in docs/standalone/requirements.md: \(orphan)")
    }

    // Risks are documented, not implemented, so they are not required to have a covering
    // task — the same reasoning that exempts AC-level identifiers in the core pass.
    func standaloneTopLevel(_ set: Set<String>) -> Set<String> {
        set.filter { id in
            id.hasPrefix("NFR-S-") || id.hasPrefix("DEG-S-") || id.hasPrefix("CON-S-")
                || (id.hasPrefix("FR-S-") && !id.hasPrefix("AC-"))
        }
    }

    for uncovered in standaloneTopLevel(sDefined).subtracting(sCitedByTasks).sorted() {
        standaloneFailures.append("defined but no standalone task satisfies it: \(uncovered)")
    }

    let standaloneTaskRegex = try! NSRegularExpression(
        pattern: "^### (S-\\d{3}) — ", options: .anchorsMatchLines)
    let standaloneRange = NSRange(
        standaloneImplementation.startIndex..., in: standaloneImplementation)
    let standaloneTaskCount = standaloneTaskRegex.numberOfMatches(
        in: standaloneImplementation, range: standaloneRange)

    if standaloneFailures.isEmpty {
        print("ok: standalone track — \(standaloneTopLevel(sDefined).count) top-level "
            + "requirements, \(sDefined.count) identifiers, \(standaloneTaskCount) tasks")
    } else {
        print("::error::standalone traceability check failed")
        for failure in standaloneFailures { print("  \(failure)") }
        exit(1)
    }
} else {
    // Absent rather than broken: the standalone track is a separate body of work and the
    // core gate must keep passing in a tree that does not have it.
    print("note: docs/standalone/ not present — standalone traceability skipped")
}
