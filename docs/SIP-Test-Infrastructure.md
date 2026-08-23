# SIP test infrastructure

Where to point Offhook to exercise the stack against **real SIP infrastructure**, ordered so you
can get first audio the moment it compiles, then grow into each milestone. Verified as of
June–July 2026 (web-level: docs/status pages; SIP-level liveness re-confirmed only where
marked); public services come and go, so treat liveness as "confirmed recently, re-check if it
fails." No secrets here — register your own accounts; credentials are yours.

## 0. Fastest path to first audio (Phase 0 smoke)

Register one free account, then type its values into Offhook's three fields + a dial target:

| # | Register at | Registrar host | Dial target (echo) | Why |
|---|---|---|---|---|
| **A** | <https://subscribe.linphone.org> | `sip.linphone.org;transport=tcp` | a **second own account** (loopback) — the historic echo `4443` is **gone**: SIP **404**, verified 2026-07-04 | Flexisip stack we'll target for push/conference later; TLS/SRTP/video. **TCP required** — see §6 fragmentation gotcha. |
| **B** | <https://sip2sip.info> | `sip2sip.info` | `sip:4444@sip2sip.info` (mic echo) · `sip:3333@sip2sip.info` (audio+video) | AG Projects/Blink; ICE/STUN, TLS, SRTP, presence. |
| **C** | <https://www.iptel.org> | `iptel.org` | `sip:echo@iptel.org` (`sip:music@iptel.org` = announcement) | Kamailio; oldest free service. |

Expected: register → `registered (200)`; dial → `confirmed` / media `active` → **you hear your
own voice**. Flexisip negotiated **iLBC** with our binary (SIP-verified 2026-07-04); G.711
(PCMU/PCMA) elsewhere — Opus is absent from the current binary
(`../../swift-pjsip/docs/Codec-Coverage.md`). Offhook defaults to option **A**.

> **Loopback pattern** (SIP-verified 2026-07-04; automated by `../Tests/`): register **two**
> accounts on the same registrar and call one from the other. The INVITE goes out to the real
> server and back — real signalling, auth, and RTP — with no dependency on an echo service
> staying alive. This is now the recommended "echo" for Flexisip.

## 1. Provider reference

### Free SIP services (real registrars, immediate)

| Service | Domain | Transports | SRTP | Test endpoints | Good for |
|---|---|---|---|---|---|
| **Linphone** | `sip.linphone.org` | UDP/TCP/TLS | ZRTP/SRTP | ~~`4443` (echo)~~ **404** as of 2026-07-04 — use the two-account loopback (§0) | register, audio, **video**, **server conference** (native acct), **push** (self-host, §3) |
| **sip2sip.info** | `sip2sip.info` | UDP/TCP/TLS | SRTP | `4444` mic, `3333` A/V, `echo@conference.sip2sip.info` (RTP+MSRP echo), `<room>@conference.sip2sip.info` (ad-hoc SylkServer conference) | register, echo, video, ICE/STUN, presence, **multi-party conference** (signup verified working 2026-08-22 — no captcha, instant; but its backend **rejects `+` plus-aliased e-mails**, which reads as a generic "invalid input data value") |
| **iptel.org** | `iptel.org` | UDP/TCP | — | `echo@iptel.org`, `music@iptel.org` | register, echo (Kamailio home turf) |
| **antisip** | `sip.antisip.com` | UDP/TCP/TLS | SRTP | ~~`thetestcall@sip.antisip.com`~~ **404 "User Is Offline"** (Kamailio 5.8.8), verified 2026-08-19 — register still works | register, RTP/media edge cases |
| **OnSIP** | `sip.onsip.com` | UDP/TCP/TLS | SRTP | `echo` test app on the account | register, audio/video, IM — free plan still advertised, signup flow **re-check** |

### Commercial / PSTN-connected (real telco, exercise NAT, SRV, TLS)

| Provider | Account | Echo / test | Notes |
|---|---|---|---|
| **Callcentric** | free + free NY DID | `sip:17771234567@callcentric.com` | own STUN server; good NAT/STUN test |
| **VoIP.ms** | paid (small funds) | `4443` (only number callable without funds) | TLS+SRTP, SRV records, many POPs — good SRV-vs-A test |
| **Telnyx / Twilio / sip.us** | free trial credit | provider IVR / your own DID | programmable; credential-based register or IP auth |

## 2. Capability → where to test (milestone map)

