import Foundation

/// Reduces a series for charting while preserving its visible shape (AC-FR-F-2-8).
///
/// Largest-Triangle-Three-Buckets rather than naive decimation. Taking every *n*-th
/// point silently deletes peaks and troughs — a runner's one badly-paced kilometre
/// would vanish from the chart it exists to show. LTTB keeps whichever point in each
/// bucket forms the largest triangle with its neighbours, which is a good proxy for
/// visual significance.
public enum Downsample {

    /// - Parameters:
    ///   - x: monotonically increasing axis values, typically distance or time.
    ///   - y: matching values. NaN entries are treated as gaps and never selected.
    ///   - threshold: maximum output length. Values below 3 return the endpoints.
    /// - Returns: indices into the original series, ascending. First and last are
    ///   always included so the chart's extent never changes.
    public static func largestTriangleThreeBuckets(
        x: [Double],
        y: [Double],
        threshold: Int
    ) -> [Int] {
        let count = min(x.count, y.count)
        guard count > 0 else { return [] }
        guard threshold >= 3 else { return count == 1 ? [0] : [0, count - 1] }
        guard count > threshold else { return Array(0..<count) }

        var selected: [Int] = [0]
        // Two buckets are reserved for the fixed first and last points.
        let bucketSize = Double(count - 2) / Double(threshold - 2)
        var previous = 0

        for bucket in 0..<(threshold - 2) {
            let currentStart = Int(Double(bucket) * bucketSize) + 1
            let currentEnd = min(Int(Double(bucket + 1) * bucketSize) + 1, count - 1)
            let nextStart = currentEnd
            let nextEnd = min(Int(Double(bucket + 2) * bucketSize) + 1, count - 1)

            guard currentStart < currentEnd else { continue }

            // The next bucket's centroid forms the far vertex of the triangle.
            var avgX = 0.0
            var avgY = 0.0
            var avgCount = 0
            for index in nextStart..<max(nextEnd, nextStart + 1) where index < count {
                guard y[index].isFinite else { continue }
                avgX += x[index]
                avgY += y[index]
                avgCount += 1
            }
            if avgCount > 0 {
                avgX /= Double(avgCount)
                avgY /= Double(avgCount)
            } else {
                avgX = x[min(nextStart, count - 1)]
                avgY = 0
            }

            let px = x[previous]
            let py = y[previous].isFinite ? y[previous] : 0

            var bestIndex = currentStart
            var bestArea = -1.0
            for index in currentStart..<currentEnd {
                let cy = y[index].isFinite ? y[index] : 0
                let area = abs((px - avgX) * (cy - py) - (px - x[index]) * (avgY - py)) / 2
                if area > bestArea {
                    bestArea = area
                    bestIndex = index
                }
            }

            selected.append(bestIndex)
            previous = bestIndex
        }

        selected.append(count - 1)
        return selected
    }

    /// Convenience returning the reduced pairs directly.
    public static func reduce(
        x: [Double],
        y: [Double],
        threshold: Int
    ) -> [(x: Double, y: Double)] {
        largestTriangleThreeBuckets(x: x, y: y, threshold: threshold).map { (x[$0], y[$0]) }
    }
}
