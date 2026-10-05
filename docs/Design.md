# Offhook — Design

Architecture decisions for the Offhook softphone. Each subsection states the **decision**, the
**why**, and the **alternative rejected**. Authoritative over code comments where they disagree.

Offhook is the bring-up / debug client for `swift-pjsua`. Phase 0 is a smoke test that proves the
stack runs end-to-end (start → register → echo call → hear audio); the broader Swiss-knife
softphone grows on top. See [Roadmap](./Roadmap.md) and [Tech-Debt](./Tech-Debt.md).

## `PhoneModel` is the single engine owner

**Decision.** A `@MainActor @Observable` `PhoneModel` is the *only* type that touches the `PJSUA`
engine actor, and the only source of UI truth. `RootView` reads model state and writes back only
through `@Bindable` text bindings; it never calls the engine.

**Why.** Separation of concerns and low coupling: the view has no engine knowledge, the engine has
no view knowledge. Every engine call hops to the engine's own serial executor via `await`, so the
main actor never blocks on `pjsua_*`.

**Rejected.** Views calling the engine directly, or scattering engine access across types — that
re-introduces the re-entrancy and threading hazards the engine's one-thread model exists to
prevent (see `../../swift-pjsua/docs/Production-Roadmap.md`).

## Engine events: one long-lived `Task`, mutate on the main actor

**Decision.** `engine.events` (an `AsyncStream`) is consumed by a single long-lived `Task`
inheriting `PhoneModel`'s `@MainActor` context. The handler mutates observable state directly.

**Why.** `AsyncStream` is single-consumer; one loop keeps event handling structured and race-free,
and main-actor inheritance lets it update `@Observable` state without hops. `[weak self]` breaks
the model↔task cycle.

**Rejected.** Combine — banned workspace-wide in favor of async/await. Multiple consumers — would
silently split the single stream and drop events.

## Phase 0 drives the engine directly — no CallKit yet

**Decision.** The smoke test calls the engine directly and activates `AVAudioSession` itself via
the Phase-0-only `AudioSession` helper. No CallKit, no PushKit.

**Why.** Smallest path that validates the load-bearing pieces: the `SerialExecutor`/one-thread
model, the C-callback bridge, registration parsing, and the media-state → `pjsua_conf_connect`
audio wiring.

**Rejected.** Wiring `SwiftPJSUAKit` (`CallKitController` + `CallSessionRouter`) now. CallKit owns
the audio session, so two session owners would conflict. When the Kit lands its
`CallSessionRouter` becomes the **sole** `engine.events` consumer, *replacing* `PhoneModel`'s loop
and `AudioSession` (tracked as [OH-1](./Tech-Debt.md) / [OH-2](./Tech-Debt.md)).

## Depend on `SwiftPJSUA` only (pure engine) for Phase 0

**Decision.** The app target links `SwiftPJSUA` (the pure engine), not `SwiftPJSUAKit`.

**Why.** The Kit only matters once CallKit/PushKit is wired; pulling it in early adds surface with
no Phase-0 use.

**Rejected.** Linking the Kit up front — YAGNI until the CallKit milestone.

## Project generated from `project.yml` (XcodeGen)

**Decision.** `Offhook.xcodeproj` is generated from `project.yml` and git-ignored; the manifest is
the source of truth. It pins `swift-pjsua` **and** `swift-pjsip` to local checkouts (`../`).

**Why.** Declaring `swift-pjsip` here pins `swift-pjsua`'s transitive dependency to the local
checkout — the shared package identity overrides the GitHub `branch:main` edge (closes
`swift-pjsua` TD-1 for local builds) and avoids a network fetch.

**Rejected.** Committing the `.xcodeproj` — it churns on every Xcode touch and would let the
transitive dependency drift back to the remote.

## Logging: `Logger` categories under one subsystem; pjsip through `logSink`

**Decision.** Offhook's own lines go to the unified log only. They use static `Logger`s
(`Logger+Offhook.swift`) with the bundle ID as the subsystem and six categories: `app`, `engine`,
`accounts`, `calls`, `push`, `pjsip`. `PhoneModel.note(_:to:level:)` is the model's one funnel; it
writes to the on-screen log and OSLog. pjsip's own lines arrive through the engine's `logSink`.
`PJSIPLog` scrubs each line once and sends it to `Logger.pjsip`, with pjsip's level mapped to an
OSLog type. Debug builds also write it to a SIP log file: one per launch in `Library/Caches/Logs/`,
each line a single `write(2)` on an `O_APPEND` descriptor. The Kit logs under its own subsystem,
`io.github.laconicman.SwiftPJSUAKit`. How to read all of it from the Mac:
[Testing-Playbook](./Testing-Playbook.md) §9.

