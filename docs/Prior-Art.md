# Offhook — Prior art

Teardowns of other softphones, kept as a survey. Each entry records what was **verified** (with a
file or symbol reference), what we **take**, and what we **avoid** — so a decision that came from
someone else's code can be traced back to the evidence for it.

**This file is the only source-oriented doc in `docs/`.** Everything else is organised by concern:
a decision lives in [Design](./Design.md), a plan in [Roadmap](./Roadmap.md), a thing we owe in
[Tech-Debt](./Tech-Debt.md). When an idea from here graduates into one of those, it moves there and
carries a one-line provenance note (`Source: Prior-Art §1.3`) — it does **not** stay duplicated
here. This file keeps the analysis; those files keep the commitments.

Entries are respectful teardowns of other people's work. Keep them factual, cite what was actually
checked, and mark inference as inference.

---

## 1. SashaSIP — native macOS softphone (GPL-2.0-or-later)

<https://github.com/IIITrinity/SashaSIP-Releases> · analysed at **v1.0.53 (build 153)**, 2026-08-11.

A macOS-only SIP softphone written by one developer for his wife, who needed a real softphone for
work and had been running Windows apps under Whisky. It is the closest existing thing to
"Offhook, but macOS and finished", which is why it is worth a full teardown.

### 1.1 The repo layout is deliberate, not broken

The public repo holds 4 commits: two READMEs, a licence, and five screenshots. No code. Development
happens in a private repo, and **GPL compliance is met by attaching a full source tarball to every
GitHub release** (`SashaSIP-<version>-source.tar.gz`, listed in `SHA256SUMS`). So the entire
codebase is public — just as release assets rather than as tracked files.

`AGENTS.md` in that tarball explains the release cadence (builds 142→153 in about two weeks): the
project is Codex-agent-driven, and the mandated per-task workflow is commit to `main` → bump
version → publish a release. `.codex/agents/` holds five role definitions and `docs/AGENT_TEAM.md`
a routing table between them.

*Working copy for this analysis:* `../../SashaSIP-Releases/releases/v1.0.53/` — `src/` (extracted
tarball, checksum-verified) and `pkg/` (expanded installer, for binary inspection).

### 1.2 Verified stack

| Layer | What it is | How verified |
|---|---|---|
| Core | PJSIP **2.17**, vendored as a checksummed tarball, patched, built static, universal arm64+x86_64 | `Scripts/build-pjsip.sh`; `file` on the shipped binary |
| API | **PJSUA2 (C++)** behind a 1530-line ObjC++ bridge | `Sources/SIPBridge/SIPCoreBridge.mm` |
| TLS | pjproject's **`PJ_SSL_SOCK_IMP_DARWIN`** backend — Apple SecureTransport | `_SSLCreateContext` / `_SSLSetProtocolVersionMin` are undefined symbols in the shipped binary; no OpenSSL linked |
| Codecs | `--disable-video` plus almost every codec disabled → G.711 + G.722 only | `Scripts/build-pjsip.sh` configure flags |
| App | AppKit lifecycle + window controllers, SwiftUI content, Combine view models, direct `libsqlite3` | `otool -L`; `Sources/SashaSIPApp/` |
| Ship | macOS 13+, 9 MB universal, **ad-hoc signed, not notarized**, unsandboxed | `codesign -dv`; `SashaSIP.entitlements` |

**On PJSUA2 vs our pjsua1 invariant.** They use the C++ API and it works — *because ObjC++ can
subclass `Call`/`Account` and override virtuals*. That confirms the premise of
`../../swift-pjsua/docs/Production-Roadmap.md` §2 rather than contradicting it: C++ subclassing is the
whole point of PJSUA2, Swift/C++ interop cannot do it, and ObjC++ is the only door. The price is
visible in their tree — an untyped 1530-line bridge that redeclares every model as an `NSObject`
and is unreachable from Swift tests.

**On TLS, we are ahead.** pjproject's own header comments mark `PJ_SSL_SOCK_IMP_DARWIN` (3,
SecureTransport) as *deprecated in macOS 10.15 / iOS 13*; `PJ_SSL_SOCK_IMP_APPLE` (4) is the
Network.framework backend. SashaSIP gets the deprecated one because `aconfigure.ac` autodetects
`--enable-darwin-ssl` first and stops there. `../../swift-pjsip/scripts/config_site.h` pins
`PJ_SSL_SOCK_IMP_APPLE` explicitly. **Caution:** that is exactly the kind of thing a "simplify the
build by trusting autoconf" change would silently regress.

