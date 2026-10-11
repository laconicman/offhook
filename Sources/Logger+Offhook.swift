import Foundation
import os

/// Offhook's unified-log categories, all under the app's bundle ID as the subsystem. The Kit logs
/// under `io.github.laconicman.SwiftPJSUAKit`, so one predicate reads both:
/// `subsystem BEGINSWITH "io.github.laconicman"` (docs/Testing-Playbook.md §9).
extension Logger {
    /// The bundle ID rather than a literal: a fork has to change it to sign, and its logs follow.
    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.laconicman.offhook"

    /// Process launch, scene phase, debug hooks.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// Engine start/stop, network path and ip_change, the engine event tap.
    static let engine = Logger(subsystem: subsystem, category: "engine")
    /// Saved accounts and their registrations.
    static let accounts = Logger(subsystem: subsystem, category: "accounts")
    /// CallKit requests and the calls `CXCallObserver` reports.
    static let calls = Logger(subsystem: subsystem, category: "calls")
    /// PushKit token and VoIP push wake-ups.
    static let push = Logger(subsystem: subsystem, category: "push")
    /// pjsip's own log, as the engine's `logSink` delivers it (see ``PJSIPLog``).
    static let pjsip = Logger(subsystem: subsystem, category: "pjsip")
}
