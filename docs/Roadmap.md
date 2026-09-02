# Offhook — Roadmap

Priority-ordered milestone summary. Rationale lives in [Design](./Design.md); debt that each
milestone discharges is in [Tech-Debt](./Tech-Debt.md).

## Now — Phase 0 smoke test

Prove the stack runs end-to-end before building breadth:
start → register → echo call → **hear audio**, driven directly by `PhoneModel` with manual
`AVAudioSession` activation. Green run validates the `SerialExecutor`/one-thread model, the
callback bridge, registration parsing, and the media → `pjsua_conf_connect` audio wiring.
See the smoke procedure in [README](../README.md) and endpoints in
[SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md).

## Next — CallKit / PushKit

- **CallKit outgoing + incoming** via `SwiftPJSUAKit` (`CallKitController` + `CallSessionRouter`).
  The router becomes the **sole** `engine.events` consumer, replacing `PhoneModel`'s event loop
  and the Phase-0 `AudioSession` (discharges [OH-1](./Tech-Debt.md), [OH-2](./Tech-Debt.md),
  [OH-3](./Tech-Debt.md)).
- **PushKit / hybrid VoIP push** (RFC 8599) — persisted-connection + push with no double ring.
  End-to-end push needs a self-hosted Flexisip/OpenSIPS with our APNs key
  ([SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md) §3).

## Later — debug tooling & the Swiss-knife

- **Debug / SIP tooling UI** — raw event stream, conference-slot inspector, live SIP log. Include
  the per-call setup timeline (created→confirmed→media→first mic sample) once the engine reports
  it — [OH-9](./Tech-Debt.md).
- **Call-liveness detection** — poll RX packet counters on the active call and surface a stalled-media
  state. Not polish: pjsip never reports that an established call's transport or media died, so
  without this the app shows a dead call as connected indefinitely —
  [OH-10](./Tech-Debt.md), mechanism in
  `../../swift-pjsua/docs/Call-Termination-Paths.md` §4. Shares one poll with the in-call quality
  indicator ([Call-Quality-Statistics](./Call-Quality-Statistics.md) §2.4).
- **Feature demos** — hold, parallel calls, local-mix and server-focus conference, video.
  Transfer, when it lands, must be **attended from the first version**, not blind-only with
  attended retrofitted (*Source: [Prior-Art](./Prior-Art.md) §1.4*).
- **Swiss-knife settings** — STUN/DNS/codec configuration (gated on `swift-pjsua` TD-14 exposing
  the STUN/ICE surface; see [OH-4](./Tech-Debt.md)).
- **Credential persistence** — Keychain-backed accounts ([OH-6](./Tech-Debt.md); `../../Phone` has a
  reference Keychain implementation).

## Gated — DTLS-SRTP (decision, not a task)

Not scheduled. Recorded so the decision is made deliberately rather than by whoever first needs it.

Media encryption today is **SDES-SRTP**, which works and ships. **DTLS-SRTP is off**
(`PJMEDIA_SRTP_HAS_DTLS = 0`, upstream's own default) and enabling it requires vendoring **OpenSSL**
into `swift-pjsip` — `transport_srtp_dtls.c` includes the OpenSSL headers unconditionally, and no
choice of SIP-TLS backend changes that. Full reasoning:
[`swift-pjsip/docs/Build-Time-Feature-Gates.md`](../../swift-pjsip/docs/Build-Time-Feature-Gates.md).

**Trigger — do it when one of these is true, not before:**

- a provider we intend to support offers DTLS-SRTP only, or refuses SDES;
- we need WebRTC interop;
- or a deployment requires that media keys never traverse signalling, which SDES cannot satisfy
  (see [OH-10](./Tech-Debt.md)).

**What it costs when we pull the trigger:** an OpenSSL dependency in a shipped binary, with its
patch cadence, plus the size. That is an ongoing obligation, not a one-off build change, which is
why this is written as a gate rather than a backlog item.

Note that if we ever do link OpenSSL, the question "why carry two TLS stacks" reopens — the answer
is likely still Apple's Network framework for SIP-TLS (platform-native, no certificate-store
plumbing) with OpenSSL confined to media keying, but it should be re-argued at that point rather
than inherited.

## Later — product surface (from prior art)

Small, independent items lifted from the [Prior-Art](./Prior-Art.md) survey. Each is cheap on its
own; none blocks another.

- **Account-settings UX** — a realistic example under every SIP field plus inline help. Username vs
  Login vs Domain vs Server is where users get stuck, and it is a UI problem, not a docs problem.
  *(§1.3)*
