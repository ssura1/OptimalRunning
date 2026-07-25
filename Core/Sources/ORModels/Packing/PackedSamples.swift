import Foundation

/// Run samples stored as parallel binary columns rather than an array of structs
/// (ADR-007).
///
/// A 90-minute run is 5 400 samples. As database rows across 1 000 runs that is 5.4 M
/// rows that nothing ever queries individually — samples are always read as a whole
/// series to draw a chart. Columnar packing makes a run ~103 KB raw and lets the run
/// list query never page the blob in at all.
///
/// Compression is deliberately *not* applied here: Foundation's compression APIs are
/// Apple-only, and `Core` must build on Linux (ADR-001). The app layer gzips the
/// envelope on write. AC-FR-D-2-4's 1 MB budget is stated pre-compression, so it is
/// measurable against this type directly.
///
/// Each column has a documented resolution; `PackedSamples` round-trips within that
/// resolution, not exactly. That trade is the entire point.
public struct PackedSamples: Codable, Sendable, Hashable {

    /// Number of samples in every column.
    public let count: Int
    /// Session-relative timestamp of the first sample, in seconds.
    public let startTimestamp: TimeInterval
    /// Nominal spacing between samples. 1.0 normally, 5.0 in low-power mode.
    public let intervalSeconds: Double

    /// Float32 metres.
    public let cumulativeDistance: Data
    /// Float32 seconds per metre. NaN encodes "undefined" — stationary, or the
    /// window has not filled.
    public let rollingPace: Data
    /// UInt8 bpm. 0 encodes "missing", which is unambiguous because a live runner
    /// never reads 0.
    public let heartRate: Data
    /// Float32 metres relative to session start.
    public let relativeAltitude: Data
    /// Int8, grade × 200. Resolution 0.5%; range ±0.635, far beyond the ±0.15 clamp.
    public let smoothedGrade: Data
    /// UInt8, (factor − 0.85) × 255. Resolution ≈0.004.
    public let gradeFactor: Data
    /// Float32 seconds per metre. NaN encodes "no target".
    public let effectiveTarget: Data
    /// UInt8 `PaceZone` raw value.
    public let zone: Data

    // MARK: Column encoding constants

    /// Offset subtracted before scaling the grade factor into a byte.
    public static let gradeFactorOffset: Double = 0.85
    public static let gradeFactorScale: Double = 255
    /// Grade is stored as `grade × gradeScale` in a signed byte.
    public static let gradeScale: Double = 200

    public static let gradeResolution: Double = 1 / gradeScale
    public static let gradeFactorResolution: Double = 1 / gradeFactorScale

    // MARK: Packing

    public init(samples: [RunSample], intervalSeconds: Double = 1.0) {
        self.count = samples.count
        self.startTimestamp = samples.first?.timestamp ?? 0
        self.intervalSeconds = intervalSeconds

        self.cumulativeDistance = PackedSamples.packFloats(samples.map { Float($0.cumulativeDistance) })
        self.rollingPace = PackedSamples.packFloats(
            samples.map { $0.rollingPace.map { p in Float(p.secondsPerMetre) } ?? Float.nan }
        )
        self.heartRate = Data(samples.map { sample in
            guard let hr = sample.heartRate, hr.isFinite, hr > 0 else { return UInt8(0) }
            return UInt8(min(max(hr.rounded(), 0), 255))
        })
        self.relativeAltitude = PackedSamples.packFloats(
            samples.map { Float($0.relativeAltitude ?? Double.nan) }
        )
        self.smoothedGrade = Data(samples.map { sample in
            let scaled = (sample.smoothedGrade * PackedSamples.gradeScale).rounded()
            return UInt8(bitPattern: Int8(min(max(scaled, -128), 127)))
        })
        self.gradeFactor = Data(samples.map { sample in
            let scaled = ((sample.gradeFactor.value - PackedSamples.gradeFactorOffset)
                * PackedSamples.gradeFactorScale).rounded()
            return UInt8(min(max(scaled, 0), 255))
        })
        self.effectiveTarget = PackedSamples.packFloats(
            samples.map { $0.effectiveTarget.map { p in Float(p.secondsPerMetre) } ?? Float.nan }
        )
        self.zone = Data(samples.map { UInt8($0.zone.rawValue) })
    }

    // MARK: Unpacking

    /// Rebuilds the sample series. Returns `nil` if any column length disagrees with
    /// `count`, which means the payload was truncated or corrupted in transit.
    public func unpack() -> [RunSample]? {
        guard let distances = PackedSamples.unpackFloats(cumulativeDistance, count: count),
              let paces = PackedSamples.unpackFloats(rollingPace, count: count),
              let altitudes = PackedSamples.unpackFloats(relativeAltitude, count: count),
              let targets = PackedSamples.unpackFloats(effectiveTarget, count: count),
              heartRate.count == count,
              smoothedGrade.count == count,
              gradeFactor.count == count,
              zone.count == count
        else { return nil }

        let hrBytes = Array(heartRate)
        let gradeBytes = Array(smoothedGrade)
        let factorBytes = Array(gradeFactor)
        let zoneBytes = Array(zone)

        return (0..<count).map { i in
            let factor = PaceRatio(
                value: Double(factorBytes[i]) / PackedSamples.gradeFactorScale
                    + PackedSamples.gradeFactorOffset
            )
            let effective = targets[i].isNaN
                ? nil : Pace(secondsPerMetre: Double(targets[i]))
            // The raw (pre-grade) target is recoverable rather than stored, because
            // effectiveTarget = rawTarget × gradeFactor. Storing both would be
            // redundant, and AC-FR-A-4-8 only requires that both be *available*.
            let raw = effective.map { Pace(secondsPerMetre: $0.secondsPerMetre / factor.value) }

            return RunSample(
                timestamp: startTimestamp + Double(i) * intervalSeconds,
                cumulativeDistance: Double(distances[i]),
                rollingPace: paces[i].isNaN ? nil : Pace(secondsPerMetre: Double(paces[i])),
                heartRate: hrBytes[i] == 0 ? nil : Double(hrBytes[i]),
                relativeAltitude: altitudes[i].isNaN ? nil : Double(altitudes[i]),
                smoothedGrade: Double(Int8(bitPattern: gradeBytes[i])) / PackedSamples.gradeScale,
                gradeFactor: factor,
                rawTarget: raw,
                effectiveTarget: effective,
                zone: PaceZone(rawValue: Int(zoneBytes[i])) ?? .neutral
            )
        }
    }

    /// Total bytes across all columns — the figure AC-FR-D-2-4 budgets.
    public var byteCount: Int {
        cumulativeDistance.count + rollingPace.count + heartRate.count
            + relativeAltitude.count + smoothedGrade.count + gradeFactor.count
            + effectiveTarget.count + zone.count
    }

    // MARK: Byte helpers

    /// Little-endian explicitly, so a run recorded on one architecture decodes
    /// identically on another.
    static func packFloats(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpackFloats(_ data: Data, count: Int) -> [Float]? {
        guard data.count == count * 4 else { return nil }
        let bytes = Array(data)
        return (0..<count).map { i in
            let o = i * 4
            let bits = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8
                | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
            return Float(bitPattern: UInt32(littleEndian: bits))
        }
    }
}
