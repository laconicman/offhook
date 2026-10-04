# Own SIP server — which one, and why

**Status: research, 2026-10-04.** Builds on [SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md)
§3 (push mechanics, verified July 2026) and §5 (self-hosting); this note records the choice.

## 1. What Offhook needs from a server

1. **VoIP push to our own bundle** (RFC 8599 parameters in the Contact, APNs PushKit pushes).
   Public servers hold their own Apple credentials, so this alone requires running one.
2. **A registrar that recognises a reconnecting phone** by its instance ID
   ([Instance-ID](./Instance-ID.md)), so wake-ups do not leave stale bindings behind.
3. TLS, a lab setup on the Mac and a small public host, and a licence we can live with.

## 2. Candidates

| | Flexisip | OpenSIPS 3.1+ | Kamailio | Asterisk |
|---|---|---|---|---|
| Sends the APNs push itself | **yes** (HTTP/2) | no: raises `E_UL_CONTACT_REFRESH`; you write the sender (`rest_client`) | no | no |
| RFC 8599 signalling | reads `pn-provider`/`pn-prid`/`pn-param`; **no** `Feature-Caps: +sip.pns` | complete, incl. `Feature-Caps` and `pn_ct_match_params` | none; DIY in script (`tsilo`, `t_suspend`) | none |
| APNs auth | **certificate only**, one PEM per app and mode | whatever your sender does (`.p8` token) | yours | — |
| Holds the INVITE until the push re-registers the phone | `fork-late` | `lookup()` returns 2, `pn_refresh_timeout` | `tsilo`, bounded by the transaction timer | — |
| `+sip.instance` without `reg-id` | binding keyed on it | stored, not used for matching | binding matched on (instance, reg-id) | ignored |
| Minimal lab | registrar with in-memory DB, file or no auth; Redis optional | registrar + usrloc + event route | registrar + usrloc, push is all script | `res_pjsip` |
| Licence | AGPL-3.0-or-later (commercial licence sold separately) | GPL-2.0 | GPL-2.0 | GPL-2.0 |
| Runs as | Linux; Belledonne publishes packages and images (check the current source) | Linux packages; images maintained by the project | Linux packages; official image | Linux packages |

None of the four is in Homebrew (checked 2026-10-04); the lab runs Linux containers on the Mac.

## 3. Decision

**Flexisip first.** It is the only one that turns a REGISTER with push parameters into an APNs
VoIP push with nothing else to write, it parks the INVITE until the phone comes back, and it is the
registrar that keys bindings on `+sip.instance`, which is exactly the behaviour Offhook's instance
ID is for. It is also what our integration tests already register to (`sip.linphone.org`).

What it costs:
- **A certificate, not a key.** Flexisip reads a VoIP Services certificate per bundle and mode;
  there is no `.p8` token auth in its source. The certificate has to be exported and renewed.
- **RFC 8599 is not complete.** No `Feature-Caps: +sip.pns` in the 200, so the app must not wait
  for it before trusting push.
- **AGPL.** Fine for running it unmodified; offering a modified version over the network obliges
  us to offer its source.

**OpenSIPS second**, for when `.p8` auth or standard `Feature-Caps` matter, or when a registrar
sits in front of infrastructure we do not control (`mid_registrar`). Its RFC 8599 state machine
is done; the APNs request (one HTTP/2 POST with a JWT) is ours. The OpenSIPS tree ships a
reference config for it (`modules/registrar/test/opensips.cfg`).

**Kamailio and Asterisk** stay in the lab as measurement subjects: Kamailio because most
deployments run it and its instance matching differs (it compares `reg-id` too); Asterisk as the
control that ignores the instance ID, and as a PBX for feature tests.

## 4. Testing push without Apple

Flexisip can send every push as an HTTP request to a URL of our choice
(`module::PushNotification/external-push-uri` with `$type`, `$token`, `$app-id`, `$call-id`
placeholders). Pointed at a local sink, that verifies the whole server side (push trigger, INVITE
parking, fork on re-REGISTER, no push while the connection is alive) before any Apple credential
exists. `flexisip_pusher` then tests the server-to-APNs leg on its own.

## 5. Push parameters as a second device key

With push, the token also identifies a device: Flexisip removes an older contact with identical
push parameters, and OpenSIPS can match bindings on them (`pn_ct_match_params`). It is not a
replacement for the instance ID: the token changes when iOS rotates it and differs between
sandbox and production builds, while the instance ID does not.

## Sources

- DeepWiki: [Flexisip push](https://deepwiki.com/search/answer-from-source-on-current_0c585d42-0210-49a6-9145-87cc3c4f3a59?mode=deep),
  [OpenSIPS and Kamailio push](https://deepwiki.com/search/for-each-of-opensips-and-kamai_3acb493a-c2b0-4fd3-bed0-e134a0c873f2?mode=deep),
  [Flexisip registrar](https://deepwiki.com/search/answer-from-source-on-current_a2992c7a-23cf-4abd-9d43-e36dd472ef5d?mode=deep).
  Index pins were 5 to 8 months old; the Flexisip registrar behaviour and Kamailio's instance
  matching were re-checked against current source. DeepWiki's claim that Kamailio ships in
  Homebrew is wrong.
- [SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md) §3, §5 · [Instance-ID](./Instance-ID.md) ·
  [Push-vs-Active-Socket](./Push-vs-Active-Socket.md)
