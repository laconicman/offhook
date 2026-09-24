import XCTest
import SwiftPJSUA

/// Live observation runs for the call-lifecycle verification pass
/// (`../../TASK-code-call-lifecycle-verification.md`).
///
/// These are **instruments, not assertions about our code**. Each one drives a real call into a
/// chosen condition and prints a timestamped trace of everything the engine reports, so the
/// source-derived claims in `swift-pjsua/docs/Call-Termination-Paths.md` can be confirmed or
/// refuted against a live stack. Most of them cannot fail: "nothing happened" is the predicted
/// result, and the trace is the deliverable.
///
/// Opt-in (`OFFHOOK_OBSERVE=1`) and meant to be run **alone**, because §2 deliberately breaks
/// the host's network for ten minutes:
///
/// ```
/// TEST_RUNNER_OFFHOOK_OBSERVE=1 xcodebuild test -scheme Offhook \
///   -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.5' \
///   -only-testing:OffhookTests/CallLifecycleObservationTests/test20_sessionTimerAndHoldResumeRecords
/// ```
///
/// Every host-visible marker is prefixed `[OBSERVE]` so a driver script can wait on it; every
/// engine event is traced by ``EngineHarness`` as `[EVENT]`. Both carry a local wall clock, so
/// the trace lines up with actions taken on the Mac (`date '+%H:%M:%S.%3N'`).
final class CallLifecycleObservationTests: XCTestCase {

    private var harness: EngineHarness { .shared }

    override func setUp() async throws {
        try XCTSkipUnless(EngineHarness.tracing,
                          "observation runs are opt-in — set TEST_RUNNER_OFFHOOK_OBSERVE=1")
        try await harness.startIfNeeded()
    }

    private func mark(_ text: String) {
        print("[OBSERVE] \(EngineHarness.stamp()) \(text)")
    }

    // MARK: 20 — §1 free observations (no network interference)

    /// §1.1 + §1.2 together, because both are read out of one call's pjsip log.
    ///
    /// - **§1.1 session timer**: the INVITE/200 OK dump in the log carries `Supported: timer`,
    ///   `Session-Expires:` and `Min-SE:` if RFC 4028 was negotiated. Harvested from the log by
    ///   the driver, not asserted here — whether our providers negotiate one is a property of
    ///   *them*, and either answer is a valid finding.
    /// - **§1.2 smart media update**: one hold/resume cycle should produce three stream
    ///   lifetimes (initial, held, resumed), i.e. two `Media stream call%02d:%d is destroyed`
    ///   lines before the final teardown. The `HOLD`/`RESUME` markers bracket the log so the
    ///   lines can be attributed.
    func test20_sessionTimerAndHoldResumeRecords() async throws {
        let (caller, calleeAOR) = try await harness.registerLoopbackPair()
        mark("REGISTERED caller=\(caller) callee=\(calleeAOR)")

        let call = try await harness.engine.makeCall(to: calleeAOR, from: caller)
        try await harness.waitForCallState(call, .confirmed)
        try await harness.waitForActiveMedia(call, kind: .audio)
        mark("CALL-UP \(call) — SDP settled, counting stream lifetimes from here")
        try await Task.sleep(for: .seconds(5))

        mark("HOLD-BEGIN")
        try await harness.engine.setHold(call)
        try await Task.sleep(for: .seconds(5))
        mark("HOLD-END")

        mark("RESUME-BEGIN")
        try await harness.engine.resume(call)
        try await harness.waitForActiveMedia(call, kind: .audio)
        try await Task.sleep(for: .seconds(5))
        mark("RESUME-END")

        mark("HANGUP-BEGIN")
        try await harness.engine.hangup(call)
        try await harness.waitForCallState(call, .disconnected)
        mark("HANGUP-END — expect one more stream teardown above this line")
    }

    // MARK: 21 — §2 the decisive experiment: transport death under an idle call

