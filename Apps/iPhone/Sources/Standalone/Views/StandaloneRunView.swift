import ORColor
import ORModels
import PhoneSupport
import SwiftUI

/// The live run screen — the **tertiary** channel (S-044, FR-S-D-3, design.md §9.4).
///
/// Every decision this screen makes was already made in `StandaloneMetricsScreen`, which is
/// a value type tested without a simulator. This file decides only layout, which is why
/// there is not a single `if` here about zones, degradation or run type: the screen model
/// already resolved them, and a second resolution here would be a second place they could
/// be resolved differently.
///
/// The proportions are the one thing that is genuinely a phone decision. The primary metric
/// is far larger than the watch's equivalent because AC-FR-S-D-3-3 asks for legibility at
/// arm's length in motion — and because on this tier a glance is expensive enough
/// (CON-S-6) that it should return an answer immediately or not be worth taking.
struct StandaloneRunView: View {

    @Bindable var controller: StandaloneRunController
    let onFinish: (RunEnvelope?) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var isEnding = false
    @State private var showEndConfirmation = false

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            if let screen = controller.screen {
                content(screen)
            } else {
                // Before the first tick there is nothing measured to show. A spinner over
                // the neutral swatch, rather than zeros — a zero pace is a claim.
                ProgressView().tint(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.requestManualAdvance() }
        .statusBarHidden()
        // AC-FR-S-D-3-5 — the screen stays awake while this view is up, and the system
        // idle timer is restored when it is not. Set in both directions here rather than
        // in the run controller, because the requirement is about *this screen being
        // foregrounded*, not about the run: a run continues with the phone locked, and it
        // should.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog(
            "End this run?", isPresented: $showEndConfirmation, titleVisibility: .visible
        ) {
            Button("End run", role: .destructive) { end() }
            Button("Keep running", role: .cancel) {}
        }
        .onChange(of: controller.didCompleteWorkout) { _, completed in
            // The plan ran out. Ending automatically rather than waiting for a tap is the
            // point of the audio-first design: the runner has already been told "workout
            // complete" and should not have to find the phone to make it true.
            if completed { end() }
        }
    }

    // MARK: - Layout

    private var background: Color {
        guard let screen = controller.screen else { return .black }
        return Color(screen.background)
    }

    private func content(_ screen: StandaloneMetricsScreen) -> some View {
        VStack(spacing: 0) {
            header(screen)

            Spacer(minLength: 0)

            // The one metric sized for arm's length. `.monospacedDigit` so the layout does
            // not shuffle as digits change width — AC-FR-S-D-3-3's "glance targets do not
            // move" applies within a number as well as between fields.
            VStack(spacing: 4) {
                Text(screen.primaryMetricText)
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(screen.isTimedOnly ? screen.primaryMetricCaption : screen.paceSuffix)
                    .font(.title3.weight(.medium))
                    .opacity(0.75)
            }

            if let delta = screen.signedDeltaText {
                HStack(spacing: 10) {
                    Image(systemName: screen.glyphSymbolName)
                        .font(.system(size: 34, weight: .bold))
                    Text(delta)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .padding(.top, 12)
            } else {
                // Reserved space, not a conditional layout: without this the metric stack
                // jumps every time the runner crosses into or out of the on-target zone,
                // which is the exact moment they are most likely to be looking.
                Color.clear.frame(height: 58).padding(.top, 12)
            }

            Text(screen.zoneCaption)
                .font(.headline.weight(.semibold))
                .opacity(0.8)
                .padding(.top, 6)

            Spacer(minLength: 0)

            metrics(screen)
            controls
        }
        .foregroundStyle(Color(screen.textColour))
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func header(_ screen: StandaloneMetricsScreen) -> some View {
        VStack(spacing: 6) {
            if let step = screen.stepHeaderText {
                Text(step)
                    .font(.subheadline.weight(.bold))
                    .textCase(.uppercase)
                    .opacity(screen.isCountingDown ? 1 : 0.85)
            }
            if let notice = screen.statusNotice {
                Text(notice)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.top, 12)
        .frame(minHeight: 44)
    }

    private func metrics(_ screen: StandaloneMetricsScreen) -> some View {
        HStack(alignment: .top, spacing: 0) {
            metric("Time", screen.elapsedText)
            metric("Distance", screen.distanceText, suffix: screen.distanceSuffix)
            metric("Avg", screen.averagePaceText, suffix: screen.paceSuffix)
            // Cadence is first-class on this tier because it is directly measured rather
            // than derived (AC-FR-S-E-2-2) — the one metric the watch does not show here.
            metric("Cadence", screen.cadenceText, suffix: "spm")
        }
        .padding(.vertical, 18)
    }

    private func metric(_ caption: String, _ value: String, suffix: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(suffix.map { "\(caption) \($0)" } ?? caption)
                .font(.caption2)
                .opacity(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                Task {
                    if controller.phase == .paused {
                        await controller.resume()
                    } else {
                        await controller.pause()
                    }
                }
            } label: {
                Label(
                    controller.phase == .paused ? "Resume" : "Pause",
                    systemImage: controller.phase == .paused ? "play.fill" : "pause.fill"
                )
                .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.bordered)

            Button {
                showEndConfirmation = true
            } label: {
                Label("End", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.bordered)
            .disabled(isEnding)
        }
        .tint(.white)
        .labelStyle(.titleAndIcon)
    }

    private func end() {
        guard !isEnding else { return }
        isEnding = true
        Task {
            let envelope = try? await controller.end()
            onFinish(envelope)
        }
    }
}