| swift-pjsua capability | Engine API exercised | Where to test |
|---|---|---|
| Register / auth, 401→digest | `addAccount`, `on_reg_state2` | any provider above |
| Audio call + media wiring | `makeCall`, `pjsua_conf_connect` | any echo endpoint (§0) |
| Hold / unhold | `setHold`/`resume` | call a second client (two Offhook/Linphone instances) |
| Mute, DTMF (RFC 2833) | `setMute`, `sendDTMF` | a **menu/IVR** endpoint (provider IVR, or Asterisk `Read()`), not a bare echo |
| **Video** + interactive up/downgrade | `addVideoStream`/`removeVideoStream`/`changeVideoCaptureDevice` | sip2sip `3333`, or two Linphone clients |
| Parallel calls + **local-mix conference** | `connectAudio(_:and:)`, CallKit `setGroup` | place 2 calls (two echo endpoints / two clients) and merge |
| **Simultaneous incoming calls** (dedup, CallKit multi-call UI) | `CallRegistry`, UUIDv5 dedup | two *other* accounts (different domains ideally) calling your AOR at once — needs 3 accounts total |
| **Server-focus conference** (RFC 4579) | `isConferenceFocus`, single leg | `<room>@conference.sip2sip.info` (SylkServer ad-hoc mix; verify it sets `isfocus` — re-check), Linphone conference (native acct), or self-hosted Asterisk ConfBridge |
| **Hybrid VoIP push** (RFC 8599) | `PushConfiguration.apns`, `reRegister` | **self-hosted** Flexisip/OpenSIPS (§3) — public servers won't push your bundle |
| STUN / ICE | (engine surface TODO — TD-14) | set a STUN server (§4), call across NAT |
| TLS / SRTP | `Transport.tls` | Linphone / sip2sip / VoIP.ms over TLS |

## 3. Push (RFC 8599) — servers, what to supply, self-hosting

Goal: the app **rings in the background via APNs** (PushKit VoIP push). The server holds the
Apple credential and fires the push when an INVITE arrives for a sleeping registration; the app
wakes, re-REGISTERs, and receives the parked INVITE. The public `sip.linphone.org` holds
*Linphone's* APNs credentials and **will not push `com.laconicman.offhook`** — end-to-end push
requires a server provisioned with *your* Apple credential (§3.3). Until then, test the
persisted-connection INVITE path (no push) against any provider; the dedup logic
(`CallIdentity`/`CallRegistry`) is what self-hosted push later validates.

### 3.1 Which servers implement RFC 8599 (verified July 2026)

