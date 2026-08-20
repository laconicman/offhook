import XCTest
import SwiftPJSUA

/// Live-infrastructure integration suite: drives the real engine against real SIP servers
/// using the registered test accounts (see `TestAccounts`). Needs network; tests skip when
/// their accounts aren't configured.
///
/// **Ordering is load-bearing.** pjsua is process-global — one engine per process, no restart —
/// so the suite is a single class whose `testNN_` methods run alphabetically and build on each
/// other (engine → auth → registration → calls). Cross-test state lives in `static` members
/// (XCTest makes a fresh instance per method).
///
/// "Between devices" is realised as **loopback through the registrar**: ACC1 and ACC2 live on
/// the same server, so calling ACC2's AOR sends a real INVITE out to the server and back to
/// this process, which auto-answers (`EngineHarness`) — real signalling and real RTP over the
/// same engine path a two-device call uses, but automatable in one process.
final class OffhookIntegrationTests: XCTestCase {

    /// AccountIDs registered by `test03`, keyed by TestAccounts slot.
    static var accounts: [Int: AccountID] = [:]

    private var harness: EngineHarness { .shared }

    override func setUp() async throws {
        try await harness.startIfNeeded()
    }

    // MARK: 01 — lifecycle

    /// Engine starts headlessly (null sound device, no AVAudioSession) and start is idempotent
    /// across tests. `setUp` already started it; a second call must be a clean no-op.
    func test01_engineStartsHeadless() async throws {
        try await harness.startIfNeeded()
    }

    // MARK: 02 — authorization (negative)

    /// Bogus credentials must be rejected by the registrar with a 4xx — proves the digest-auth
    /// path is exercised, not just an open registrar. (The positive case is test03.)
    ///
    /// Deliberately uses a **made-up username on a slot ≥ 3 domain**: probing with a *real*
    /// account's username trips server-side brute-force protection — Flexisip answered the
    /// correct password with 403 for minutes after one failed attempt — which must never hit
    /// the ACC1/ACC2 loopback pair.
    func test02_authorizationRejectsBadCredentials() async throws {
        // Highest slot first (deterministic), never the loopback pair.
        guard let account = TestAccounts.all.sorted(by: { $0.key > $1.key })
            .first(where: { $0.key >= 3 })?.value else {
            throw XCTSkip("needs an account slot ≥ 3 — won't risk rate-limiting the loopback pair")
        }
        let probeUser = "offhook-bogus-probe"
        let bad = try await harness.engine.addAccount(
            AccountConfiguration(id: "sip:\(probeUser)@\(account.domain)",
                                 registrar: account.registrar,
                                 username: probeUser,
                                 isDefault: false),
            credentials: InlineCredentialStore(password: "wrong-\(UUID().uuidString.prefix(8))"))
        let reg: EngineHarness.Registration
        do {
            reg = try await harness.waitForRegistrationResult(bad)
        } catch is EngineHarness.Timeout {
            try? await harness.removeAccount(bad)
            throw XCTSkip("\(account.domain) didn't answer the probe REGISTER — provider weather, re-run later")
        }
        // Free the slot promptly: the binary's account table holds PJSUA_MAX_ACC == 4 total
        // and test03 needs all four. Also exercises removeAccount(). Via the harness so the
        // snapshot dies with the account (pjsua recycles ids).
        try await harness.removeAccount(bad)

        // 408 = no answer from the server, which proves nothing about auth — that's weather too.
        try XCTSkipIf(reg.statusCode == 408,
                      "\(account.domain) timed out (408) on the probe — provider weather")
        XCTAssertFalse(reg.active, "registered with a bogus password?!")
        // Any final failure class counts as a rejection: 4xx auth, or 6xx like iptel's
        // 604 "Doesn't exist here" for unknown users.
        XCTAssertGreaterThanOrEqual(reg.statusCode, 400,
                                    "expected a rejection, got \(reg.statusCode)")
    }

    // MARK: 03 — registration (positive) + params settled

