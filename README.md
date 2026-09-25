# Offhook

The swift-pjsua **bring-up / debug softphone** — and, later, the better-than-official PJSIP
sample and Swiss-knife softphone. This first cut is the **Phase 0 smoke test**: prove the stack
runs end-to-end (start → register → echo call → hear audio) before building breadth.

## Direction docs

The authoritative architecture, plan, and debt register live under [`docs/`](docs/):
[Design](docs/Design.md) (decisions + rejected alternatives), [Roadmap](docs/Roadmap.md)
(Now/Next/Later), [Tech-Debt](docs/Tech-Debt.md) (`OH-#` register), and
[SIP-Test-Infrastructure](docs/SIP-Test-Infrastructure.md) (where to point the app). The
Architecture and Next-milestones notes below are a summary; the docs are authoritative.

## Prerequisites

- Xcode 16+, an iOS 17+ Simulator or device.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the project is
  generated from `project.yml`, so there's no `.xcodeproj` in git.
- A SIP account to register with (the smoke needs a real registrar + a live echo target).

## Generate & run

```sh
cd offhook
xcodegen generate          # writes Offhook.xcodeproj from project.yml
open Offhook.xcodeproj
```

Build & run on an iOS 17 Simulator (Audio works in the Simulator; for a device, set your signing
team in the target). `project.yml` pins `swift-pjsip` to the **local** checkout (`../swift-pjsip`),
so no network fetch.

> No XcodeGen? Create an iOS App target manually (iOS 17, bundle id `com.laconicman.offhook`),
> add the `Sources/` files, set `INFOPLIST_FILE = Sources/Info.plist`, and add the local
> `../swift-pjsua` package → product **SwiftPJSUA**.

## Smoke procedure

1. Edit the three account fields (or change the defaults in `PhoneModel`): **Registrar host**,
   **Username**, **Password**, and a **Dial** target that echoes audio back.
2. **Start engine** → the Engine row should read `running` and the log show `engine started`.
3. **Register** → watch the Registration row flip to `registered (200)`.
4. **Dial** → the call goes through CallKit and appears in the **Calls** list (label = the
   dialed target): state `dialing… → connected` from `CXCallObserver`; audio starts once
   CallKit activates the session (`didActivate` → engine sound device) — you should **hear
   the far end**. Multiple calls can be up at once — each row gets its own **Hang up** and
   **Hold / Resume**.
5. **Hang up** a row (or let the far end end it) → the row clears; audio is released by
   CallKit when the last call ends.

A green run validates the whole engine: the `SerialExecutor`/one-thread model, the callback
bridge, registration parsing, and the media-state → `pjsua_conf_connect` audio wiring.

### Test targets

See **[`docs/SIP-Test-Infrastructure.md`](docs/SIP-Test-Infrastructure.md)** — verified providers,
echo endpoints, STUN, push, and a capability→where-to-test map. Fastest: register **two** free
[Linphone](https://subscribe.linphone.org) accounts and call one from the other (the loopback
pattern — Linphone's echo `4443` answers **404** as of 2026-07-04). Register and dial with
`;transport=tcp` (the app default): Flexisip's authenticated INVITEs fragment on UDP (doc §6).
Flexisip negotiates **iLBC** with our binary; G.711 elsewhere (Opus absent —
`../swift-pjsip/docs/Codec-Coverage.md`).

## Integration tests (`Tests/`)

A live-infrastructure XCTest suite drives the engine against real SIP servers — it *is* the
Phase 0 smoke, automated: headless engine start (null sound device — no mic permission),
negative auth (4xx/6xx), all-accounts registration (200 + expiration), an audio loopback call
with RTP/RTCP statistics + codec assertions, simultaneous calls (up to the binary's
`PJSUA_MAX_CALLS` = 8), and a video loopback (H264 negotiates on the Simulator; RTP flow needs
a camera, so that step skips off-device).

```sh
xcodebuild test -scheme Offhook -destination 'platform=iOS Simulator,name=iPhone 16'
```

**Credentials** (never in this repo): `OFFHOOK_TEST_ACC<n>_AOR` / `_PASSWORD`
(+ optional `_REGISTRAR` override) read from the process **environment first** (CI:
`TEST_RUNNER_`-prefixed vars via xcodebuild), then from `../secrets/test-accounts.env` —
outside the repo tree. ACC1+ACC2 must be a same-registrar pair (the loopback); slots 3–8 are
optional extras — tests that need them `XCTSkip` when unset. The suite is one ordered test
class: pjsua is process-global, so one engine instance serves all tests.

**Live-infra weather:** these tests hit real public servers. Back-to-back runs can trip
provider rate limits (observed: iptel going silent → 408 after many runs in one hour); the
suite tolerates *no-answer* weather on non-loopback accounts with a warning and skips — it only
hard-fails on stack behavior. Space runs a couple of minutes apart; if a provider goes quiet,
it recovers on its own.

## Architecture (applies the loaded skills)

- **`PhoneModel`** — `@MainActor @Observable` view-model. Owns the engine + `CallKitController`
  (which owns the `CXProvider` and starts `CallSessionRouter`, the sole `engine.events`
  consumer). Requests go out as CallKit transactions (`CXCallController`); state comes back
  from `CXCallObserver` and the router's registration relay — the model never reads
  `engine.events` and never touches `AVAudioSession`.
- **`RootView`** — renders model state, writes only through `@Bindable` text bindings.

## Caveats / what's deliberately not here yet (KISS / YAGNI)

- **CallKit is wired (2026-07-04)** — `SwiftPJSUAKit`'s `CallKitController` + `CallSessionRouter`
  are the sole `engine.events` consumer; the app requests actions via `CXCallController` and
  observes via `CXCallObserver` (outgoing round trip verified live). Not here yet: **PushKit /
  VoIP push** (needs self-hosted push infra — docs §3), **video rendering**, multi-call UI, and
  a live verification of the **incoming**-call UI (needs a second instance — Tech-Debt OH-8).
- **Scripted smoke:** launch with `OFFHOOK_AUTOSMOKE=1` (+ `OFFHOOK_USERNAME` / `OFFHOOK_PASSWORD`
  / `OFFHOOK_REGISTRAR` / `OFFHOOK_DIAL`) to prefill and run start → register → dial with no
  taps — e.g. `SIMCTL_CHILD_OFFHOOK_AUTOSMOKE=1 … xcrun simctl launch <sim> com.laconicman.offhook`.
- The app and the test suite **can't run on one simulator at the same time** — both bind SIP
  port 5060 (the second engine start fails with "Address already in use"). Terminate one first.

## Next milestones

CallKit outgoing/incoming via `SwiftPJSUAKit` → PushKit (hybrid, no double ring) → the debug/SIP
tooling UI (raw event stream, conf-slot inspector, SIP log) → hold/parallel/conference/video
demos → Swiss-knife settings (STUN/DNS/codecs). See `../PROJECT-MEMORY.md` §5.
