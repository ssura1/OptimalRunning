import Charts
import MapKit
import SwiftUI
import ORColor
import ORModels
import PhoneSupport
import SwiftData

/// The run detail screen (T-056 … T-060, design.md §13.2).
///
/// Every number, series and flag comes from `RunAnalysis`, which is tested against Wave 1's
/// recorded fixtures end to end. This file decides only *layout* — which is why a degraded run
/// renders correctly here without a single `if` of its own: the analysis already reports what is
/// missing, and each section asks before drawing.
struct RunDetailView: View {

    let runID: UUID

    @Environment(\.modelContext) private var modelContext
    @State private var analysis: RunAnalysis?
    @State private var unit: UnitPreference = .miles
    @State private var palette: PaletteChoice = .standard
    @State private var axis: RunAnalysis.ChartAxis = .distance

    var body: some View {
        ScrollView {
            if let analysis {
                VStack(alignment: .leading, spacing: 24) {
                    SummarySection(analysis: analysis, unit: unit)

                    if analysis.isDegraded {
                        DegradedNotice(analysis: analysis)
                    }

                    // FR-S-E-2. Present only for a standalone run, which is the whole of
                    // what AC-FR-S-E-1-2 permits this screen to change: a watch run renders
                    // exactly as it did, because `analysis.standalone` is `nil` and every
                    // one of these asks first.
                    if analysis.showsDistanceProvenance {
                        ProvenanceSection(analysis: analysis)
                    }

                    if analysis.hasSamples {
                        PaceChartSection(analysis: analysis, unit: unit, axis: $axis)

                        if analysis.hasElevationData {
                            ElevationChartSection(analysis: analysis, unit: unit, axis: axis)
                        }

                        ZoneSection(analysis: analysis, palette: palette)
                        SplitsSection(analysis: analysis, unit: unit)

                        if analysis.isStructured {
                            RepSection(analysis: analysis, unit: unit)
                        }
                    }

                    if analysis.hasRoute {
                        RouteSection(analysis: analysis, palette: palette)
                    }
                }
                .padding()
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .navigationTitle(analysis.map { PhoneFormat.runType($0.runType) } ?? "Run")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func load() {
        guard let record = try? RunRepository(context: modelContext).record(for: runID) else {
            return
        }
        analysis = try? RunAnalysis(record: record)

        // The palette is the runner's *current* choice, unlike the band — a colour preference is
        // about how they read a chart today, whereas the band is a fact about the run.
        let profile = try? ProfileRepository(context: modelContext).profile()
        unit = profile?.units ?? .miles
        palette = profile?.palette ?? .standard
    }
}

// MARK: - Summary

private struct SummarySection: View {
    let analysis: RunAnalysis
    let unit: UnitPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(analysis.startedAt, format: .dateTime.weekday(.wide).day().month().year().hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                Metric("Distance", PhoneFormat.distance(analysis.summary.distanceMetres, unit: unit))
                Metric("Time", PhoneFormat.duration(analysis.summary.activeSeconds))
                Metric("Avg pace", PhoneFormat.pace(analysis.summary.averagePace, unit: unit))
                Metric("Avg HR", PhoneFormat.heartRate(analysis.summary.averageHeartRate))
                Metric("Max HR", PhoneFormat.heartRate(analysis.summary.maxHeartRate))
                Metric("Climb", "\(Int(analysis.summary.elevationGainMetres.rounded())) m")
            }
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Where a standalone run's distance came from (S-034, FR-S-E-2).
///
/// **Provenance is visible, not hidden.** The whole reason this tier is honest is that it
/// can say which metres it observed and which it inferred — and a screen that showed one
/// distance without saying which was which would be claiming GNSS precision for a modelled
/// number. Every string comes from `RunAnalysis`, which reads what the run *stored*: a run
/// is not re-derived when calibration later improves (AC-FR-S-E-2-5).
private struct ProvenanceSection: View {
    let analysis: RunAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Phone run", systemImage: "iphone.gen3")
                .font(.headline)

            if let fraction = analysis.standalone?.measuredFraction {
                // A bar rather than only a sentence: the split is a proportion, and a
                // proportion is read faster as a length than as a percentage.
                ProgressView(value: fraction)
                    .tint(.green)
                    .accessibilityLabel("Measured by GPS")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            }

            if let text = analysis.distanceProvenanceText {
                Text(text).font(.caption).foregroundStyle(.secondary)
            }

            if let cadence = analysis.averageCadenceText {
                // AC-FR-S-E-2-2 — first-class, because on this tier it is measured rather
                // than derived.
                LabeledContent("Average cadence") { Text(cadence).monospacedDigit() }
                    .font(.subheadline)
            }

            if let reason = analysis.lowerConfidenceReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(analysis.motionNotices, id: \.self) { notice in
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// T-051 — the detail view states what is missing rather than rendering empty charts.
private struct DegradedNotice: View {
    let analysis: RunAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Partial data", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text(
                "This run was rebuilt from Health because its full data never arrived from the "
                    + "watch. Distance, time, and heart rate are correct. Pace zones, the target "
                    + "band, elevation, and splits are not available for it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - T-056: pace and heart rate

private struct PaceChartSection: View {
    let analysis: RunAnalysis
    let unit: UnitPreference
    @Binding var axis: RunAnalysis.ChartAxis

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pace").font(.headline)
                Spacer()
                // AC-FR-F-2-9 — the distance/time axis toggle.
                Picker("Axis", selection: $axis) {
                    Text("Distance").tag(RunAnalysis.ChartAxis.distance)
                    Text("Time").tag(RunAnalysis.ChartAxis.time)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            let series = analysis.paceSeries(axis: axis, unit: unit)

            Chart {
                // The band as a shaded region built from the run's own configuration snapshot
                // (AC-FR-F-2-1) — never today's settings.
                ForEach(Array(zip(series.bandFast, series.bandSlow)), id: \.0.x) { fast, slow in
                    AreaMark(
                        x: .value("x", fast.x),
                        yStart: .value("Fast", fast.y),
                        yEnd: .value("Slow", slow.y)
                    )
                    .foregroundStyle(.green.opacity(0.15))
                }

                ForEach(series.target, id: \.x) { point in
                    LineMark(x: .value("x", point.x), y: .value("Target", point.y))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }

                ForEach(series.pace, id: \.x) { point in
                    LineMark(x: .value("x", point.x), y: .value("Pace", point.y))
                        .foregroundStyle(.blue)
                }
            }
            // Pace charts read fastest at the top, which is the inverse of the numeric order:
            // a *lower* seconds-per-mile is a faster run.
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .frame(height: 220)
            .accessibilityLabel("Pace over \(axis == .distance ? "distance" : "time")")
            .accessibilityChartDescriptor(PaceChartDescriptor(series: series, unit: unit))

            if !series.heartRate.isEmpty {
                Text("Heart rate").font(.headline).padding(.top, 8)
                Chart(series.heartRate, id: \.x) { point in
                    LineMark(x: .value("x", point.x), y: .value("bpm", point.y))
                        .foregroundStyle(.red)
                }
                .frame(height: 120)
                .accessibilityLabel("Heart rate over \(axis == .distance ? "distance" : "time")")
            }
        }
    }
}

/// VoiceOver reads the underlying values, not just "a chart" (AC-FR-F-2-2).
private struct PaceChartDescriptor: AXChartDescriptorRepresentable {
    let series: RunAnalysis.PaceSeries
    let unit: UnitPreference

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXNumericDataAxisDescriptor(
            title: series.axis == .distance ? "Distance" : "Time",
            range: (series.pace.first?.x ?? 0)...(series.pace.last?.x ?? 1),
            gridlinePositions: []
        ) { value in
            series.axis == .distance
                ? PhoneFormat.distance(value, unit: unit)
                : PhoneFormat.duration(value)
        }

        let values = series.pace.map(\.y)
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Pace",
            range: (values.min() ?? 0)...(values.max() ?? 1),
            gridlinePositions: []
        ) { value in
            ORFormat.duration(value) + " per " + PhoneFormat.unitName(unit)
        }

        return AXChartDescriptor(
            title: "Pace",
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [
                AXDataSeriesDescriptor(
                    name: "Pace",
                    isContinuous: true,
                    dataPoints: series.pace.map { AXDataPoint(x: $0.x, y: $0.y) }
                ),
            ]
        )
    }
}

// MARK: - T-057: elevation

private struct ElevationChartSection: View {
    let analysis: RunAnalysis
    let unit: UnitPreference
    let axis: RunAnalysis.ChartAxis

    var body: some View {
        let series = analysis.elevationSeries(axis: axis, unit: unit)

        VStack(alignment: .leading, spacing: 8) {
            Text("Elevation").font(.headline)

            Chart {
                ForEach(series.elevation, id: \.x) { point in
                    AreaMark(x: .value("x", point.x), y: .value("Elevation", point.y))
                        .foregroundStyle(.brown.opacity(0.3))
                }
            }
            .frame(height: 140)
            .accessibilityLabel("Elevation profile")

            // The overlay appears only where grade actually moved the target (AC-FR-A-4-8) —
            // otherwise the two curves would sit on top of each other and imply an adjustment
            // that never happened.
            if analysis.hasGradeAdjustment {
                Text("Target, adjusted for grade").font(.headline).padding(.top, 4)
                Chart {
                    ForEach(series.rawTarget, id: \.x) { point in
                        LineMark(
                            x: .value("x", point.x), y: .value("Target", point.y),
                            series: .value("Series", "Prescribed")
                        )
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    ForEach(series.adjustedTarget, id: \.x) { point in
                        LineMark(
                            x: .value("x", point.x), y: .value("Adjusted", point.y),
                            series: .value("Series", "Adjusted for grade")
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false, reversed: true))
                .chartForegroundStyleScale([
                    "Prescribed": Color.secondary, "Adjusted for grade": Color.orange,
                ])
                .frame(height: 140)
                .accessibilityLabel("Prescribed target compared with the grade-adjusted target")
            }
        }
    }
}

// MARK: - T-058: time in zone

private struct ZoneSection: View {
    let analysis: RunAnalysis
    let palette: PaletteChoice

    var body: some View {
        let shares = analysis.zoneShares().filter { $0.seconds > 0 }

        VStack(alignment: .leading, spacing: 8) {
            Text("Time in zone").font(.headline)

            Chart(shares, id: \.zone) { share in
                BarMark(x: .value("Share", share.percentage))
                    .foregroundStyle(Color.zone(share.zone, palette: palette))
            }
            .chartXScale(domain: 0...100)
            .frame(height: 44)
            .accessibilityHidden(true)   // the table below is the accessible representation

            // The table is what VoiceOver navigates (AC-FR-F-2-4), and it carries the glyph so the
            // zones are distinguishable without colour.
            VStack(spacing: 4) {
                ForEach(shares, id: \.zone) { share in
                    HStack {
                        Image(systemName: ZoneLabels.symbol(share.zone))
                            .foregroundStyle(Color.zone(share.zone, palette: palette))
                            .frame(width: 20)
                        Text(ZoneLabels.name(share.zone))
                        Spacer()
                        Text(PhoneFormat.duration(share.seconds)).monospacedDigit()
                        Text("\(share.percentage, specifier: "%.1f")%")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(ZoneLabels.name(share.zone)): "
                            + "\(PhoneFormat.duration(share.seconds)), "
                            + String(format: "%.1f percent", share.percentage)
                    )
                }
            }
        }
    }
}

// MARK: - T-059: splits and reps

private struct SplitsSection: View {
    let analysis: RunAnalysis
    let unit: UnitPreference

    var body: some View {
        let splits = analysis.splits(unit: unit)

        VStack(alignment: .leading, spacing: 8) {
            Text("Splits").font(.headline)

            ForEach(splits, id: \.number) { split in
                HStack {
                    Text("\(split.number)")
                        .frame(width: 28, alignment: .leading)
                        .foregroundStyle(.secondary)
                    if split.isPartial {
                        // Labelled, never presented as a full split that happened to be quick
                        // (AC-FR-F-2-5).
                        Text("partial")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text(PhoneFormat.pace(split.averagePace, unit: unit)).monospacedDigit()
                    Text(PhoneFormat.duration(split.activeSeconds))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Split \(split.number)\(split.isPartial ? ", partial" : ""): "
                        + "\(PhoneFormat.pace(split.averagePace, unit: unit)), "
                        + PhoneFormat.duration(split.activeSeconds)
                )
            }
        }
    }
}

private struct RepSection: View {
    let analysis: RunAnalysis
    let unit: UnitPreference

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workout steps").font(.headline)

            ForEach(analysis.repRows(), id: \.step.index) { row in
                HStack {
                    Text(row.label)
                        .font(.caption.weight(.semibold))
                        .frame(width: 110, alignment: .leading)
                    if row.isPartial {
                        Text("cut short")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(row.step.distanceMetres.rounded())) m").monospacedDigit()
                    Text(PhoneFormat.duration(row.step.activeSeconds))
                        .monospacedDigit()
                        .frame(width: 58, alignment: .trailing)
                    Text(PhoneFormat.pace(row.step.averagePace, unit: unit))
                        .monospacedDigit()
                        .frame(width: 84, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - T-060: route

private struct RouteSection: View {
    let analysis: RunAnalysis
    let palette: PaletteChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Route").font(.headline)

            Map {
                // One polyline per zone-coloured segment (AC-FR-F-2-7). Drawn as segments rather
                // than one line because the colour changes along it.
                ForEach(Array(analysis.routeSegments().enumerated()), id: \.offset) { _, segment in
                    MapPolyline(coordinates: [
                        CLLocationCoordinate2D(
                            latitude: segment.from.latitude, longitude: segment.from.longitude
                        ),
                        CLLocationCoordinate2D(
                            latitude: segment.to.latitude, longitude: segment.to.longitude
                        ),
                    ])
                    .stroke(Color.zone(segment.zone, palette: palette), lineWidth: 4)
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // NFR-17 — the route is the most sensitive thing here and is never included in a
            // diagnostic export. There is no export path that reads this view's data.
            .accessibilityLabel("Route map, coloured by pace zone")
        }
    }
}
