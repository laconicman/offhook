# Testing playbook

How to actually run the tests for this stack, on what, and what will bite you. Testing a
softphone spans three repos, two hosts and a live network, and almost every constraint below
cost someone an afternoon to discover. **Read this before inventing a way to run something.**

- *What* to test against — providers, accounts, echo endpoints — is
  [`SIP-Test-Infrastructure.md`](./SIP-Test-Infrastructure.md).
- *How* to run it is here.

## 1. The four suites

| Suite | Repo | Kind | Runs on | Network |
|---|---|---|---|---|
| `verify-xcframework.sh` | `swift-pjsip` | shell, inspects the artifact | **macOS**, no simulator | none |
| `SwiftPJSUATests` (incl. `TLSTransportTests`) | `swift-pjsua` | XCTest, tool-hosted | **Simulator only** (§2) | none |
| `SwiftPJSUAKitTests` | `swift-pjsua` | XCTest, tool-hosted | **Simulator only** | none |
| `OffhookIntegrationTests` | `offhook` | XCTest, tool-hosted | **Simulator only** (§2) | **live SIP** |
| the app's auto-smoke | `offhook` | the app itself | Simulator **and device** | **live SIP** |

```sh
# swift-pjsip — 57 checks, no build state needed
swift-pjsip/scripts/verify-xcframework.sh swift-pjsip/.build-pjsip/output/PJSIP.xcframework

# swift-pjsua — 8 tests, offline
xcodebuild test -scheme swift-pjsua-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# offhook — LIVE, hits real registrars. Space runs out; see §5.
xcodebuild test -scheme Offhook -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OffhookTests/OffhookIntegrationTests/test03_allConfiguredAccountsRegister
```

## 2. Why nothing in the table runs XCTest on a device

An XCTest bundle is either **app-hosted** — injected into a host application, which XCTest
launches — or **tool-hosted** (historically "logic tests"), run by the `xctest` command-line
tool with no host app at all. Apple allows tool-hosted testing on macOS and the Simulator and
**not on device destinations**:

```
Cannot test target "X" on "device": Tool-hosted testing is unavailable on device
destinations. Select a host application for the test target, or use a simulator destination.
```

Both our XCTest bundles are tool-hosted, for different reasons:

- **`swift-pjsua`'s** are SwiftPM package tests. `Package.swift` has **no way to declare a
  host application** — the setting does not exist in the manifest API — so a package test
  target is tool-hosted by construction. There is no flag that fixes this; the only routes are
  an Xcode project wrapping the package, or moving the tests into a project that has an app.
- **`offhook`'s** could be app-hosted (it has an app) and currently is not.

### Making `OffhookTests` app-hosted — tried, and what stops it

In `project.yml`, adding the app as a dependency is all XcodeGen needs; it writes `TEST_HOST`
and `BUNDLE_LOADER` for you:

```yaml
  OffhookTests:
    dependencies:
      - target: Offhook          # <- this line is the whole change
      - package: swift-pjsua
        product: SwiftPJSUA
```

**Verified 2026-09-03: this generates correctly and then fails to link.** Hosting makes the
test bundle link `libpjproject.a` in a context that pulls in `ios_opengl_dev.o`, and
`SwiftPJSUA`'s `linkerSettings` do not carry the frameworks that object needs:

```
Undefined symbol: _OBJC_CLASS_$_CAEAGLLayer, _EAGLContext          -> OpenGLES
Undefined symbol: _OBJC_CLASS_$_UIView, _UIApplication, _UIDevice  -> UIKit
Undefined symbol: _OBJC_CLASS_$_MTLRenderPipelineDescriptor        -> Metal (MetalKit is not enough)
                  _OBJC_CLASS_$_GLView in libpjproject.a[22](ios_opengl_dev.o)
```

The app itself links because SwiftUI drags UIKit/Metal in anyway. The support-target pattern
(`SwiftPJSUA` carries the `-framework` flags for its consumers) is simply missing three of
them. **Two prerequisites before adopting hosting**, neither done:

1. add `OpenGLES`, `UIKit` and `Metal` to `SwiftPJSUA`'s `linkerSettings`, or stop compiling
   the OpenGL video device into the binary;