    /// Establishes a loopback call over the pair's TCP-registered transport, then sits idle
    /// while the driver kills the network underneath it, tracing state and RTP counters
    /// throughout.
    ///
    /// The prediction under test (`Call-Termination-Paths.md` §4): **nothing fires**. The call
    /// stays `.confirmed`, no `PJSUAEvent` arrives, and only the receive packet counter — which
    /// pjmedia maintains but never acts on — reveals that the media stopped.
    ///
    /// Two things make the trace decisive rather than merely quiet:
    ///
    /// - `statistics(for:)` wraps `pjsua_call_get_stream_info`, which fails once the call or its
    ///   media session is gone. **A successful read each tick is positive evidence that pjsua
    ///   still considers the call live** — the absence of events is not just an event we missed.
    /// - Both legs are traced. The loopback callee is the same process, so a one-sided failure
    ///   (only the caller's transport dying) is visible as a divergence between them.
    ///
    /// Finally it hangs up, to observe what §4 predicts for a *new* transaction over a dead
    /// transport: immediate failure rather than the full Timer B/F wait.
    func test21_transportDeathIdleCall() async throws {
        let seconds = ProcessInfo.processInfo.environment["OFFHOOK_OBSERVE_SECONDS"]
            .flatMap(Int.init) ?? 660
        let (caller, dial) = try await observationTarget()
        let answeredBefore = await harness.answeredIncoming.count
        let call = try await harness.engine.makeCall(to: dial, from: caller)
        try await harness.waitForCallState(call, .confirmed)
        try await harness.waitForActiveMedia(call, kind: .audio)
        try await Task.sleep(for: .seconds(3)) // let RTP settle before the baseline sample

        let callee = await localCalleeLeg(newerThan: answeredBefore)
        mark("CALL-UP caller-leg=\(call) callee-leg=\(callee.map(String.init(describing:)) ?? "none")")
        mark("IDLE-BEGIN — no hold, no DTMF, no re-INVITE for \(seconds)s. Kill the transport now.")

        try await observeIdle(caller: call, callee: callee, seconds: seconds)

        // §4's other half: a *new* transaction over a dead transport should fail fast rather
        // than wait out Timer B/F (~32 s). Time it and record the state we land in.
        mark("HANGUP-BEGIN")
        let hangupStarted = Date()
        do {
            try await harness.engine.hangup(call)
        } catch {
            mark("HANGUP-THREW \(error)")
        }
        do {
            try await harness.waitForCallState(call, .disconnected, timeout: 60)
            mark("HANGUP-END disconnected after "
                 + String(format: "%.1f", Date().timeIntervalSince(hangupStarted)) + "s")
        } catch {
            mark("HANGUP-END still not disconnected after 60s — state="
                 + String(describing: await harness.state(of: call)))
        }
    }

    // MARK: 22 — §3 media death with signalling intact

    /// Drops **RTP only** (`pf-blackhole.sh udp`) and leaves SIP/TCP up, to see what — if
    /// anything — reaches the app when the media path dies under a call whose signalling is
    /// perfectly healthy. Rows 9/10/12/13 of the taxonomy.
    ///
    /// The prediction (`Call-Termination-Paths.md` §3): **nothing**. `PJMEDIA_EVENT_MEDIA_TP_ERR`
    /// falls through `default: break` in `call_media_on_event()` and pjsua takes no action; now
    /// that `on_call_media_event` is installed we can see whether the event is even raised.
    ///
    /// Runs past the 900 s session-timer refresh on purpose. Signalling is up, so the refresh
    /// should **succeed** — renewing a call whose media has been dead for a quarter of an hour.
    /// That is worth having on the record: it shows the session timer is a dialog keep-alive, not
    /// a liveness check.
    func test22_rtpOnlyBlackhole() async throws {
        let seconds = ProcessInfo.processInfo.environment["OFFHOOK_OBSERVE_SECONDS"]
            .flatMap(Int.init) ?? 1000
        let (caller, dial) = try await observationTarget()
        let answeredBefore = await harness.answeredIncoming.count
        let call = try await harness.engine.makeCall(to: dial, from: caller)
        try await harness.waitForCallState(call, .confirmed)
        try await harness.waitForActiveMedia(call, kind: .audio)
        try await Task.sleep(for: .seconds(3))

        let callee = await localCalleeLeg(newerThan: answeredBefore)
        mark("CALL-UP caller-leg=\(call) callee-leg=\(callee.map(String.init(describing:)) ?? "none")")
        mark("IDLE-BEGIN — signalling stays UP; kill RTP only for \(seconds)s.")
        try await observeIdle(caller: call, callee: callee, seconds: seconds)

        // Signalling was never touched, so this should behave exactly like a normal hangup —
        // which is itself the check that the `udp` block really did leave TCP alone.
        mark("HANGUP-BEGIN")
        let started = Date()
        do { try await harness.engine.hangup(call) } catch { mark("HANGUP-THREW \(error)") }
        do {
            try await harness.waitForCallState(call, .disconnected, timeout: 60)
            mark("HANGUP-END disconnected after "
                 + String(format: "%.1f", Date().timeIntervalSince(started)) + "s")
        } catch {
            mark("HANGUP-END still not disconnected after 60s")
        }
    }

