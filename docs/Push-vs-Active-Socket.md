# Push vs. an already-active socket — precedence, deferral, and whether to hold a socket

> Decision record for the research pass asked for by
> [`Provisioning-Models.md`](./Provisioning-Models.md) §B.1. **Model-B-facing**: nothing here is to
> be built into Offhook now — the app stays Model A. This is the map for when we branch.
>
> Research 2026-08-04. Ground truth is the local `pjproject` fork at **`4896a5e6a`**
> (`2.17-98-g4896a5e6a`), read directly, plus RFC 8599 and RFC 5626 text. Every mechanical claim
> below carries a `file:line`; claims without one are marked **unverified** and collected in §9.

---

## 0. Verdict in one paragraph

**Defer by default, and check for equality before doing anything at all.** A config change that
arrives while a call is live should be *queued* and applied when the call ends; the only changes
worth applying mid-call are those pjsua does not consider registration-affecting, and those are
exactly the ones that do not help you answer. H1 is **confirmed at the pjsua level and unresolved
at the SBC level**: if the pushed config equals the live config there is genuinely nothing to do —
pjsua would emit no signalling either — so the cheap equality check removes most instances of the
race for free, and should be adopted regardless of how the SBC question lands. H2 is **rejected as
a policy but half-true as a consequence**: on iOS you do not get to decide whether to hold a
socket, because the OS closes it when it suspends you; what you must decide is *what you do on
wake*, and for TCP/TLS that is unavoidably "REGISTER first". The RFC 8599 alignment work
(`sip.pnsreg` omission made deliberate; `pn-purr` adopted) is cheap, entirely app-side, and worth
doing — see §7.

---

## 1. What we verified, and what pjsua actually does

### 1.1 `pjsua_acc_modify()` field classification

The single most load-bearing artifact of this pass. Every field that sets `unreg_first` forces a
**real unregister followed by a fresh REGISTER**; everything else is silent.
All line numbers are `pjsip/src/pjsua-lib/pjsua_acc.c` on `4896a5e6a`.

| Changed field | Effect | Line |
|---|---|---|
| `reg_hdr_list` | `unreg_first` | 1346–1348 |
| `proxy` / `proxy_cnt` (route-set CRC) | `unreg_first` | 1406–1410 |
| `id` (AOR) | `unreg_first` | 1417–1425 |
| `ipv6_sip_use` | `unreg_first` | 1429–1432 |
| `force_contact` | `unreg_first` | 1498–1502 |
| `reg_contact_params` | `unreg_first` | 1506–1510 |
| **`reg_contact_uri_params`** (← our push params live here) | `unreg_first` | 1514–1520 |
| `contact_params` | `unreg_first` | 1524–1528 |
| `contact_uri_params` | `unreg_first` | 1532–1536 |
| `transport_id` | `unreg_first` | 1550–1554 |
| `reg_use_proxy` | `unreg_first` | 1619–1622 |
| **`cred_info` (any change)** | `unreg_first` | 1628–1682 |
| `auth_pref.algorithm` | `unreg_first` | 1692–1696 |
| `reg_uri` | `unreg_first` | 1759–1763 |
| `use_rfc5626` / `rfc5626_instance_id` / `rfc5626_reg_id` | `unreg_first` | 1767–1786 |
| `publish_enabled` (enabling it) | re-REGISTER only (`update_reg`) | 1489–1494 |
| `ka_interval` (keep-alive not running) | re-REGISTER only | 1598–1601 |
| `reg_timeout` | re-REGISTER only; also `pjsip_regc_update_expires` in place | 1706–1709 |
| `sip_stun_use` | re-REGISTER only | 1832–1834 |
| `mwi_enabled` / `mwi_expires` | MWI resubscribe, no REGISTER | (`update_mwi`) |
| `use_srtp`, `call_hold_type`, `ice_cfg`/`turn_cfg`, `rtp_cfg`, `vid_*` | **silent — no signalling at all** | 1790–1872 |

**Consequence for us:** our push parameters (`PushConfiguration` → `reg_contact_uri_params`) and
our credentials are *both* in the `unreg_first` column. A Model-B middleware payload that changes
either one cannot be applied mid-call without removing the binding.

### 1.2 The `unreg_first` tail is harsher than it reads

```c
/* pjsua_acc.c:1874-1891 */
if (unreg_first) {
    if (acc->regc && !cfg->disable_reg_on_modify) {
        status = pjsua_acc_set_registration(acc->index, PJ_FALSE);  /* un-REGISTER */
        /* failure is logged and swallowed */
    }
    destroy_regc(acc, PJ_TRUE);          /* <- UNCONDITIONAL */
    ...
}
if (update_reg && !cfg->disable_reg_on_modify) { pjsua_acc_set_registration(index, PJ_TRUE); }
```

Three things follow, all verified:

