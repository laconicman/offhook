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
(`../swift-pjsip/docs/Codec-Coverage.md`). Offhook defaults to option **A**.

> **Loopback pattern** (SIP-verified 2026-07-04; automated by `../Tests/`): register **two**
> accounts on the same registrar and call one from the other. The INVITE goes out to the real
> server and back — real signalling, auth, and RTP — with no dependency on an echo service
> staying alive. This is now the recommended "echo" for Flexisip.

## 1. Provider reference

### Free SIP services (real registrars, immediate)

| Service | Domain | Transports | SRTP | Test endpoints | Good for |
|---|---|---|---|---|---|
| **Linphone** | `sip.linphone.org` | UDP/TCP/TLS | ZRTP/SRTP | ~~`4443` (echo)~~ **404** as of 2026-07-04 — use the two-account loopback (§0) | register, audio, **video**, **server conference** (native acct), **push** (self-host, §3) |
| **sip2sip.info** | `sip2sip.info` | UDP/TCP/TLS | SRTP | `4444` mic, `3333` A/V, `echo@conference.sip2sip.info` (RTP+MSRP echo), `<room>@conference.sip2sip.info` (ad-hoc SylkServer conference) | register, echo, video, ICE/STUN, presence, **multi-party conference** (status page: operational, May 2026) |
| **iptel.org** | `iptel.org` | UDP/TCP | — | `echo@iptel.org`, `music@iptel.org` | register, echo (Kamailio home turf) |
| **antisip** | `sip.antisip.com` | UDP/TCP/TLS | SRTP | `thetestcall@sip.antisip.com` (callable without an account) | register, echo, RTP/media edge cases |
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