### 1.3 Taken

Ordered by value. Where an item has graduated, the destination is named.

1. **Minimise VoiceProcessingIO other-audio ducking.** Their `Patches/PJSIP/0001-…` sets
   `kAUVoiceIOProperty_OtherAudioDuckingConfiguration` on the VPIO unit (advanced ducking on,
   ducking level minimum) when echo cancellation is enabled, macOS 14+. Without it the system
   slams all other audio for the duration of a call. Apple-documented property, applies to iOS 17+
   equally, and pjmedia owns the AudioUnit so there is no way to reach it except at build time.
   → **[Roadmap](./Roadmap.md)** (macOS/audio), work routed to `swift-pjsip` in
   `../../TASK-code-swift-pjsua-audio-and-diagnostics.md` §1.
2. **Keep the sound device open between calls** — `snd_auto_close_time = -1`. Stops CoreAudio
   restarting the device at media start, which is a classic "first half-second is missing" cause.
   → same task, §2.
3. **First-audio timing instrumentation.** Their bridge measures created→confirmed,
   confirmed→media, created→media, and **media→first captured mic sample**, logged once per call.
   This is precisely the telemetry that turns "I couldn't hear anything" into a number, and Phase
   0's success criterion is literally *hear audio*. → **[OH-9](./Tech-Debt.md)**, engine work in
   the same task §3.
4. **VAD off by default.** Their `EpConfig` comment gives the reason: VAD clips the beginning of
   the first phrase. Right default for a softphone. → same task, §4.
5. **A no-op backend behind a compile flag.** `SASHASIP_HAS_PJSIP` selects between the real bridge
   and a complete stub, so the app builds and tests with no PJSIP linked at all. This is the
   cheapest known answer to `swift-pjsua` TD-15/TD-8 (pure-logic types aren't headlessly testable;
   no macOS slice) and unblocks TD-12 (no CI gate) without waiting for the macOS slice. → same
   task, §5.
6. **`latest.json` update feed, no Sparkle.** A small JSON (version, build, `minimumSystemVersion`,
   artifact name, sha256) published beside the release; the app checks the OS floor *and* verifies
   the SHA-256 of the download before installing (`Sources/SashaSIPUpdateKit/`, ~185 lines).
   Directly reusable when Offhook ships outside the App Store. → **[Roadmap](./Roadmap.md)**.
7. **Ring device separate from speaker device.** Ring on the built-in speakers while call audio
   goes to the headset — otherwise an incoming call is inaudible whenever the headset is off the
   head. → **[Roadmap](./Roadmap.md)**.
8. **Statistics, and the filter that makes them useful.** The stats view itself is a reduce over
   call history into a donut (incoming/outgoing/missed) plus total duration, for day/week/month —
   no separate table, no aggregation layer. The non-obvious part is in Settings: a user-editable
   **excluded-numbers list**, so test extensions and robocalls don't distort the picture.
   → **[Roadmap](./Roadmap.md)**.
9. **Per-field examples in SIP account settings.** Every field carries a realistic example
   underneath (`1001, 2002, operator`) and an ⓘ. Username vs Login vs Domain vs Server is where
   users of every softphone get stuck; this is a UI fix for it, not a documentation fix.
   → **[Roadmap](./Roadmap.md)**.
10. **Reduce-motion as a design token.** `MotionPolicy(userPreference:systemReduceMotion:)`
    combines the app setting with `@Environment(\.accessibilityReduceMotion)` and is unit-tested —
    the one part of their app with real test coverage. The transferable idea is not "support
    reduce motion" but **extracting a cross-cutting UI decision into a value type**, which is what
    made it a pure function of two inputs and therefore testable at all. Applies equally to any
    other policy we accumulate (selected line, degraded-network state, what a call state permits).