    /// Every configured account registers: final 200, `active`, and a non-zero re-registration
    /// interval (params settled server-side).
    ///
    /// **Strictness is tiered**: the ACC1/ACC2 loopback pair must register (hard assert — the
    /// call tests hang off it); extra accounts (slots ≥ 3) tolerate *no-answer* weather (408 /
    /// silent registrar — observed from iptel after many back-to-back runs) with a warning,
    /// but still hard-fail on a real rejection (4xx auth).
    func test03_allConfiguredAccountsRegister() async throws {
        try XCTSkipIf(TestAccounts.all.isEmpty, "no test accounts configured")
        for (slot, account) in TestAccounts.all.sorted(by: { $0.key < $1.key }) {
            let id = try await harness.engine.addAccount(
                AccountConfiguration(id: account.aor,
                                     registrar: account.registrar,
                                     username: account.username,
                                     isDefault: slot == 1),
                credentials: InlineCredentialStore(password: account.password))
            let reg: EngineHarness.Registration
            do {
                reg = try await harness.waitForRegistrationResult(id)
            } catch is EngineHarness.Timeout {
                if slot <= 2 {
                    XCTFail("\(account.aor) (loopback pair) got no registration result")
                } else {
                    print("[warn] \(account.aor): no registration result — provider weather, tolerated")
                }
                continue
            }
            if !reg.active && reg.statusCode == 408 && slot >= 3 {
                print("[warn] \(account.aor): 408 request timeout — provider weather, tolerated")
                continue
            }
            XCTAssertTrue(reg.active, "\(account.aor) failed to register (\(reg.statusCode))")
            XCTAssertEqual(reg.statusCode, 200, account.aor)
            XCTAssertGreaterThan(reg.expiration, 0, "\(account.aor) expiration not settled")
            // Only successful registrations feed the call tests — a failed account here must
            // make 04–06 *skip* (missing prerequisite), not time out dialing from a dead AOR.
            if reg.active {
                Self.accounts[slot] = id
            }
        }
    }

    // MARK: 04 — audio call + statistics + codec caps

    /// Audio loopback call ACC1 → ACC2 through the registrar: confirmed, media active, RTP in
    /// both directions, and the negotiated codec within the binary's documented set
    /// (G.711/G.722/iLBC/G.729 — **no Opus**; see swift-pjsip/docs/Codec-Coverage.md).
    func test04_audioLoopbackCallWithStatistics() async throws {
        let (caller, calleeAOR) = try Self.loopbackPair()
        let call = try await harness.engine.makeCall(to: calleeAOR, from: caller)
        try await harness.waitForCallState(call, .confirmed)
        try await harness.waitForActiveMedia(call, kind: .audio)

        try await Task.sleep(for: .seconds(5)) // let RTP + first RTCP round flow

        var stats = try await harness.engine.statistics(for: call)
        // Return media relays through the server (Flexisip MediaRelay — RTT ≈ 118 ms measured),
        // and its first packets can lag; allow up to two more windows before judging.
        for _ in 0..<2 where stats.receive.packets == 0 {
            try await Task.sleep(for: .seconds(5))
            stats = try await harness.engine.statistics(for: call)
        }
        let allowedCodecs: Set<String> = ["PCMU", "PCMA", "G722", "ILBC", "G729"]
        XCTAssertTrue(allowedCodecs.contains(stats.codec.name.uppercased()),
                      "negotiated \(stats.codec) — outside the binary's documented codec set")
        XCTAssertGreaterThan(stats.transmit.packets, 0, "no RTP transmitted")
        XCTAssertGreaterThan(stats.receive.packets, 0, "no RTP received")
        XCTAssertGreaterThanOrEqual(stats.receive.jitter.meanMs, 0)
        print("[stats] audio \(stats.codec): tx \(stats.transmit.packets) pkt/\(stats.transmit.bytes) B, " +
              "rx \(stats.receive.packets) pkt (lost \(stats.receive.lost), " +
              "jitter \(stats.receive.jitter.meanMs) ms), rtt \(stats.roundTrip.meanMs) ms")

        try await harness.engine.hangup(call)
        try await harness.waitForCallState(call, .disconnected)
    }

    // MARK: 05 — simultaneous calls

    /// Two loopback calls concurrently confirmed — with their two auto-answered incoming legs
    /// that's four live calls, exactly the binary's PJSUA_MAX_CALLS — then independent
    /// teardown. Self-contained: no external echo service to depend on (Linphone's historic
    /// `4443` echo answers 404 as of 2026-07-04).
    func test05_simultaneousCalls() async throws {
        let (caller, calleeAOR) = try Self.loopbackPair()
        let callA = try await harness.engine.makeCall(to: calleeAOR, from: caller)
        try await harness.waitForCallState(callA, .confirmed)

        let callB = try await harness.engine.makeCall(to: calleeAOR, from: caller)
        try await harness.waitForCallState(callB, .confirmed)

        try await Task.sleep(for: .seconds(2))
        let stateA = await harness.state(of: callA)
        let stateB = await harness.state(of: callB)
        XCTAssertEqual(stateA, .confirmed, "call A dropped while B was live")
        XCTAssertEqual(stateB, .confirmed)

        try await harness.engine.hangup(callA)
        try await harness.waitForCallState(callA, .disconnected)
        let stateBAfterA = await harness.state(of: callB)
        XCTAssertEqual(stateBAfterA, .confirmed, "hanging up A must not affect B")
        try await harness.engine.hangup(callB)
        try await harness.waitForCallState(callB, .disconnected)
    }

