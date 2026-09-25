import CallKit
import Foundation
import Network
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

    /// One call the UI tracks, keyed by its CallKit UUID. Multi-call: the array can hold
    /// several (parallel calls are the point of the demo); `isOnHold` mirrors `CXCall`.
    /// `handle` is the remote party we dialed, when known — incoming calls arrive through
    /// `CXCallObserver` which doesn't expose a handle, so they keep `nil` until the event
    /// tap's `from` can be correlated (needs the router's call→UUID map; not exposed yet).
    struct CallSnapshot: Identifiable, Equatable {
        let id: UUID
        var state: String
        var isOnHold: Bool = false
        var handle: String? = nil
    }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    /// One pjsip log line as delivered by the engine's `logSink` — level is the PJSIP
    /// verbosity (0 fatal … 6 trace); `text` keeps the sender prefix pjsip already formats.
    struct SIPLogRow: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Int32
        let text: String
    }

    /// One engine event, timestamped as the tap delivered it — the Diagnostics view's row.
    /// Keeps the `PJSUAEvent` itself rather than a flattened string so the view can render
    /// every field (SIP Call-IDs, stream details) instead of losing them at capture time.
    struct EventRow: Identifiable {
        let id = UUID()
        let timestamp: Date
        let event: PJSUAEvent
    }

    // MARK: Observable state (read by the view)
    private(set) var engineState: EngineState = .idle
    private(set) var registration = "not registered"
    private(set) var calls: [CallSnapshot] = []
    private(set) var log: [LogEntry] = []
    /// Structured engine-event history (the tap already feeds `log`; this keeps the typed
    /// rows so Diagnostics can format them without re-parsing text).
    private(set) var events: [EventRow] = []
    /// Raw SIP/pjsip log lines via the engine's `logSink` — bounded; SIP traces are chatty.
    private(set) var sipLog: [SIPLogRow] = []
    /// Latest media vector per engine call — the conference-slot inspector's source. Keyed
    /// by `CallID` (the tap's events don't expose CallKit UUIDs, and don't need to — this
    /// view is engine-facing). Filled by `.callMediaState`, evicted on `.disconnected`.
    private(set) var mediaByCall: [CallID: [CallMediaInfo]] = [:]

    /// Saved accounts (secrets live in the Keychain, never here) and their live registration
    /// text, keyed by `SavedAccount.id` → engine `AccountID` → status.
    private(set) var accounts: [SavedAccount] = []
    private(set) var accountStates: [UUID: String] = [:]
    private var accountIDs: [UUID: AccountID] = [:]
    /// The saved row the router's outgoing account currently belongs to — tracked so
    /// deleting that row can reselect a survivor instead of leaving the router pointed at
    /// a removed engine account.
    private var outgoingAccountID: UUID?
    private var accountStore = AccountStore()
    private let credentials = KeychainCredentialStore()

    /// CallKit UUIDs we know are ours — every `dial()` request lands here. Calls reported by
    /// `CXCallObserver` that aren't in this set are another app's (the observer is
    /// system-wide); they're left untracked until the router can answer "is this UUID ours?"
    /// for incoming legs too (SwiftPJSUAKit follow-up).
    private var outgoingUUIDs: Set<UUID> = []
    private var handlesByUUID: [UUID: String] = [:]
    /// UUIDs the router confirmed as ours (incoming legs); `outgoingUUIDs` covers dials.
    private var checkedOurs: Set<UUID> = []
    /// UUIDs with an in-flight `isKnownCall` query — keeps repeated `callChanged` fires for
    /// the same foreign call from spawning a Task per fire.
    private var ownershipChecksInFlight: Set<UUID> = []

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
    private static let maxLogLines = 200

    /// Overrides the UDP/TCP listening port when `OFFHOOK_PORT` is set; `nil` keeps the IANA
    /// defaults. Debug-tool hook only — see `init()`.
    private var transportPort: UInt32?

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
        // `0` binds ephemeral ports instead of 5060/5061. Needed on a real device, where
        // another VoIP app may already hold 5060 and `PJSUA.start()` is fail-fast (TD-18),
        // so one squatted port takes the whole engine down before it ever registers.
        if let value = env["OFFHOOK_PORT"], let port = UInt32(value) { transportPort = port }
        if let value = env["OFFHOOK_DIAL"] { dialTarget = value }
        accounts = accountStore.accounts
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
    var canDial: Bool { !accountIDs.isEmpty && !dialTarget.isEmpty }

    // MARK: Intents

    func startEngine() async {
        guard engineState == .idle else { return }
        engineState = .starting
        do {
            // UDP + TCP (the engine defaults) plus TLS on an ephemeral port. A client-only TLS
            // transport needs no fixed listening port and no certificate — pjsip sets one only
            // when configured — so this costs nothing when unused and is what lets a registrar
            // URI carry `;transport=tls`. Port 0 rather than 5061 because `start()` is
            // fail-fast: losing a race for the IANA port would take the whole engine down.
            var configuration = PJSUA.Configuration()
            if let transportPort {
                configuration.transports = [TransportConfiguration("udp", .udp, port: transportPort),
                                            TransportConfiguration("tcp", .tcp, port: transportPort)]
            }
            configuration.transports.append(TransportConfiguration("tls", .tls, port: 0))
            // The sink fires on pjsip's log thread; stamp there (a busy main actor would
            // misdate queued lines), then hop before mutating observable state.
            configuration.logSink = { [weak self] level, text in
                let timestamp = Date()
                Task { @MainActor in self?.recordSIPLog(level: level, text: text, timestamp: timestamp) }
            }
            // The monitor precedes `start()` so a handoff racing engine bind is still
            // observed — it lands as `pendingIPChange` and fires once `.running`.
            startPathMonitor()
            try await engine.start(configuration)
            // Registration relay: the router owns the event stream; the app observes through it.
            // The observer is @MainActor, so this closure runs on the main actor — update directly.
            await callKit.router.setRegistrationObserver { [weak self] account, active, code, expiration in
                guard let self else { return }
                let text = active ? "registered (\(code))" : "not registered (\(code))"
                if let saved = accountIDs.first(where: { $0.value == account })?.key {
                    accountStates[saved] = text
                }
                registration = text
                note("reg[\(account)]: active=\(active) code=\(code) expires=\(expiration)s")
            }
            // Event tap: the router's single app-facing relay of every event it processes —
            // structured rows for Diagnostics (C1), plus the one-line log entry.
            await callKit.router.setEventObserver { [weak self] event in
                self?.recordEvent(event)
            }
            engineState = .running
            note("engine started — CallKit routing active")
            pumpIPChange()   // drains a handoff that arrived during .starting
            // Softphone-on-launch: saved accounts come up on their own.
            await registerAll()
        } catch {
            // The monitor was started before `engine.start` — don't leave it running
            // against an engine that never came up.
            pathMonitorTask?.cancel()
            pathMonitorTask = nil
            ipChangeRetryTask?.cancel()
            ipChangeRetryTask = nil
            pendingPathSignature = nil
            engineState = .failed("\(error)")
            note("start failed: \(error)")
        }
    }

    /// Save the typed-in account (record → JSON, secret → Keychain) and register it.
    /// A failed registration still leaves the account saved — that's the point of a store.
    func register() async {
        guard engineState == .running else { note("start the engine first"); return }
        // Strip the sip: scheme if the user typed one — the AOR would otherwise come out
        // as sip:alice@sip:host, which no server can parse.
        var host = registrar.split(separator: ";").first.map(String.init) ?? registrar
        if host.hasPrefix("sip:") { host = String(host.dropFirst(4)) }
        let draft = SavedAccount(
            aor: "sip:\(username)@\(host)",
            registrar: registrar.hasPrefix("sip:") ? registrar : "sip:\(registrar)",
            username: username)
        do {
            try credentials.store(password, for: draft.credentialRequest)
            try accountStore.save(draft)
            accounts = accountStore.accounts
        } catch {
            note("save failed: \(error)")
            return
        }
        // Register the canonical stored row: `save` preserves the existing UUID on an AOR
        // match, and `accountIDs` is keyed by *that* — not the draft's fresh id.
        guard let canonical = accounts.first(where: { $0.aor == draft.aor }) else { return }
        await register(canonical)
    }

    /// Register one saved account — the engine fetches the secret from the Keychain itself,
    /// through the `CredentialStore` seam (the app never handles it on this path).
    func register(_ saved: SavedAccount) async {
        guard engineState == .running else { note("start the engine first"); return }
        guard accountIDs[saved.id] == nil else {
            note("\(saved.aor) is already registered")
            return
        }
        do {
            let added = try await engine.addAccount(
                AccountConfiguration(id: saved.aor,
                                     registrar: saved.registrar,
                                     username: saved.username,
                                     realm: saved.realm,
                                     isDefault: accountIDs.isEmpty),
                credentials: credentials)
            // A swipe-delete can win the race while `addAccount` is suspended — if the row
            // is gone, take the fresh engine account down with it rather than leaving a
            // live registration with nothing to manage it.
            guard accounts.contains(where: { $0.id == saved.id }) else {
                try? await engine.removeAccount(added)
                return
            }
            accountIDs[saved.id] = added
            // The most recently registered account becomes the outgoing leg's account —
            // a real picker arrives with the multi-call UI.
            await callKit.router.setOutgoingAccount(added)
            outgoingAccountID = saved.id
            accountStates[saved.id] = "registering…"
            note("registering \(saved.aor)…")
        } catch {
            accountStates[saved.id] = "add failed"
            note("addAccount failed: \(error)")
        }
    }

    /// Register every saved account — the softphone-on-launch shape.
    func registerAll() async {
        for saved in accounts where accountIDs[saved.id] == nil {
            await register(saved)
        }
    }

    /// Forget an account entirely: unregister if live, delete the Keychain item, drop the
    /// persisted record.
    func removeAccount(_ saved: SavedAccount) async {
        if let id = accountIDs[saved.id] {
            try? await engine.removeAccount(id)
            accountIDs[saved.id] = nil
        }
        // If the removed row was the outgoing account, promote a survivor so `dial` doesn't
        // aim the router at a dead engine id.
        if outgoingAccountID == saved.id {
            if let next = accountIDs.first {
                await callKit.router.setOutgoingAccount(next.value)
                outgoingAccountID = next.key
            } else {
                outgoingAccountID = nil
            }
        }
        try? credentials.removeSecret(for: saved.credentialRequest)
        try? accountStore.remove(saved)
        accounts = accountStore.accounts
        accountStates[saved.id] = nil
        note("removed \(saved.aor)")
    }

    /// Request an outgoing call **through CallKit** (`CXStartCallAction`); the provider delegate
    /// forwards it to the router, which drives `engine.makeCall` and fulfills on `.confirmed`.
    func dial() async {
        guard !accountIDs.isEmpty else { note("register first"); return }
        let uuid = UUID()
        // Snapshot before the await: the field is user-editable and a mid-request edit
        // would otherwise mislabel the row with the *new* target.
        let target = dialTarget
        // Record ownership *before* requesting: CallKit can announce the call to
        // CXCallObserver before the transaction (and thus the router's `startCall` binding)
        // completes — an observer fire in that window must already see us as the owner.
        outgoingUUIDs.insert(uuid)
        handlesByUUID[uuid] = target
        let start = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: target))
        do {
            try await callController.requestTransaction(with: [start])
            // No optimistic row: the observer can report the call ending *before* this
            // transaction returns, and a "requested" insert would resurrect it. CallKit
            // reports our own call to the observer either way — trust the single source.
            note("CXStartCallAction requested → \(target)")
        } catch {
            outgoingUUIDs.remove(uuid)
            handlesByUUID.removeValue(forKey: uuid)
            note("start-call request failed: \(error)")
        }
    }

    /// End a call through CallKit (`CXEndCallAction` → router → `engine.hangup`).
    func hangUp(_ uuid: UUID) async {
        do {
            try await callController.requestTransaction(with: [CXEndCallAction(call: uuid)])
        } catch {
            note("end-call request failed: \(error)")
        }
    }

    /// Hold/resume a call through CallKit (`CXSetHeldCallAction` → router → `engine.setHold`/
    /// `resume`). CallKit fulfils the action when the router sees the media transition.
    func setHeld(_ uuid: UUID, onHold: Bool) async {
        do {
            try await callController.requestTransaction(
                with: [CXSetHeldCallAction(call: uuid, onHold: onHold)])
        } catch {
            note("hold request failed: \(error)")
        }
    }

    private func upsertCall(_ snapshot: CallSnapshot) {
        if let i = calls.firstIndex(where: { $0.id == snapshot.id }) {
            calls[i] = snapshot
        } else {
            calls.append(snapshot)
        }
    }

    /// Shut the engine down. Call from the app's scene teardown.
    func stop() async {
        pathMonitorTask?.cancel()
        pathMonitorTask = nil
        ipChangeRetryTask?.cancel()
        ipChangeRetryTask = nil
        ipChangeInFlight = false
        pendingPathSignature = nil
        await engine.hangupAll()
        await engine.shutdown()
        engineState = .idle
    }

    // MARK: Network changes → engine

    /// Drives the Wi-Fi ↔ cellular / loss ↔ regain handoff into `handleIPChange()` —
    /// pjsua then restarts listeners, re-registers contacts, and re-INVITEs live calls.
    /// `NWPathMonitor`'s own `AsyncSequence` is iOS 17+ (our floor) and retains the
    /// monitor for the stream's life; the loop dies with the task on `stop()`.
    private var pathMonitorTask: Task<Void, Never>?

    /// Newest observed path not yet covered by a completed ip_change sequence.
    private var pendingPathSignature: String?
    /// A `handleIPChange()` sequence is running — pjsua skips re-entrant requests, so a
    /// newer path must wait for `.completed` rather than be dropped mid-sequence.
    private var ipChangeInFlight = false
    private var ipChangeRetryTask: Task<Void, Never>?
    private var ipChangeRetryAttempt = 0

    private func startPathMonitor() {
        pathMonitorTask = Task { [weak self] in
            // The first path is the baseline, not a change — don't kick ip_change at start.
            var lastSignature: String?
            for await path in NWPathMonitor() {
                guard let self, !Task.isCancelled else { return }
                // Local addresses — what a SIP transport is actually bound to — so a
                // same-type handoff (new DHCP lease, AP roam onto another subnet) still
                // counts as a change; `status` alone would swallow it. The preferred-route
                // types catch flips where every interface keeps its address but iOS starts
                // preferring cellular over Wi-Fi (or back) — the reachability pjsua just
                // registered under changed.
                let routes = Self.routeTypes(in: path)
                let signature = "\(path.status)|\(routes)|\(Self.localAddressSignature())"
                if lastSignature == nil { lastSignature = signature; continue }
                guard signature != lastSignature else { continue }
                lastSignature = signature
                pendingPathSignature = signature
                pumpIPChange()
            }
        }
    }

    /// Serial recovery pump: at most one ip_change sequence in flight. A handoff that
    /// arrives mid-sequence stays parked in `pendingPathSignature` (newest wins — the
    /// intermediate paths are superseded) and drains when `.completed` arrives.
    private func pumpIPChange() {
        guard engineState == .running, !ipChangeInFlight,
              let signature = pendingPathSignature else { return }
        pendingPathSignature = nil
        ipChangeInFlight = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.handleIPChange()
                ipChangeRetryAttempt = 0
                note("network path → \(signature): ip_change started")
            } catch {
                // Never started — no `.completed` will arrive to release in-flight.
                ipChangeInFlight = false
                pendingPathSignature = signature
                note("network path → \(signature): ip_change failed: \(error)")
                scheduleIPChangeRetry()
            }
        }
    }

    /// `handleIPChange()` throws *before* pjsua's sequence starts, so no progress event
    /// will arrive — retry with growing gaps, bounded; success resets the counter.
    private func scheduleIPChangeRetry() {
        ipChangeRetryAttempt += 1
        guard ipChangeRetryAttempt <= 5 else {
            note("ip_change: giving up after \(ipChangeRetryAttempt) failed starts")
            return
        }
        let delay = ipChangeRetryAttempt * 5
        ipChangeRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            pumpIPChange()
        }
    }

    /// Interface types this path would actually carry traffic over (`usesInterfaceType`
    /// tracks the preferred route, not just availability).
    private static func routeTypes(in path: NWPath) -> String {
        [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other]
            .filter { path.usesInterfaceType($0) }
            .map { String(describing: $0) }
            .joined(separator: "+")
    }

    /// Up-interface IPv4/IPv6 addresses, sorted — the route-level identity that
    /// `NWPath` doesn't expose (`availableInterfaces` lists eligible interfaces, not
    /// the addresses they're bound to).
    private static func localAddressSignature() -> String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return "" }
        defer { freeifaddrs(list) }
        var parts: [String] = []
        var cursor = list
        while let iface = cursor?.pointee {
            defer { cursor = iface.ifa_next }
            guard let sa = iface.ifa_addr,
                  iface.ifa_flags & UInt32(IFF_UP) != 0,
                  sa.pointee.sa_family == AF_INET || sa.pointee.sa_family == AF_INET6
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            parts.append("\(String(cString: iface.ifa_name))=\(String(cString: host))")
        }
        return parts.sorted().joined(separator: ",")
    }

    // MARK: Log
    private func note(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }

    private static let maxSIPLogRows = 1000

    private func recordSIPLog(level: Int32, text: String, timestamp: Date) {
        sipLog.append(SIPLogRow(timestamp: timestamp, level: level, text: Self.redactAuth(text)))
        while sipLog.count > Self.maxSIPLogRows {
            // Evict the oldest *chatty* line first — a level-5 flood must not push the
            // level-1 error you opened the view for out of the buffer before the filter
            // can show it.
            if let chatty = sipLog.firstIndex(where: { $0.level > 2 }) {
                sipLog.remove(at: chatty)
            } else {
                sipLog.removeFirst()
            }
        }
    }

    /// SIP logs carry credentials — digest `response` values and Basic payloads — and this
    /// buffer feeds a copyable UI. Header/param names stay (they're what auth debugging
    /// needs); the credential material is blanked. Case-insensitive with optional LWS:
    /// `RESPONSE = "…"` and `response="…"` are the same header to a SIP parser.
    private static let authRedactors: [(pattern: String, template: String)] = [
        (#"(?i)(response\s*=\s*")[^"]*""#, #"\1•••"#),
        (#"(?i)((?:Proxy-)?Authorization\s*:\s*Basic\s+)\S+"#, #"\1<redacted>"#),
    ]

    private static func redactAuth(_ line: String) -> String {
        authRedactors.reduce(line) {
            $0.replacingOccurrences(of: $1.pattern, with: $1.template, options: .regularExpression)
        }
    }

    // MARK: Diagnostics (C1)
    private static let maxEventRows = 300

    /// Event-tap entry point: append the structured row, keep the media-slot table current,
    /// and mirror a one-liner into the shared log so actions and events stay in one timeline.
    private func recordEvent(_ event: PJSUAEvent) {
        events.append(EventRow(timestamp: .now, event: event))
        if events.count > Self.maxEventRows { events.removeFirst(events.count - Self.maxEventRows) }
        if case .ipChangeProgress(let operation, _, _, _, _) = event,
           operation == .completed {
            ipChangeInFlight = false
            pumpIPChange()   // a handoff may have queued while the sequence ran
        }
        switch event {
        case .callMediaState(let call, let media):
            mediaByCall[call] = media.isEmpty ? nil : media
        case .callState(let call, .disconnected, _, _):
            mediaByCall[call] = nil
        default:
            break
        }
        note("evt: \(event.diagnosticSummary)")
    }
}

// MARK: - CXCallObserverDelegate (CallKit → UI state)

extension PhoneModel: CXCallObserverDelegate {
    /// Delegate is registered on the main queue, so hopping straight onto the main actor is
    /// sound (`assumeIsolated`); the requirement itself is nonisolated.
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        MainActor.assumeIsolated {
            let uuid = call.uuid
            if call.hasEnded {
                note("call \(uuid.uuidString.prefix(8)) ended")
                calls.removeAll { $0.id == uuid }
                outgoingUUIDs.remove(uuid)
                handlesByUUID.removeValue(forKey: uuid)
                checkedOurs.remove(uuid)
                ownershipChecksInFlight.remove(uuid)
                return
            }
            let state = Self.describe(call)
            // The observer is system-wide: a UUID is ours if we requested it (dial) or the
            // router knows it (our provider reported it). Foreign calls get no row — the
            // controls we render would only fail on them.
            guard outgoingUUIDs.contains(uuid) || checkedOurs.contains(uuid) else {
                if ownershipChecksInFlight.insert(uuid).inserted {
                    let router = callKit.router
                    Task { @MainActor [weak self] in
                        let known = await router.isKnownCall(uuid)
                        guard let self else { return }
                        self.ownershipChecksInFlight.remove(uuid)
                        guard known, !call.hasEnded else { return }
                        self.checkedOurs.insert(uuid)
                        self.upsertCall(CallSnapshot(id: uuid, state: state,
                                                     isOnHold: call.isOnHold))
                        self.note("call \(uuid.uuidString.prefix(8)): \(state)")
                    }
                }
                return
            }
            upsertCall(CallSnapshot(id: uuid, state: state, isOnHold: call.isOnHold,
                                    handle: handlesByUUID[uuid]))
            note("call \(uuid.uuidString.prefix(8)): \(state)")
        }
    }

    private static func describe(_ call: CXCall) -> String {
        var state = if call.hasConnected { "connected" }
                    else if call.isOutgoing { "dialing…" }
                    else { "ringing (incoming)" }
        if call.isOnHold { state += " · held" }
        return state
    }
}