**Voice Isolation — the answer is that there is no API.** Worth recording because it saves the
research: an app cannot select a microphone mode. SashaSIP sets
`NSAlwaysAllowMicrophoneModeControl` in `Info.plist` (so macOS offers the Mic Mode picker outside
active capture), then ships a settings panel that explains Standard / Voice Isolation / Wide
Spectrum and deep-links to Control Center and
`x-apple.systempreferences:com.apple.Sound-Settings.extension?input`. Mic Mode is user-owned on
both platforms; the plist key plus a good explanation is the entire lever available.
→ **[Design](./Design.md)**, "Constraints".

### 1.4 Avoided

None of these are debt *we* carry — they are things to not reproduce when we build the equivalent.

- **Blind transfer only.** `xfer()` with no attended variant, and refused outright while the call
  is held or in a conference. Their own `docs/AGENT_TEAM.md` lists attended transfer as still to
  come. **Lesson for us:** design the transfer surface so attended (`REFER` with `Replaces`) is
  expressible from the first version, not retrofitted — see the task, §6.
- **Conference as a client-side N×N mesh.** Every participant pair gets a reciprocal
  `startTransmit` through the pjsua conference bridge, and the full route set is torn down and
  rebuilt on every media change. Workable for three parties; it is not server-side conferencing
  and does not pretend to be. Relevant to D-CONF.
- **Call state discovered by polling.** Their level-metering timer doubles as state reconciliation
  — if the bridge no longer tracks a call, the app infers the call ended. State should arrive on
  callbacks; a poll loop that also owns state is a workaround wearing a metering hat. Offhook is
  event-driven by construction ([Design](./Design.md), "Engine events"), so this is a confirmation
  rather than a warning.
- **A retry ladder that never exits early.** `AppDelegate.swift:394` loops over delays
  `[initial, 10, 30, 60]`, re-registering each time, and on success calls `continue` — which is
  identical to falling through. Every wake therefore burns the full ladder (~102 s of wakeups)
  even when the first attempt succeeded; it wants `return`. **Take the shape, not the code:**
  `NWPathMonitor` path-satisfied plus `NSWorkspace.didWakeNotification`, both feeding one
  backoff-limited re-register, is the right skeleton for macOS
  ([Push-vs-Active-Socket](./Push-vs-Active-Socket.md) covers the iOS half).
- **Recording that defaults to on.** Their own P0 list flags it: a missing setting is read as
  `true`, so a fresh install records calls. Whatever we build, the default is off and the consent
  state is explicit.
- **Hand-rolled log redaction.** Their `AppLogger` (447 lines) writes structured text to files and
  strips secrets with regex substitution before writing. The goal is right; the mechanism is a
  **denylist** — miss a pattern and it leaks, and SIP payloads are precisely where an unanticipated
  pattern appears. `Logger`/OSLog inverts this: interpolated values are `<private>` unless
  explicitly marked public, so the failure mode is a missing detail rather than a leaked
  credential. **Decision (2026-08-11): use `Logger`, not a redacting file logger.** Their ZIP
  export still names a real need, which is why the *export* half graduated to
  [Roadmap](./Roadmap.md) while the redaction half is rejected here.
- **God objects.** `MainRootView` 3341 lines, `SettingsWindowController` 3243, `MainViewModel`
  1573, over ~20k Swift LOC total with 8 test files and essentially no app or bridge coverage.
  Acknowledged in their own P2 list. Mentioned here only because it is the predictable end state
  of high-velocity agent-driven development without a structural gate.

### 1.5 Licence posture — read before copying anything

SashaSIP is **GPL-2.0-or-later**. Ideas, API knowledge, UI patterns, and the facts recorded above
are free to use. **Their source is not**, and that includes the ducking patch — it is their
authored work even though it targets pjproject.

For the one item where this matters in practice: the ducking property, its configuration struct,
and the minimum-level constant are all public Apple API documented in `AudioUnitProperties.h`.
Write our patch from Apple's documentation. Setting a documented property in the one way it can be
set is not copyrightable expression; pasting their hunk would still be copying. Do the former.

---

## See Also

- [Design](./Design.md) · [Roadmap](./Roadmap.md) · [Tech-Debt](./Tech-Debt.md)
- [Push-vs-Active-Socket](./Push-vs-Active-Socket.md) — the iOS side of the lifecycle question
- `../../TASK-code-swift-pjsua-audio-and-diagnostics.md` — the engine-side work this analysis produced
- `../../Phone/` — the other in-tree reference app (own `SwiftSIP` engine; Keychain and video view)
