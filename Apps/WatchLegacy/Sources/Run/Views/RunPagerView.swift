import SwiftUI
import ORModels
import LegacySupport

/// The run screen: metrics and controls as pages, with interruptions layered over — Legacy tier
/// (T-067, T-068, T-069).
///
/// `TabView(.page)` is available on watchOS 8, so the paged layout matches the Modern tier's shape.
/// What differs is what is *absent*: no always-on dimmed variants, and no Double Tap gesture.
struct RunPagerView: View {

    @ObservedObject var coordinator: AppCoordinator
    @State private var page = 0

    private var caseSize: LegacyCaseSize { LegacyDevice.caseSize }

    var body: some View {
        ZStack {
            TabView(selection: $page) {
                metricsPage.tag(0)
                ControlsView(coordinator: coordinator).tag(1)
            }
            .tabViewStyle(.page)

            // An interruption covers the pager entirely (FR-B-2). Layered rather than pushed so
            // dismissing it cannot lose the runner's page.
            if let alert = coordinator.run.alert {
                WarningView(alert: alert, caseSize: caseSize) {
                    coordinator.run.dismissAlert()
                }
                .transition(.opacity)
            }
        }
        // The screen is on or off on this hardware, never dimmed — so a pace warning raised while the
        // wrist is down is dropped rather than queued (AC-FR-B-2-5). watchOS 8 exposes no
        // `isLuminanceReduced`, so the app's own active state is the signal. See AlertPresenter.
        .onNotification(WKExtension.applicationDidBecomeActiveNotification) {
            coordinator.run.isScreenVisible = true
        }
        .onNotification(WKExtension.applicationWillResignActiveNotification) {
            coordinator.run.isScreenVisible = false
        }
    }

    @ViewBuilder private var metricsPage: some View {
        if let screen = coordinator.run.screen {
            ZStack {
                MetricsView(screen: screen, caseSize: caseSize)

                // The final-100 m countdown sits over the metrics (AC-FR-C-4-5).
                if screen.isCountingDown {
                    IntervalCountdownOverlay(screen: screen, caseSize: caseSize)
                }
            }
            // Tap to advance — but only where Core permits it, which is open-goal steps only
            // (AC-FR-C-3). A distance-goal rep ends when the distance is covered; a stray glove-tap
            // must not end it early. Crown detent is the other input; Series 3 has no Double Tap.
            .onTapGesture { coordinator.advanceStepIfPermitted() }
        } else {
            ProgressView()
        }
    }
}

/// The big countdown number over the final 100 m.
struct IntervalCountdownOverlay: View {

    let screen: MetricsScreen
    let caseSize: LegacyCaseSize

    var body: some View {
        VStack {
            Spacer()
            // Whole metres, no unit — context makes it obvious and the digits need every pixel,
            // which at 38 mm is not a figure of speech.
            Text(screen.countdownText ?? "")
                .font(LegacyTypography.countdown(caseSize))
                .foregroundColor(Color(screen.textColour))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Spacer()
        }
    }
}

/// A small helper so the lifecycle wiring above reads as one line per event.
///
/// Deliberately *not* named `onReceive`: an overload of that name taking a `Notification.Name` would
/// sit beside SwiftUI's publisher-based `onReceive`, and the body below calls that one — so sharing
/// the name invites an overload-resolution surprise that compiles into infinite recursion.
extension View {
    func onNotification(
        _ name: Notification.Name,
        perform action: @escaping () -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
    }
}