**Debug builds log public; release builds stay private by default.** A debug build only carries
test accounts, and a collected log full of `<private>` cannot be debugged from the Mac. Secrets
stay out either way:
- passwords are never interpolated;
- the push token appears only as its first 8 hex digits;
- pjsip lines lose digest `response` values, Basic credentials and `pn-prid` before any sink
  sees them.

This is a deliberate exception to [Prior-Art](./Prior-Art.md) §1.4 ("privacy by default, no
denylist redaction"). Release builds keep that rule. In debug builds the scrub is a backstop
behind "never interpolate a secret", not the privacy mechanism.

**Why a SIP file, and why not pjsua's own.** An iOS app can't read the unified-log lines of a
process iOS already killed, even its own: on iOS the only `OSLogStore` scope is
`.currentProcessIdentifier` (`.system` is macOS-only). From the Mac only `sudo log collect`
(or a sysdiagnose) reaches those lines, and `.debug` lines aren't kept. pjsua's `log_filename` won't do either:
`log_writer` writes it with stdio `fwrite` and the flush is commented out (`pjsua_core.c`; Darwin
builds `file_io_ansi.c`). So the buffered tail is lost when iOS SIGKILLs a suspended app, and
those last lines are the push-handling ones. The file is also unscrubbed.

**Rejected.**
- A subsystem parameter on the libraries. A subsystem names the code that emits the line, as
  Apple's frameworks' subsystems do, and a host app combines two in one predicate.
- Writing the app's own lines to a file as well, the dual OSLog-plus-file shape a production app
  needs for in-app log export. That waits for log sharing ([Roadmap](./Roadmap.md)).
- swift-log or XCGLogger: dependencies that buy nothing here.

## Constraints (inherited, not chosen here)

- **iOS 17+.** Floor set by `swift-pjsua` (SE-0392 custom executors).
- **G.711 only** (PCMU/PCMA; also G.722/iLBC/G.729). Opus is absent from the current
  `swift-pjsip` binary — see `../../swift-pjsip/docs/Codec-Coverage.md`. Fine for all echo endpoints
  in [SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md).
- **Microphone mode (Voice Isolation / Wide Spectrum) is user-owned, not app-controlled.** There
  is no API to select or read it on either platform. The only lever an app has is
  `NSAlwaysAllowMicrophoneModeControl` in `Info.plist`, which lets the system offer the Mic Mode
  picker outside an active capture session; the choice stays the user's, made in Control Center.
  Any "enable noise suppression" affordance we ship is therefore an *explanation plus a deep link*,
  never a toggle that claims to control it. What we **can** control is the VoiceProcessingIO unit's
  ducking of other audio — a build-time setting since
  [pjproject#5178](https://github.com/pjsip/pjproject/pull/5178), configured in `swift-pjsip`'s
  `scripts/config_site.h`, not an app-level toggle either. See [Roadmap](./Roadmap.md).
  *Source: [Prior-Art](./Prior-Art.md) §1.3.*
- **On macOS, echo cancellation and a device picker are mutually exclusive.** pjmedia sets
  `kAudioOutputUnitProperty_CurrentDevice` only when EC is *off*, because setting it under VPIO
  breaks the later buffer-size query. So a Mac build either cancels echo or lets the user choose a
  mic — never both — and the warning pjsip logs about it fires only when input *and* output are
  both explicitly set, so a single-device choice is dropped silently. This is a product decision
  waiting to be made, not a bug to engineer around; Mac users expect a device picker.
  *Details: `../../swift-pjsua/docs/Tech-Debt.md` TD-8.*

## See Also

- [Roadmap](./Roadmap.md)
- [Tech-Debt](./Tech-Debt.md)
- [Prior-Art](./Prior-Art.md)
- [SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md)
- `../../swift-pjsua/docs/Production-Roadmap.md`, `../../swift-pjsua/docs/SwiftPJSUAKit-Design.md`
