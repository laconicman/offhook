# Provisioning models — where SIP credentials and config come from

A map of the directions this app can take, written down because they are **mutually exclusive at
the implementation level** and we will have to branch. Current target is **Model A**; Model B is
on the roadmap and may warrant a separate app rather than a dual-nature one.

Companion docs: `Credentials.md` (Keychain, D-CRED-1..5),
`../../swift-pjsua/docs/Configuration-Design.md` (the `CredentialStore` seam that makes both models
pluggable without engine changes).

---

## Model A — secrets and config are effectively static *(current target)*

The user (or an operator, once) enters an AOR, registrar and password. They change rarely. The app
caches them locally and the engine reads them on demand.

- **VoIP push arrives → no additional queries.** Report to CallKit, await the INVITE, answer.
  This is the efficient, reliable path: no network round-trip on the latency-critical wake-up.
- `KeychainCredentialStore` (`Credentials.md` §4) is the whole implementation.
- Config lives in the `Codable` `AccountConfiguration`; secrets never travel with it.

**This is what most common SIP infrastructure looks like**, and it is what we optimise for now.

---

## Model B — secrets and config come from middleware *(roadmap)*

A backend owns the SIP identity: registrar, port, STUN, credentials, sometimes codec policy. It
can arrive three ways, and real deployments use all three:

1. **Silent push carrying config** — often delivered *alongside* the VoIP push, especially when
   the app was suspended or backgrounded.
2. **VoIP push carrying config** in its payload.
3. **UA queries the middleware** after receiving the VoIP push.

Design consequences that do not exist in Model A:

- **The wake-up path acquires a network dependency.** (3) in particular puts an HTTP round-trip
  in front of ringing. A push has seconds; the network may be unavailable. Whatever the model, the
  app must be able to fall back to cached config and ring anyway.
- **`CredentialStore.secret(for:)` becomes genuinely async-with-I/O**, which is what D-CRED-4 was
  written for: take the suspension **up front**, keep the `SecItem`/cache read in a synchronous
  tail. The seam already supports this — a `MiddlewareCredentialStore` is a new conformance, not
  an engine change.
- **Rotating secrets.** If the backend issues short-lived credentials, refresh proactively in the
  foreground with expiry tracking. At push time, use the cached secret even if nominally stale
  (servers commonly still accept it) and refresh in parallel. **Never block ringing on a token
  round-trip.**
- **Config, not just secrets, becomes remote** — registrar/port/STUN. `AccountConfiguration` being
  `Codable` was chosen partly for this: a middleware payload can decode straight into it.

### B.1 The push-vs-active-socket race — **researched, see the decision record**

**A VoIP push plus a re-REGISTER-with-new-config can arrive while an active PJSIP socket
connection already exists.** The pushed/reconfigured settings should take over — but *how*,
without dropping the call the push is announcing, was not designed:

- Does the new config apply before or after the in-flight INVITE is answered?
- `pjsua_acc_modify` + `set_registration(renew)` unregisters and re-registers when credentials
  change (verified) — doing that mid-call is exactly what we must not do blindly.
- Ordering between the silent push (config) and the VoIP push (call) is **not guaranteed**.
- Our engine serialises everything on one executor thread, which prevents interleaving but does
  **not** decide precedence.

> **Answered by [`Push-vs-Active-Socket.md`](./Push-vs-Active-Socket.md)** (2026-08-04). The short
> version: **check for config equality first, then defer.** A config change that arrives while a
> call is live is queued and applied when the *last* call ends; the only changes safe to apply
> mid-call are those pjsua emits no signalling for, and those are exactly the ones that do not help
> you answer. Credentials and push parameters both force an unregister-then-re-REGISTER, and that
> unregister genuinely removes the binding.
>
> That record also carries the `pjsua_acc_modify` field-by-field classification, the per-transport
> cost of holding vs. not holding a socket, the RFC 8599 `pn-purr` / `sip.pnsreg` recommendations,
> and the list of what remains unverified. Do not improvise this when Model B work starts.

---

## The reboot problem, precisely *(applies to both models)*

Raised as a concern, and it deserves accuracy rather than alarm: *a phone whose battery died and
was recharged must still receive calls.*

**What is certain:**

- SIP secrets stored per D-CRED-1 use `afterFirstUnlock`, so they are **unreadable between boot
  and the first unlock**.
- `kSecAttrAccessibleAlways` is **deprecated**, and Apple's documentation does *not* state any
  runtime remapping — whether it still functions is undocumented. Apple's own guidance is to use
  "an accessibility level that provides some user protection, such as
  `kSecAttrAccessibleAfterFirstUnlock`". **Do not build on it.**