2. settle that **pjsua is process-global** — one engine per process, no restart. An app-hosted
   bundle runs inside the app, whose `PhoneModel` constructs its own `PJSUA` and installs the
   global event sink. The harness constructs a second one. Last writer wins on the sink, which
   happens to be the harness today. That is an accident, not a design.

Until then: **XCTest is Simulator-only here, and that is a constraint, not an oversight.**

## 3. Running on a device anyway

The app is the device harness. `OFFHOOK_AUTOSMOKE=1` runs start → register → dial, and the
other `OFFHOOK_*` variables (see `PhoneModel.init()`) supply the account, so no UI typing and
no test bundle is involved.

```sh
D=<device-udid>                      # xcrun devicectl list devices
xcodebuild build-for-testing -scheme Offhook -destination "platform=iOS,id=$D" \
  DEVELOPMENT_TEAM=WEJF495R4D
xcrun devicectl device install app --device $D \
  ~/Library/Developer/Xcode/DerivedData/Offhook-*/Build/Products/Debug-iphoneos/Offhook.app
xcrun devicectl device process launch --device $D --console \
  --environment-variables '{"OFFHOOK_AUTOSMOKE":"1","OFFHOOK_PORT":"0",
    "OFFHOOK_REGISTRAR":"iptel.org;transport=tls","OFFHOOK_USERNAME":"…","OFFHOOK_PASSWORD":"…"}' \
  com.laconicman.offhook
```

Four things that will stop you, in the order you will hit them:

- **`The developer disk image could not be mounted`** — the device is **locked**. Nothing to
  debug; unlock it and turn auto-lock off. Developer Mode being enabled is separate and is not
  what this message means.
- **`Signing for "Offhook" requires a development team`** — `project.yml` sets
  `CODE_SIGN_STYLE: Automatic` but no team, deliberately. Pass `DEVELOPMENT_TEAM=…` on the
  command line rather than committing one. `WEJF495R4D` is the team carrying `com.laconicman.*`.
- **`OFFHOOK_REGISTRAR` is a bare host, not a URI.** The app builds `sip:<user>@<registrar>`
  itself, so `sip:iptel.org;transport=tls` yields `sip:offhook@sip:iptel.org` and
  `PJSIP_EINVALIDURI`. Pass `iptel.org;transport=tls`.
- **`bind() error: Address already in use`** — see §4.

Terminate between runs (`devicectl device process terminate --pid …`); a live app keeps
re-registering every 60 s.

## 4. Port 5060 is not yours on a real phone

`PJSUA.start()` is fail-fast (TD-18): if one listener cannot bind, the whole engine throws.
On a real device that is a live hazard, because **5060 is the IANA SIP port and any installed
softphone holds it** — a registered client must, to receive inbound INVITEs.

Measured on PavP, 2026-09-03, with **zero** Offhook processes running:

| port | result |
|---|---|
| 5060 | `bind() error: Address already in use [status=120048]`, engine start fails |
| 5062 | UDP + TCP bind, TLS listener up, registration 200 OK |

So it is genuine, port-specific occupancy — not a sandbox denial (that would be `EACCES`),
and not our own leftover. `devicectl device info apps --include-all-apps` found **three SIP
clients installed**: AlloPhone (`ru.alloincognito.sip1`), MizuPhone (`com.mizu-voip.mizuphone`)
and MobileVOIP (`com.mobilevoip.MobileVOIP`).

**iOS gives you no way to name the holder.** There is no `lsof`/`netstat` for a
non-jailbroken device and the sandbox hides other processes' sockets. The two things that do
work are exactly what was done above: enumerate installed apps for SIP clients, and bind-probe
from your own app to find which ports are free.

**Use `OFFHOOK_PORT=0`** for device runs. Ephemeral ports are correct for a client anyway; a
fixed 5060 only matters for unsolicited inbound SIP, which a mobile UA gets via push, not by
squatting the IANA port.

## 5. Live-run etiquette

- **Space runs out.** These are other people's free registrars.
- **A provider 408 is weather, not a bug** — the suite tolerates it for accounts on slots ≥ 3
  and hard-fails only for the ACC1/ACC2 loopback pair.
- **Never probe bad credentials against the loopback pair.** Flexisip answers the *correct*
  password with 403 for minutes after one failed attempt. `test02` deliberately uses a made-up
  username on a slot ≥ 3 domain.
