# Offhook — Tech Debt

Numbered register of Offhook-app debt. Each item: **Cost** (what it hurts) and **Discharge** (the
change that retires it). IDs are `OH-#` to avoid collision with `swift-pjsua`'s `TD-#`. Reference
from code as `// TODO(OH-1): …`.

Status legend: **open** (live), **deferred** (intentional until a milestone), **obligation**
(must be removed before a milestone can land).

---

### OH-1 — `PhoneModel` doubles as engine-event consumer · **discharged 2026-07-04**

Phase 0 had `PhoneModel` own the single `engine.events` loop. Discharged by the CallKit
milestone: `SwiftPJSUAKit.CallSessionRouter` is now the sole consumer; `PhoneModel` observes
through `CXCallObserver` + the router's registration relay, and its event loop is deleted.

### OH-2 — Manual `AVAudioSession` activation · **discharged 2026-07-04**

`AudioSession.swift` (the Phase-0 bypass) is deleted. CallKit owns the session:
`CallKitController` configures the category on Start/Answer; the engine opens/closes the sound
device on `didActivate`/`didDeactivate`.

### OH-3 — Incoming calls auto-answered · **discharged 2026-07-04** (app path)

The app no longer auto-answers — incoming INVITEs surface through the router as CallKit
incoming-call UI (answer fulfills on `.confirmed`). *Note:* the **test harness** still
auto-answers by design (it is the loopback callee), and the incoming CallKit UI still awaits a
live two-instance verification (OH-8).

### OH-4 — No STUN/ICE configuration · *deferred*

No STUN/ICE surface in the UI; blocked on `swift-pjsua` TD-14 exposing the engine API.

- **Cost.** One-way / no audio behind symmetric NAT (echo endpoints mask it).
- **Discharge.** Expose STUN/DNS settings once `swift-pjsua` TD-14 lands. (Roadmap: Later)

### OH-5 — Single active call only · *deferred*

`PhoneModel.activeCall` tracks at most one call.

- **Cost.** No parallel calls, hold-and-swap, or conference.
- **Discharge.** Multi-call model + UI for the feature-demo milestone. (Roadmap: Later)

### OH-6 — Credentials held in plain in-memory state · *open*

`username`/`password` live in `PhoneModel` `@State`, unpersisted and unprotected.

- **Cost.** Re-typed every launch; not secure for a real account.
- **Discharge.** Keychain-backed account store (`../../Phone` has a reference implementation).

### OH-7 — Integration suite is XCTest, not Swift Testing · *deferred (works; don't churn)*

