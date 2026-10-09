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
        // A softphone needs no tap to come up: the engine starts, and the saved accounts register,
        // once a scene is in the foreground. A VoIP push launch has no such scene; the push starts
        // the engine itself (`PhoneModel.wakeForPush`), after CallKit has the call.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Task { await model.startEngine() } }
        }
    }
}
