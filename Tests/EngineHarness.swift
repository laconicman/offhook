import Foundation
import SwiftPJSUA
import XCTest

/// Process-wide harness around the single ``PJSUA`` engine for the integration suite.
///
/// pjsua is process-global (one engine per process, no restart) and `engine.events` is a
/// single-consumer `AsyncStream`, so the whole suite shares **one** started engine and **one**
/// event pump — this actor is the sole events consumer (mirroring the app's PhoneModel /
/// future CallSessionRouter role). Tests read its event-fed snapshots through polling wait
/// helpers; incoming calls are auto-answered (the callee leg of loopback calls).
///
/// Audio runs on the **null sound device** (``PJSUA/activateNullAudioDevice()``): the bridge
/// gets its clock without `AVAudioSession` or mic permission, so RTP flows headlessly in CI.
actor EngineHarness {
    static let shared = EngineHarness()

    let engine = PJSUA()

    struct Registration: Equatable {
        var active: Bool
        var statusCode: Int32
        var expiration: UInt32
    }

    private(set) var registrations: [AccountID: Registration] = [:]
    private(set) var callStates: [CallID: CallState] = [:]
    private(set) var media: [CallID: [CallMediaInfo]] = [:]
    private(set) var answeredIncoming: [CallID] = []

    /// One per `on_stream_destroyed`, in arrival order — the end-of-stream statistics records
    /// that `Call-Quality-Statistics.md` is built on, and what test07 asserts survives a local
    /// hangup.
    struct StreamRecord {
        var call: CallID
        var mediaIndex: Int
        var statistics: CallStreamStatistics
    }
    private(set) var streamRecords: [StreamRecord] = []

    /// One per `on_call_media_event` — the events pjsua forwards without acting on.
    private(set) var mediaEvents: [(call: CallID, mediaIndex: Int, event: CallMediaEvent)] = []

    private var pump: Task<Void, Never>?
    private var started = false
    private var loopback: (caller: AccountID, calleeAOR: String)?
    private var registered: [Int: AccountID] = [:]

    /// Timestamped console trace of every event, for the observation runs in
    /// `CallLifecycleObservationTests`. Off unless `OFFHOOK_OBSERVE=1` so the normal suite's
    /// output is unchanged.
    static let tracing = ProcessInfo.processInfo.environment["OFFHOOK_OBSERVE"] == "1"

    /// Local `HH:mm:ss.SSS` wall clock — the observation runs are correlated against actions
    /// taken on the host (killing a transport), so the trace needs a real timestamp, not an
    /// offset. Formatted by hand: a shared `DateFormatter` would be a non-`Sendable` static.
    static func stamp(_ date: Date = Date()) -> String {
        let local = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
        let whole = Int(local.rounded(.down))
        let ms = Int((local - Double(whole)) * 1000)
        let day = whole % 86_400
        return String(format: "%02d:%02d:%02d.%03d", day / 3600, (day % 3600) / 60, day % 60, ms)
    }

    // MARK: lifecycle

    /// Start engine + event pump once; subsequent calls are no-ops (`setUp` runs per test).
    func startIfNeeded() async throws {
        guard !started else { return }
        started = true
        pump = Task { [engine] in
            for await event in engine.events {
                await self.handle(event)
            }
        }
        try await engine.start()
        try await engine.activateNullAudioDevice()
    }

    private func handle(_ event: PJSUAEvent) async {
        if Self.tracing { print("[EVENT] \(Self.stamp()) \(event)") }
        switch event {
        case let .registrationState(account, active, statusCode, expiration):
            registrations[account] = Registration(active: active,
                                                  statusCode: statusCode,
                                                  expiration: expiration)

        case let .incomingCall(_, call, _, _, _):
            callStates[call] = .incoming
            answeredIncoming.append(call)
            try? await engine.answer(call) // auto-answer: the callee leg of loopback tests

        case let .callState(call, state, _, _):
            callStates[call] = state

        case let .callMediaState(call, streams):
            media[call] = streams

        case let .streamDestroyed(call, mediaIndex, statistics):
            streamRecords.append(StreamRecord(call: call, mediaIndex: mediaIndex,
                                              statistics: statistics))

        case let .callMediaEvent(call, mediaIndex, event):
            mediaEvents.append((call: call, mediaIndex: mediaIndex, event: event))
        }
    }

    /// Register the ACC1/ACC2 same-domain pair and return the caller's id + the callee's dial
    /// URI — the same pair `OffhookIntegrationTests` builds in test03, but self-contained so an
    /// observation run can be launched with `-only-testing:` and still have somewhere to call.
    /// Idempotent: the pair is registered once per process.
    func registerLoopbackPair() async throws -> (caller: AccountID, calleeAOR: String) {
        if let loopback { return loopback }
        guard let acc2 = TestAccounts.all[2] else {
            throw XCTSkip("needs the ACC1/ACC2 same-domain pair (secrets/test-accounts.env)")
        }
        let caller = try await registerAccount(slot: 1)
        _ = try await registerAccount(slot: 2)
        let pair = (caller: caller, calleeAOR: acc2.dialURI)
        loopback = pair
        return pair
    }

    /// The account already registered under `slot`, if any — including ones the ordered suite
    /// created through its own `addAccount` and adopted via ``adoptAccount(_:forSlot:)``.
    func account(forSlot slot: Int) -> AccountID? { registered[slot] }

    /// Record an account the caller created outside ``registerAccount(slot:)``. The ordered
    /// suite registers through `engine.addAccount` directly; without this shared table a run
    /// mixed with it would double-register the slot and burn a second account slot.
    func adoptAccount(_ id: AccountID, forSlot slot: Int) {
        registered[slot] = id
    }

    /// Register one configured account by slot. Idempotent per slot, so an observation run can
    /// bring up just the account it needs — which is what lets the same instruments be pointed at
    /// a provider that offers an echo endpoint instead of a same-domain pair.
    func registerAccount(slot: Int) async throws -> AccountID {
        if let existing = registered[slot] { return existing }
        guard let account = TestAccounts.all[slot] else {
            throw XCTSkip("test account ACC\(slot) not configured")
        }
        let id = try await engine.addAccount(
            AccountConfiguration(id: account.aor,
                                 registrar: account.registrar,
                                 username: account.username,
                                 isDefault: slot == 1),
            credentials: InlineCredentialStore(password: account.password))
        let reg = try await waitForRegistrationResult(id)
        guard reg.active else {
            throw XCTSkip("\(account.aor) failed to register (\(reg.statusCode))")
        }
        registered[slot] = id
        return id
    }

    // MARK: snapshots

    func state(of call: CallID) -> CallState? { callStates[call] }

    /// Remove an account **and drop its snapshot**: pjsua recycles account ids, so a later
    /// `addAccount` may reuse this id — a stale registration entry would satisfy the next
    /// `waitForRegistrationResult` instantly with the old result. (Learned the hard way.)
    func removeAccount(_ account: AccountID) async throws {
        try await engine.removeAccount(account)
        registrations[account] = nil
        if let slot = registered.first(where: { $0.value == account })?.key {
            registered[slot] = nil
        }
    }

    // MARK: waiting (poll the event-fed snapshots)

    /// Wait until `account` has a *final* registration result (status ≥ 200 — 200 on success,
    /// 4xx on auth failure). The default outlives pjsip's own ~32 s transaction timeout so a
    /// silent registrar surfaces as a 408 *result* rather than racing this poll's deadline.
    func waitForRegistrationResult(_ account: AccountID,
                                   timeout: TimeInterval = 40) async throws -> Registration {
        try await poll(timeout: timeout, what: "registration result for \(account)") {
            if let reg = registrations[account], reg.statusCode >= 200 { return reg }
            return nil
        }
    }

    func waitForCallState(_ call: CallID, _ target: CallState,
                          timeout: TimeInterval = 30) async throws {
        _ = try await poll(timeout: timeout, what: "\(call) to reach \(target)") {
            callStates[call] == target ? true : nil
        }
    }

    /// Wait for an **active** stream of `kind` on `call` and return its media info.
    @discardableResult
    func waitForActiveMedia(_ call: CallID, kind: CallMediaInfo.Kind,
                            timeout: TimeInterval = 20) async throws -> CallMediaInfo {
        try await poll(timeout: timeout, what: "active \(kind) media on \(call)") {
            media[call]?.first { $0.kind == kind && $0.status == .active }
        }
    }

    /// Wait for a stream record for `call` that arrives after `index` records have been seen.
    /// The index makes the wait unambiguous: a call that was held and resumed already has
    /// records, and the one being waited on is the *next* one.
    func waitForStreamRecord(of call: CallID, after index: Int,
                             timeout: TimeInterval = 10) async throws -> StreamRecord {
        try await poll(timeout: timeout, what: "a stream record for \(call)") {
            streamRecords.dropFirst(index).first { $0.call == call }
        }
    }

    struct Timeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting for \(what)" }
    }

    private func poll<T>(timeout: TimeInterval, what: String,
                         _ check: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = check() { return value }
            try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }
        throw Timeout(what: what)
    }
}