- **Call statistics & call quality** — designed in
  [Call-Quality-Statistics](./Call-Quality-Statistics.md) (2026-08-17). One immutable record per
  stream captured at `on_stream_destroyed`, stored raw in an append-only file; **no MOS** — the
  components, because G.107 disclaims per-call opinion prediction. The consumer-facing
  incoming/outgoing/missed donut falls out of the same data as a `reduce`, and ships with the
  **excluded-numbers filter** that stops test extensions distorting it *(§1.3)*. Blocked on
  `swift-pjsua` wiring `on_stream_destroyed` and exposing the jitter-buffer stats it already
  discards (`swift-pjsua` TD-26) — see that doc §10.
- **Separate ring device from call-audio device** — otherwise incoming calls are inaudible whenever
  the headset is off the head. *(§1.3)*
- **Mic Mode panel** — explain Standard / Voice Isolation / Wide Spectrum and deep-link to Control
  Center; set `NSAlwaysAllowMicrophoneModeControl`. Never a toggle: see
  [Design](./Design.md), "Constraints". *(§1.3)*
- **Recording**, if we add it: default **off**, explicit consent state. *(§1.4)*
- **Audio settings that must not be hard-coded** — VAD on/off, and keep-sound-device-open. Both
  have a defensible other value and the second is platform-split (CallKit owns the device
  lifecycle on iOS; nothing does on macOS). Engine side:
  `../../TASK-code-swift-pjsua-audio-and-diagnostics.md` §§2/4.
- **Diagnostics & log export** — two channels, both settings-controlled. `Logger`/OSLog for
  operational logging (privacy by default; **no** hand-rolled regex redaction — see
  [Prior-Art](./Prior-Art.md) §1.4), plus an explicitly enabled diagnostic capture that can
  include pjsip's own log at a chosen level (`pjsua_logging_config.cb`) and be scoped and exported
  from settings. Off by default, bounded retention.
  **Unverified, and it decides the design:** whether `OSLogStore` (`.currentProcessIdentifier`)
  returns `private` values to the process that wrote them, or redacts them on readback. If it
  redacts, OSLog cannot be the export source and the diagnostic capture must write its own file.
  Check this before building either half.

## Later — macOS

Offhook is iOS-first but intended to run on macOS, which is what makes the dual push/socket
architecture necessary ([Push-vs-Active-Socket](./Push-vs-Active-Socket.md)). Blocked at the
bottom on `swift-pjsua` TD-8 (no macOS slice) —
see `../../TASK-code-swift-pjsip-macos-slice.md`.

- **Audio quality baseline** — minimise VoiceProcessingIO ducking of other audio, and keep the
  sound device open between calls. Both are build-time changes in `swift-pjsip`/`swift-pjsua`
  rather than app work: `../../TASK-code-swift-pjsua-audio-and-diagnostics.md` §§1–2.
  *(Source: [Prior-Art](./Prior-Art.md) §1.3)*
  **The ducking half no longer needs a patch.** We contributed the lever upstream
  ([pjproject#5178](https://github.com/pjsip/pjproject/pull/5178), merged 2026-08-17) as two
  `config.h` macros, so it is now a line in `swift-pjsip`'s `scripts/config_site.h` rather than a
  carried patch — and legally clean, written from Apple's headers and WWDC23 10235 rather than from
  SashaSIP's GPL patch. Two things to decide when we set it:
  - `PJMEDIA_AUDIO_DEV_COREAUDIO_ADVANCED_DUCKING 1` — voice-activity-driven instead of a duck
    held for the whole call. Upstream defaults it to `0` and enables it only for iOS —
    a deliberate decision, confirmed by the maintainer — so **a macOS slice must set it
    explicitly**.
  - `PJMEDIA_AUDIO_DEV_COREAUDIO_DUCKING_LEVEL` — depth, left at Apple's `Default` upstream on
    purpose. Prior-Art §1.3 records SashaSIP choosing `Min`; that is now our choice to make per
    product rather than something we inherit, and "minimise" in this bullet means picking
    `kAUVoiceIOOtherAudioDuckingLevelMin` here, deliberately.
- **Lifecycle recovery** — `NWPathMonitor` path-satisfied and `NSWorkspace.didWakeNotification`
  both feed one backoff-limited re-register that **exits on success**. The socket-only half of the
  hybrid model. *(§1.4 records the retry-ladder bug to not reproduce.)*
- **Distribution outside the App Store** — a `latest.json` feed (version, build,
  `minimumSystemVersion`, artifact, sha256) beside the release; verify OS floor and SHA-256 before
  install. Sparkle-free, ~200 lines. Requires Developer ID signing and notarization — the step
  SashaSIP has not taken. *(§1.3)*

## See Also

- [Design](./Design.md) · [Tech-Debt](./Tech-Debt.md) · [Prior-Art](./Prior-Art.md)
