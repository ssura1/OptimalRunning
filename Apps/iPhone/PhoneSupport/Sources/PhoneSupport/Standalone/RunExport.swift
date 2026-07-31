import Foundation
import ORColor
import ORIntervals
import ORModels
import ORPace

/// A recorded run, in a form that can leave the phone (S-067).
///
/// **This exists so field testing produces evidence instead of screenshots.** A tester who
/// runs 2.8 measured miles and sees 2.88 on screen has found something worth investigating,
/// and the investigation needs the sample series, the calibration state, the degradation
/// flags and the estimated spans — none of which fit in a photograph of a phone.
///
/// ## The route is scrubbed, structurally
///
/// Every fix is reduced to metres east and north **of the run's own first fix**, using the
/// same transform as `Tools/scrub-trace.swift`. Everything an analysis needs survives —
/// track shape, turn radius, fix spacing, bearing change, total displacement — and the one
/// thing that does not survive is where the runner lives.
///
/// The scrubbing is not a flag on this type and there is no unscrubbed path to forget to
/// take. `ExportedFix` has no field that could hold a latitude, so an export that leaked
/// one would not compile. That is deliberate: this repository's privacy discipline exists
/// because absolute fixes were once committed and could not be taken back, and a
/// convenience option here would be the same mistake with a nicer interface.
public enum RunExport {

    /// The current shape of the exported document. Bumped when a field is removed or
    /// changes meaning, so a file found on disk months later can still be read correctly.
    public static let formatVersion = 1

