# On-device test harness — plan (video first)

A plan for a **scenario engine the app can be launched into**, so that camera, CallKit,
lock-screen and permission behaviour can be driven and observed on real hardware. Video is the
first domain it is built against; it is **not** the reason the engine exists. Network conditions,
intents, and interaction with other apps are the same shape of problem — a scripted sequence, some
steps a device can take alone, some a human must take, and one merged record afterwards — and the
core here is designed so those arrive as new step packs rather than a second harness.

Nothing here replaces the four suites in [`Testing-Playbook.md`](./Testing-Playbook.md) §1. It
covers what those cannot reach: §2 of that document records why **no XCTest bundle runs on a
device**, and that constraint is what forces this design.

**Provenance convention.** Every claim about existing behaviour is marked **[V]** (verified — read
in the source named) or **[A]** (assumed — not checked; the plan says how to check it). A claim
with no marker is a design proposal, not a statement about the world.

---

## 1. What is already settled — cited, not restated

| Source | Load-bearing conclusion this plan builds on |
|---|---|
| [`Testing-Playbook.md`](./Testing-Playbook.md) §2 | Tool-hosted XCTest cannot run on device destinations; `OffhookTests` cannot be app-hosted until `swift-pjsua` **TD-28** adds three frameworks and the process-global-pjsua ownership question is settled. **The harness is therefore not a test bundle.** |
| [`Testing-Playbook.md`](./Testing-Playbook.md) §3 | The app *is* the device harness. `OFFHOOK_*` environment variables reach it via `devicectl device process launch --environment-variables`, and `PhoneModel.init()` already reads them. **The selection mechanism exists; this plan extends the variable set.** |
| [`Testing-Playbook.md`](./Testing-Playbook.md) §4 | `OFFHOOK_PORT=0` on device; 5060 is held by other softphones and `PJSUA.start()` is fail-fast. Every device scenario inherits this. |
| [`Testing-Playbook.md`](./Testing-Playbook.md) §5 | Live-run etiquette: these are other people's registrars; never probe bad credentials against the loopback pair. Scenario runs are live runs. |
| [`SIP-Test-Infrastructure.md`](./SIP-Test-Infrastructure.md) §2 | Video and interactive up/downgrade are mapped to `addVideoStream` / `removeVideoStream` / `changeVideoCaptureDevice` against sip2sip `3333` or two clients. The capability→endpoint map is the input to §7's scenario catalogue, not something to redo. |
| `Tests/EngineHarness.swift` | `startIfNeeded`, `waitForRegistrationResult`, `waitForCallState`, `waitForCallOutcome`, `waitForActiveMedia` — the await vocabulary. §6 extends it; §9 names what it cannot express. |
| `Tests/OffhookIntegrationTests.swift` | The **shape** of a live, ordered, stateful run over one process-global engine, and the classification discipline (`providerRejection`, 408-is-not-a-rejection). The scenario engine formalises what that suite does by convention. |
| [`Tech-Debt.md`](./Tech-Debt.md) OH-8 | "Between devices" is loopback in one process today; it cannot catch device asymmetry, camera capture, or CallKit paths. **This plan is OH-8's discharge for the device case.** |
| [`Tech-Debt.md`](./Tech-Debt.md) OH-9 | "Connected but no audio" is diagnosable only by ear. The same hole exists for video, and the run log is where it closes. |
| `../../swift-pjsua/docs/Production-Roadmap.md` §3, §6 | The load-bearing design: one `actor` on a custom `SerialExecutor` pinned to one PJLIB-registered thread; `thread_cnt >= 1`; pjsua is process-global — **one engine per process, no restart**. The harness runs *inside* the app that already owns that engine, which is why §3.3 is an observability API and not a second engine. |
| `../../swift-pjsua/docs/Threading-Validation.md` | The same invariants checked against upstream. G1: one PJLIB-registered thread for all `pjsua_*` calls. G2: callbacks hold no actor reference. **A test mode must not add a second engine, a second event consumer, or a second thread into PJSIP.** §5 and §9.2 are written around this. |
| `../../swift-pjsua/docs/Tech-Debt.md` TD-3 | `engine.events` is `.bufferingNewest(64)` — under burst the **oldest** events are dropped. §4.4 and §9 treat this as a measurement problem, not a footnote. |

---

## 2. The concrete motivation, and what evidence it actually needs

