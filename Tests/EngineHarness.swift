import Foundation
import SwiftPJSUA

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

    private var pump: Task<Void, Never>?
    private var started = false

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
        }
    }

    // MARK: snapshots

    func state(of call: CallID) -> CallState? { callStates[call] }

    /// Remove an account **and drop its snapshot**: pjsua recycles account ids, so a later
    /// `addAccount` may reuse this id — a stale registration entry would satisfy the next
    /// `waitForRegistrationResult` instantly with the old result. (Learned the hard way.)
    func removeAccount(_ account: AccountID) async throws {
        try await engine.removeAccount(account)
        registrations[account] = nil
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
