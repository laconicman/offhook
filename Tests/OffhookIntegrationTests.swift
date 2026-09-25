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
        // Free the slot promptly: the binary's account table holds PJSUA_MAX_ACC == 8 total
        // and test03 uses every slot the secrets file configures, which is also eight. Still
        // load-bearing, then — just at a different number than it used to be (the preset said
        // 4 until swift-pjsip 0.2.1 fixed the module map; see PR-swift-pjsip-module-abi.md).
        // Also exercises removeAccount(). Via the harness so the snapshot dies with the
        // account (pjsua recycles ids).
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
            // Reuse rather than re-add: in a mixed run the observation suite may already
            // hold this slot, and pjsua's account table is finite.
            let id: AccountID
            if let existing = await harness.account(forSlot: slot) {
                id = existing
            } else {
                id = try await harness.engine.addAccount(
                    AccountConfiguration(id: account.aor,
                                         registrar: account.registrar,
                                         username: account.username,
                                         isDefault: slot == 1),
                    credentials: InlineCredentialStore(password: account.password))
                await harness.adoptAccount(id, forSlot: slot)
            }
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

    // MARK: 05 — simultaneous calls, to the ceiling

    /// Four loopback calls concurrently confirmed — with their four auto-answered incoming legs
    /// that is **eight live calls, exactly `PJSUA_MAX_CALLS`** — then a ninth that must be
    /// refused, then independent teardown. Self-contained: no external echo service to depend on
    /// (Linphone's historic `4443` echo answers 404 as of 2026-07-04).
    ///
    /// Saturation used to come free at two calls, when the ceiling was 4. swift-pjsip 0.2.1's
    /// module-map fix moved it to 8 (`PR-swift-pjsip-module-abi.md`) and quietly retired the
    /// property; four outbound legs restores it.
    ///
    /// **The ninth call costs the provider nothing.** `pjsua_call_make_call()` allocates a call
    /// slot before it builds an INVITE, so a full table is refused locally with `PJ_ETOOMANY` and
    /// nothing reaches the wire. That is what makes asserting the ceiling cheap enough to do on
    /// every run.
    ///
    /// **Rejections are classified, not merely counted.** Eight legs in a burst through a public
    /// registrar is enough to trip flood protection, and a 403 four INVITEs in is Flexisip
    /// defending itself rather than a bug of ours. ``providerRejection(_:)`` is the list of
    /// answers a busy server is entitled to give; anything else disconnecting a leg fails the
    /// test with the status it died on.
    ///
    /// Expect `RTP socket bind() at 0.0.0.0:400x error: Address already in use` in the log at
    /// this load — eight legs take RTP 4000–4014, the first attempt on a port collides with a
    /// socket an earlier call has not released, and pjsua walks the range. Observed 2026-09-03:
    /// all eight sockets came up, no call lost media. Noise, not a symptom.
    func test05_simultaneousCalls() async throws {
        let (caller, calleeAOR) = try Self.loopbackPair()
        let outboundLegs = 4 // × 2 legs each (we auto-answer the inbound side) = PJSUA_MAX_CALLS

        var calls: [CallID] = []
        func hangUpEverything() async {
            for call in calls { try? await harness.engine.hangup(call) }
        }

        for leg in 1...outboundLegs {
            let call: CallID
            do {
                call = try await harness.engine.makeCall(to: calleeAOR, from: caller)
            } catch {
                await hangUpEverything()
                XCTFail("leg \(leg) of \(outboundLegs) could not be placed, below the ceiling: \(error)")
                return
            }
            calls.append(call)

            let outcome: (state: CallState, status: Int32)
            do {
                outcome = try await harness.waitForCallOutcome(call)
            } catch is EngineHarness.Timeout {
                await hangUpEverything()
                throw XCTSkip("leg \(leg) of \(outboundLegs) never settled — no answer at all, "
                              + "which is weather rather than a rejection")
            }

            guard outcome.state == .confirmed else {
                await hangUpEverything()
                if let rejection = Self.providerRejection(outcome.status) {
                    throw XCTSkip("leg \(leg) of \(outboundLegs) rejected — \(rejection)")
                }
                XCTFail("leg \(leg) of \(outboundLegs) disconnected with SIP \(outcome.status), "
                        + "which is not an answer a registrar is entitled to give here")
                return
            }
        }

        // Everything placed is still up: a later leg must not have torn down an earlier one.
        try await Task.sleep(for: .seconds(2))
        for (index, call) in calls.enumerated() {
            let state = await harness.state(of: call)
            XCTAssertEqual(state, .confirmed, "leg \(index + 1) dropped while the others were live")
        }

        // The table is now full. Local refusal, no INVITE.
        do {
            let ninth = try await harness.engine.makeCall(to: calleeAOR, from: caller)
            calls.append(ninth)
            XCTFail("a ninth call was accepted — either PJSUA_MAX_CALLS is not 8, or not all "
                    + "eight legs were actually live")
        } catch let error as PJSUAError {
            XCTAssertEqual(error.status, Self.pjTooMany,
                           "at the ceiling expected PJ_ETOOMANY (\(Self.pjTooMany)); got \(error)")
        }

        // Independent teardown: hanging up one leg must not disturb the rest.
        for (index, call) in calls.enumerated() {
            try await harness.engine.hangup(call)
            try await harness.waitForCallState(call, .disconnected)
            for survivor in calls.dropFirst(index + 1) {
                let state = await harness.state(of: survivor)
                XCTAssertEqual(state, .confirmed,
                               "hanging up leg \(index + 1) disturbed a later leg")
            }
        }
    }

    /// `PJ_ETOOMANY` — `PJ_ERRNO_START_STATUS + 10`, `pjlib/include/pj/errno.h`. Spelled as a
    /// literal on purpose: this target links `SwiftPJSUA` only, and pulling in `PJSIP` for one
    /// constant would widen the test bundle's dependency surface to save nothing.
    private static let pjTooMany: Int32 = 70_010

    /// Answers a busy public registrar — or a saturated far leg — is entitled to give, and what
    /// each one means here. A leg that ends on one of these is weather; anything else is ours.
    ///
    /// Deliberately narrow, and 408 wears it on the label: a terminal 408 means nothing answered
    /// conclusively — either our INVITE's Timer B expired or a proxy reported its own upstream
    /// timeout — which is the same weather class the `Timeout` branch covers for a call that
    /// produced no terminal event at all. It is *not* folded into the silent-rejection codes
    /// below; it is named separately so a real 4xx/5xx regression still fails rather than skips.
    private static func providerRejection(_ status: Int32) -> String? {
        switch status {
        case 408: return "408 Request Timeout — nothing answered conclusively (our Timer B or "
                       + "the provider's upstream); weather, same class as no terminal event"
        case 403: return "403 Forbidden, i.e. flood or brute-force protection; Flexisip keeps "
                       + "this up for minutes after a burst"
        case 429: return "429, rate limited"
        case 480: return "480 Temporarily Unavailable — the far leg is not taking calls"
        case 486: return "486 Busy Here — the callee would not take another leg"
        case 500: return "500 Server Internal Error"
        case 503: return "503 Service Unavailable — overload, usually with a Retry-After"
        case 603: return "603 Decline"
        default:  return nil
        }
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

    // MARK: 08 — TLS registration

    /// Registers over **TLS** against a real provider. `Transport.tls` and
    /// `TransportConfiguration`'s 5061 default have existed and compiled since TD-18, but
    /// nothing had ever put a REGISTER through them — the whole TLS surface was unexercised
    /// against a live server.
    ///
    /// Runs last and **retires an account first**: `test03` fills the account table
    /// (`PJSUA_MAX_ACC`), so this needs a free slot. It re-registers that same account's AOR,
    /// changing only the transport — which is what makes any difference in the result
    /// attributable to TLS and not to the account.
    ///
    /// No client certificate is involved: pjsip calls `pj_ssl_sock_set_certificate()` only
    /// when one is configured, and the provider's certificate is validated against the Darwin
    /// trust store (`swift-pjsip/docs/Apple-TLS-Backends.md`). Mutual TLS is a separate
    /// question and is blocked on swift-pjsua's TD-19 — a listener restart drops the
    /// credentials, and restart is the only recovery path there is.
    func test08_registersOverTLS() async throws {
        // Never the loopback pair: 04–06 are finished with it, but retiring ACC1/ACC2 would
        // make a `-only-testing:` re-run of this method behave unlike a full-suite run.
        let account: TestAccount
        if let (slot, id) = Self.accounts.filter({ $0.key >= 3 })
                .max(by: { $0.key < $1.key }),
           let configured = TestAccounts.all[slot] {
            // Full suite: the account table can be full, so retire a ≥3 binding first.
            try await harness.removeAccount(id)
            Self.accounts[slot] = nil
            account = configured
        } else if let (_, configured) = TestAccounts.all.filter({ $0.key >= 3 })
                .max(by: { $0.key < $1.key }) {
            // `-only-testing:` re-run: nothing is registered, so add the account over TLS
            // directly — the isolated path must exercise registration, not skip it.
            account = configured
        } else {
            throw XCTSkip("needs a configured account on a slot >= 3 to register over TLS")
        }

        // TLS probes the *same* registrar test03 used — an override may name a different
        // host or carry URI parameters that rebuilding from `domain` would drop.
        var registrar = account.registrar
        if let transport = registrar.range(of: ";transport=[^;]*", options: .regularExpression) {
            registrar.replaceSubrange(transport, with: ";transport=tls")
        } else {
            registrar += ";transport=tls"
        }
        let tls = try await harness.engine.addAccount(
            AccountConfiguration(id: account.aor,
                                 registrar: registrar,
                                 username: account.username,
                                 isDefault: false),
            credentials: InlineCredentialStore(password: account.password))

        let reg: EngineHarness.Registration
        do {
            reg = try await harness.waitForRegistrationResult(tls)
        } catch is EngineHarness.Timeout {
            try? await harness.removeAccount(tls)
            throw XCTSkip("\(registrar) gave no registration result — provider weather, re-run later")
        }
        // Give the binding back before asserting, so a failure here does not leave the AOR
        // registered over a transport the rest of the suite does not use.
        try? await harness.removeAccount(tls)

        try XCTSkipIf(reg.statusCode == 408, "\(registrar) timed out (408) — provider weather")
        XCTAssertTrue(reg.active, "TLS registration to \(registrar) failed (\(reg.statusCode))")
        XCTAssertEqual(reg.statusCode, 200, registrar)
        XCTAssertGreaterThan(reg.expiration, 0, "TLS registration expiration not settled")
        print("[tls] \(account.aor) registered over TLS via \(registrar), expires in \(reg.expiration)s")
    }

    // MARK: 09 — attended transfer

    /// Loopback **attended** transfer (REFER with Replaces): call A is ACC1→ACC2, call B is
    /// ACC2→ACC1, then `attendedTransfer(A, replacing: B)` REFERs A's remote leg (ACC2) into
    /// an INVITE-with-Replaces against B's remote leg (ACC1's inbound side).
    ///
    /// Three observable legs of the exchange, all asserted:
    /// 1. `.callTransferStatus` on A reaches a **final** 2xx — the REFER/NOTIFY round-trip
    ///    succeeded (the REFER recipient reports its follow-up INVITE's outcome back).
    /// 2. `.callReplaced` fires on B's *inbound* leg with a fresh `newCall` — pjsua answers
    ///    INVITE-with-Replaces itself, so the replacement never passes `.incomingCall`.
    /// 3. **The transferor leg stays `.confirmed`.** Installing `on_call_transfer_status`
    ///    suppresses pjsua's built-in "hang up our leg on success" — that hangup is router
    ///    policy (`CallSessionRouter`), which this harness deliberately does not run. The
    ///    assertion pins the layering boundary: raw-engine consumers own the leg.
    ///
    /// Provider weather: a registrar that refuses to relay REFER (or swallows the NOTIFY
    /// subscription) makes step 1 time out or fail non-2xx — classified weather, not a defect.
    func test09_attendedTransfer() async throws {
        // `harness.registerLoopbackPair` registers the pair itself, so this runs standalone
        // under `-only-testing:` as well as inside a full-suite run.
        let (caller, calleeAOR) = try await harness.registerLoopbackPair()
        guard let secondAccount = await harness.account(forSlot: 2),
              let callerAOR = TestAccounts.all[1]?.dialURI else {
            throw XCTSkip("needs the ACC1/ACC2 same-domain pair (secrets/test-accounts.env)")
        }

        // Call A: ACC1 → ACC2 (the leg we REFER away). Call B: ACC2 → ACC1 (the leg whose
        // inbound side gets replaced by the REFER recipient's new INVITE).
        let callA = try await harness.engine.makeCall(to: calleeAOR, from: caller)
        try await harness.waitForCallOutcome(callA)
        try await harness.waitForCallState(callA, .confirmed)

        let inboundBefore = await harness.answeredIncoming.count
        let callB = try await harness.engine.makeCall(to: callerAOR, from: secondAccount)
        try await harness.waitForCallOutcome(callB)
        try await harness.waitForCallState(callB, .confirmed)
        // B's inbound leg is the last auto-answered call — the one `.callReplaced` fires on.
        guard let callBInbound = await harness.answeredIncoming.dropFirst(inboundBefore).last else {
            try await harness.engine.hangup(callA)
            try await harness.engine.hangup(callB)
            return XCTFail("call B produced no inbound leg to replace")
        }

        try await harness.engine.attendedTransfer(callA, replacing: callB)

        let finalStatus: Int32
        do {
            finalStatus = try await harness.waitForTransferFinal(callA)
        } catch is EngineHarness.Timeout {
            await hangUpAll([callA, callB])
            throw XCTSkip("REFER never reached a final NOTIFY — the registrar may not relay "
                          + "REFER (provider weather, not a defect)")
        }
        guard (200..<300).contains(finalStatus) else {
            await hangUpAll([callA, callB])
            throw XCTSkip("transfer REFER refused with SIP \(finalStatus) — provider weather")
        }

        // The replacement: ACC1's inbound leg of call B is superseded by a brand-new call
        // that pjsua answered internally.
        let newCall = try await harness.waitForReplaced(callBInbound)
        try await harness.waitForCallState(newCall, .confirmed)

        // Layering pin: the transferor leg is still up — the router's final-2xx hangup is
        // not in play here. Then we end it ourselves.
        let callAState = await harness.state(of: callA)
        XCTAssertEqual(callAState, .confirmed,
                       "raw engine must leave the transferor leg connected — hangup is "
                       + "SwiftPJSUAKit policy, not pjsua's (the installed callback disables it)")
        await hangUpAll([callA, callB, newCall])
    }

    // MARK: helpers

    /// Hang up every leg we know about; failures ignored — teardown must not throw.
    private func hangUpAll(_ calls: [CallID]) async {
        for call in calls { try? await harness.engine.hangup(call) }
    }

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
