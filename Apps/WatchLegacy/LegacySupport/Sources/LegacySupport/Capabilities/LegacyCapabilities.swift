import Foundation
import ORModels

/// What Series 3 hardware on watchOS 8 can actually do (T-063, design.md §8, §8.1).
///
/// Declared as a constant rather than probed at runtime, and that is the whole point of this
/// file: the Legacy target has exactly one hardware generation and one OS version behind it, so
/// every answer here is known at compile time. Probing would mean asking the system questions
/// whose answers cannot vary, and the natural way to write such a probe — "is this API
/// available?" — is precisely the `#available` conditional that CON-3, AC-FR-K-1-5 and
/// Tools/check-no-availability.sh exist to keep out of both watch targets.
///
/// Every field below is a claim about Series 3 specifically, so each one is justified:
///
/// - **`hasAltimeter: true`.** The barometric altimeter arrived *with* Series 3, so grade
///   adjustment is genuinely in scope for this tier. T-063 calls this out because the tempting
///   assumption is the opposite — that the oldest supported watch must be the least capable in
///   every respect — and acting on it would silently disable a feature the hardware supports.
///   `CMAltimeter.isRelativeAltitudeAvailable()` is still checked by the adapter before use,
///   because a *capability* being present is not the same as authorization being granted.
/// - **`hasGPS: true`.** Series 3 GPS models. The cellular/GPS split is not modelled here: a
///   GPS-less Series 3 would report no usable fixes, which the pipeline already handles through
///   `GPSAvailabilityTracker` and DEG-1 rather than through a capability flag.
/// - **`hasAlwaysOnDisplay: false`.** No AOD hardware before Series 5. This is the single
///   divergence with real user-visible consequences on this tier: the screen is fully *off*
///   between wrist raises, not dimmed, which is what makes the 500 ms wrist-raise-to-correct
///   -colour requirement (T-066, AC-FR-A-6-8) a Legacy-specific timing concern.
/// - **`supportsNativeActivitySegmentation: false`.** `HKWorkoutSession.beginNewActivity`
///   is watchOS 9+. This tier records interval boundaries as `HKWorkoutEvent(.segment)`
///   instead (design.md §8.1, AC-FR-D-1-6) — a genuine divergence, already in the matrix.
/// - **`supportsDoubleTap: false`.** Double Tap is Series 9+ hardware. Manual advance on this
///   tier is tap and crown detent only (T-069).
public enum LegacyCapabilities {

    /// The Series 3 capability set. One value, because there is one device family.
    public static let seriesThree = SensorCapabilities(
        hasAltimeter: true,
        hasGPS: true,
        hasAlwaysOnDisplay: false,
        supportsNativeActivitySegmentation: false,
        supportsDoubleTap: false
    )
}