    // MARK: pointing the instruments somewhere else

    /// Where an observation run should call, and from which account.
    ///
    /// Defaults to the ACC1 → ACC2 loopback pair. Override to aim the same instrument at **any**
    /// provider — which is the only way to answer "is this behaviour provider-specific?", and the
    /// only way to reach a transport (UDP) or a codec our own pair cannot negotiate:
    ///
    /// ```
    /// TEST_RUNNER_OFFHOOK_OBSERVE_DIAL=sip:thetestcall@sip.antisip.com \
    /// TEST_RUNNER_OFFHOOK_OBSERVE_ACCOUNT=4 …
    /// ```
    ///
    /// With a dial override there is no local callee leg — the far end is somebody else's echo
    /// service — so runs report one leg instead of two.
    private func observationTarget() async throws -> (caller: AccountID, dial: String) {
        let env = ProcessInfo.processInfo.environment
        guard let dial = env["OFFHOOK_OBSERVE_DIAL"], !dial.isEmpty else {
            let pair = try await harness.registerLoopbackPair()
            return (pair.caller, pair.calleeAOR)
        }
        let slot = env["OFFHOOK_OBSERVE_ACCOUNT"].flatMap(Int.init) ?? 1
        let caller = try await harness.registerAccount(slot: slot)
        mark("TARGET override — calling \(dial) from ACC\(slot)")
        return (caller, dial)
    }

    /// The auto-answered local callee leg, if this run has one. A dial override means the far end
    /// is remote, so there is nothing local to trace — and a *stale* id from an earlier call in the
    /// same process would be worse than nothing.
    private func localCalleeLeg(newerThan count: Int) async -> CallID? {
        let answered = await harness.answeredIncoming
        return answered.count > count ? answered.last : nil
    }

    // MARK: the shared instrument

    /// Sit on a confirmed call and trace it: per-leg state, RTP counters, and the running count of
    /// media events. Samples every 2 s; the trace is the deliverable, there is nothing to assert.
    ///
    /// `statistics(for:)` wraps `pjsua_call_get_stream_info`, which fails once the call or its
    /// media session is gone — so a successful read is **positive** evidence that pjsua still
    /// considers the call live, which is what makes "no events arrived" mean something.
    private func observeIdle(caller: CallID, callee: CallID?, seconds: Int) async throws {
        let started = Date()
        var tick = 0
        var reportedEvents = 0
        while Date().timeIntervalSince(started) < Double(seconds) {
            var line = "t+\(Int(Date().timeIntervalSince(started)))s"
            for (label, id) in [("caller", caller), ("callee", callee)]
                .compactMap({ pair -> (String, CallID)? in pair.1.map { (pair.0, $0) } }) {
                let state = await harness.state(of: id)
                let stats = try? await harness.engine.statistics(for: id)
                line += " | \(label) state=\(state.map(String.init(describing:)) ?? "nil")"
                if let stats {
                    line += " rx=\(stats.receive.packets)pkt/\(stats.receive.bytes)B"
                        + " tx=\(stats.transmit.packets)pkt lost=\(stats.receive.lost)"
                        + " rtt=\(String(format: "%.0f", stats.roundTrip.meanMs))ms"
                } else {
                    line += " stats=UNAVAILABLE" // the call or its media session is gone
                }
            }
            // The harness's list is process-wide; only this run's legs count.
            let events = await harness.mediaEvents
                .filter { $0.call == caller || $0.call == callee }
            line += " | mediaEvents=\(events.count)"
            mark(line)
            // Surface each new one once, in full — the whole question of §3 is what arrives.
            for event in events.dropFirst(reportedEvents) {
                mark("MEDIA-EVENT call=\(event.call) mediaIndex=\(event.mediaIndex) \(event.event)")
            }
            reportedEvents = events.count
            tick += 1
            try await Task.sleep(for: .seconds(2))
        }
        mark("IDLE-END after \(tick) samples, \(reportedEvents) media events")
    }
}
