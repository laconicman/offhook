import CallKit
import Foundation
import Observation
import SwiftPJSUA
import SwiftPJSUAKit

/// Coordination + presentation layer for Offhook, now on the **CallKit path**.
///
/// The engine's event stream is consumed exclusively by `SwiftPJSUAKit.CallSessionRouter`
/// (single-consumer `AsyncStream` — design D-ROUTER), so this model no longer runs an event
/// loop and never touches `AVAudioSession`:
///
/// - **Requests out** go through `CXCallController` transactions (`CXStartCallAction` /
///   `CXEndCallAction`); CallKit routes them to `CallKitController` → router → engine.
/// - **State in** arrives from `CXCallObserver` (call lifecycle for the UI) and the router's
///   registration observer (account UI) — never from `engine.events` directly.
/// - **Audio** is CallKit-owned end to end: the controller configures the session category on
///   Start/Answer, and the engine opens/closes the sound device on `didActivate`/`didDeactivate`.
///
/// `@MainActor` because every stored property is UI-bound.
@MainActor
@Observable
final class PhoneModel: NSObject {

    enum EngineState: Equatable { case idle, starting, running, failed(String) }

    /// The one call the bring-up UI tracks, keyed by its CallKit UUID.
    struct CallSnapshot: Identifiable, Equatable {
        let id: UUID
        var state: String
    }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    // MARK: Observable state (read by the view)
    private(set) var engineState: EngineState = .idle
    private(set) var registration = "not registered"
    private(set) var activeCall: CallSnapshot?
    private(set) var log: [LogEntry] = []

    // MARK: User input (bound from the view via @Bindable)
    // ;transport=tcp — Flexisip 407-challenges INVITE and the authenticated resend (~1.6 kB)
    // fragments on UDP and is dropped silently (call never confirms); registering over TCP
    // keeps inbound requests whole. The engine listens on TCP alongside UDP.
    var registrar = "sip.linphone.org;transport=tcp"
    var username = ""
    var password = ""
    // Loopback is the echo now: dial a *second* own account from another device/app instance
    // (Linphone's echo 4443 answers 404 — SIP-verified 2026-07-04; docs/SIP-Test-Infrastructure.md).
    var dialTarget = "sip:user2@sip.linphone.org;transport=tcp"

    // MARK: Engine + CallKit plumbing
    private let engine = PJSUA()
    /// Owns the `CXProvider` and starts the router — the sole `engine.events` consumer.
    private let callKit: CallKitController
    /// App → CallKit: action requests (start/end) go through transactions, never to the engine.
    private let callController = CXCallController()
    /// CallKit → app: system-truth call lifecycle for the UI.
    private let callObserver = CXCallObserver()
    private var account: AccountID?
    private static let maxLogLines = 200

    override init() {
        callKit = CallKitController(engine: engine)
        super.init()
        callObserver.setDelegate(self, queue: .main)
        // Debug-tool hooks: prefill the fields from the environment (`simctl launch` with
        // SIMCTL_CHILD_*, or an Xcode scheme), so scripted smokes and the two-sim harness
        // (Tech-Debt OH-8) never need UI typing. Absent variables leave the defaults.
        let env = ProcessInfo.processInfo.environment
        if let value = env["OFFHOOK_REGISTRAR"] { registrar = value }
        if let value = env["OFFHOOK_USERNAME"] { username = value }
        if let value = env["OFFHOOK_PASSWORD"] { password = value }
        if let value = env["OFFHOOK_DIAL"] { dialTarget = value }
    }

    /// Scripted smoke, opt-in via `OFFHOOK_AUTOSMOKE=1`: start → register → dial with no UI
    /// taps. The fixed settle delay is deliberate KISS for a debug hook — the on-screen log
    /// tells the real story.
    func autoSmokeIfRequested() async {
        guard ProcessInfo.processInfo.environment["OFFHOOK_AUTOSMOKE"] == "1" else { return }
        note("auto-smoke: start → register → dial")
        await startEngine()
        await register()
        try? await Task.sleep(for: .seconds(4)) // let registration settle (observer updates UI)
        await dial()
    }

    // MARK: Derived view helpers
    var engineStateText: String {
        switch engineState {
        case .idle: "idle"
        case .starting: "starting…"
        case .running: "running"
        case .failed(let why): "failed: \(why)"
        }
    }
    var canRegister: Bool { engineState == .running && !username.isEmpty }
    var canDial: Bool { account != nil && activeCall == nil && !dialTarget.isEmpty }

    // MARK: Intents

    func startEngine() async {
        guard engineState == .idle else { return }
        engineState = .starting
        do {
            try await engine.start()
            // Registration relay: the router owns the event stream; the app observes through it.
            // The observer is @MainActor, so this closure runs on the main actor — update directly.
            await callKit.router.setRegistrationObserver { [weak self] _, active, code, expiration in
                guard let self else { return }
                registration = active ? "registered (\(code))" : "not registered (\(code))"
                note("reg: active=\(active) code=\(code) expires=\(expiration)s")
            }
            engineState = .running
            note("engine started — CallKit routing active")
        } catch {
            engineState = .failed("\(error)")
            note("start failed: \(error)")
        }
    }

    func register() async {
        guard engineState == .running else { note("start the engine first"); return }
        let id = "sip:\(username)@\(registrar.split(separator: ";").first.map(String.init) ?? registrar)"
        do {
            let added = try await engine.addAccount(
                id: id,
                registrar: "sip:\(registrar)",
                username: username,
                password: password
            )
            account = added
            await callKit.router.setOutgoingAccount(added)
            note("registering \(id)…")
        } catch {
            note("addAccount failed: \(error)")
        }
    }

    /// Request an outgoing call **through CallKit** (`CXStartCallAction`); the provider delegate
    /// forwards it to the router, which drives `engine.makeCall` and fulfills on `.confirmed`.
    func dial() async {
        guard account != nil else { note("register first"); return }
        let uuid = UUID()
        let start = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: dialTarget))
        do {
            try await callController.requestTransaction(with: [start])
            activeCall = CallSnapshot(id: uuid, state: "requested")
            note("CXStartCallAction requested → \(dialTarget)")
        } catch {
            note("start-call request failed: \(error)")
        }
    }

    /// End the tracked call through CallKit (`CXEndCallAction` → router → `engine.hangup`).
    func hangUp() async {
        guard let uuid = activeCall?.id else { return }
        do {
            try await callController.requestTransaction(with: [CXEndCallAction(call: uuid)])
        } catch {
            note("end-call request failed: \(error)")
        }
    }

    /// Shut the engine down. Call from the app's scene teardown.
    func stop() async {
        await engine.hangupAll()
        await engine.shutdown()
        engineState = .idle
    }

    // MARK: Log
    private func note(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }
}

// MARK: - CXCallObserverDelegate (CallKit → UI state)

extension PhoneModel: CXCallObserverDelegate {
    /// Delegate is registered on the main queue, so hopping straight onto the main actor is
    /// sound (`assumeIsolated`); the requirement itself is nonisolated.
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        MainActor.assumeIsolated {
            if call.hasEnded {
                note("call \(call.uuid.uuidString.prefix(8)) ended")
                if activeCall?.id == call.uuid { activeCall = nil }
                return
            }
            let state = if call.hasConnected { "connected" }
                        else if call.isOutgoing { "dialing…" }
                        else { "ringing (incoming)" }
            activeCall = CallSnapshot(id: call.uuid, state: state)
            note("call \(call.uuid.uuidString.prefix(8)): \(state)")
        }
    }
}