- **`test05` classifies rejections.** 403/429/480/486/500/503/603 skip with the code named;
  anything else disconnecting a leg fails. 408 is deliberately excluded — no answer at all is
  a different event from a server saying "no", and merging them hides real regressions.
- Credentials come from the environment first, then `../secrets/test-accounts.env`, which lives
  outside the repo. Never commit them, never echo them into a log.

## 6. Caveats that are not bugs

| What you see | What it is |
|---|---|
| `Build input file cannot be found: …CallLifecycleObservationTests.swift` | `Offhook.xcodeproj` is **generated and gitignored**. Run `xcodegen generate` after switching branches — the checked-out project is from whichever branch generated it last. |
| `RTP socket bind() at 0.0.0.0:400x error: Address already in use`, repeatedly | Normal. `acc->next_rtp_port` is a **per-account** cursor starting at `media_cfg.port` (4000), and `test05` runs two accounts in one process, so the second account's first attempts land on ports the first already holds. `pjsua_media.c` walks up by 2, `RTP_RETRY == 100` times. The only real problem is that the retry logs at `PJ_PERROR(1, …)` — **error level inside a normal allocation walk**. Eight legs occupy 4000–4014. |
| `198.18.0.1` as the local address, on the Mac *and* the phone | A **VPN tunnel**, not a LAN address — `utun4` on the Mac, Psiphon on the device. 198.18.0.0/15 is RFC 2544 benchmarking space that VPN clients like. Every live result recorded so far is a *VPN-on* result; VPN-off is untested (§7). |
| `IP address change detected for account 0 (… --> …). Updating registration (using method 4)` | Working as designed. See §7. |
| `dig`/`host` time out while the app resolves fine | Both talk to a nameserver directly and a full-tunnel VPN breaks that. Use `dscacheutil -q host -a name <host>`, which asks the resolver the app uses. |
| several different `Executed N tests` lines from one `swift-pjsua-Package` run | `xcodebuild` prints a total per *suite*, per *bundle* and per *run*. The package has **8 tests in `SwiftPJSUATests`** (6 of them `TLSTransportTests`) and **8 in `SwiftPJSUAKitTests`**. Read the last line, or use `-only-testing:`. |

## 7. Contact rewrite, and what is still untested

On the device the registrar was reached through a VPN, so the Contact pjsua put in the REGISTER
(`198.18.0.1:56128`) was not the address the packet arrived from. Observed:

```
REGISTER … Contact: <sip:offhook@198.18.0.1:56128>
SIP/2.0 401 Unauthorized                     ← Via carries received=72.57.78.66;rport=42288
IP address change detected for account 0 (198.18.0.1:56128 --> 72.57.78.66:42288)
        Updating registration (using method 4)
REGISTER … (authenticated, corrected Contact)
SIP/2.0 200 OK → registration success, re-register in 60 s
```

**Method 4 is `PJSUA_CONTACT_REWRITE_ALWAYS_UPDATE`**, and the detail worth keeping is *when*
it fired: `pjsua_acc.c` calls `acc_check_nat_addr(acc, PJSUA_CONTACT_REWRITE_ALWAYS_UPDATE, …)`
on any final response **with code ≥ 400** — here the 401 challenge. Without that flag the
rewrite waits for a 2xx. So pjsua learned the public mapping from the *challenge* and the very
first authenticated REGISTER already carried the right Contact: one round trip saved, and no
window in which the registrar holds a binding pointing somewhere unroutable. The default
`contact_rewrite_method` is `NO_UNREG(2) | ALWAYS_UPDATE(4)`, so this is stock behaviour, not
something we configured.

**Still untested, and worth a deliberate run:**

- **VPN off.** Everything above is a VPN-on result on both hosts. Off, the phone gets a
  carrier-NAT or Wi-Fi mapping instead, which is the topology real users are on — and carrier
  NAT rebinds far more aggressively than a tunnel, which is what the rewrite path exists for.
- **Cellular vs Wi-Fi**, and the handover between them (the M2 IP-change milestone).
- **A device-to-device call.** Everything so far is loopback through a registrar in one process.
- **XCTest on a device** — blocked on §2's two prerequisites.
