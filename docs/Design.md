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
prevent (see `../swift-pjsua/docs/Production-Roadmap.md`).

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

## Constraints (inherited, not chosen here)

- **iOS 17+.** Floor set by `swift-pjsua` (SE-0392 custom executors).
- **G.711 only** (PCMU/PCMA; also G.722/iLBC/G.729). Opus is absent from the current
  `swift-pjsip` binary — see `../swift-pjsip/docs/Codec-Coverage.md`. Fine for all echo endpoints
  in [SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md).

## See Also

- [Roadmap](./Roadmap.md)
- [Tech-Debt](./Tech-Debt.md)
- [SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md)
- `../swift-pjsua/docs/Production-Roadmap.md`, `../swift-pjsua/docs/SwiftPJSUAKit-Design.md`
