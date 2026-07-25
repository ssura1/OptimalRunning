import Foundation

// MARK: - Activity kind

/// What kind of run a feed is being started for.
///
/// Distinct from `RunType`: that is a *training* classification (tempo, easy, VO2
/// max) and drives targets and colouring; this is a *sensor* classification and
/// drives which hardware is used. An indoor tempo run and an indoor VO2 max session
/// configure the sensors identically.
public enum RunActivityKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// GPS on, altimeter on, grade adjustment possible.
    case outdoorRun
    /// No GPS fix expected: pedometer distance, and grade adjustment disabled
    /// rather than assumed flat (DEG-10).
    case indoorRun
}

// MARK: - The sensor seam

/// What `Core` needs from a device in order to judge a run (design.md §8).
///
/// This declaration is the whole of ADR-002's load-bearing surface. Each watch tier
/// has its own sensor code with nothing shared between them, so the *only* thing
/// making their behaviour comparable is that both satisfy this one protocol and both
/// emit the same `EngineInput` stream. AC-FR-K-1-2's tier-equivalence test is
/// meaningful precisely because the protocol is declared once, here, rather than
/// twice in two app targets that could drift apart without anything noticing.
///
/// Note what is deliberately absent: no fusion, no smoothing, no zone, no alert. An
/// adapter's entire job is to answer "where is the runner, how fast, how high, how
/// hard" once per second in `Core`'s own value types. Everything that constitutes a
/// judgement happens in `RunEngine`, on the far side of `EngineInput`.
///
/// **On the `@MainActor` isolation.** design.md §8 sketches this protocol without an
/// isolation annotation, which does not survive Swift 6's strict concurrency checking:
/// `stop()` is `async` on a non-`Sendable` class-bound protocol, so any caller that is
/// itself isolated would be sending a non-`Sendable` value across domains. Of the ways
/// to resolve that, main-actor isolation is the one that matches reality — a feed is
/// owned for the lifetime of a run screen, the watchOS APIs behind it deliver on the
/// main queue already, and it makes each tick an ordered synchronous call rather than
/// an enqueued one. That ordering is not cosmetic: `ActiveClock` credits a full
/// interval whenever two ticks arrive out of order, so unordered delivery would
/// inflate active time.
@MainActor
public protocol RunSensorFeed: AnyObject {

    /// Invoked once per capture tick (1 Hz) with a fully-formed engine input —
    /// distance already fused across sources (design.md §8.2), so `Core` never
    /// learns which sensor produced it.
    var onSample: ((EngineInput) -> Void)? { get set }

    func start(activity: RunActivityKind) throws
    func pause()
    func resume()

    /// Stops the feed, releases every sensor, and returns the run's totals.
    ///
    /// Returning the summary from `stop` rather than exposing it as a property is
    /// what makes NFR-8 checkable: there is exactly one call that ends a session,
    /// so "did everything get torn down?" has exactly one place to be true.
    func stop() async throws -> RunSummary

    var capabilities: SensorCapabilities { get }
}