    // MARK: 06 — video call + statistics

    /// Video loopback call ACC1 → ACC2: audio confirmed, then a video stream active, with video
    /// RTP flowing. Skips (not fails) when video can't come up on this host — the Simulator has
    /// no camera, so this depends on the binary's fallback capture device; run on a device for
    /// the authoritative result.
    func test06_videoLoopbackCallWithStatistics() async throws {
        let (caller, calleeAOR) = try Self.loopbackPair()
        let call = try await harness.engine.makeCall(to: calleeAOR, from: caller, video: true)
        try await harness.waitForCallState(call, .confirmed)
        try await harness.waitForActiveMedia(call, kind: .audio)

        let video: CallMediaInfo
        do {
            video = try await harness.waitForActiveMedia(call, kind: .video, timeout: 15)
        } catch {
            try? await harness.engine.hangup(call)
            throw XCTSkip("video stream did not become active on this host (no camera?) — run on a device")
        }

        try await Task.sleep(for: .seconds(5))
        let stats = try await harness.engine.statistics(for: call, mediaIndex: video.index)
        XCTAssertEqual(stats.kind, .video)
        XCTAssertFalse(stats.codec.name.isEmpty, "video active but no codec negotiated")
        print("[stats] video \(stats.codec): tx \(stats.transmit.packets) pkt, " +
              "rx \(stats.receive.packets) pkt (lost \(stats.receive.lost))")

        try await harness.engine.hangup(call)
        try await harness.waitForCallState(call, .disconnected)

        // Negotiation + active stream + readable stats prove the video *surface*. Actual RTP
        // needs a capture source; the Simulator has no camera (H264 negotiates, 0 packets
        // flow — observed), so flow verification is a device test: skip, don't fail.
        if stats.transmit.packets == 0 && stats.receive.packets == 0 {
            throw XCTSkip("video negotiated (\(stats.codec)) but no RTP on this host — verify flow on a device")
        }
    }

    // MARK: 07 — a local hangup must still produce a statistics record

    /// Pins undocumented ordering inside `pjsua_call_hangup()`: it calls
    /// `pjsua_media_channel_deinit()` **before** setting `call->hanging_up = PJ_TRUE`
    /// (`pjsua_call.c:3410-3414`), and `on_stream_destroyed` is guarded by `!hanging_up`
    /// (`pjsua_aud.c:553`). Hoisting that assignment three lines would silently delete the
    /// end-of-call statistics record for **every locally ended call** — no compile error, no
    /// other test in this suite failing. This test is the only thing that would notice.
    ///
    /// Filtering to the caller leg is the point: the callee leg is torn down by the BYE, which
    /// is a different path (`Call-Termination-Paths.md` row 2) and would pass even if the local
    /// path were broken.
    func test07_localHangupProducesStatisticsRecord() async throws {
        let (caller, calleeAOR) = try Self.loopbackPair()
        let call = try await harness.engine.makeCall(to: calleeAOR, from: caller)
        try await harness.waitForCallState(call, .confirmed)
        try await harness.waitForActiveMedia(call, kind: .audio)
        try await Task.sleep(for: .seconds(3)) // let RTP flow, so the record carries real counters

        let seen = await harness.streamRecords.count
        try await harness.engine.hangup(call)
        let record: EngineHarness.StreamRecord
        do {
            record = try await harness.waitForStreamRecord(of: call, after: seen)
        } catch is EngineHarness.Timeout {
            return XCTFail("no on_stream_destroyed record for a locally hung-up call — the "
                           + "deinit-before-hanging_up ordering in pjsua_call_hangup() is gone")
        }
        try await harness.waitForCallState(call, .disconnected)

        // Non-zero counters prove the stream was still fully constructed when the callback ran,
        // not already torn down to zeros — the other half of what makes the record trustworthy.
        XCTAssertGreaterThan(record.statistics.transmit.packets, 0,
                             "record captured, but with empty counters")
        XCTAssertFalse(record.statistics.codec.name.isEmpty)
        print("[stats] hangup record: \(record.statistics.codec) "
              + "tx \(record.statistics.transmit.packets) pkt, "
              + "rx \(record.statistics.receive.packets) pkt")
    }

    // MARK: helpers

    /// The registered same-domain pair: ACC1's AccountID (caller) + ACC2's dial URI (callee,
    /// with the server's transport param — see `TestAccount.transportSuffix`).
    private static func loopbackPair() throws -> (caller: AccountID, calleeAOR: String) {
        guard let caller = accounts[1], accounts[2] != nil,
              let callee = TestAccounts.all[2] else {
            throw XCTSkip("needs ACC1+ACC2 registered (test03) for a loopback call")
        }
        return (caller, callee.dialURI)
    }
}
