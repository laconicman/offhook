import os
import SwiftUI

/// Offhook — the swift-pjsua bring-up / debug softphone.
///
/// Phase 0 goal: prove the stack runs end-to-end (start → register → echo call → audio).
/// The app owns the single ``PhoneModel`` (which owns the one ``PJSUA`` engine) as the
/// single source of truth and injects it into the view tree.
@main
struct OffhookApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        // Foreground/background in the log, so a push that arrives in the background is visible
        // as one.
        .onChange(of: scenePhase) { _, phase in
            Logger.app.notice("scene \(String(describing: phase), privacy: .public)")
        }
    }
}