`Tests/` was written on XCTest for two load-bearing properties of a **live, ordered, stateful**
suite: strict `testNN_` execution order over one process-global engine (pjsua can't restart), and
**runtime** skips (`XCTSkip` mid-test on provider weather / no-camera). Swift Testing has
`.serialized` and condition traits, but runtime skipping and guaranteed intra-suite ordering need
re-design (state machine instead of ordered methods).

- **Cost.** Off the modern default; misses parameterized tests, `#expect` diagnostics, tags.
- **Discharge.** Migrate when touching the suite structurally anyway: one `@Suite(.serialized)`
  holding an explicit phase state machine; runtime skips become early returns with
  `withKnownIssue`/comments. Not before the suite is otherwise stable — it currently works.

### OH-8 — No true two-instance test (loopback shares one process) · *deferred*

The suite's "between devices" is loopback-through-registrar in **one** process: real SIP + real
(relayed) RTP, but both endpoints share an engine, a bridge, and a media clock — it cannot catch
device-asymmetry bugs (audio-route, CallKit interactions, camera capture) and never exercises two
independent engine instances.

- **Cost.** Video RTP flow, audible audio, and CallKit paths are only human-verifiable today.
- **Discharge.** Two-simulator harness: `simctl` boots two sims, installs the app on both, XCUITest
  (UI tests are the automation surface here — fill account fields from the same env/secrets scheme,
  tap dial/answer) drives A→B and asserts via the app's on-screen state/log. Prereq for the CallKit
  milestone's regression net. (Roadmap: Later)

### OH-9 — "connected but no audio" is diagnosable only by ear · *open*

Phase 0's success criterion is *hear audio*, and today nothing measures whether we did. When media
never flows, the app reports a connected call and the only instrument is a human listening. There
is no record of how long setup took, whether the sound device was open when media started, or
whether the microphone ever produced a sample.

- **Cost.** Every audio bring-up failure — the most common class in this stack — is bisected by
  hand. It also leaves a flaky provider ([SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md))
  indistinguishable from one of our own regressions.
- **Discharge.** Two halves. *Engine:* per-call timings (created→confirmed, confirmed→media,
  created→media, media→first captured mic sample) plus sound-device-active state around media
  start, emitted once per call — `../../TASK-code-swift-pjsua-audio-and-diagnostics.md` §3. *App:*
  surface the timeline in the debug/SIP tooling UI ([Roadmap](./Roadmap.md), Later). The app half
  is deferred until the engine half lands; the engine half is worth having on its own, since the
  integration suite can assert on it. The app half's shape is now specified —
  [Call-Quality-Statistics](./Call-Quality-Statistics.md) §2.1 gives these four intervals a home on
  `CallRecord`, and §8 makes "reached `confirmed` but media never flowed" the headline number this
  debt exists to produce.
- *Source: [Prior-Art](./Prior-Art.md) §1.3 — SashaSIP instruments exactly these four intervals.*

### OH-10 — a call that dies silently is still shown as connected · *open*

Established 2026-08-17 by `../../swift-pjsua/docs/Call-Termination-Paths.md`. **This is a
correctness bug in the app's model of a call, not a missing nicety.**

pjsip does not tell anyone when an established call stops working. Transport-state listeners are
registered per **transaction**, never per dialog (`sip_transaction.c:2922` is the only registration
in the SIP layer; `sip_dialog.c` has none), and pjsua's transport handler never touches
`pjsua_var.calls[]`. So when the TCP/TLS socket under an idle confirmed call dies — routine on iOS,
which kills sockets on suspend and changes network path constantly — the invite session stays
`CONFIRMED` and **nothing fires, indefinitely**. Over UDP there is no transport-death event at all.
Media-level failures do not help: `PJMEDIA_EVENT_MEDIA_TP_ERR` is forwarded but pjsua takes no
action on it (`pjsua_media.c:1918-1919`), and pjmedia has **no RTP inactivity detection** at any
build setting.

The user sees a running call timer, a "connected" label, and silence.

- **Cost.** The app actively asserts something false, in the one place a softphone must be
  trustworthy. It also makes every "the call dropped" report unattributable after the fact, since no
  record distinguishes *ended* from *died* — see
  [Call-Quality-Statistics](./Call-Quality-Statistics.md) §2.4.
- **Discharge.** Two halves.
  *App:* poll `statistics(for:)` on the active call every ~2 s while confirmed; treat `rx.packets`
  flat for N seconds (not on hold, media direction includes receive) as media-stalled — surface it
  in the UI and record `lastRxPacketAt` + `terminationClass`. This is the same poll the live quality
  indicator needs, so it is one mechanism serving both.
  *Engine:* `swift-pjsua` [TD-27](../../swift-pjsua/docs/Tech-Debt.md) — install
  `on_call_media_event`, `on_transport_state`, `on_call_media_transport_state` /
  `on_ice_transport_error`, so the app gets the fast signals too instead of waiting on a poll.
- **Confirmed live, 2026-08-18 — the premise holds, and this is no longer speculative.** A
  CONFIRMED call over a blackholed TCP transport sat for **938 s (15 min 38 s)** with **zero**
  callbacks before the session timer eventually killed it. `rx.packets` went flat within 2 s of
  the kill and stayed flat for the whole 938 s; `tx.packets` kept climbing the entire time; a
  `statistics(for:)` read succeeded every 2 s throughout, so the engine positively considered the
  call live. Full timeline:
  [Call-Termination-Paths](../../swift-pjsua/docs/Call-Termination-Paths.md) §4.1; apparatus:
  [SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md) §7.

  **The number that sizes this work: 938 s of a call the user was told was fine.** For comparison,
  on the *same dead socket*, registration reported 408 after 162 s — because it periodically
  transmits, and a call does not.

- **`rx.packets` flat is validated as the detector**, by the widest possible margin: it had the
  answer **938 s before the stack did**. Two refinements from the run, both narrowing the design:
  RTT is *not* a usable companion signal (RTCP rides the same transport and froze with it), and the
  detector's floor is the DTX silence period below, not the packet rate.

  Ranked by what actually knew, on one dead socket: **pjmedia's RTP counter at 2 s**, pjsip's
  transport layer at **126 s** (its 90 s TCP keep-alive found the dead connection and told the
  *account* handler), the account layer at **162 s**, and the call at **938 s**. Our poll is not a
  workaround for a missing signal — it is the earliest signal that exists, by two orders of
  magnitude.

- **The engine half of the discharge is smaller than it looked.** A second run (2026-08-18) dropped
  **RTP only**, leaving signalling healthy, for 1000 s: `on_call_media_event` fired **zero** times,
  because a silently blackholed path raises no socket error and so no `PJMEDIA_EVENT_MEDIA_TP_ERR`
  is generated at any layer. So installing that callback does **not** cover the "dead network path"
  case — it covers local socket errors and audio-device failures. The same run also showed the
  session timer refreshing a call whose media had been dead for 15 minutes, successfully and
  silently. **Nothing but the RTP counter detects this failure mode.** See
  [Call-Termination-Paths](../../swift-pjsua/docs/Call-Termination-Paths.md) §3.
- **Tuning is a product decision, but it now has a measured floor.** Observed live 2026-08-18: a
  healthy call that is *silent* still advances `rx.packets`, but only just. pjmedia suspends VAD for
  the first `PJMEDIA_STREAM_VAD_SUSPEND_MSEC` = **600 ms** of a stream and then lets it suppress
  silence, after which the codec emits one packet every `PJMEDIA_CODEC_MAX_SILENCE_PERIOD` =
  **5000 ms**. Measured: transmit froze at **22 packets** on every stream we captured — 600 ms of
  30 ms iLBC frames plus the silence trickle — against ~33 pkt/s while speech flows.

  So the rate on a healthy line is **not** "≈50 pkt/s or dead": it is a **166× swing** between
  speech and silence, and a flat-for-N detector with N ≤ 5 s fires on ordinary quiet. N must clear
  5 s by a wide margin. The existing guess (~10 s to "suspect", ~30 s to "declare") survives, and
  now has a reason rather than a hunch behind it.

  Two things this does not license. **Those are our binary's compile-time constants, not the
  peer's** — a peer built with `PJMEDIA_CODEC_MAX_SILENCE_PERIOD = -1` sends *nothing* during
  silence, and against that peer a flat counter is indistinguishable from death at any N. And
  **our null-audio test rig is the worst case**: digital silence, so VAD suppresses everything,
  where a real microphone's ambient noise would keep the stream talking. A muted call, or a peer
  who is simply not speaking, reproduces the worst case on real hardware.

  Prefer *showing* a degraded state over auto-terminating the call — hanging up on a user because
  of a two-second Wi-Fi glitch is a worse bug than the one being fixed.
- **Do not rely on session timers as the backstop** — measured, not assumed. `PJSUA_SIP_TIMER_OPTIONAL`
  only applies if the peer supports it (ours does, §8.1), and the refresh is only the *trigger*:
  failure → 10 s retry → BYE → the BYE's own 32 s timeout adds **83 s**. So the refresher's worst
  case is `SE/2 + ~83 s` ≈ **983 s**, and the **refreshee's is 1768 s (~29.5 min)** — which is the
  *incoming* call case, i.e. the one where the user is most likely to be waiting on a dead line.
  An inbound call that dies is invisible for roughly twice as long as an outbound one.
- *Related:* ICE keep-alive failure is the stack's only continuous liveness signal and needs
  [OH-4](#oh-4--no-stunice-configuration--deferred); upstream note:
  `../../swift-pjsua/Upstream/no-transport-death-notification-for-established-calls.md`.

## See Also

- [Design](./Design.md) · [Roadmap](./Roadmap.md) · [Prior-Art](./Prior-Art.md)
- `../../swift-pjsua/docs/Tech-Debt.md` (TD-1, TD-14 referenced above)

### OH-10 — media encryption is only as strong as the signalling hop · open (constraint, not a bug)

We ship SRTP with **SDES** keying and no DTLS-SRTP (`PJMEDIA_SRTP_HAS_DTLS = 0`, upstream's
default; see [`swift-pjsip/docs/Build-Time-Feature-Gates.md`](../../swift-pjsip/docs/Build-Time-Feature-Gates.md)).
SDES puts the media key **in the SDP**, so it is protected only by whatever protects the
signalling.

- **Cost.** Any hop that can read our signalling can read our media keys. That means every SIP
  proxy, SBC and registrar on the path, not just the far endpoint — and it means media
  confidentiality collapses to *"was every signalling hop TLS, all the way"*, which is a property
  we cannot verify from the client. Over UDP or TCP signalling, SRTP with SDES is close to
  decorative against a network attacker.
- This is **not** end-to-end encryption and should never be described as such in UI or docs. If a
  padlock is ever shown, it can honestly mean "encrypted to the server", nothing more.
- **Not a defect.** It is the upstream default and the correct trade for a client that does not
  vendor OpenSSL. Recorded because the constraint is invisible from our own API surface: nothing in
  `swift-pjsua` reports which keying method was used, so "SRTP is on" reads as stronger than it is.
- **Discharge.** Either enable DTLS-SRTP — which is a gated decision with real cost, see
  [Roadmap](./Roadmap.md) — or, much cheaper and worth doing first, surface the keying method and
  the signalling transport together so the actual guarantee is visible rather than assumed.
- Relates: [Roadmap](./Roadmap.md) "Gated — DTLS-SRTP"; `swift-pjsua` TD-22 (TLS listener
  credentials), since both are about believing a security property we have not verified.