1. **The un-REGISTER really reaches the registrar.** `destroy_regc` → `pjsip_regc_destroy2(force)`
   takes its *transaction-in-flight* branch: it sets `_delete_flag`, NULLs `regc->cb` and returns
   **without freeing anything** (`pjsip/src/pjsip-ua/sip_reg.c:203-207`). `tsx_callback` then
   *skips the application callback* but the transaction itself completes normally
   (`sip_reg.c:1380-1386`), and the real teardown happens later via
   `pjsip_regc_dec_ref` → `pjsip_regc_destroy` (`sip_reg.c:441-449`). So the binding is
   genuinely **removed server-side** — it is not left to expire, and our app never hears about it.
   Between that point and the 2xx of the new REGISTER the account is **unreachable for inbound
   calls**, and the push server has nothing to push against.
2. **`destroy_regc` wipes the account's identity state**, not just the regc: `acc->contact.slen = 0`,
   `acc->reg_mapped_addr.slen = 0`, `acc->rfc5626_status = OUTBOUND_UNKNOWN`, `rfc5626_flowtmr = 0`
   (`pjsua_acc.c:288-314`).
3. **`disable_reg_on_modify` does not do what its name suggests.** It suppresses the un-REGISTER
   and the re-REGISTER, but `destroy_regc()` still runs. The account therefore keeps a live binding
   on the server that it will *never refresh* — the refresh timer lives inside the regc and is
   cancelled by `pjsip_regc_destroy2`'s no-transaction-in-flight branch (`sip_reg.c:212-216`),
   which is exactly the branch taken here because suppressing the un-REGISTER means there is no
   transaction — until something calls `pjsua_acc_set_registration()` again.
   The documented purpose ("disable when immediate registration is not desirable, such as during IP
   address change", `pjsua.h:5055-5065`) is safe only because pjsua's own IP-change path always
   re-registers afterwards. **Used as "apply config without REGISTER traffic", it silently expires
   your registration.**

   > **Established 2026-08-17: this is deliberate, and only the docs are wrong.**
   > [#3910](https://github.com/pjsip/pjproject/pull/3910) guarded the whole block;
   > [#4509](https://github.com/pjsip/pjproject/pull/4509) (`ce81bb698`, labelled `type: bug`)
   > moved the guard inward on purpose — *"destroying old regc may still be needed so we can use
   > the updated registration related settings"*. The doc comment has not changed since #3910, in
   > either `pjsua.h` or `pjsua2/account.hpp`. **Encouragingly, #4509's rationale is our design:**
   > apply the settings, let the *next* registration carry them — precisely the pending-config slot
   > drained on last-call-end in §2. We just have to own the re-registration.
   > → upstream note [`acc-modify-disable-reg-still-destroys-regc`](../../swift-pjsua/Upstream/acc-modify-disable-reg-still-destroys-regc.md),
   > handoff `TASK-code-pjsip-disable-reg-on-modify.md`.

### 1.2a How much of the teardown is actually necessary *(added 2026-08-17)*

The `unreg_first` cost above is a **pjsua policy, not a SIP or `pjsip_regc` necessity.** Only five
pieces of regc state have no public setter and genuinely force a rebuild — **registrar/target URI,
From, To, Call-ID, CSeq** — plus header *removal*, because `pjsip_regc_add_headers()` is
additive-only (the `pj_list_init` reset is commented out, `sip_reg.c:544-545`). Everything else has
one: `pjsip_regc_update_contact`, `_update_expires`, `_set_route_set`, `_set_credentials`,
`_set_auth_sess`, `_set_prefs`, `_set_transport` (which does **not** update the Contact — pair it),
`_set_via_sent_by`.

Mapping that onto §1.1: the teardown is genuinely required only for **`id`**, **`reg_uri`**, and
**`reg_hdr_list`** when a header is removed. Credentials and all four contact-param fields — *our
two most likely Model-B updates* — map onto state that has a setter. This does not change any
decision in §2 (we go through pjsua-lib, so we pay pjsua's policy), but it does mean the cost is
contingent rather than fundamental, and it is the basis for the optional upstream enhancement in
`TASK-code-pjsip-disable-reg-on-modify.md` (Deliverable B). Tracked as `swift-pjsua` TD-25.

### 1.3 Established calls are *not* torn down by `acc_modify` — but new dialogs get a different Contact

- `pjsua_acc_modify()` contains no call-teardown path. The only places pjsua hangs calls up for
  account reasons are `drop_calls_on_reg_fail` after a failed re-registration attempt
  (`pjsua_acc.c:5202-5216`) and `ip_change_cfg.hangup_calls` (`pjsua_acc.c:5476-5510`). Neither is
  on the `acc_modify` path.
- An **established** dialog keeps the Contact captured at dialog creation: `dlg->local.contact` is
  set once in `pjsip_dlg_create_uac`/`_uas` (`sip_dialog.c:285, 460-470`) and cloned for forked
  dialogs (`:811`); there is no public setter. pjsua re-reads `acc->contact` only through
  `call_update_contact()`, which is **opt-in** via the `PJSUA_CALL_UPDATE_CONTACT` flag on
  hold/re-INVITE/UPDATE (`pjsua_call.c:823-845, 3485, 3640, 3788`). So a mid-call Contact change
  does not break in-dialog requests unless we ask for it.
- A **new** INVITE arriving while `acc->contact` is empty does *not* fail: `pjsua_call.c:2058-2066`
  falls back to `pjsua_acc_create_uas_contact()`, which synthesises a Contact from the receiving
  transport's local address (`pjsua_acc.c`, `pjsua_acc_create_uas_contact`). That Contact carries
  **none** of `contact_params` / `contact_uri_params` / `+sip.instance` / `reg-id`. It is answerable
  — and it is different from the one the registrar holds. This is the precise mechanism by which
  H1 can break against a Contact-sensitive SBC (§3).

### 1.4 There is no interlock between registration and inbound INVITEs

Both paths take the same global `PJSUA_LOCK()`, so they cannot interleave, but nothing gates an
inbound INVITE on registration state: `pjsua_call_on_incoming_call` performs account lookup and
answers, with no reference to `acc->regc` or any registration flag. **Serialisation is not
precedence** (as the task already said) — pjsua will happily accept a call while an un-REGISTER is
in flight, and equally happily hand the UAS dialog a synthesised Contact.

### 1.5 Two things that bit us in passing

- **`pjsua_acc_set_registration()` right after `pjsua_acc_modify()` returns `PJSIP_EBUSY`.**
  `pjsip_regc_send` refuses while `has_tsx` is set (`sip_reg.c:1565-1573`). `swift-pjsua`'s
  `reRegister` does exactly this (`Sources/SwiftPJSUA/PJSUA+Accounts.swift`, the `pjsua_acc_modify`
  → `pjsua_acc_set_registration(true)` tail) and `.throwIfFailed()`s the result — so a
  **successful** credential rotation would surface as a thrown error. Local bug; see §8 and TD-23.
  *(Static reading — whether `has_tsx` is still set by the time we call depends on transport speed,
  so this wants a runtime test.)*
- **`use_rfc5626` defaults to `PJ_TRUE`** (`pjsua.h:4630-4648`) and is *silently ignored on UDP*
  (`need_outbound` requires `;transport=tcp` or `;transport=tls` in the Contact,
  `pjsua_acc.c:2105-2122`). So on TCP/TLS we are already an RFC 5626 client whether we decided to
  be or not.

---

## 2. Q1 — Precedence: the decision table

Read `identical` as "the pushed `AccountConfiguration` compares equal to the live one, field by
field, after normalisation". Rows are evaluated top-down; the first match wins.

| # | Call state | Pushed config | Which fields | **Decision** | Rationale |
|---|---|---|---|---|---|
| 1 | any | **identical** | — | **Do nothing.** Do not call `acc_modify`. | Nothing to gain: `acc_modify` with an equal struct sets no flag and emits no SIP (§1.1). Skipping it also dodges the `PJSIP_EBUSY` tail (§1.5). **This is H1, and it is free.** |
| 2 | no call, not registering | differs | anything | Apply immediately. | Nothing to protect. |
| 3 | no call, REGISTER in flight | differs | anything | **Wait for the registration to settle, then apply.** | `pjsip_regc_send` returns `PJSIP_EBUSY` while a transaction is outstanding (§1.5); "apply now" would mean "fail now". |
| 4 | **INVITE in flight / call up** | differs | **only §1.1's silent column** (`use_srtp`, `call_hold_type`, ICE/TURN, `rtp_cfg`, video) | Apply immediately. | No signalling, no binding change, no Contact change. Note `rtp_cfg`/media changes still will not affect the *current* call's already-negotiated media. |
| 5 | **INVITE in flight / call up** | differs | `reg_timeout`, `sip_stun_use`, `publish_enabled`, `ka_interval` (`update_reg` only, no `unreg_first`) | **Defer.** | A bare re-REGISTER does not remove the binding, so it is *survivable* — but it consumes the regc for the duration and would make row 3 apply to anything queued behind it, for no benefit during a call. Cheap to defer; defer. |
| 6 | **INVITE in flight / call up** | differs | **any `unreg_first` field** — credentials, push params, AOR, registrar, transport, proxies | **Defer until the call ends.** | The un-REGISTER genuinely removes the binding (§1.2.1). Doing that while announcing/serving a call is the failure this whole document exists to prevent. |
| 7 | call up | differs | `unreg_first` fields **and** the app believes the new config is *required to answer* | **Still defer — the premise is almost always false.** | Answering an inbound INVITE is a UAS response: digest challenges *requests*, not responses, so no credential is needed to send 180/200 (`Provisioning-Models.md`, "the reboot problem" table). See §4. |
| 8 | any | differs | any | **Apply last-writer-wins, ordered by a monotonic sequence number in the payload — never by arrival order.** | RFC 8599 §4.1.3 explicitly warns the SIP request may reach the UA *before* the REGISTER response, and APNs gives no ordering between a silent and a VoIP push. |

**The rule the table encodes, stated once:** *equality first, then defer; apply only what pjsua
would not signal.*

Two supporting mechanics the implementation needs:

- **A pending-config slot, not a queue.** Model B config is a whole-value replacement, so one
  slot with last-writer-wins (by sequence) is correct and a queue is not — a queue would replay
  superseded configs. (DRY: the same `AccountConfiguration` value type, no parallel "delta" type.)
- **A drain point.** Apply the pending config on the *last* call ending, not on any call ending —
  row 6 must survive a second inbound call arriving during the first (this is exactly the case H2
  claims to reduce but cannot eliminate).

---

## 3. Q2 — Is deferral ever wrong?

Deferral is wrong only if the deferred config is what makes answering possible. Three candidate
mechanisms, and where each actually lands:

| Claimed reason the new config is needed to answer | Verdict |
|---|---|
| "We need the new credentials to authenticate" | **False for inbound.** A UAS does not authenticate its own responses. Credentials matter for REGISTER and for *outgoing* INVITE; neither is on the answer path. |
| "The INVITE will arrive at the new registrar/port, and we are not listening there" | **Real, but deferral is not the problem.** If we are not reachable at the new address we never receive the INVITE at all, so there is no call to defer *for*. This is the "cold" case (row 2), not the mid-call case. |
| "The SBC keys media/authorisation to the current registration flow, and the middleware moved us" | **Real, unresolved, and the actual open question** — see §4. Note that applying the config mid-call does not fix it either: the `unreg_first` sequence tears down the very flow the in-flight call is using. |

So: **deferral is not wrong in any case we could construct.** The residual risk is not "we deferred
and could not answer", it is "we answered over a flow the infrastructure had already invalidated" —
which is H1's risk, and applying the config would not have helped.

---

## 4. Q3 — H1: answering over the existing socket without re-REGISTER

**Where H1 is safe, on evidence:**

- **The pjsua layer imposes no requirement.** There is no registration gate on inbound INVITEs
  (§1.4). If the INVITE arrives, pjsua will answer it.
- **SIP itself imposes no requirement.** A UAS answers within the dialog; the 200 OK's Contact is
  the UA's own, and the ACK and subsequent in-dialog requests route by Route set + Contact, not by
  registration binding. RFC 3261 does not condition answering on a live binding.
- **Where the config is equal, the question is vacuous** (row 1) — this is the case that makes the
  equality check worth building on its own merits.

**Where H1 breaks, mechanically:**

1. **RFC 5626 flow identity.** If the registrar/edge proxy routed the INVITE to us over the
   registration flow (which is the entire point of outbound, and pjsua enables it by default on
   TCP/TLS — §1.5), then the flow *is* the reachability. Answering over it is fine; what is not
   fine is anything that drops it. RFC 5626 §4.2.2 makes the matching point from the other side:
   a UAC "SHOULD NOT tear down the corresponding flow" on a recoverable re-registration error.
2. **A Contact that does not match the binding.** If `acc->contact` was cleared (§1.2.2) the UAS
   dialog gets a synthesised Contact without our `contact_uri_params`, `+sip.instance` or `reg-id`
   (§1.3). An SBC that pins the dialog to the registered Contact — or that uses the Contact URI
   parameters for its own correlation — sees a Contact it does not recognise. **This, not the
   absence of a re-REGISTER, is the concrete breakage vector**, and it is one we create ourselves
   by reconfiguring at the wrong moment.
3. **Media/latching policy.** Some SBCs latch RTP to the source address seen during the *registered*
   flow, or authorise media by registration state. This is genuinely vendor-specific.

**What we could not settle.** Which SBCs actually invalidate an in-progress call when the binding
is refreshed or removed, and whether any of them require a re-REGISTER before a call may be
answered. We deliberately did not go looking for vendor blog posts; the honest position is that
this needs a lab, and §9 names the test.

**Recommendation.** Adopt H1 in the narrow, provable form — *equal config ⇒ no reconfiguration* —
and treat "answer over an existing socket after a config change" as forbidden by row 6 rather than
as a thing we need SBC evidence to permit. That way the unresolved SBC question stops being
load-bearing.

---

## 5. Q4 — H2: the cost of not holding a socket, per transport

**The framing needs correcting first.** On iOS, "hold a socket" is not a policy we get to set.
When the app suspends, the OS reclaims the socket; nothing in pjsip prevents it
(`pjsua_acc_on_tp_state_changed` reacts to `PJSIP_TP_STATE_DISCONNECTED` after the fact,
`pjsua_acc.c:5300-5360`). Even in the foreground the defaults are tight:
`PJSIP_TRANSPORT_IDLE_TIME` is **33 s** (`sip_config.h:675-676`) and a transport with zero
references starts that countdown; what actually keeps a TCP/TLS connection up is the transport-layer
double-CRLF keep-alive at **90 s** (`PJSIP_TCP_KEEP_ALIVE_INTERVAL` / `PJSIP_TLS_KEEP_ALIVE_INTERVAL`,
`sip_config.h:806-807, 868-869`), and timers do not fire while suspended.

So H2's real question is **what we must do on wake**:

| | **UDP** | **TCP / TLS** |
|---|---|---|
| Is there a "flow" to lose? | No. The registrar sends to the last-known Contact address. | Yes — and with `use_rfc5626` on (default) the registrar routes *by* that flow. |
| What keeps inbound reachability alive while suspended? | The **NAT binding**, sustained by `ka_interval` (default **15 s**, `pjsua_core.c:353`) raw-CRLF pings — which stop when the app is suspended. | Nothing. The connection is gone. |
| Can an INVITE arrive without a fresh REGISTER? | **Yes**, if the NAT binding survived. If it did not, the INVITE is dropped silently by the NAT and we never learn. | **No.** The registrar has no socket to write to. pjsip agrees: on disconnect it downgrades `rfc5626_status` `OUTBOUND_ACTIVE → OUTBOUND_WANTED`, releases the regc's transport and schedules re-registration (`pjsua_acc.c:5311-5355`). |
| Cost of *not* holding a socket | Low — you were not holding one. Cost is NAT-binding expiry, i.e. dark until the next REGISTER. | You pay a REGISTER round-trip in front of ringing on every push wake. |
| Cost of *trying* to hold one | Battery: 15 s UDP pings vs RFC 5626 §4.4.2's recommended 24–29 s STUN interval — pjsip's default is more aggressive than the RFC's, and it does not implement STUN keep-alive at all (raw CRLF only, §4.4.1). | Battery + the OS closes it anyway on suspend. |

**Conclusions.**

1. **H2 is not a lever on iOS.** Adopt the consequence, not the policy: assume the socket is gone
   on every push wake, and make "REGISTER, then answer" the normal path for TCP/TLS rather than an
   error path. Design the ring flow so the REGISTER round-trip is concurrent with CallKit reporting,
   never in front of it (this matches `Provisioning-Models.md`'s "never block ringing" rule).
2. **H2's own caveat stands and is decisive.** Even if we could avoid holding a socket, a second
   call arriving during the first re-creates the race. The precedence table (§2) is required
   either way, which is the real reason H2 is not an alternative to it.
3. **Transport choice is a real fork in this design.** UDP keeps inbound reachability without a
   REGISTER (at the cost of NAT-binding fragility and no outbound); TCP/TLS gives flow-based
   routing but makes a REGISTER mandatory on wake. If Model B ever lets middleware *change the
   transport*, note that `transport_id` is an `unreg_first` field (§1.1) — so it can never be
   applied mid-call.

---

## 6. Q6 — Failure modes to design against

| Failure mode | What actually happens | Design response |
|---|---|---|
| **Push arrives while a re-REGISTER is in flight** | No interlock (§1.4); the INVITE is processed. But `pjsua_acc_set_registration` would return `PJSIP_EBUSY` if we tried to touch registration too (§1.5). | Never issue registration operations from the push path. Report to CallKit and answer; let the in-flight REGISTER finish on its own. |
| **Config change arrives mid-INVITE** | Row 6 → deferred. If not deferred, `unreg_first` removes the binding while the INVITE is being answered. | The pending-config slot + drain-on-last-call-end (§2). |
| **Unregister-then-register races an inbound INVITE** | Binding is genuinely gone for the gap (§1.2.1); if the INVITE lands in the gap it is still answerable, but with a synthesised Contact (§1.3). | Row 6 makes the gap impossible while a call is up. For the no-call case, accept the gap but keep it short — do not interleave other work. |
| **Re-registration fails after a config change** | The account is left unregistered **and the config is not rolled back** (already documented at `Configuration-Design.md` D-CONFIG-4). Auto-retry only fires for 408/480/500/502/503/504/6xx (`pjsua_acc.c:3137-3148`). | Keep the previous known-good `AccountConfiguration` and re-apply it on a non-retryable failure. This is app-side; pjsua will not do it. |
| **`disable_reg_on_modify` used to "apply quietly"** | Silently expires the registration (§1.2.3). | Do not use it for this. If we ever need a truly signalling-free apply, the only safe fields are §1.1's silent column. |
| **439 (First Hop Lacks Outbound Support)** | ~~Defined (`sip_msg.h:506`) but never acted on~~ — **fixed upstream 2026-08 by our own PRs [#5154](https://github.com/pjsip/pjproject/pull/5154) (`77ad3feec`) and [#5168](https://github.com/pjsip/pjproject/pull/5168) (`716ef557d`)**: pjsua now retries registration without SIP outbound on 439, and a first-hop change clears the sticky rejection (`first_hop_changed` → `reset_outbound_rejection()` in `pjsua_acc_modify()`). | **Do not build the app-side mitigation this row used to prescribe.** Still latent until `swift-pjsip` ships a binary carrying both commits — `swift-pjsua` TD-22. Note: [`pjproject-5154`](../../swift-pjsua/Upstream/439-first-hop-lacks-outbound.md). |
| **Proxy demands more refresh lead time than our margin** | `sip.pnsreg` indicator is never parsed (TD-20); pjsua schedules purely from `Expires` − `reg_delay_before_refresh`. | §7. |

---

## 7. Q5 — RFC alignment: what to adopt

### 7.1 `sip.pnsreg` media feature tag — omit, deliberately, and write it down

RFC 8599 §8.5 (verified): the tag "indicates that the SIP UA ... **is able to send** binding-refresh
REGISTER requests ... without being awakened by push notifications." §4.1.4 makes it a **MUST**
insert *if* the UA can self-refresh. There is no "cannot" flag; omission is the signal.

A backgrounded iOS app cannot self-refresh on its own timer. **Omitting is correct.** Make it
explicit: `PushConfiguration` should carry a documented note (and, ideally, a validating
initializer) that `+sip.pnsreg` must not appear in `params`. Today we omit it by accident — TD-20
already says so; this pass confirms the RFC reading that makes it deliberate.

### 7.2 `sip.pnsreg` feature-capability indicator — the real gap

RFC 8599 §8.4 (verified): in a REGISTER 2xx it means the entity "expects to receive binding-refresh
REGISTER requests ... even if [it] does not request that a push notification be sent", and **its
value is the minimum seconds before expiry at which the UA MUST send one.**

Two independent consequences, both currently unhandled:

- **Present and larger than our margin ⇒ we under-refresh.** pjsua never parses it; it computes the
  refresh from the granted `Expires` and `reg_delay_before_refresh`, neither of which
  `AccountConfiguration` exposes (§8).
- **Absent ⇒ we over-refresh, in violation of a SHOULD.** §4.1.4: with no indicator "the UA SHOULD
  only send a binding-refresh REGISTER request when it receives a push notification". pjsua's
  timer-driven refresh does the opposite. Harmless for correctness, wasteful for battery, and it
  keeps a socket alive we said we did not want (§5).

Adoption is app-side parsing of the 2xx's `Feature-Caps` header — pjsua gives us the `rdata` in
`on_reg_state2`. Cost is small; the payoff is that our refresh margin stops being a guess.

> Note for whoever implements this: the RFC's §4.1.4 prose spells the indicator **`sip.pnsreq`**
> twice, while §8.4 and the IANA registrations (§14.3.3) spell it `sip.pnsreg`. Parse `sip.pnsreg`;
> the §4.1.4 spelling is evidently a typo. *(We did not check the errata list — §9.)*

### 7.3 `pn-purr` / `sip.pnspurr` — adopt, and it is cheap

RFC 8599 §6.1.1 (verified): if the UA is willing to receive push for mid-dialog requests it MUST put
`pn-purr` in the Contact URI of the initial request **or the 2xx to it**, with the value of the last
`sip.pnspurr` it received in a REGISTER response — and MUST NOT insert it if it never received one.
§6.2.3: the proxy then buckets a mid-dialog request addressed to us and pushes instead of failing.

This is squarely the shape of our race: *dialog up, app suspended, a re-INVITE/BYE/UPDATE arrives.*
Today that request times out and we look dead. The mechanism is:

1. Read `sip.pnspurr` from the REGISTER 2xx `Feature-Caps` (same parse as §7.2 — one parser, DRY).
2. Store it per account; it rotates, and §6.2.1 requires the proxy to keep old values alive for
   ongoing dialogs, so a stale value is safe but a wrong one is not.
3. Put `;pn-purr=<value>` in the Contact URI of outgoing INVITEs and of our 2xx answers — i.e.
   `contact_uri_params` scope, per-dialog.

**Blocker to note:** `contact_uri_params` is per-*account*, and `pn-purr` is per-*dialog*
(§6.1.1's NOTE). Setting it account-wide via `acc_modify` is both wrong-grained and an `unreg_first`
field (§1.1) — so it must go through `pjsua_msg_data`'s contact URI on the specific call, not
through account config. That is an engine ask (§8), not something the app can do today.

**Recommendation:** adopt §7.2 and §7.3 together when Model B starts, since they share the
`Feature-Caps` parser and neither is useful alone. Do not adopt §7.1 as work — adopt it as a
comment and a test.

### 7.4 RFC 5626 — already on, mostly implemented, two gaps

Enabled by default on TCP/TLS (§1.5). Verified present: `+sip.instance` and `reg-id` on the Contact
(`pjsua_acc.c:237-282, 2097-2189`), `Supported: outbound, path` (`:3423-3431`), `Require: outbound`
detection in the 2xx (`:2839-2868`), `Flow-Timer` parsed and given priority over `ka_interval`
(`:2740-2760, 2807`), disconnect → re-register (`:5311-5355`).

Gaps: **439 was not handled** — now fixed upstream by #5154/#5168, pending a `swift-pjsip` bump (§6) —
and UDP keep-alive is raw CRLF rather than
RFC 5626 §4.4.2's STUN Binding ("Clients MUST support STUN-based keep-alives") — pjsip implements
only §4.4.1, and its 15 s default is more aggressive than the RFC's 24–29 s. Neither changes the
precedence design; both are worth knowing before we tune battery.

---

## 8. What this asks of `swift-pjsua`

Engine-side, none of it Model-B-specific — all of it is "expose what pjsua already has":

1. **`AccountConfiguration: Equatable` must mean what row 1 needs.** It already conforms; confirm
   the comparison is total over everything a middleware payload can change, and that `push` is part
   of it. Add a test that a no-op re-apply emits no SIP.
2. **Fix the `PJSIP_EBUSY` tail in `reRegister`** (§1.5): after `pjsua_acc_modify` has itself
   re-registered, the trailing `pjsua_acc_set_registration(true)` is both redundant and an error
   source. Either drop it when `acc_modify` signalled, or tolerate `PJSIP_EBUSY`.
3. **Expose `reg_timeout` and `reg_delay_before_refresh`** on `AccountConfiguration` — the minimum
   fix TD-20 already named, and the prerequisite for §7.2.
4. **Per-call Contact URI parameters** (`pjsua_msg_data.contact_uri_params` on answer/INVITE) —
   the prerequisite for §7.3. Note this is a *new surface*, not a config field.
5. **Surface the REGISTER 2xx `rdata`** (or at least parsed `Feature-Caps`) through the registration
   state event, so §7.2/§7.3 can be app-side without reaching into C.
6. **Document the §1.1 table** where `reRegister` is documented — the "which fields cost a binding"
   question will be asked again.
7. *(added 2026-08-17)* **Bump `swift-pjsip` past `77ad3feec` + `716ef557d`** so the 439 fix is
   actually in the binary — until then TD-22 is discharged upstream but still live for us, and the
   §6 row is theoretical rather than fixed. This is the single highest-value item on this list,
   because it converts a "registration fails forever with an unrecognised status code" field
   failure into a non-event.

New tech-debt entries proposed: **TD-21** (`disable_reg_on_modify` regc destruction — engine must
never use it as a quiet-apply), **TD-22** (439 → outbound fallback; **discharged upstream 2026-08**,
awaiting the binary bump), **TD-23** (the `EBUSY` tail), **TD-25** (regc mutability, §1.2a).

---

## 9. What remains unverified — and the tests that would settle it

Listed because a well-argued "insufficient evidence" was an accepted outcome, and because two of
these are the load-bearing ones.

| # | Unverified claim | Why it is open | Test that settles it |
|---|---|---|---|
| U1 | **Which SBCs invalidate an in-progress call when the binding is removed or refreshed**, and whether any require a live registration before a call may be answered | Vendor-specific; we refused to source it from blog posts | Lab against ≥2 stacks (Kamailio+rtpengine as the permissive baseline; one commercial SBC as the strict one). Establish a call, then from a second process remove the binding. Does the call survive? Does media survive? |
| U2 | **Whether an SBC rejects a 200 OK whose Contact lacks the registered URI parameters** (the §1.3 synthesised-Contact case) | Same | Same rig: force `acc->contact` empty (call `acc_modify` with a changed `reg_contact_uri_params` immediately before answering) and compare the SBC's behaviour against the registered-Contact case |
| U3 | **Whether iOS delivers a silent (config) push at all while the app is suspended and, if so, with what ordering relative to the VoIP push** | Cannot be measured in Simulator | Device test: send both from a controlled sender with known ordering and timestamps; log arrival order across 50 wakes. This also settles whether row 8's sequence number is necessary or merely prudent |
| U4 | **Whether iOS launches the app for a VoIP push before first unlock**, and what PushKit delivers then | Inherited open question from `Provisioning-Models.md` — unchanged by this pass | Device test on a rebooted, un-unlocked phone |
| U5 | **Real-world `Expires` and `Flow-Timer` values** from the target infrastructure | We have no target registrar yet | Capture a REGISTER 2xx from the intended provider; read `Expires`, `Flow-Timer`, and whether `Feature-Caps` carries `sip.pnsreg` / `sip.pnspurr` at all. **If no operator sends these, §7.2/§7.3 drop to "nice to have"** |
| U6 | Whether the `sip.pnsreq`/`sip.pnsreg` spelling discrepancy in RFC 8599 §4.1.4 has a published erratum | We read the RFC text, not the errata list | Check the RFC Editor errata page for RFC 8599 |
| U7 | pjsua's behaviour when an INVITE arrives *between* the un-REGISTER and the new REGISTER, end to end | Read statically; not executed | Covered by the Phase-0 smoke rig once it exists (`SIP-Test-Infrastructure.md`) |

**U5 is the cheapest and it gates the most work** — one packet capture decides whether §7.2 and
§7.3 are worth building at all. Do it first.

---

## 10. Provenance

- **Source:** local `pjproject` fork `4896a5e6a` (`2.17-98-g4896a5e6a`), read directly. Line numbers
  are from that tree and will drift.
- **RFCs:** RFC 8599 (May 2019) §4.1.3, §4.1.4, §5.6, §6.1.1, §6.2.1, §6.2.3, §8.4, §8.5, §8.6, §8.7;
  RFC 5626 (Oct 2009) §4.2.1, §4.2.2, §4.4.1, §4.4.2, §4.5, §11.6. Both read as published text.
- **DeepWiki:** three deep-mode consults, one useful. The RFC 8599 thread follow-up
  ([`…_dbc6e482`](https://deepwiki.com/search/rfc-8599-support-in-pjsippjsua_dbc6e482-8331-4443-b78f-3c5c9a2045ab?mode=deep))
  answered the transport-lifetime and RFC 5626 questions well, and its substantive claims were
  independently re-verified against the fork above. Two cold asks
  ([`…_eb7c6079`](https://deepwiki.com/search/reconfiguring-an-account-while_eb7c6079-5aa2-4f3b-a397-fadd445f593a?mode=deep),
  [`…_30e67a94`](https://deepwiki.com/search/in-pjsuaaccmodify-on-the-unreg_30e67a94-ded5-4853-b0a6-b6aeb4e75e89?mode=deep))
  **aborted with "ran out of tool calls" and returned no answer** — the second despite being
  deliberately narrowed. Operational note for the next pass: **follow up inside an existing thread
  rather than asking cold**; the thread with accumulated context completed, both cold asks did not.
- **Related:** `../../swift-pjsua/docs/Tech-Debt.md` TD-20/21/22/23/25 ·
  `../../swift-pjsua/docs/Configuration-Design.md` D-CONFIG-4 ·
  `offhook/docs/Provisioning-Models.md` §B.1 · `offhook/docs/SIP-Test-Infrastructure.md` ·
  `VoIP/TASK-code-pjsip-disable-reg-on-modify.md`

### Revision 2026-08-17

Three substantive changes, each marked inline where it lands.

1. **The 439 gap is fixed upstream** — by our own PRs
   [#5154](https://github.com/pjsip/pjproject/pull/5154) (`77ad3feec`) and
   [#5168](https://github.com/pjsip/pjproject/pull/5168) (`716ef557d`). §6 and §7.4 updated; the
   app-side mitigation this document used to prescribe must **not** be built. Pending a
   `swift-pjsip` binary bump — §8 item 7, and now the highest-value item on that list.
2. **`disable_reg_on_modify` is deliberate, not inconsistent** —
   [#4509](https://github.com/pjsip/pjproject/pull/4509) moved the guard on purpose; only the doc
   comment is stale. §1.2 updated. The 08-04 upstream draft proposed reverting it, which would have
   been an own goal against a maintainer's own `type: bug` fix. The rule that came out of it:
   **run `git log -S"<symbol>" --all` on any flag before writing an issue about its behaviour.**
3. **New §1.2a** — most of `pjsip_regc` is mutable in place, so the `unreg_first` cost is a pjsua
   policy rather than a protocol necessity. Changes no decision in §2; opens an optional upstream
   enhancement (Deliverable B of the handoff) and `swift-pjsua` TD-25.

**DeepWiki, second data point on the same lesson.** A four-part question about the fix **aborted
again** on tool budget, and the engine itself asked for a narrower one. Re-asked as a single
question about `pjsip_regc` mutability inside the existing misuse-sweep thread
([`…_bb8d7a19`](https://deepwiki.com/search/misuse-sweep-for-that-same-cla_bb8d7a19-cc1b-44fb-bd24-32dd7d442b8e?mode=deep))
— **completed, and every claim independently verified against `sip_regc.h` / `sip_reg.c`.** The
rule is now firm: *one topic per deep ask, and follow up inside an existing thread.* Score so far
on `pjsip/pjproject`: 2 of 2 single-topic follow-ups completed, 0 of 3 multi-part asks.