pjproject PR [#5249](https://github.com/pjsip/pjproject/pull/5249) fixes two `CVPixelBuffer`
stride defects in `darwin_dev.m`. `swift-pjsip` has carried the patch as
`scripts/patches/iphone17-darwin-dev-stride.patch` on production use alone **[V]**, and a reviewer
has asked for evidence of universality.

Reading the patch tells you exactly what "universality" means as data
**[V, patch + `darwin_dev.m`]**:

| Half of the fix | Defect condition | Numbers that prove or disprove it |
|---|---|---|
| Bi-planar (NV12→I420) chroma walk | `bytesPerRowOfPlane(1) != bytesPerRowOfPlane(0)` | both plane strides, width, height, per camera and preset |
| Packed (BGRA) flat `memcpy` | `bytesPerRow != width * 4` | `bytesPerRow`, width, height, per camera and preset |

And the search space is small and enumerable from source **[V, `darwin_dev.m`]**: on iOS the
factory offers exactly two pixel formats — `kCVPixelFormatType_32BGRA` and
`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` — over four session presets (`352x288`,
`640x480`, `1280x720`, `1920x1080`), landscape and portrait, at `DEFAULT_FPS` 15, across whatever
cameras `AVCaptureDeviceDiscoverySession` returns.

**This is the single most important finding for the phasing.** Those numbers come from
`CVPixelBuffer` — from AVFoundation. They need **no SIP call, no network, no far end, no second
device, and no change to any of the four repos' engine code**. A scenario that opens a capture
session per camera × preset × format and records plane geometry answers the reviewer's question
by itself. §8 makes it phase 1.

---

## 3. Where the code lives, and why

Four repos exist; the harness needs a fifth thing that belongs to none of them.

### 3.1 `FieldKit` — a new, VoIP-free package (the general engine)

*Field* as in field testing: real hardware, real infrastructure, a human in the loop — the
opposite of CI. (`ScenarioKit` is the obvious alternative name; pick one before phase 1 and do not
revisit.)

**Decision.** The scenario engine is a **new standalone SwiftPM package**, developed at the
workspace root as `field-kit/` and consumed by `offhook` as a local package the way `swift-pjsua`
already is. It knows: runs, run ids, scenarios, steps, step outcomes, expectations, tester
prompts, the event record, and the export. It knows **nothing** about SIP, pjsua, cameras or
CallKit, and links neither.

**Why.** The stated goal is a general on-device testing engine; network, intents and app-interaction
domains follow. A core that imports `SwiftPJSUA` could never be used to test a non-VoIP app, and a
core buried in `offhook` could never be used by a second app. Low coupling here is not tidiness —
it is the only thing that makes the second domain cheap. It is also what keeps the core publishable
later without a VoIP dependency hanging off it.

**Rejected — the scenario engine as a `SwiftPJSUAKit` facility.** The task asks the question
directly, and the answer is no. `SwiftPJSUAKit` is a CallKit/PushKit integration library; putting a
test harness in it inverts the dependency (a shipping SDK carrying a test framework), and it would
permanently tie the general engine to VoIP. What *does* belong in `swift-pjsua` is §3.3: the small
observability API the pack needs, each item justified as product API a real app would want.

**Rejected — a separate harness app.** A second app cannot observe the app under test. The whole
premise (Playbook §2/§3) is that the app is the only vantage point.

### 3.2 `offhook` — the domain pack, the launch mode, the catalogue

- `Sources/Fieldwork/` — the **VoIP/video step pack**: steps that place calls, add and remove video
  streams, switch cameras, read stream statistics, probe capture geometry; and the observers that
  translate `PJSUAEvent`, `CXCallObserver` and `AVCaptureSession` notifications into `FieldKit`
  event records.
- `Sources/Fieldwork/Scenarios/` — the catalogue in §7, one file per scenario.
- The launch-mode entry point (§4.1) and the prompt presentation host.
- The video render view the app is missing anyway (`swift-pjsua` TD-6 defers app-side pixel
  rendering to the app **[V]**), because several scenarios need a human to say whether the picture
  was right.

**Why here and not in the SDK.** The pack composes `PhoneModel`, `CallKitController` and the
router — app-level composition. It is also where the *product* decisions live (which registrar,
which account, which dial target), and those are exactly what `SIP-Test-Infrastructure.md` owns.

### 3.3 `swift-pjsua` — four additions, each justified without the harness

The harness must not motivate test-only API in a shipping SDK. Each of these is product surface
that the harness merely needs *first*:

| # | Addition | Product justification (independent of testing) | Status today |
|---|---|---|---|
| E1 | An **event tap** on `CallSessionRouter` — `setEventObserver(_:)` alongside the existing `setRegistrationObserver(_:)` | Any app wanting a diagnostics view, a call-quality log, or analytics needs to see engine events. Today the router is the **sole** `engine.events` consumer and `AsyncStream` is single-consumer, so an app literally cannot observe them **[V, `CallSessionRouter.swift`, `PJSUAEvent` docs]**. This is the offhook Roadmap's "raw event stream" debug-tooling item. | **Blocking.** No mechanism exists. |
| E2 | A **sequence number** on tapped events, assigned inside the engine at yield time | Makes TD-3's drop policy *observable*: a gap in the sequence is a recorded fact instead of a silent hole. Cheap and permanent. | Does not exist. |
| E3 | Expose `pjsua_logging_config.cb` (and `level` / `msg_logging`) on `PJSUA.Configuration` | The offhook Roadmap already lists "diagnostic capture that can include pjsip's own log at a chosen level (`pjsua_logging_config.cb`)" as a product feature. `PJSUA.start()` sets **only** `console_level` today; `cb`, `level`, `msg_logging` and `log_filename` are left at defaults, so pjsip's log goes to the console and **nothing in the app can capture it** **[V, `PJSUA.swift:112–120`]**. | Does not exist. |
| E4 | `custom_call_id` on the outgoing-call path, plus video-device enumeration (`pjsua_vid_dev_count` / `pjsua_vid_enum_devs` / `pjsua_vid_dev_get_info`) | A Swiss-knife softphone needs a camera picker; `changeVideoCaptureDevice(_:to:)` already takes a `pjmedia_vid_dev_index` with **no way to discover one** **[V, `PJSUA+Video.swift`]**. `custom_call_id` is the correlation seed (§5.3). | `custom_call_id` exists upstream at `pjsua.h:1245` but `makeCall` builds `pjsua_call_setting` internally and never sets it **[V]**. No `pjsua_vid_dev_*` wrapper exists **[V, grep of `Sources/`]**. |

One more gap the harness will expose rather than fix: `PJMEDIA_VID_DEV_CAP_ORIENTATION` is
advertised by the Darwin factory **[V, `darwin_dev.m:407`]** but `swift-pjsua` exposes no
orientation API **[V]**, so scenario C4 (§7) can only *observe* rotation, not drive it.

### 3.4 `swift-pjsip` — no change

The binary already builds video on: `PJMEDIA_HAS_VIDEO`, `PJMEDIA_VIDEO_DEV_HAS_IOS`,
`PJMEDIA_HAS_VID_TOOLBOX_CODEC` **[V, `scripts/config_site-ios.h`]**, and the stride fix is already
carried as a patch **[V]**. Stated explicitly so nobody goes looking: the harness needs nothing
from this repo. If the §7 A1 survey *disproves* the fix's universality, that changes the patch —
which is a `swift-pjsip` and upstream matter, not a harness one.

### 3.5 `swift-pjsip-gen` — no change

It generates Swift conveniences from the C headers. The harness adds no header surface and
consumes no generated type it does not already get. Recorded so the question is closed.

---

## 4. The scenario engine

### 4.1 Identification, selection, parameters

Follow the mechanism the Playbook already documents rather than inventing a second one **[V, §3]**:

```sh
xcrun devicectl device process launch --device $D --console \
  --environment-variables '{
    "OFFHOOK_RUN_ID":"v7q4f2a9c1", "OFFHOOK_SCENARIO":"B1-camera-in-use",
    "OFFHOOK_ROLE":"caller", "OFFHOOK_PARAMS":"preset=640x480,camera=front",
    "OFFHOOK_PORT":"0", "OFFHOOK_REGISTRAR":"…", "OFFHOOK_USERNAME":"…" }' \
  com.laconicman.offhook
```

- **`OFFHOOK_SCENARIO`** selects by id from a registry the pack builds at launch. Absent → the app
  starts normally. This keeps the harness strictly opt-in, exactly as `OFFHOOK_AUTOSMOKE` is
  today **[V, `PhoneModel.autoSmokeIfRequested()`]**.
- **`OFFHOOK_PARAMS`** is a flat `k=v,k=v` string parsed into a `[String: String]` the scenario
  reads through a small typed accessor. Flat because it has to survive a shell quote, a JSON
  string, and a human typing it on a second device.
- **`OFFHOOK_RUN_ID`** and **`OFFHOOK_ROLE`** are §5.
- Environment, not launch arguments, because `devicectl` and the existing code already use it.

A debug-UI selector (phase 4) sets the same values in-process; the environment is the contract, the
UI is a second front door onto it.

### 4.2 Steps

```swift
public protocol ScenarioStep: Sendable {
    var id: StepID { get }
    var title: String { get }
    /// Steps whose failure or skip makes this one meaningless.
    var requires: [StepID] { get }
    /// Only run when the device holds this role; otherwise recorded as `.notMyRole`.
    var role: Role? { get }
    func run(_ context: StepContext) async throws -> StepOutcome
}
```

`FieldKit` ships six generic conforming steps, and **that is the whole core vocabulary**; every
domain adds its own beyond it.

| Step | Purpose | Fails? |
|---|---|---|
| `Act` | Do something and record entry/exit. | Yes, on a thrown error |
| `Await` | Wait for a predicate over observed state, with a timeout. The generalisation of `EngineHarness`'s `waitFor*` family. | Yes, on timeout |
| `Dwell` | Bounded settle. Named, not a bare `sleep`, so the run log shows why time passed. RTP needs seconds before statistics mean anything **[V, `test04`]**. | No |
| `Probe` | Measure and record. **Never fails** — a measurement is a result. | No |
| `AskTester` | A human performs an action (§4.3). | No — skips |
| `AskObserver` | A human reports something the device cannot observe (§4.3). | No — records |
| `Expect` | Evaluate an expectation, including absence (§4.4). | Yes |

A step records, on entry: step id, title, role, wall clock, run-relative monotonic time, and the
parameters it resolved. On exit: outcome, duration, and any values it produced. Entry and exit are
separate records so a step that never returns still has a beginning in the log.

### 4.3 Tester actions — and skip as a first-class result

`AskTester` presents a full-screen, unmissable sheet: one sentence of instruction, optional detail,
a **Done** button, a **Skip** button, and a countdown. Three outcomes, all recorded, none silent:

| Outcome | Meaning | Effect on the run |
|---|---|---|
| `.done(after:)` | The tester performed the action. | Continue. The elapsed time is data — a 30 s "lock the screen" says something. |
| `.skipped(.testerSkipped(note:))` | The tester declined, with an optional typed note. | Continue. Every step whose `requires` names this one becomes `.blocked`. |
| `.skipped(.testerTimedOut)` | Nobody answered. | Same as above, and the run is marked **unattended from here**. |

`AskObserver` is the same sheet with a different question: *did the far end's video appear?* —
**yes / no / could not tell**. This is a human sensor reading, and it is recorded as an observation
with a value, never converted into a pass or a fail. A great deal of what matters here ("did the
picture look right", "did the lock screen show the right name") is only available this way, and
pretending otherwise is how a harness starts lying.

**The verdict algebra, which is the point of all this.** A run's result is not a boolean. It is the
tuple *(passed, failed, skipped, blocked, recorded)*, and:

> **A run with any skipped or blocked step is reported as `PARTIAL`, never as green.** The summary
> line leads with what was *not* observed, the artifact filename carries the word, and the merged
> report's first table is the skip list.

This is deliberate and load-bearing. A skipped step that logs nothing produces a run that *looks*
complete, and this workspace has already paid for that failure mode more than once. Making
"complete" a stricter state than "no failures" is the cheapest possible defence.

### 4.4 Expectations, including "correctly does nothing"

A scenario declares its expected outcome so a run is pass/fail rather than a log to read. Two
shapes, and the second is the one that matters here:

- **Positive** — `Expect.eventually { … }`: the state reaches something within a timeout.
- **Negative** — `Expect.noChange(in:for:)`: the observed value does **not** change over an
  interval. §6 of the problem statement is full of these: a locked device must *not* start the
  camera; a backgrounded app must *not* keep transmitting video; a permission-denied call must
  *not* report an active video stream. `EngineHarness` cannot express any of them today, and a
  `waitFor…` that times out is not the same statement — it fails for the right reason and the
  wrong one indistinguishably.

Expectations are attached to steps, and a scenario also carries a whole-run expectation (for
example: *the engine stayed responsive throughout*, §9.2).

---

## 5. Roles, orchestration, correlation

### 5.1 The operator is the orchestration — settled 2026-09-09

There is no coordination protocol in any phase of this plan. The same human who answers the §4.3
prompts is the synchronisation mechanism: they hold both devices and advance both through the
scenario, and the prompt on each device is what keeps them in step. A step needing *simultaneous*
action on two devices is expressible as a prompt on each.

What it costs, stated rather than discovered: **scenarios must be written for one pair of hands.**
No scenario may require two actions more than a second or two apart on two devices, and none may
require watching two screens at once. Where a scenario would need that, it is split.

Roles are `caller`, `callee`, `observer` (watches and records, never acts), and `bystander` (holds
the camera, takes the parallel call — the §3.2 contention source). Assignment is
`OFFHOOK_ROLE`. A step with a non-matching `role` records `.notMyRole` and moves on: that is a
distinct outcome from `.skipped`, because nothing was lost.

**Drop-out.** A device that stops is not a failure of the device that did not. The merge step
reports `INCOMPLETE — role callee last seen at step 7` and continues to render everything the
surviving side saw. A missing side must never turn into a fabricated failure on the other.

**Future — a coordination layer.** A Bonjour or Multipeer channel could assign roles, distribute
the run id, and release both devices from one "go". It would remove the typing in §5.2 and make
sub-second simultaneity expressible, which unlocks races this design cannot script. It would also
add a distributed system underneath a harness whose value is that it has none. Not now; one
paragraph is all it gets.

### 5.2 The run id

Harness-generated, assigned out of band, identical on every participating device, stable for the
whole run, and the primary key for every record — including the many that precede any call at all,
which is most of the permission surface.

**It must be typeable by a human**, because §5.1 means the operator carries it from one device to
the other. That rules out a UUID. Proposal: a short token of a sortable time prefix plus six
characters of Crockford base32 (no `I`, `L`, `O`, `U`), e.g. `v7q4f2a9c1` — unambiguous read aloud,
short enough to retype, and enough entropy that two runs never collide in one session.

**It must survive process death.** §9.1 shows the app is killed outright by some of the very
transitions being tested. The recorder therefore appends to a file named by run id, and a relaunch
with the same `OFFHOOK_RUN_ID` **continues that run** rather than starting a new one — with a
`processRestarted` record marking the seam. A harness that loses its identity at the moment the
interesting thing happens is no harness.

### 5.3 The join key is the run id — and the SIP identifiers are attributes

| Identifier | What it is | Why it cannot be the key |
|---|---|---|
| SIP `Call-ID` | The dialog identifier on the wire; reaches us as `sipCallID` on `.incomingCall` and `.callState` **[V, `PJSUAEvent.swift`]** | SBCs rewrite it, RFC notwithstanding, and it differs per leg — the two devices in one call may never see the same value |
| `pjsua_call_id` | `typedef int`, `pjsua.h:262` **[V]** — an index into pjsua's local call array | Per-process, per-device, reused after teardown. Meaningless across devices |

Both are recorded as **attributes** of the events that carry them, never as keys.

`pjsua_call_setting.custom_call_id` (`pjsua.h:1245`) lets the caller **propose** a Call-ID on an
outgoing INVITE — *"Overrides default Call-ID generated by dialog"*, caller-side only, uniqueness
unverified **[V, header text]**. Seed it from the run id (`fk-<runid>-<seq>`), then record what each
side actually observes.

That inverts the unreliability into a result:

- proposed == observed on both sides → correlation is trivial;
- proposed != observed → the harness has **detected an SBC rewriting the Call-ID**, which is a
  finding in its own right and exactly the infrastructure behaviour this stack must survive.

The mismatch is a recorded observation, not an error. Note that `custom_call_id` is not exposed by
`swift-pjsua` today (E4, §3.3), so phase 3 is what needs it; phases 1–2 correlate on the run id
alone and lose nothing.

### 5.4 Clocks

**Recorded and tolerated, not corrected.** Every record carries both a wall-clock timestamp and a
run-relative monotonic offset taken from a `ContinuousClock` started at run begin — the monotonic
axis is what survives a wall-clock adjustment mid-run, which on a phone is not hypothetical.

Cross-device alignment uses one **synchronisation marker**: an `AskTester` step that says *press
Continue on both devices at the same time*, whose completion is the shared zero. Where a call
exists, the caller's INVITE and the callee's `.incomingCall` give a second anchor bounding the
offset by one network trip.

The honest consequence, stated here so no reader infers otherwise: **this design does not support
cross-device claims finer than a few hundred milliseconds.** Within one device, ordering is exact.
Across devices, it is human-reaction accurate. Any scenario whose result depends on sub-100 ms
cross-device ordering is out of scope until §5.1's coordination layer exists.

### 5.5 The event record and the log

One record per line, JSON Lines, appended to `Documents/fieldkit/<runID>/<role>-<device>.jsonl`.
Append-only and flushed per line, because a crash mid-run is a *result* and must not take the
evidence with it.

| Field | Notes |
|---|---|
| `run` | Run id — the join key |
| `seq` | Per-device monotonic record counter; a gap means the writer lost a record |
| `t` | Run-relative monotonic offset, milliseconds |
| `wall` | ISO-8601 with fractional seconds and offset |
| `device` | Model identifier + a stable per-install id (never the device name — see §10) |
| `role`, `scenario`, `step`, `phase` | `phase` is `enter` / `exit` / `observe` |
| `source` | `harness` / `engine` / `callkit` / `avfoundation` / `pjsip-log` / `tester` |
| `kind` | Record type — the discriminator for `payload` |
| `payload` | Type-specific, JSON object |

**pjsip's own log is interleaved as records with `source: "pjsip-log"`**, carrying pjsip's level and
message. This needs E3 (§3.3): today the log goes to the console and is unreachable from the app
**[V]**. Two consequences worth planning for: pjsip's log callback is invoked from arbitrary PJSIP
threads, so the recorder's write path must be thread-safe and non-blocking (an `actor` with an
unbounded in-memory queue draining to the file); and at `level` 4 the SIP messages themselves
appear, which is most of the value and also most of the volume — the level is a scenario parameter,
defaulting to 4, and 5 exists for when a scenario is chasing something specific.

**Export.** Three routes, in the order they should be tried:

1. `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` in `Info.plist` → the run folder is
   visible in the Files app and AirDrops off a phone with no cable. This is the one the operator
   uses in the field. *(One `Info.plist` change; `Sources/Info.plist` has neither key
   today **[V]**.)*
2. A share sheet at end of run, which is what makes a two-device run collectable in thirty seconds.
3. `xcrun devicectl device copy from --domain-type appDataContainer` for a scripted pull from a
   wired Mac. **[A]** — the flag spelling is from memory and must be checked against the installed
   Xcode before it is written into a script.

---

## 6. The step vocabulary for the video pack

Built on `EngineHarness`'s primitives where they exist, and naming what has to be added.

| Pack step | Built on | New? |
|---|---|---|
| `Register(account:)` → `Await` | `waitForRegistrationResult` | reuse |
| `Call(to:video:)` → `Await(.confirmed)` | `makeCall`, `waitForCallState` | reuse |
| `AwaitMedia(kind:)` | `waitForActiveMedia` | reuse |
| `AwaitOutcome` | `waitForCallOutcome` | reuse |
| `AwaitRTP(kind:direction:minPackets:)` | polls `statistics(for:mediaIndex:)` until counters move | **new** — `test06` hand-rolls this with a `sleep` and a comparison **[V]** |
| `AwaitStall(kind:direction:for:)` | the same counters *failing* to move while `status == .active` | **new** — and it is the only way to see §9.3's invisible camera loss |
| `ProbeCaptureGeometry(camera:preset:format:)` | AVFoundation directly; no engine involvement | **new** — §2, and it needs nothing from any repo |
| `ProbeVideoDevices` | `pjsua_vid_dev_*` (E4) | **new** |
| `AddVideo` / `RemoveVideo` / `SwitchCamera` | `addVideoStream`, `removeVideoStream`, `changeVideoCaptureDevice` | reuse |
| `ExpectNoVideoCapture(for:)` | `Expect.noChange` over `CallMediaInfo.videoCapture` **[V — the field exists]** | **new** (the `Expect` half) |

---

## 7. First scenario catalogue

Ids are stable and are what `OFFHOOK_SCENARIO` takes. Phase in brackets.

### Class A — permissions and geometry (§3.1)

- **`A1-capture-geometry-survey` [P1].** For each camera × each of the four iOS presets × both
  pixel formats **[V, §2]**: open an `AVCaptureSession`, take N frames, `Probe` width, height,
  `bytesPerRow`, `bytesPerRowOfPlane(0)`, `bytesPerRowOfPlane(1)`, pixel format, and the two defect
  predicates. Verdict: `recorded`. Output: the table PR #5249 was asked for. No call, no network,
  no engine.
- **`A2-permission-denied-cold` [P2].** Launch with camera permission never granted. Do *not*
  request it. `ProbeVideoDevices`, then place a video call. Record what `pjsua_vid_dev_count`
  returns, what `makeCall(video: true)` does, and whether a video stream is reported active with
  no frames. `ExpectNoVideoCapture`.
- **`A3-permission-granted-late` [P2].** Start denied; `AskTester` to grant in Settings; expect the
  app to be terminated (§9.1); relaunch with the same run id; place a video call and expect it to
  come up. Proves the *recovery* path, and exercises §5.2's process-death requirement on purpose.
- **`A4-permission-revoked-between-calls` [P2].** A working video call, hang up, tester revokes,
  relaunch, call again. The safe half of "revoked mid-call" — see §9.1 for why the unsafe half
  cannot exist.

### Class B — acquisition and release contention (§3.2)

- **`B1-camera-in-use` [P2].** During a live video call, `AskTester` to open the system Camera app,
  wait, and return. Record `AVCaptureSession` interruption notifications on the app side, the pjsip
  stream status, and the tx counters. **Expected result, and the one to prove: a stall with the
  stream still reported `.active`** (§9.3).
- **`B2-add-remove-cycles` [P2].** Ten `AddVideo` → `AwaitMedia` → `RemoveVideo` cycles on one live
  call. Every `RemoveVideo` runs the `darwin_stream_stop` path that upstream
  [#4928](https://github.com/pjsip/pjproject/issues/4928) is about. Whole-run expectation: the
  engine stayed responsive (§9.2's watchdog).
- **`B3-camera-switch-under-load` [P2].** Ten front↔back `SwitchCamera` mid-call, same watchdog,
  plus a geometry probe after each switch — a switch changes the active format, which is where §2's
  strides change.
- **`B4-teardown-race` [P2].** Hang up within 200 ms of `AddVideo`, ten times. Teardown racing
  setup is the other half of the release risk, and it is scriptable without a human.
- **`B5-bystander-holds-camera` [P3].** A second device (`bystander`) is irrelevant here; this is
  the same device, a *second app*. Kept as a note: B1 is the realisable form.

### Class C — CallKit, background, lock screen (§3.3)

- **`C1-answer-from-lock-screen` [P3].** Inbound video call to a locked device; tester answers from
  the system UI. Expect audio up and **no video capture while locked**; `AskObserver` for what the
  lock screen showed; then tester unlocks, and the harness records whether video starts or does not.
  Either is a legitimate result and both must be written down.
- **`C2-background-mid-call` [P2].** Tester backgrounds the app during a video call. Expect capture
  to stop and audio to continue (the `voip` + `audio` background modes are set
  **[V, `Info.plist`]**); on return, record whether video resumes by itself, and whether
  pjsip noticed anything at all.
- **`C3-parallel-native-call` [P3].** Tester places a cellular call to the device mid-call. Expect
  CallKit hold, audio session yielded, video stopped; record the CallKit action sequence.
- **`C4-rotation-mid-call` [P2].** Tester rotates the device. Observe only — `swift-pjsua` exposes
  no orientation API **[V, §3.3]** — and `AskObserver` on whether the far end's picture rotated.
- **`C5-lock-during-video` [P2].** Tester locks the screen mid-call and unlocks 15 s later. Prompts
  cannot render while locked, so the *next* prompt is queued and the locked interval is recorded
  (§9.4).

### Class D — two devices (§4.3)

- **`D1-device-to-device-video` [P3].** The first genuinely two-device scenario, and the discharge
  of OH-8's device half. Both sides run `A1`'s probe, both record proposed vs observed Call-ID
  (§5.3), both record RTP counters, and both `AskObserver` on whether the other's picture was right.
- **`D2-video-upgrade-both-ways` [P3].** Audio call, then each side adds video in turn. The
  re-INVITE path from both directions, which loopback in one process cannot exercise **[V, OH-8]**.

---

## 8. Phasing

The task proposes: (1) single device scripted + prompts + local log, (2) export and merge, (3) two
devices and correlation, (4) live orchestration and debug UI. **The shape is right. Two changes.**

**Change one — phase 1 is narrower and lands sooner.** As written, phase 1 needs the engine event
tap (E1), which does not exist and is a `swift-pjsua` change. §2 shows that the single most valuable
output — the PR #5249 stride evidence — needs **no engine at all**. So:

> **Phase 1: `FieldKit` core + `A1-capture-geometry-survey`.**
> Run id, steps, outcomes, the skip algebra, the tester sheet, the JSONL recorder, Files-app export
> — plus one probe scenario built on AVFoundation alone.

**What phase 1 delivers that is worth having even if nothing else is ever built:** a per-device
table of luma and chroma plane strides across every camera, preset and pixel format that
`darwin_dev.m` can select, collected on as many devices as anyone can carry — which is exactly the
universality evidence a pjproject reviewer asked for, and which the workspace currently owes. It
converts a months-old "works in production" claim into data. It also forces the log schema, the run
id and the skip algebra to be real before anything harder depends on them.

**Change two — merge export into phase 2, and keep the merger.** A log that cannot leave the device
is not a result, so export ships with the first scenario that produces a long log. But the *merge*
step still has a job on one device, because one device produces at least two interleaved streams
(harness events and pjsip's log, §5.5) — which is the right place to get interleaving right, before
two devices make it harder to debug.

| Phase | Contents | New dependencies |
|---|---|---|
| **P1** | `FieldKit` core; `A1`; JSONL recorder; Files-app export | none |
| **P2** | Engine-backed steps; `A2`–`A4`, `B1`–`B4`, `C2`, `C4`, `C5`; `scenario-report` merger; pjsip log interleaving; the watchdog | **E1**, **E2**, **E3** (§3.3) |
| **P3** | Roles; two devices; run-id correlation at analysis time; `C1`, `C3`, `D1`, `D2` | **E4** (`custom_call_id`, device enumeration) |
| **P4** | In-app scenario picker, live run view, on-device report | none |

**Against the original phase 4.** "Live orchestration" is not a phase — §5.1 settled that the
operator is the orchestration, and a coordination layer is a future consideration (§5.1), not the
end of this road. Phase 4 is the debug UI alone, and it is genuinely optional: the environment
contract in §4.1 is the interface, and the UI is a convenience over it.

---

## 9. Named gaps — what this design cannot reach

A named gap is worth more than a plan implying full coverage. Five.

### 9.1 "Permission revoked mid-call" is not observable as one continuous run

Changing a privacy setting for a running app terminates it **[A — long-standing iOS behaviour, not
verified here; it is the first thing phase 2 should confirm, and it costs one run]**. If that holds,
no scenario can observe a live call surviving a revocation, because the process does not survive it.

What is reachable: the state *after*, and whether the app recovers. That is `A3`/`A4`, and it is why
§5.2 requires the run id to outlive the process. State this in the report rather than letting a
reader assume mid-call revocation was covered.

### 9.2 A real deadlock cannot be reported by anything that goes through the engine

If the pinned PJLIB thread wedges — the §3.2 release-path risk, upstream #4928 — then every
subsequent `await engine.…` queues behind it forever, **including any step that would record the
failure**. `EngineHarness`'s `poll` cannot help: it polls snapshots that only the wedged actor
updates.

The mitigation is an **off-actor watchdog**: a plain `Task` holding no engine reference, checking a
heartbeat the engine bumps, able to write a `wedged` record and flush the file. It can report the
wedge. It cannot clear it, and it cannot say what the PJLIB thread was doing. The run ends as
`WEDGED` and the artifact is the last flushed line plus whatever the device console holds.

### 9.3 pjmedia does not report a lost camera, so the harness must infer it

`darwin_dev.m` observes `AVCaptureSessionRuntimeErrorNotification` and its handler **only logs, at
level 3** — it propagates no status, stops no stream, and emits no media event
**[V, `session_runtime_error:`]**.
It does not observe `AVCaptureSessionWasInterrupted` at all **[V, grep]**, which is the notification
iOS actually posts when another app takes the camera or the app is backgrounded.

So a camera lost mid-call is **invisible above the videodev layer**: the stream stays `.active` and
frames simply stop. The harness can only infer it, from two sides — the app's own
`AVCaptureSession` notifications, and `AwaitStall` on the RTP counters. That inference is the
result of `B1`, and if it holds it is itself worth reporting upstream.

### 9.4 The lock screen is a one-way surface

The app cannot lock the screen (no API), so every lock is an `AskTester`. Worse, the app cannot
present a prompt while locked — so `C5` must queue the next prompt and record the locked interval as
elapsed time rather than as a step the tester ignored. And "did the lock screen show the right
thing" is permanently an `AskObserver` question: CallKit tells the app what it *asked* for, never
what was drawn.

### 9.5 The event stream can lose events, and the run log must say so

`engine.events` is `.bufferingNewest(64)`; under a callback burst the **oldest** events are dropped
**[V, TD-3]**. A harness claiming a complete timeline over a lossy input is claiming too much. E2
(§3.3) turns this from an invisible hole into a recorded one — a gap in the per-event sequence
number — but it does not prevent it. The merged report must render sequence gaps as visible
discontinuities in the timeline, in the same spirit as §4.3's skip rule.

**And one thing that is not a gap but must be said plainly: the Simulator is out of scope.** None of
§3's three classes is observable there. The existing suite already records the evidence — `test06`
skips with *"video negotiated but no RTP on this host"*, and the comment notes H264 negotiates while
0 packets flow **[V]**. A half-supported Simulator path would produce green runs that mean nothing.

**CI, likewise, is out of scope in every phase here.** What would have to become true: a scenario
with zero `AskTester` steps, a device farm with a wired, unlocked, permission-preseeded phone, and
a merger that exits non-zero on `PARTIAL`. `A1`, `B2` and `B4` are already human-free and would be
the first candidates the day such a rig exists — which is worth knowing, but is not a reason to
build for it now.

---

## 10. Conventions this harness must respect

- **Credentials** come from the environment first, then `../secrets/test-accounts.env`, never a
  commit and never a log line **[V, `TestAccounts.swift`, Playbook §5]**. The recorder redacts
  `OFFHOOK_*PASSWORD*` by key at write time rather than by pattern.
- **Device identity** in the log is the model identifier plus a stable per-install UUID. Never
  `UIDevice.name` — on a personal phone that is a human name, and these logs are attached to public
  bug reports.
- **Live-run etiquette** applies unchanged: scenario runs hit other people's registrars, and a
  scenario that loops must bound its call count the way `test05` bounds its legs **[V]**.
- **Repo docs stay public-safe.** This document is. Device inventory, account slots and cross-repo
  sequencing live in `PROJECT-MEMORY.md`.

## See Also

- [Testing-Playbook](./Testing-Playbook.md) ·
  [SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md)
- [Tech-Debt](./Tech-Debt.md) OH-8, OH-9 · [Roadmap](./Roadmap.md) "Debug / SIP tooling UI"
- `../../swift-pjsua/docs/Production-Roadmap.md` · `../../swift-pjsua/docs/Threading-Validation.md`
  · `../../swift-pjsua/docs/Tech-Debt.md` TD-3, TD-6, TD-28
- pjproject [#5249](https://github.com/pjsip/pjproject/pull/5249) (stride fix) ·
  [#4928](https://github.com/pjsip/pjproject/issues/4928) (`darwin_stream_stop` deadlock)
