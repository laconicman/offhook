import SwiftUI

/// Offhook — the swift-pjsua bring-up / debug softphone.
///
/// Phase 0 goal: prove the stack runs end-to-end (start → register → echo call → audio).
/// The app owns the single ``PhoneModel`` (which owns the one ``PJSUA`` engine) as the
/// single source of truth and injects it into the view tree.
@main
struct OffhookApp: App {
    @State private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
