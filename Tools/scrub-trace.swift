#!/usr/bin/env swift
// S-059 — strip absolute position from a motion trace before it is published.
//
// USAGE
//   swift Tools/scrub-trace.swift <input.motion.json> <output.motion.json>
//
// ## Why
//
// A trace recorded during a real run is a map of where its runner lives: a neighbourhood
// loop repeated six times is not anonymous data. This repository is public, and a trace was
// once committed to it with 276 absolute fixes intact (commit `ab44f40`, corrected in
// S-059). The tool exists so that "remember to strip it" is not the control.
//
// ## What is kept, and why that is enough
//
// Nothing in the estimator ever reads `latitude` or `longitude`. Distance reaches the fusion
// through `cumulativeDistanceMetres` and speed through `speedMetresPerSecond`; the
// coordinates rode along only because the capture tool happened to have them. So they are
// replaced by `eastMetres`/`northMetres` measured from the trace's **own first fix**, which
// preserves every quantity a distance or kinematics validation uses — displacement between
// fixes, track shape, bearing change, turn radius — while discarding the origin that would
// place any of it on a map.
//
// The conversion is a local tangent-plane approximation, which is exact enough by a wide
// margin at these distances: over a few kilometres its error is centimetres, against a GNSS
// horizontal accuracy of metres.
//
// ## Refusal
//
// The tool re-reads its own output and exits non-zero if a coordinate key survived, because
// a scrubber that silently half-works is worse than none: it produces a file that everyone
// downstream believes is safe.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("scrub-trace: " + message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    fail("usage: swift Tools/scrub-trace.swift <input.motion.json> <output.motion.json>")
}

let inputURL = URL(fileURLWithPath: arguments[0])
let outputURL = URL(fileURLWithPath: arguments[1])

guard let data = try? Data(contentsOf: inputURL) else { fail("cannot read \(arguments[0])") }
guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    fail("\(arguments[0]) is not a JSON object")
}

var locations = root["locations"] as? [[String: Any]] ?? []
var strippedCount = 0

if !locations.isEmpty {
    // The origin is the first fix that actually has coordinates. Using the trace's own
    // first fix rather than a fixed datum means the offsets say nothing about where the
    // trace was recorded, only about its shape.
    guard
        let origin = locations.first(where: { $0["latitude"] != nil && $0["longitude"] != nil }),
        let originLatitude = origin["latitude"] as? Double,
        let originLongitude = origin["longitude"] as? Double
    else {
        // Already scrubbed, or never carried coordinates. Copying through is correct.
        try? data.write(to: outputURL)
        print("scrub-trace: \(inputURL.lastPathComponent) carried no coordinates; copied as is")
        exit(0)
    }

    let metresPerDegreeLatitude = 111_320.0
    let metresPerDegreeLongitude = metresPerDegreeLatitude * cos(originLatitude * .pi / 180)

    for index in locations.indices {
        if let latitude = locations[index]["latitude"] as? Double,
            let longitude = locations[index]["longitude"] as? Double
        {
            locations[index]["northMetres"] =
                ((latitude - originLatitude) * metresPerDegreeLatitude * 1000).rounded() / 1000
            locations[index]["eastMetres"] =
                ((longitude - originLongitude) * metresPerDegreeLongitude * 1000).rounded() / 1000
            strippedCount += 1
        }
        locations[index].removeValue(forKey: "latitude")
        locations[index].removeValue(forKey: "longitude")
    }
    root["locations"] = locations
}

guard
    let output = try? JSONSerialization.data(
        withJSONObject: root, options: [.sortedKeys])
else { fail("cannot serialise the scrubbed trace") }

do { try output.write(to: outputURL) } catch { fail("cannot write \(arguments[1]): \(error)") }

// Verify rather than trust. A scrubber that silently half-works produces a file everyone
// downstream believes is safe.
guard let verifyData = try? Data(contentsOf: outputURL),
    let verifyRoot = (try? JSONSerialization.jsonObject(with: verifyData)) as? [String: Any]
else { fail("cannot re-read the output for verification") }

let verifyLocations = verifyRoot["locations"] as? [[String: Any]] ?? []
let survivors = verifyLocations.filter { $0["latitude"] != nil || $0["longitude"] != nil }
guard survivors.isEmpty else {
    fail("\(survivors.count) fixes still carry coordinates after scrubbing — refusing")
}

print(
    "scrub-trace: \(inputURL.lastPathComponent) -> \(outputURL.lastPathComponent), "
        + "\(strippedCount) fixes relativised, 0 absolute coordinates remain")