| Server | RFC 8599 | APNs auth | SIP → APNs mechanics |
|---|---|---|---|
| **Flexisip** (Belledonne) | ✓ native, most complete (+ `apns.dev` sandbox extension) | **VoIP Services certificate** (PEM); token/`.p8` auth not in its docs | Built in. `module::Router` `fork-late=true` parks the INVITE; `module::PushNotification` posts to APNs; periodic register-wakeup keeps bindings alive. Docker images exist. |
| **OpenSIPS 3.1+** | ✓ native *signaling* (`registrar`/`mid_registrar`, `pn_enable`) | **your choice** — you write the sender, so `.p8` token auth works | `lookup()` returns **2** = "contacts found but all push-only" (park, don't relay); raises `E_UL_CONTACT_REFRESH` with the `pn-*` coordinates → your `event_route` does the actual APNs HTTP/2 call (§3.3). `mid_registrar` variant fronts an existing registrar. |
| **Kamailio** | ✗ **no native support** (maintainer-confirmed, issue #3508) | n/a | DIY assembly: registrar stores `pn-*` params → `tsilo` suspends the INVITE → `http_client`/`evapi` triggers your push sender → `ts_append` on re-REGISTER. Third-party `push` module (tvntsr) is stale. Workable, most effort. |
| **Asterisk** | ✗ | n/a | No RFC 8599; expects persistent connections or an external gateway in front. |
| **Push gateways** | Flexisip has a dedicated *push-gateway mode*; **Mizu MPUSH** (commercial, Windows, self-hosted) speaks RFC 8599 + proprietary | cert | Transparent proxy in front of any existing SIP server — relevant only for infra we don't control. |

Contact-URI parameters (Flexisip's RFC 8599 profile — the de-facto reference; matches what
the engine emits):

| Param | Value for APNs |
|---|---|
| `pn-provider` | `apns` (production) · `apns.dev` (sandbox — Flexisip extension; IANA registers only `apns`/`fcm`/`webpush`) |
| `pn-prid` | `<PushKitToken>` for VoIP-only · `<RemoteToken>:remote&<PushKitToken>:voip` for both |
| `pn-param` | `<TeamID>.<BundleID>.voip` for PushKit · `.remote&voip` suffix for both (Flexisip extension) |

`PushConfiguration.apns(teamID:bundleID:token:)` emits exactly
`;pn-provider=apns;pn-param=<TeamID>.<BundleID>.voip;pn-prid=<token>` — Flexisip-compatible for
production builds; see the sandbox trap in §3.2 step 6.

### 3.2 To get a background ring for `com.laconicman.offhook` you need

**Apple side (one-time provisioning, developer.apple.com):**
1. Apple Developer Program membership; App ID `com.laconicman.offhook` with the Push
   Notifications capability.
2. An APNs credential — one of:
   - **APNs Auth Key `.p8`** + Key ID + Team ID (token auth). One key serves all your apps,
     both sandbox *and* production, never expires; valid for VoIP pushes
     (`apns-push-type: voip`, `apns-topic: com.laconicman.offhook.voip`). The path for
     OpenSIPS / Kamailio / any DIY sender.
   - **VoIP Services Certificate**, exported Keychain→`.p12`→PEM. The form **Flexisip
     requires** (its docs are cert-only): file must be named
     `/etc/flexisip/apn/com.laconicman.offhook.voip.prod.pem` (+ a `.dev.pem` symlink for
     sandbox). One VoIP cert covers sandbox + production.

**App / Xcode side (already in place — verify, don't re-add):**
3. `voip` background mode + PushKit entitlement (set), PushKit registration providing the
   token (`PKPushRegistry`, type `.voIP`).
4. iOS 13+ hard rule: **every** VoIP push must be reported to CallKit immediately
   (`reportNewIncomingCall`) or iOS kills the app and stops delivering pushes —
   `SwiftPJSUAKit`'s `VoIPPushHandler` owns this.
5. REGISTER carries the push params via `PushConfiguration` (engine appends
   `reg_contact_uri_params`); `pn-prid` = the PushKit token as hex.
6. **Sandbox trap:** Xcode/dev-signed builds receive *sandbox* PushKit tokens → pushes must go
   to `api.sandbox.push.apple.com`. Flexisip routes to sandbox only when
   `pn-provider=apns.dev`, but the `.apns()` helper emits `apns` (production). For dev builds
   register with the raw-string initializer:
   `PushConfiguration(params: ";pn-provider=apns.dev;pn-param=…voip;pn-prid=…")`.
   TestFlight/App Store builds use production tokens + `apns`. Mismatched env is the classic
   `BadDeviceToken` / flexisip_pusher "error 8 (Invalid token)".

**Server side:**
7. A §3.1 server holding credential (2), with long registration expiry
   (Flexisip `max-expires=604800`) and INVITE parking (`fork-late=true` / OpenSIPS rc==2 flow).

### 3.3 Shortest viable self-host recipe

**Flexisip (Docker) — aligns with our stack:**

```ini
# /etc/flexisip/flexisip.conf (knobs that matter for push)
[module::Registrar]
reg-domains=<your-domain>
max-expires=604800          # wakeable for 7 days after last REGISTER

[module::Router]
fork-late=true              # park INVITEs while the push wakes the app

[module::PushNotification]
enabled=true
apple=true                  # certs read from /etc/flexisip/apn (apple-certificate-dir)
```

Steps: run the Belledonne Docker image (official `docker/` in the flexisip repo; community
compose files exist), mount `/etc/flexisip`, drop the VoIP-cert PEM into `/etc/flexisip/apn/`
under the imposed name (§3.2-2), create accounts (flexisip-account-manager, or static auth
db for a lab). Verify the server→APNs leg *alone* with the bundled tool before touching the app:

```sh
flexisip_pusher --pn-provider apns.dev \
  --pn-param <TeamID>.com.laconicman.offhook.voip \
  --pn-prid <pushkit-token-hex> --apple-push-type PushKit --debug
# expect: "1 push notification(s) sent, 1 successfully and 0 failed."
```

**OpenSIPS 3.1+ — if you'd rather keep the `.p8` (no cert/Keychain dance):** enable
`pn_enable` on `registrar`, catch `E_UL_CONTACT_REFRESH` in an `event_route`, and send the
push yourself; the whole APNs leg is one HTTP/2 request with an ES256 JWT signed by the `.p8`:

```sh
curl --http2 -H "authorization: bearer $APNS_JWT" \
  -H "apns-topic: com.laconicman.offhook.voip" \
  -H "apns-push-type: voip" -H "apns-priority: 10" \
  -d '{"aps":{"call-id":"..."}}' \
  https://api.sandbox.push.apple.com/3/device/$PN_PRID   # prod: api.push.apple.com
```

Division of labor for the lab setup: **you provide** the Apple credential (VoIP cert PEM or
`.p8` — keep it out of every repo) + a host with a public IP/domain; the compose file,
`flexisip.conf` template, and account seeding are scaffoldable.

### 3.4 Hosted alternative?

None found (as of July 2026) that lets you register a **custom** bundle id for RFC 8599 push
without running a server: CPaaS "mobile push credentials" (Telnyx, Twilio, …) apply to *their
app SDKs*, not raw SIP registrations (re-check periodically); Mizu MPUSH is explicitly
self-hosted, not SaaS; public Flexisip/Linphone infra is bound to Linphone's certs. Budget a
small VPS — the Flexisip container is light.

## 4. STUN / ICE

- Google: `stun.l.google.com:19302` (+ `stun1.l.google.com` … `stun4.l.google.com:19302`).
- Cloudflare: `stun.cloudflare.com:3478`.
- Live-verified list (refreshed hourly): <https://github.com/pradt2/always-online-stun>.
- TURN for relay testing: Open Relay (metered.ca) or self-host coturn.

(Engine STUN/ICE surface is TD-14 — not yet exposed; this is for when it lands.)

## 5. Self-hosting (full control: push, focus conference, transfer, IVR)

| Tool | Best for | Note |
|---|---|---|
| **Flexisip** (Docker) | RFC 8599 **push** (built-in APNs sender), Linphone-style conference, registrar | aligns with the swift-pjsip/Linphone stack; §3.3 recipe |
| **OpenSIPS 3.1+** | RFC 8599 **push** signaling with a BYO `.p8` sender, registrar, mid-registrar in front of other infra | most flexible push lab; §3.3 |
| **Asterisk** | echo (`Echo()`), **ConfBridge** focus, IVR/DTMF (`Read()`), **transfer**, registrar (`res_pjsip`) | easiest full PBX for feature tests; no RFC 8599 |
| **Kamailio + rtpengine** | scale, SRV, registrar, media relay | what iptel.org runs; push = DIY `tsilo` pattern (§3.1) |

A local Asterisk on the LAN is the quickest way to get a registrar + echo + conference + IVR you
fully control for the M3 feature demos.

## 6. Gotchas

- **Proxy-authenticated INVITE exceeds the UDP MTU** (hit live, 2026-07-04) — Flexisip
  407-challenges INVITE; the authenticated resend (~1.6 kB of SDP + digest) is over pjsip's
  1300-byte UDP threshold, and the RFC 3261 §18.1.1 UDP→TCP auto-switch does **not** cover the
  resend (it reuses the already-resolved UDP destination) → the request fragments and is
  dropped **silently**; the call just never confirms. Fix: register **and** dial with
  `;transport=tcp` (swift-pjsua now always opens a TCP listener beside UDP; its TD-16 tracks
  proper outbound-proxy support).
  **Reproduced on a second provider, 2026-08-19** — so it is our stack's behaviour, not Flexisip's.
  Calling `sip:thetestcall@sip.antisip.com` from ACC4 over UDP: initial INVITE **1289 B** (under
  pjsip's 1300 threshold) → `407` answered normally → authenticated resend **1578 B** → sent over
  UDP anyway, retransmitted 5×, never answered, call times out. Identical shape at
  `sip.linphone.org` (1322 B → 407 → 1634 B).

  **Consequence for testing: we cannot place an authenticated call over UDP to any provider**, so
  the UDP rows of the call-termination taxonomy are unreachable from this stack until the INVITE
  fits or the switch works. That blocked the planned UDP transport-death run
  (`../../swift-pjsua/docs/Call-Termination-Paths.md` row 16).

  **Root cause found 2026-08-19, and it is ours, not pjsip's.** `swift-pjsip/scripts/config_site.h`
  sets `#define PJSIP_DONT_SWITCH_TO_TCP 1` (upstream default is **0**). That is consulted at
  `sip_util.c:1419` — `if (pjsip_cfg()->endpt.disable_tcp_switch==0 && …)` — and it guards the
  **entire** RFC 3261 §18.1.1 block, size check and TCP-transport lookup included. So the switch
  never runs at all: the oversized authenticated resend goes out on UDP by configuration.

  This supersedes the closing analysis in
  `../../swift-pjsua/Upstream/udp-tcp-switch-not-reapplied-on-auth-resend.md`, which
  attributed our symptom to the switch running and finding no TCP transport to acquire. On this
  binary the switch is disabled before it can look. (The upstream logging PR that came out of that
  investigation, pjproject#5076, is unaffected — the path it instruments is real and reachable by
  any app that leaves the switch enabled. What was wrong was our attribution of *our* symptom
  to it.)

  **Fixed 2026-08-19 at runtime**, no rebuild: `swift-pjsua` now sets
  `pjsip_cfg()->endpt.disable_tcp_switch = 0` in `PJSUA.start()`. Verified immediately — the same
  antisip call that had been swallowed by fragmentation now switches the authenticated INVITE to
  TCP (`INVITE/cseq=5418 … to TCP 5.39.72.109:5060`) and gets a real answer. The loopback suite
  (test03/04/07) passes unchanged, so nothing regressed.

  **Two consequences worth knowing.** The `;transport=tcp` advice above is still the right default
  — it keeps *inbound* requests off UDP too, which the switch cannot help with. And an
  authenticated call now **leaves UDP by design**: since our INVITE crosses 1300 bytes once the
  digest is added, §18.1.1 moves it to TCP every time. So this stack effectively never carries an
  authenticated dialog over UDP, which is correct behaviour and also why UDP transport-death
  testing stays out of reach (`../../swift-pjsua/docs/Call-Termination-Paths.md` §6.5).

- **SRV vs A record** — some providers publish no SRV; an SRV-only resolver fails to register.
  Fall back to A/AAAA (roadmap M2 / TD-14). VoIP.ms is a good SRV test.
- **NAT / symmetric RTP** — without STUN/ICE you may register fine but get one-way/no audio
  behind NAT. Echo endpoints on public servers usually have symmetric-RTP handling.
- **TLS** — `Transport.tls` validates against the Darwin trust store; provider cert must chain
  to a system root.
- **Codec** — only G.711/G.722/iLBC/G.729 today (no Opus); fine for all these endpoints.
- **Push needs your APNs credential on the server** (§3.2) — the single biggest "why doesn't
  it ring in the background" trap.
- **Sandbox vs production APNs mismatch** (§3.2-6) — dev-signed build + `pn-provider=apns`
  = `BadDeviceToken`. Second-biggest push trap.
- **iOS 13+ CallKit reporting** — a VoIP push not reported to CallKit immediately gets the app
  terminated and future pushes dropped; symptoms look like "push stopped working".
- **`dig` / `host` lie behind a full-tunnel VPN** (2026-08-18) — both talk to a nameserver
  directly and time out, so a resolution check "fails" while the stack resolves the host fine.
  Use `dscacheutil -q host -a name <host>`, which asks the same system resolver the app does.
- **The simulator has no network of its own.** It shares the Mac's stack, so host-level pf rules,
  VPN routes and DNS apply to it unchanged — which is what makes §7 possible, and also means the
  Mac's VPN is silently in the path of every "live SIP" result (our SDP origin line carried the
  tunnel address `198.18.0.1`, not a LAN address).

## 7. Failure injection — breaking the network on purpose

Most of the call-lifecycle taxonomy in `../../swift-pjsua/docs/Call-Termination-Paths.md` is about
what happens when a transport dies **without** a SIP goodbye. No amount of app-side testing
produces that: you have to kill the network under a live call and watch. `scripts/pf-blackhole.sh`
is that lever.

### 7.1 Why pf, and not the obvious alternatives

| Lever | Reach | Verdict |
|---|---|---|
| **`pfctl`** | one host, or one *protocol* to one host | **Chosen.** Surgical enough to drop RTP while leaving signalling up (the only way to observe rows 9–13); nothing else on the machine is disturbed. Costs one `sudo` per window. |
| Wi-Fi off (`networksetup -setairportpower`) | everything | Kills the VPN with it — which may need a manual reconnect — and cannot separate signalling from media. Fine as a fallback, blunt. |
| Airplane mode on a device | everything, plus iOS socket suspension | The most *realistic* case and the right one for the backgrounded re-run, but needs a device build and two taps mid-experiment. |
| A local SIP proxy the test dials through | one dialog | Rejected. Routing a dialog through `127.0.0.1` transparently means rewriting the Request-URI **and** the Record-Route/Contact of every response, or the ACK and BYE leave via the real server and the isolation evaporates. A mini-ALG for less isolation than one pf rule. |

### 7.2 The script

```sh
sudo offhook/scripts/pf-blackhole.sh all      # signalling AND media — a dead network
sudo offhook/scripts/pf-blackhole.sh udp      # RTP only; SIP/TCP stays up
sudo offhook/scripts/pf-blackhole.sh tcp      # signalling only; RTP keeps flowing
```

It waits to be **armed** rather than blocking on launch, so you type the password up front and the
driver picks the moment to the second:

```sh
sudo offhook/scripts/pf-blackhole.sh all &   # password now, then it waits
# …start the observation run; wait for its [OBSERVE] CALL-UP marker…
touch /tmp/offhook-pf/arm                    # block
touch /tmp/offhook-pf/release                # restore (or let the hard cap do it)
```

Four things make it safe to run against your own machine: it restores on **every** exit path
(release, hard cap, Ctrl-C, SIGTERM); it keeps Apple's ruleset and appends a `quick` rule, so
restoring is a plain reload of `/etc/pf.conf`; it gives back the `pfctl -E` token, so pf ends
disabled if it started disabled; and startup clears any stale arm file, so a leftover can never
blackhole the network the instant you authenticate. Manual undo if a run is killed outright:
`sudo pfctl -f /etc/pf.conf && sudo pfctl -d`.

### 7.3 Things that are true and not obvious

- **pf sees the packets before they enter the VPN** — verified 2026-08-18 with a full-tunnel VPN
  holding the default route (`utun4`). This is not safe to assume, so the script probes after
  blocking and prints a loud `WARNING … THE BLOCK IS NOT WORKING` if the port is still reachable.
  A run that skipped that check could look like a stack finding when it is a plumbing failure.
- **`block drop` is a silent discard** — no RST, no ICMP unreachable. That is the whole point:
  anything sent back is a notification, and the question under test is what happens when there is
  none.
- **Both directions need a rule.** An inbound packet from the server has *us* as its destination,
  so a `to` rule alone leaves the peer able to talk to a socket we can no longer answer on.
- **Never let a driver assume it armed the lever.** The first attempt at the §2 run lost 20 minutes
  to a silent no-op: the script created its run directory as root (0755), the unprivileged driver's
  `touch …/arm` failed with `EACCES`, and the driver logged "ARMED" anyway — producing a trace that
  looked like a *stack* finding ("nothing fired!") when nothing had been blocked. The directory is
  now `1777` and the driver waits for pf's own `BLOCKED` line before proceeding. The general rule:
  a failure-injection harness must confirm the injection, because its success case and its
  plumbing-failure case look identical in the output.
- **Flexisip puts signalling and media on the same host** — `sip.linphone.org` →
  `176.31.149.179`, TCP 5060 for SIP and the MediaRelay's UDP ports on the same address — which is
  what makes the `udp` / `tcp` split work as a clean separation. Elsewhere, read the `c=` line of
  the SDP before assuming it.

### 7.4 Driving it from the test suite

`../Tests/CallLifecycleObservationTests.swift` holds the runs. They are instruments, not
assertions: each drives a real call into a chosen condition and prints a timestamped trace, so a
source-derived claim can be confirmed or refuted. Opt-in via `OFFHOOK_OBSERVE=1`, run alone:

```sh
TEST_RUNNER_OFFHOOK_OBSERVE=1 xcodebuild test-without-building -scheme Offhook \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.5' \
  -only-testing:OffhookTests/CallLifecycleObservationTests/test20_sessionTimerAndHoldResumeRecords
```

Markers are `[OBSERVE] HH:mm:ss.SSS …` (host-visible checkpoints a driver can wait on) and
`[EVENT] HH:mm:ss.SSS …` (every `PJSUAEvent`, traced by `EngineHarness`). Both carry a local wall
clock so the trace lines up with `date` on the Mac. The observation class registers its own
loopback pair, so it never needs the ordered suite's `test03` and never touches the slot ≥ 3
accounts that rate-limit (see the etiquette note in §6).

## 7.5 `PJSUA_MAX_ACC` was 8 in the build and 4 in Swift — the module map, not the config *(resolved)*

Found by the 2.17.0 re-baseline 2026-08-20; **resolved 2026-08-22**. `swift-pjsip` 0.2.0 raises
`PJSUA_MAX_ACC` to 8 (`scripts/config_site-ios.h:55-56`, `#undef` then `#define … 8`), the library
was built with 8 — and every Swift consumer compiled 4:

```
test03 -> PJSUAUsageError.accountTableFull(capacity: 4)   # after adding ids 0,1,2,3
```

### The cause

Not a stale cache, not the wrong artifact, and **not a second `config_site.h`** — the shipped
`Headers/` tree contains exactly one, and it says 8. The two code paths simply disagree, and it
reproduces in two commands with no Xcode and no Swift:

```sh
H=<xcframework>/ios-arm64-simulator/Headers
printf '#include "PJSIP-umbrella.h"\nMAXACC PJSUA_MAX_ACC\n' > /tmp/probe.c

xcrun --sdk iphonesimulator clang -E -I"$H" -x c /tmp/probe.c | grep MAXACC
# MAXACC 8   <- textual: agrees with libpjproject.a

xcrun --sdk iphonesimulator clang -fmodules -fmodules-cache-path=/tmp/mc \
      -I"$H" -E -x c /tmp/probe.c | grep MAXACC
# MAXACC 4   <- modular: what `import PJSIP` gets
```

`module PJSIP { umbrella header "PJSIP-umbrella.h" }` does not only name an umbrella header — it
also registers that header's **directory**, i.e. the whole `Headers/` tree, as an umbrella
*directory*. Clang then gives every header underneath it its own inferred submodule with its own
macro scope, and when two headers define the same macro the importer keeps the **first definer's**
value and silently drops the later override. No diagnostic — not even under `-Wambiguous-macro`.

`config_site.h` is exactly that shape: it includes `config_site_sample.h` (the `PJ_CONFIG_IPHONE`
preset, which sets the small values) and then overrides it. The preset is the first definer, so the
preset wins in the module.

It reduces to twelve lines with no PJSIP involved — a module whose umbrella includes `inner.h`,
which includes `sample.h` and redefines its macro; the importer gets `sample.h`'s value. Moving
those two headers *outside* the umbrella directory makes it correct again, which is the whole
mechanism in one experiment.

Two things this explains that the earlier evidence did not:

- **`PJSIP_MAX_PKT_LEN 16000` survived** while `PJSUA_MAX_ACC 8` did not, even though both live in
  the same file. `PJSIP_MAX_PKT_LEN` is a plain `#define` with no competing definition anywhere —
  one definer, nothing to lose to. It is not that the `#undef` broke it; any cross-header
  redefinition loses, `#undef` or not.
- **It was never iOS-versus-macOS.** Both shipped iOS slices, device and simulator, are equally
  affected. There is no macOS slice yet.

Sweeping all **1427** object-like macros in the shipped headers through both paths, exactly three
diverge — and all three are `config_site.h` overrides of a preset value:

| macro | `libpjproject.a` | what Swift imported |
|---|---|---|
| `PJSUA_MAX_ACC` | 8 | 4 |
| `PJSUA_MAX_CALLS` | 8 | 4 |
| `PJSUA_MAX_CONF_PORTS` | 254 | 12 |

### Which side was authoritative, and the part that had teeth

The **library** is authoritative: the binary really does have eight account slots. The account
guard was therefore merely conservative — it refused work the library would have accepted, which is
the harmless direction, exactly as §7.5 originally argued.

The direction is not luck, though, and it is not stable. The preset always wins over our override,
so *raising* a value reads back low (safe) while *lowering* one would read back high — the
corrupting direction, silently, for whichever constant someone edits next.

And the safe direction only held for the guard. `PJSUA_MAX_CONF_PORTS` also sizes two **public
structs**, and there the same divergence was already the corrupting kind:

| | `libpjproject.a` | what Swift imported |
|---|---|---|
| `sizeof(pjsua_conf_port_info)` | 1104 | 136 |
| `sizeof(pjsua_vid_conf_port_info)` | 2104 | 168 |

A Swift caller allocating one of those and handing it to `pjsua_conf_get_port_info()` gives the
library a 136-byte buffer to write 1104 bytes into. Latent only because `swift-pjsua` does not call
those functions yet — `PJSUA+Conference.swift` uses `pjsua_conf_connect` / `_disconnect` and
`pjsua_call_get_conf_port`, none of which touch the struct. D-CONF would have walked into it.

### The fix

Two lines in the generated module map (`swift-pjsip/scripts/build.sh` step 4):

```
module PJSIP [system] {
    umbrella header "PJSIP-umbrella.h"
    textual header "pj/config_site.h"
    textual header "pj/config_site_sample.h"
    export *
}
```

`textual header` keeps those two out of the submodule split, so every override lands in the same
macro scope as the definition it overrides. `scripts/verify-xcframework.sh` now expands every macro
both ways and asserts they match, so this class of bug fails the artifact rather than the test
suite.

**Shipped as `swift-pjsip` 0.2.1 (2026-08-22); `0.2.0` was deleted** — release, asset and tag — so
nothing can resolve the broken layout. It was a headers-only respin: only `module.modulemap` and
`pj/config_site.h` differ, and the merged archives' 428 members are byte-identical per slice.
Verified from the published artifact via a fresh `swift package resolve`: `PJSUA_MAX_ACC` and
`PJSUA_MAX_CALLS` compile as 8, `MemoryLayout<pjsua_conf_port_info>.size` is 1104, and
`SwiftPJSUA` typechecks with no errors.

0.2.1 also stops restating upstream's defaults. `PJSUA_MAX_ACC` and `PJSUA_MAX_CONF_PORTS` are now
a bare `#undef` of the `PJ_CONFIG_IPHONE` preset rather than `#undef` + a literal, so a future
upstream raise is inherited instead of pinned; the values are unchanged today (8 and 254). Only
`PJSUA_MAX_CALLS 8` and `PJSIP_MAX_PKT_LEN 16000` remain real overrides, because upstream's 4 and
~4000 are genuinely insufficient.

Nothing in `swift-pjsua` changed: `pjsua_acc_get_count() < UInt32(PJSUA_MAX_ACC)` became correct on
its own once the constant was right. **Still do not hardcode 8 there** — the guard should read the
constant the library was built with, and a guard that is *too high* indexes past the end of the
fixed `pjsua_var.acc[]` array.

`swift-pjsua` tracked `swift-pjsip` by `branch: "main"`, which picked this up on any resolve —
and is itself being retired for the same reason the bug existed: a branch edge re-resolves an
**ABI** with no version to name it. `swift-pjsua` PR #10 pins the range `"0.2.1" ..< "0.3.0"`,
accepting only PATCH releases, which by that repo's bump rule are the ones that cannot move the
binary. Either way **`test03` can use all eight slots of the secrets file** once the new binary
resolves.

## 8. Observed on the wire (per endpoint)

### 8.1 Session timer (RFC 4028) — `sip.linphone.org` / Flexisip

Observed 2026-08-18 in the pjsip log of a loopback call. **Negotiated.**

| | Value | Evidence |
|---|---|---|
| Offer (our INVITE) | `Supported: … timer`, `Session-Expires: 1800`, `Min-SE: 90` | TX `INVITE/cseq=12434` |
| Answer (200 OK) | `Require: timer`, `Session-Expires: 1800;refresher=uac` | RX `200/INVITE/cseq=12435` |
| Refresher | **UAC** — the caller | `refresher=uac` |
| First refresh | **~900 s** = `sess_expires / 2` | `sip_timer.c:517` |

**Read this carefully before relying on it.** The loopback pair means *both* user agents are our
own pjsua, so what is proven is that **Flexisip passes RFC 4028 through untouched** — it is a
proxy here, not a B2BUA, and it did not strip `timer` or rewrite the interval. It says nothing
about whether an arbitrary third-party peer would accept one. Against a peer that declines, the
"up to ~15 min" row in `../../swift-pjsua/docs/Call-Termination-Paths.md` §4 becomes **never**.

Consequence for that table: for this endpoint pair the row is real, and the number is **900 s** —
that is how long an idle call over a dead transport can sit before *anything* in the stack tries
to use the dialog again. **Observed end to end 2026-08-18** (§4.1 of that document): the refresh
went out as an **UPDATE**, not a re-INVITE, at 897 s — and since an UPDATE that changes nothing
triggers no media teardown, it produces no statistics record either. On a *healthy* call the
refresh completed in 320 ms and was invisible to the app; on a dead transport it took a further
83 s to become a `.disconnected` event.

`sip2sip.info` and `iptel.org` are unmeasured — they need a call to a third-party UA or an echo
service, not a loopback pair.

**Why the refresh was an `UPDATE` and not a re-INVITE — it is entirely peer-driven.** At the moment
the refresh timer fires, `timer_cb()` branches on one field, `inv->timer->use_update`
(`sip_timer.c:396`), and that field is computed once per timer (re)start as:

```c
/* sip_timer.c:488-490 */
inv->timer->use_update = (pjsip_dlg_remote_has_cap(inv->dlg, PJSIP_H_ALLOW, NULL,
                                                   &UPDATE) == PJSIP_DIALOG_CAP_SUPPORTED);
```

i.e. purely "did the peer's cached `Allow` header list `UPDATE`". If not, it falls back to a
re-INVITE (and forces SDP on it, since an INVITE always carries one). **There is no pjsua1 knob for
this** — an application can turn session timers on or off (`PJSIP_INV_SUPPORT_TIMER` /
`REQUIRE_TIMER`) but cannot choose the refresh method. So expect `UPDATE` against modern peers and
a re-INVITE against older ones, with no configuration involved either way. Note this is about the
**session timer**, not registration: a registration refresh is always a re-REGISTER, never an
UPDATE — UPDATE is a mid-dialog method and has no meaning outside an INVITE dialog.
(DeepWiki deep consult 2026-08-19, re-verified against the fork.)

### 8.2 Codec and media path

`iLBC/8000` mode=30, re-confirmed 2026-08-18 (matches the 2026-07-04 observation). Media relays
through Flexisip's MediaRelay rather than flowing peer-to-peer, so both directions traverse
`176.31.149.179` — convenient for §7, and the reason the measured RTT is dominated by the relay.

Our INVITE also offers a second m-line, `m=text` (T.140 real-time text), which the binary
negotiates and starts alongside audio. It is invisible to the statistics API: `on_stream_destroyed`
is an **audio** callback, so a text stream is torn down without producing a record, and
`CallMediaInfo.Kind` surfaces it as `unknown(3)`.

## Sources
- SIP2SIP status + test endpoints — <https://sip2sip.info/> · <https://sip2sip.info/help/> · <http://wiki.sip2sip.info/projects/sip2sip/wiki/SipTesting> · SylkServer conferencing <https://sylkserver.com/documentation/sip-conferencing/>
- iptel.org — <https://www.iptel.org/>
- Linphone free service / echo 4443 / Flexisip — <https://www.linphone.org/en/getting-started/> · <https://www.linphone.org/en/flexisip-sip-server/>
- Callcentric test number — <https://www.callcentric.com/faq/8>
- VoIP.ms echo 4443 — <https://wiki.voip.ms/article/Getting_Started>
- RFC 8599 — <https://www.rfc-editor.org/rfc/rfc8599.html>
- Flexisip push configuration (cert setup, `flexisip_pusher`) — <https://wiki.linphone.org/xwiki/wiki/public/view/Flexisip/Core%20servers/Configuration/Push%20notifications/> · REGISTER-parameter spec (`pn-provider`/`pn-prid`/`pn-param` table) — <https://wiki.linphone.org/xwiki/wiki/public/view/Flexisip/Core%20servers/Specifications/Push%20notifications/> · Docker — <https://github.com/BelledonneCommunications/flexisip/blob/master/docker/Dockerfile>
- OpenSIPS RFC 8599 — Part I <https://blog.opensips.org/2020/05/07/sip-push-notification-with-opensips-3-1-lts-rfc-8599-supportpart-i/> · Part II (cfg + `E_UL_CONTACT_REFRESH` sample) <https://blog.opensips.org/2020/06/03/sip-push-notification-with-opensips-3-1-lts-rfc-8599-supportpart-ii/> · registrar module PN params <https://opensips.org/docs/modules/3.2.x/registrar.html#rfc-8599-support>
- Kamailio: no native RFC 8599 (maintainer) — <https://github.com/kamailio/kamailio/issues/3508> · third-party push module <https://github.com/tvntsr/push>
- Apple: token-based APNs connection (`.p8`, all push types, dev+prod) — <https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns> · request headers (`apns-push-type: voip` ⇒ topic needs `.voip` suffix) — <https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns> · VoIP Services certificate — <https://developer.apple.com/help/account/certificates/create-voip-services-certificates/>
- Mizu MPUSH push gateway (self-hosted, RFC 8599) — <https://www.mizu-voip.com/Software/VoIPPushGateway.aspx>
- Public STUN list — <https://github.com/pradt2/always-online-stun>
