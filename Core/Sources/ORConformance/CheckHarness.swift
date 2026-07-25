import Foundation

/// A single assertion result. `nil` message means it passed.
public struct CheckResult: Sendable {
    public let name: String
    public let failure: String?

    public var passed: Bool { failure == nil }

    public init(name: String, failure: String?) {
        self.name = name
        self.failure = failure
    }
}

/// A named group of assertions covering one task or requirement.
public struct CheckSuite: Sendable {
    public let name: String
    /// The requirement IDs this suite defends, for traceability in output.
    public let covers: [String]
    public let results: [CheckResult]

    public init(name: String, covers: [String], results: [CheckResult]) {
        self.name = name
        self.covers = covers
        self.results = results
    }

    public var failures: [CheckResult] { results.filter { !$0.passed } }
    public var passed: Bool { failures.isEmpty }
}

/// Collects assertions inside a suite body.
///
/// Deliberately minimal: this is not a test framework, it is the small amount of
/// scaffolding needed to state the same assertions once and consume them from both a
/// plain executable and an XCTest wrapper.
public struct CheckCollector {
    private var results: [CheckResult] = []

    public init() {}

    public mutating func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        results.append(CheckResult(
            name: name,
            failure: condition ? nil : (detail().isEmpty ? "expectation failed" : detail())
        ))
    }

    public mutating func expectEqual<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        results.append(CheckResult(
            name: name,
            failure: actual == expected ? nil : "expected \(expected), got \(actual)"
        ))
    }

    public mutating func expectClose(
        _ name: String,
        _ actual: Double,
        _ expected: Double,
        accuracy: Double
    ) {
        let ok = actual.isFinite && expected.isFinite && abs(actual - expected) <= accuracy
        results.append(CheckResult(
            name: name,
            failure: ok ? nil : "expected \(expected) ± \(accuracy), got \(actual)"
        ))
    }

    public mutating func expectNil<T>(_ name: String, _ value: T?) {
        results.append(CheckResult(
            name: name,
            failure: value == nil ? nil : "expected nil, got \(String(describing: value!))"
        ))
    }

    public mutating func expectNotNil<T>(_ name: String, _ value: T?) {
        results.append(CheckResult(name: name, failure: value != nil ? nil : "expected non-nil"))
    }

    public func finish(_ name: String, covers: [String]) -> CheckSuite {
        CheckSuite(name: name, covers: covers, results: results)
    }
}

/// Builds a suite from a body that records assertions.
public func suite(_ name: String, covers: [String], _ body: (inout CheckCollector) -> Void) -> CheckSuite {
    var collector = CheckCollector()
    body(&collector)
    return collector.finish(name, covers: covers)
}