**Why `UserDefaults` + encryption does not fix it.** `UserDefaults` is a plist in the app
container, subject to the same Data Protection machinery as any file.
`FileProtectionType.completeUntilFirstUserAuthentication` means a file "cannot be accessed until
after the device has booted" and the user authenticates once — i.e. *the same window as the
Keychain*. To beat that you would need `NSFileProtectionNone`, meaning **unencrypted at rest** —
strictly worse than the Keychain. And adding your own encryption is circular: the key must itself
be readable pre-first-unlock, so it ends up embedded in the binary (not security) or in the
Keychain (same window again). **There is no local-storage trick here** — the restriction is the
platform's, not the Keychain's.
*(To verify on device: whether the app container's default protection class is in fact
`completeUntilFirstUserAuthentication` — Apple's page for that class does not state it is the
default.)*

**Why the impact is narrower than it first appears.** Digest authentication challenges
*requests*, not *responses*:

| Operation | Needs the SIP secret? |
|---|---|
| REGISTER | **yes** |
| Outgoing INVITE (proxy-challenged) | **yes** |
| **Answering an inbound INVITE** (1xx/200) | **no** — a UAS does not authenticate its own responses |
| RTP / media | no |

And a VoIP push does **not** require the app to be registered at that instant — the server pushes
against a binding established by an *earlier* REGISTER. So after a reboot with no unlock:

- inbound calls can still arrive **and be answered**, for as long as the prior registration
  binding remains valid on the server;
- once that binding **expires** (typically 300–3600 s) the app cannot renew it, and the device
  goes dark for inbound calls until first unlock.

So the real failure mode is *"VoIP survives until the registration expires, then stops until the
phone is unlocked"* — not *"VoIP is dead after reboot"*.

**How RFC 8599 actually handles this — corrected 2026-08-19.** An earlier note here claimed the
RFC "assumes a PNS that can silently wake a UA on demand" and that its refresh model is
"unimplementable on iOS as written". **Both were wrong**, and the distinction matters because it
decides whether a lapsed binding is a problem at all. The RFC text contains **no** mention of
silent, non-alerting, or user-invisible pushes — an APNs VoIP push *does* wake the device; it is
simply not silent. The RFC has **two** push purposes, and only one of them is a problem on iOS:

| RFC 8599 mechanism | What it does | On iOS |
|---|---|---|
| **§5.2 SIP Request Push Bucket** (reactive, call-triggered) | A request arrives for the UA → the proxy **pushes, stores the request in a bucket with a Bucket Timer, and forwards it once the UA's binding-refresh REGISTER arrives**. Measured round-trip in the RFC's own note: **~2 s**. | ✅ **Fully available.** This push announces a real call, so reporting it to CallKit is exactly right. |
| **§5.5 Trigger Periodic Binding Refresh** (proactive) | With no call pending, the proxy pushes ≥120 s before expiry purely to make the UA re-REGISTER. | ❌ **Not available.** A PushKit push must result in a CallKit call, so a refresh-only push would have to ring the user; a silent push is best-effort and cannot be relied on. |

**The consequence is the reassuring one, and it matches the original instinct** that a
push-reachable mobile UA should be treated as reachable rather than expired: under §5.2 **the
binding does not need to be live when the call arrives.** The proxy pushes first and *waits* for
the refresh REGISTER before forwarding — so a client that never self-refreshes is still reachable,
provided the proxy implements the bucket. §4.1.4's "SHOULD only send a binding-refresh REGISTER
when it receives a push notification" is therefore not a trap; it is the intended steady state for
exactly our kind of client.

So the provider taxonomy is sharper than "understands mobile or doesn't":

- **Implements §5.2** → an iOS client that never self-refreshes works correctly. Nothing to fix.
- **Pushes only while a binding is live, no bucket** → structurally hostile to iOS, because the one
  mechanism that would keep the binding fresh (§5.5) is the one iOS forbids. This is the case worth
  detecting early, and **U5** in `Push-vs-Active-Socket.md` §9 is the capture that reveals it.

Related engine hazard, independent of any of this: **TD-24** — after suspension pjsip does not
notice the OS killed its socket until a send fails or a keep-alive timer fires, so "we are
registered" can be false on resume.

**Mitigations available today:** negotiate the longest registration expiry the provider allows;
re-register immediately on first unlock; treat "credential unavailable" as an expected,
recoverable state rather than a fatal error logged once. **Needs a device test** (not simulator):
whether iOS actually launches the app for a VoIP push before first unlock, and what PushKit
delivers in that window. Until measured, do not claim either way in user-facing docs.

---

## The branch point

Model B's async, network-dependent, order-sensitive wake-up path is a different app shape from
Model A's "read the cache and ring". Attempting both behind one set of switches risks the code
quality and clarity we have been protecting.

> **Direction:** keep Offhook firmly Model A. When Model B becomes real, first try a
> `MiddlewareCredentialStore` + a config-source abstraction *behind the existing seams* — if that
> starts requiring conditionals in the call/push lifecycle rather than just in the stores, that is
> the signal to fork a second app rather than deepen this one.

The engine (`swift-pjsua`) should stay model-agnostic in either case: it already takes config as a
value and secrets through a protocol, and it should never learn where either came from.
