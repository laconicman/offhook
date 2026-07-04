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
- **Discharge.** Keychain-backed account store (`../Phone` has a reference implementation).

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

## See Also

- [Design](./Design.md) · [Roadmap](./Roadmap.md)
- `../swift-pjsua/docs/Tech-Debt.md` (TD-1, TD-14 referenced above)
