import SwiftUI
// `NowPlayingView` lives in the `_WatchKit_SwiftUI` cross-import overlay, which only
// materialises when both SwiftUI and WatchKit are imported.
import WatchKit
import ORModels
import WatchSupport

/// The paged run container (T-041, design.md §12.1).
///
/// ```
/// ◀ Controls  │  Metrics (default)  │  Now Playing ▶
/// ```
///
/// Mirrors the stock Workout app, which is what makes the End gesture safe and familiar
/// (CON-1, AC-FR-A-6-9). Metrics is the landing page; Controls is one deliberate swipe
/// right; Now Playing is the system's own view.
struct RunPagerView: View {

    @Bindable var model: RunSessionModel
    let configuration: PaceEngineConfiguration
    let onEnd: () -> Void

    private enum Page: Hashable { case controls, metrics, nowPlaying }

    @State private var page: Page = .metrics
    /// Crown rotation for opt-in manual step advance (AC-FR-C-3-3).
    @State private var crownAdvance: Double = 0

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TabView(selection: $page) {
            ControlsView(
                phase: model.phase,
                onPause: { Task { await model.pause() } },
                onResume: { Task { await model.resume() } },
                onEnd: onEnd,
                onLap: { model.requestManualAdvance() }
            )
            .tag(Page.controls)

            metricsPage
                .tag(Page.metrics)

            NowPlayingPage()
                .tag(Page.nowPlaying)
        }
        .tabViewStyle(.verticalPage)
        // The overlay sits above the pager, not inside a page: a warning or a transition
        // must be visible regardless of which page the runner happens to be on
        // (AC-FR-B-2-1), and a warning that only appeared on the metrics page would be
        // silently missed by anyone who left the pager on Controls.
        .overlay {
            if let presentation = model.presentation {
                AlertOverlayView(
                    presentation: presentation,
                    palette: model.profile.palette,
                    unit: model.profile.units,
                    onDismiss: { model.dismissPresentation() }
                )
                .transition(ORMotion.screenChange(configuration.presentation, reduceMotion: reduceMotion))
            }
        }
        // Kept in sync rather than read inside the screen builder, so a wrist raise
        // re-renders immediately instead of at the next 1 Hz tick.
        .onChange(of: isLuminanceReduced, initial: true) { _, dimmed in
            model.luminance = dimmed ? .dimmed : .normal
        }
    }

    @ViewBuilder
    private var metricsPage: some View {
        if let screen = model.screen, let output = model.output {
            ZStack {
                MetricsView(
                    screen: screen,
                    configuration: configuration.presentation,
                    tapAdvances: IntervalPresentation.tapAdvances(output.step),
                    onTap: { model.requestManualAdvance() }
                )

                if let countdown = IntervalPresentation.countdownText(for: output.step) {
                    CountdownOverlay(text: countdown, textColour: Color(screen.textColour))
                }

                if IntervalPresentation.showsUndo(output.step) {
                    VStack {
                        Spacer()
                        UndoAffordance { model.undoManualAdvance() }
                            .padding(.bottom, 2)
                    }
                }

                // VO2 max keeps the full stack plus step context (AC-FR-C-4-5). The
                // absence of colour is the model's decision, already made.
                if model.plan.runType == .vo2max, output.step.step != nil {
                    VStack {
                        Spacer()
                        VO2MaxStepStack(state: output.step, unit: model.profile.units)
                            .foregroundStyle(Color(screen.textColour))
                            .padding(.bottom, 2)
                    }
                }
            }
            // Tap and Double Tap both live on `MetricsView`'s advance button, which is
            // the only control on this page and therefore the only thing Double Tap can
            // bind to (T-095). There was a second `.onTapGesture` here as well, calling
            // the same already-gated method — harmless, and removed because two handlers
            // for one gesture is one more than can be reasoned about.
            //
            // The overlays above are siblings of that button rather than children of it,
            // which is what keeps the undo affordance an independently tappable control
            // instead of a button nested inside a button.
            //
            // Opt-in crown detent, per the runner's setting (AC-FR-C-3-3).
            .focusable(model.profile.crownAdvanceEnabled)
            .digitalCrownRotation(
                $crownAdvance,
                from: 0, through: 100, by: 1,
                sensitivity: .low,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
            .onChange(of: crownAdvance) { _, _ in
                guard model.profile.crownAdvanceEnabled else { return }
                model.requestManualAdvance()
            }
        } else {
            // Before the first tick. Not a spinner: a spinner suggests something might
            // fail, and this state lasts under a second.
            ProgressView()
        }
    }
}

/// The system's Now Playing view.
///
/// A real page rather than a placeholder because design.md §12.1 puts it in the pager,
/// and because a runner reaching for music mid-run should not leave the app.
private struct NowPlayingPage: View {
    var body: some View {
        NowPlayingView()
    }
}
