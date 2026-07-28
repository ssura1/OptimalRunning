import Foundation

/// The two orientation-invariant channels a hand-held phone can offer
/// (standalone/design.md §3.2).
///
/// The brief's hard problem is that a phone in a swinging hand changes attitude
/// continuously, which pocket-based dead-reckoning literature does not have to handle
/// the same way. Two things make it tractable:
///
/// **We only need distance, not position.** Classical PDR integrates step length along a
/// heading, and heading from a swinging hand is where most of that literature's
/// machinery goes. Here GNSS owns the route and the motion model owns a scalar, so
/// heading — and with it most of the problem — is simply discarded.
///
/// **Gravity is a body-fixed reference that arrives for free.** CoreMotion's attitude
/// filter supplies a gravity vector in the device frame; projecting user acceleration
/// onto it gives a vertical channel that does not care how the phone is held.
public struct OrientationResolver: Sendable {

    /// The resolved channels for one sample.
    public struct Channels: Sendable, Hashable {
        /// Gravity-projected vertical acceleration, m/s², positive **upward**.
        ///
        /// `nil` when the gravity vector is degenerate — see `Vector3.normalized` for
        /// why that is not silently treated as zero.
        public let vertical: Double?
        /// Magnitude of user acceleration, m/s².
        ///
        /// Orientation-invariant *without needing gravity at all*, which is the point:
        /// it is the channel that cannot be wrong for the one reason `vertical` can be.
        /// It conflates the arm swing with the footfall impact, so it is the worse
        /// channel for detection and the better one for cross-checking (design.md §4.4).
        public let magnitude: Double
    }

    public init() {}

    public func resolve(_ sample: MotionSample) -> Channels? {
        guard sample.userAcceleration.isFinite, sample.gravity.isFinite else { return nil }
        // Gravity points down, so the dot product of an upward acceleration with it is
        // negative. Negating puts "up" on the positive side, which is what every peak
        // convention downstream assumes and which is asserted by a named test rather
        // than left to this comment.
        let vertical = sample.gravity.normalized.map { -sample.userAcceleration.dot($0) }
        return Channels(vertical: vertical, magnitude: sample.userAcceleration.magnitude)
    }
}
