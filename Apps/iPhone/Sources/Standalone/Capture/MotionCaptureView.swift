import SwiftUI

/// The capture screen (S-006).
///
/// Deliberately plain. It is a developer tool whose only job is to be operable while
/// running — which drives every layout decision here: one enormous mark target, large
/// legible counters, and a stop control that cannot be hit by accident.
struct MotionCaptureView: View {
    @StateObject private var recorder = MotionCaptureRecorder()
    @AppStorage("standalone.runnerHeightMetres") private var runnerHeightMetres: Double = 0
    @State private var showingStopConfirmation = false

    var body: some View {
        List {
            if !recorder.canRecord {
                Section {
                    Label {
                        Text(
                            """
                            No motion sensors on this device. The iOS Simulator has no \
                            accelerometer and no gyroscope at all, and unlike GPS there is \
                            no route file that can stand in for them — this needs a real \
                            iPhone.
                            """)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    Text(recorder.availability)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if recorder.isRecording {
                recordingSection
            } else {
                setupSection
            }

            if let error = recorder.lastError {
                Section("Last error") {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }

            capturesSection
        }
        .navigationTitle("Motion Capture")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var setupSection: some View {
        Section {
            HStack {
                Text("Your height")
                Spacer()
                TextField(
                    "metres",
                    value: Binding(
                        get: { runnerHeightMetres > 0 ? runnerHeightMetres : 1.75 },
                        set: { runnerHeightMetres = $0 }),
                    format: .number.precision(.fractionLength(2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("m").foregroundStyle(.secondary)
            }
            Button {
                recorder.start(runnerHeightMetres: runnerHeightMetres > 0 ? runnerHeightMetres : nil)
            } label: {
                Label("Start capture", systemImage: "record.circle")
            }
            .disabled(!recorder.canRecord)
        } header: {
            Text("New capture")
        } footer: {
            Text(
                """
                Hold the phone in your hand as you normally would and do not change how \
                you carry it. Height is used by the step-length model. See \
                Tools/motion-recording-protocol.md for what to record and why.
                """)
        }
    }

    private var recordingSection: some View {
        Section("Recording") {
            LabeledContent("Elapsed", value: format(recorder.elapsed))
            LabeledContent("Motion samples", value: "\(recorder.motionSampleCount)")
            LabeledContent("Location fixes", value: "\(recorder.locationFixCount)")
            LabeledContent("Marks", value: "\(recorder.markCount)")

            // The one control that has to work at running pace, so it gets the whole row
            // and then some. A mark is information the runner cannot supply twice.
            Button {
                recorder.mark()
            } label: {
                Text("MARK")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets())

            Button(role: .destructive) {
                showingStopConfirmation = true
            } label: {
                Label("Stop capture", systemImage: "stop.circle")
            }
            .confirmationDialog(
                "Stop the capture?", isPresented: $showingStopConfirmation, titleVisibility: .visible
            ) {
                Button("Stop and save", role: .destructive) { recorder.stop() }
                Button("Keep recording", role: .cancel) {}
            }
        }
    }

    private var capturesSection: some View {
        Section {
            if recorder.captures.isEmpty {
                Text("No captures yet.").foregroundStyle(.secondary)
            } else {
                ForEach(recorder.captures, id: \.self) { url in
                    ShareLink(item: url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.footnote.monospaced())
                            Text(size(of: url)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { recorder.delete(recorder.captures[index]) }
                }
            }
        } header: {
            Text("Captures")
        } footer: {
            Text(
                """
                Tap to share a capture off the device — AirDrop to a Mac is the quickest. \
                They are also visible in the Files app under On My iPhone. The `.ndjson` \
                file is the raw stream and is kept alongside the assembled `.motion.json`; \
                it is what survives if the app is killed mid-capture.
                """)
        }
    }

    // MARK: - Formatting

    private func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func size(of url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