    public static func data(for analysis: RunAnalysis, appVersion: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(analysis: analysis, appVersion: appVersion))
    }

    /// `run-2026-07-30-1848-easy.json` — sorts chronologically and says what it is without
    /// being opened.
    public static func filename(for analysis: RunAnalysis) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "run-\(formatter.string(from: analysis.startedAt))-\(analysis.runType.rawValue).json"
    }

    /// Writes the export to a temporary file and returns its URL, for `ShareLink`.
    public static func write(
        _ analysis: RunAnalysis, appVersion: String, into directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(filename(for: analysis))
        try data(for: analysis, appVersion: appVersion).write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Document

extension RunExport {

    struct Document: Encodable {
        let formatVersion: Int
        let appVersion: String
        let exportedAt: Date

        let runID: UUID
        let runType: String
        let deviceTier: String
        let startedAt: Date
        let isDegraded: Bool
        let degradations: [String]

        let summary: ExportedSummary
        let standalone: ExportedStandalone?
        let profile: ExportedProfile?
        let steps: [ExportedStep]
        let samples: [ExportedSample]
        let route: [ExportedFix]

        init(analysis: RunAnalysis, appVersion: String) {
            formatVersion = RunExport.formatVersion
            self.appVersion = appVersion
            exportedAt = Date()

            runID = analysis.runID
            runType = analysis.runType.rawValue
            deviceTier = analysis.deviceTier.rawValue
            startedAt = analysis.startedAt
            isDegraded = analysis.isDegraded
            degradations = analysis.degradations.map(\.rawValue)

            summary = ExportedSummary(analysis.summary)
            standalone = analysis.standalone.map(ExportedStandalone.init)
            profile = analysis.profile.map(ExportedProfile.init)
            steps = analysis.steps.map(ExportedStep.init)
            samples = analysis.samples.map(ExportedSample.init)
            route = ExportedFix.scrubbed(analysis.route)
        }
    }

    struct ExportedSummary: Encodable {
        let distanceMetres: Double
        let activeSeconds: Double
        let averagePaceSecondsPerKilometre: Double?
        let elevationGainMetres: Double
        let averageHeartRate: Double?
        let maxHeartRate: Double?

        init(_ summary: RunSummary) {
            distanceMetres = summary.distanceMetres
            activeSeconds = summary.activeSeconds
            // Seconds per kilometre rather than the runner's unit: an export is read by
            // whoever asks for it, and a number whose unit depends on a setting elsewhere in
            // the file is a number that will eventually be read wrong.
            averagePaceSecondsPerKilometre = summary.averagePace?.secondsPerKilometre
            elevationGainMetres = summary.elevationGainMetres
            averageHeartRate = summary.averageHeartRate
            maxHeartRate = summary.maxHeartRate
        }
    }

    /// The standalone tier's own record — the part a watch run has no equivalent of, and
    /// the part worth having when a distance looks wrong.
    struct ExportedStandalone: Encodable {
        let carryPosition: String
        let measuredMetres: Double
        let estimatedMetres: Double
        let measuredFraction: Double?
        let isLowerConfidence: Bool
        let stepCount: Int
        let averageCadenceStepsPerMinute: Double?
        let flags: [String]
        let calibrationObservations: Int
        let calibrationIsConverged: Bool
        let calibrationIsCalibrated: Bool
        let metresPerStepAtTypicalCadence: Double?
        /// Which stretches of the run had no GNSS, as `[start, end]` second pairs. The run
        /// length encoding it is stored in, not a re-derivation.
        let estimatedSpans: [[Double]]

        init(_ facts: StandaloneRunFacts) {
            carryPosition = facts.carryPosition.rawValue
            measuredMetres = facts.measuredMetres
            estimatedMetres = facts.estimatedMetres
            measuredFraction = facts.measuredFraction
            isLowerConfidence = facts.isLowerConfidence
            stepCount = facts.stepCount
            averageCadenceStepsPerMinute = facts.averageCadenceStepsPerMinute
            // Sorted, because `Set` has no order and an export that reshuffles its own
            // fields between runs cannot be diffed against the previous one.
            flags = facts.flags.map(\.rawValue).sorted()
            calibrationObservations = facts.calibration.observationCount
            calibrationIsConverged = facts.calibration.isConverged
            calibrationIsCalibrated = facts.calibration.isCalibrated
            metresPerStepAtTypicalCadence = facts.calibration.metresPerStepAtTypicalCadence
            estimatedSpans = facts.estimatedSpans.map { [$0.startSeconds, $0.endSeconds] }
        }
    }

    /// The profile as it was *at the time of the run*, which is what makes a pace judgement
    /// in the export reproducible after the runner has since changed their targets.
    ///
    /// Paces and height only. Cue preferences, palette and voice have no bearing on a
    /// number in this file, and an export should not carry settings it does not explain.
    struct ExportedProfile: Encodable {
        let tempoPaceSecondsPerKilometre: Double?
        let easyPaceSecondsPerKilometre: Double?
        let longPaceSecondsPerKilometre: Double?
        let heightMetres: Double?

        init(_ profile: RunnerProfile) {
            tempoPaceSecondsPerKilometre = profile.tempoPace?.secondsPerKilometre
            easyPaceSecondsPerKilometre = profile.easyPace?.secondsPerKilometre
            longPaceSecondsPerKilometre = profile.longPace?.secondsPerKilometre
            heightMetres = profile.heightMetres
        }
    }

    struct ExportedStep: Encodable {
        let index: Int
        let kind: String
        let repIndex: Int
        let distanceMetres: Double
        let activeSeconds: Double
        let averagePaceSecondsPerKilometre: Double?

        init(_ step: StepSummary) {
            index = step.index
            kind = step.kind.rawValue
            repIndex = step.repIndex
            distanceMetres = step.distanceMetres
            activeSeconds = step.activeSeconds
            averagePaceSecondsPerKilometre = step.averagePace?.secondsPerKilometre
        }
    }

    struct ExportedSample: Encodable {
        let t: Double
        let distanceMetres: Double
        let paceSecondsPerKilometre: Double?
        let targetSecondsPerKilometre: Double?
        let zone: String
        let heartRate: Double?
        let relativeAltitudeMetres: Double?
        let gradePercent: Double

        init(_ sample: RunSample) {
            t = sample.timestamp
            distanceMetres = sample.cumulativeDistance
            paceSecondsPerKilometre = sample.rollingPace?.secondsPerKilometre
            targetSecondsPerKilometre = sample.effectiveTarget?.secondsPerKilometre
            zone = ExportedSample.name(of: sample.zone)
            heartRate = sample.heartRate
            relativeAltitudeMetres = sample.relativeAltitude
            gradePercent = sample.smoothedGrade * 100
        }

        /// `PaceZone` is `Int`-raw because those numbers are persisted in packed sample
        /// columns, so its raw value is a storage detail rather than a name. Spelled out
        /// here so the export reads as words and so renaming a case is a deliberate
        /// change to this file rather than a silent change to every exported run.
        static func name(of zone: PaceZone) -> String {
            switch zone {
            case .tooFast: return "tooFast"
            case .slightlyFast: return "slightlyFast"
            case .onTarget: return "onTarget"
            case .slightlySlow: return "slightlySlow"
            case .tooSlow: return "tooSlow"
            case .neutral: return "neutral"
            }
        }
    }

    /// A GNSS fix with the origin removed. See the note on `RunExport`.
    struct ExportedFix: Encodable {
        let t: Double
        let eastMetres: Double
        let northMetres: Double
        let altitudeMetres: Double

        /// Metres per degree of latitude. The same single-constant approximation
        /// `Tools/scrub-trace.swift` uses — the two must agree, because traces and exports
        /// from the same run are compared against each other.
        private static let metresPerDegreeLatitude = 111_320.0

        static func scrubbed(_ route: [RoutePoint]) -> [ExportedFix] {
            guard let origin = route.first else { return [] }
            let metresPerDegreeLongitude =
                metresPerDegreeLatitude * cos(origin.latitude * .pi / 180)
            let start = origin.timestamp

            return route.map { point in
                ExportedFix(
                    t: round(point.timestamp - start, places: 3),
                    eastMetres: round(
                        (point.longitude - origin.longitude) * metresPerDegreeLongitude,
                        places: 3),
                    northMetres: round(
                        (point.latitude - origin.latitude) * metresPerDegreeLatitude,
                        places: 3),
                    altitudeMetres: point.altitudeMetres)
            }
        }

        /// Millimetres. Enough to preserve the track exactly at GNSS resolution, and short
        /// enough that the file stays readable.
        private static func round(_ value: Double, places: Int) -> Double {
            let scale = pow(10.0, Double(places))
            return (value * scale).rounded() / scale
        }
    }
}
