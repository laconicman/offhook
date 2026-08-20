# Call statistics and call quality over time

> Decision record for the design pass asked for by
> [`Roadmap.md`](./Roadmap.md) (Later — product surface) and
> [`Prior-Art.md`](./Prior-Art.md) §1.3.8. **Nothing here is built yet** — this is the map the
> implementation follows, and it names an engine dependency that must land first (§10).
>
> Research 2026-08-17. Ground truth is the local `pjproject` fork at **`cb0544e0d`** (upstream
> master of the same day: `7e95d9f70`, `3ca540207`), read directly, plus ITU-T G.107, G.113
> and RFC 3611 text, plus one DeepWiki deep consult (§6.1). Every mechanical claim carries a
> `file:line`; claims without one are marked **unverified** and collected in §11.

---

## 0. Verdict in one paragraph

**Capture one immutable record per stream from `on_stream_destroyed`, store it raw in an
append-only file, and never show a MOS.** The capture point is not a compromise but the
strictly correct one: pjsua reads `pjmedia_stream_get_stat()` off that same pointer two
statements before it hands the pointer to us (`pjsua_aud.c:540` vs `:553-557`), and destroys
the stream sixteen lines later (`:573`) — the data is provably live, and the callback fires on
local hangup as well as remote (§2.2). Sampling buys one thing worth having, an in-call quality
indicator, and it should be scoped to "while a debug view is visible" rather than adopted as the
foundation (§3). Store raw, because the formula is exactly the part we are least sure of and the
volume is ~7 MB/year (§4). **A single quality scalar is not honest here and should not ship**:
G.107 itself says its estimates are "only made for transmission planning purposes and not for
actual customer opinion prediction", and of the E-model's inputs we can supply neither the
loudness ratings, nor a true one-way delay, nor a defensible `Bpl` — the G.711 value swings 4.3
→ 25.1 on a PLC setting we do not control (§5). On burst-vs-random loss, pjproject implements
RFC 3611 fully but behind **three** independent gates that are **all off**, and it never computes
R-factor or MOS at all — it initialises them to the RFC's "unavailable" sentinel and only relays
what a peer sends (§6). We therefore take the free half now: `pjmedia_jb_state.avg_burst` is
already inside `pjsua_stream_stat` and `swift-pjsua` is discarding it (§6.4).

---

## 1. What the engine can report — corrections and additions to the brief

The task's §1 is confirmed accurate on every point I re-checked, with the line numbers moved by
intervening commits. Four things it did not know are load-bearing.

### 1.1 Confirmations (re-verified on `cb0544e0d`)

| Claim in the brief | Status | Citation on `cb0544e0d` |
|---|---|---|
| `pj_math_stat` keeps `n/min/max/last/mean` continuously | ✅ | `pjlib/include/pj/math.h:67-82` |
| …and carries `m2_` (variance × n) that we discard | ✅ | `math.h:81`; `CallStreamStatistics.swift` `Distribution.init(usec:)` |
| Media is destroyed before `on_call_state` on disconnect | ✅ | `pjsua_call.c:5458-5464` (deinit) vs `:5486-5487` (callback) |
| `on_stream_destroyed` hands you the `pjmedia_stream *` | ✅ | `pjsua.h:1580-1582` |
| It is not wired in `swift-pjsua` | ✅ | `PJSUACallbacks.swift:73-76` installs four callbacks; this is not one |

### 1.2 We are discarding more than `m2_` — the jitter buffer is right there

`pjsua_stream_stat` has **two** members, not one (`pjsua.h:672-680`):

```c
typedef struct pjsua_stream_stat {
    pjmedia_rtcp_stat   rtcp;   /* <- all swift-pjsua reads */
    pjmedia_jb_state    jbuf;   /* <- dropped on the floor */
} pjsua_stream_stat;
```

`PJSUA+Statistics.swift` fills `pjsua_stream_stat`, reads `stat.rtcp.tx/rx/rtt`, and never touches
`stat.jbuf`. That struct (`pjmedia/include/pjmedia/jbuf.h:98-121`) carries `avg_delay`,
`min_delay`, `max_delay`, **`dev_delay`** (standard deviation of delay, in ms), **`avg_burst`**
(average burst, in frames), `lost`, `discard` and `empty`.

This matters more than the `m2_` point the brief raises, and it changes the answer to Q5: **we
already have a burst measure and a delay standard deviation, at zero cost, in a struct we are
already populating.** They are not RFC 3611 burst density, but `avg_burst > 1` is exactly the
"loss arrived in clumps" signal the brief says we lack.

### 1.3 `on_stream_destroyed` fires with `PJSUA_LOCK` **held** — stricter than any callback we run today

The chain is `pjsua_media_channel_deinit()` (`pjsua_media.c:3601`) → `stop_media_session()`
(`:3628`) → `pjsua_aud_stop_stream()` (`:3471`, defined `pjsua_aud.c:509`) → the callback
(`pjsua_aud.c:553-557`). On the disconnect path the caller wraps the whole thing:

```c
/* pjsua_call.c:5458-5464 */
if (inv->state == PJSIP_INV_STATE_DISCONNECTED) {
    PJSUA_LOCK();
    if (!call->hanging_up)
        pjsua_media_channel_deinit(call->index);
    PJSUA_UNLOCK();
}
/* :5467 — "Release locks before calling callbacks, to avoid deadlock." */
```

Compare `on_call_state`, which pjsua deliberately defers until *after* `PJSUA_RELEASE_LOCK()`
(`:5467-5468`, `:5486-5487`). `swift-pjsua`'s threading table (`PJSUACallbacks.swift:29-33`,
sourced from `docs/Threading-Validation.md`) lists callbacks held under `PJSUA_LOCK` and callbacks
held under a dialog/tsx group lock. **`on_stream_destroyed` belongs in the first group and is not
in the table.** The existing G2 discipline — callbacks hold no actor reference, read POD out of C
structs, and yield a `Sendable` value — is not merely sufficient here, it is mandatory, and §10
asks for the table to record why.

### 1.4 pjsua already computes and then throws away a full end-of-call report

`pjsua_media_channel_deinit()` calls `log_call_dump(call_id)` before stopping media, gated on
`pj_log_get_level() >= 3` (`pjsua_media.c:3624-3625`). That dump includes the RTCP XR block when
XR is compiled in (`pjsua_dump.c:504`). So the end-of-call statistics story already exists
upstream — as a string, at a log level, discarded. This is a useful sanity check on the design
rather than an alternative to it: it confirms the capture *moment* is the conventional one.

---

## 2. Q1 — The unit of record

**Recommendation: one immutable `StreamQualityRecord` per stream, captured once at
`on_stream_destroyed`, plus one `CallRecord` per call. Two types, joined by call id — not one
type, and not one record per call.**

### 2.1 What the record contains

```
StreamQualityRecord
  callID, streamIndex, sequence     // sequence disambiguates re-INVITE churn on the same index
  capturedAt, streamDuration
  kind (.audio/.video), codec (name, clockRate, channels, payloadType)
  transmit, receive: { packets, bytes, discarded, lost, reordered, duplicated,
                       jitter: Distribution }
  roundTrip: Distribution
  jitterBuffer: { avgDelayMs, minDelayMs, maxDelayMs, devDelayMs,
                  avgBurstFrames, lost, discard, empty }   // §1.2 — new
  Distribution = { samples, minMs, maxMs, lastMs, meanMs, sdMs }  // sdMs from m2_ — new
```

`sdMs` comes from **pjlib's own helper**, `pj_math_stat_get_stddev()` (`pjlib/include/pj/math.h:177-181`)
— not a hand-rolled `sqrt(m2_/(n−1))`. It is a public inline, it already guards `n == 0`, and using
it keeps our deviation on the same convention (population, divide by `n`) as everything else pjsip
reports. It returns `unsigned` microseconds via integer `pj_isqrt`, so sub-microsecond precision is
lost — irrelevant once converted to ms.

The brief is right that deviation is the more diagnostic number: 20 ms mean with 2 ms deviation is a
fine call, 20 ms mean with 40 ms deviation is not, and today those two are indistinguishable in our
data.

`CallRecord` holds the one-shot facts — direction, account, remote party (see §9 on how),
`createdAt`, the four OH-9 setup intervals, final SIP status, whether media ever flowed, and the
network interface type at media start.

### 2.2 Why `on_stream_destroyed`, and why it is genuinely safe

The strongest evidence is that **pjsua does the same read, on the same pointer, immediately
before handing it to us**:

```c
/* pjsua_aud.c:509  pjsua_aud_stop_stream() */
pjmedia_event_unsubscribe(NULL, &call_media_on_event, call_med, strm);   /* :522 */
pjmedia_stream_send_rtcp_bye(strm);                                      /* :524 */
/* conference port removed                                                  :526-531 */
if (pjmedia_stream_get_stat(strm, &stat) == PJ_SUCCESS) { ... }          /* :540  <-- */
if (!call_med->call->hanging_up && ...cb.on_stream_destroyed)            /* :553 */
    ...cb.on_stream_destroyed(call_med->call->index, strm, call_med->idx); /* :556 */
pjmedia_stream_destroy(strm);                                            /* :573 */
```

pjsua reads the statistics at `:540` to preserve RTP sequence/timestamp continuity, checks the
status, and uses the result. The stream is fully constructed. `pjmedia_stream_destroy()` is 33
lines later. There is no ambiguity to design around.

Two consequences worth stating explicitly:

- **RTCP BYE is sent at `:524`, before our callback.** Counters are final; nothing further will
  arrive. This is the natural end of the record, not a snapshot of one.
- **The `hanging_up` guard at `:553` does not lose local hangups.** This looked like a hole and is
  not one, because of ordering in `pjsua_call_hangup()`:

  ```c
  /* pjsua_call.c:3410-3414 */
  } else {
      pjsua_media_channel_deinit(call_id);   /* fires on_stream_destroyed — hanging_up still FALSE */
      call->hanging_up = PJ_TRUE;            /* set only afterwards */
      pjsua_check_snd_dev_idle();
  }
  ```

  The flag is set *after* the deinit that fires the callback (`hanging_up` declared
  `pjsua_internal.h:215`). The one branch that sets it first (`:3395-3409`, `delay_hangup`, taken
  when media transport creation has not completed) has no stream to report on — `inv->state` is
  `PJSIP_INV_STATE_NULL`. **No confirmed call loses its record**, but this is a behaviour we
  depend on that upstream did not promise us, so §10 asks for a regression assertion rather than
  trust.

### 2.3 Multi-stream calls

A call keys `CallRecord`; streams key `StreamQualityRecord`. Summarising a multi-stream call for
a list row uses **worst-of, not mean-of**, across its audio streams: max loss ratio, max jitter
mean, max RTT mean. Averaging a good stream with a bad one produces a number describing neither,
and the question the feature exists to answer is "was this call bad", to which one bad stream is
already yes. Video streams are recorded but excluded from the audio summary — a dropped video
frame and a dropped voice packet are not commensurable.

**Confirmed from source 2026-08-17.** The re-INVITE assumption below is not a guess:
`apply_med_update()` tears the stream down only when `is_media_changed()` finds a real change, and
**direction is one of the compared fields** (`pjsua_media.c:3993-3995`, `:4398-4408`). So hold and
resume each destroy and rebuild the stream — one hold/resume cycle yields **three** records — while
a re-INVITE that changes nothing (session-timer refresh, an IP-change re-INVITE with identical SDP)
correctly produces none. Full trace:
`../../swift-pjsua/docs/Call-Termination-Paths.md` §1.1. Two things follow: `sequence` is load-bearing
for ordering them, and a held stream's `receive.packets == 0` record is **expected**, so any
call-level aggregate must weight its streams by duration rather than averaging them flat.

**Rejected: one record per call.** Re-INVITE churn (hold/resume, codec renegotiation, ICE restart)
destroys and recreates streams within a single call; collapsing them discards precisely the
transition where quality usually changed.

---

### 2.4 Coverage across termination paths — and the case that inverts the priority

A follow-up pass mapped every way a call can end
(`../../swift-pjsua/docs/Call-Termination-Paths.md`, 2026-08-17). Two results change this design.

**Good news: capture is complete for terminations.** Local hangup, remote BYE, `hangupAll()`,
`pjsua_destroy()` (both flag variants), transaction timeout, IP-change hangup, IP-change re-INVITE
failure, session-timer expiry — **all** deliver `on_stream_destroyed` and therefore a record. The
`hanging_up` guard turns out to be benign for the reason given in §2.2. There is no
"we only get statistics for polite hangups" problem.

**The problem is the opposite of the one anticipated.** The interrupted calls do not fail to produce
a record because the teardown is abnormal — they fail to produce one because **there is no teardown
at all**. A call whose media transport errors, whose ICE keep-alive fails, or whose TCP/TLS socket
dies while the dialog is idle is *not terminated by pjsip*: it stays `CONFIRMED`, the stream stays
alive, and `on_stream_destroyed` is not due to fire until the call eventually ends by some other
route — typically a user who gave up. That record, when it finally arrives, describes a call that
spent its last ten minutes dead, and its cumulative counters make that nearly unreadable: the mean
jitter and mean RTT are diluted by all the silence, and `packets` simply stops rising with nothing to
mark when.

So the working assumption that *"maybe we can live without a stat for an interrupted call"* should be
inverted. **These are the calls the feature exists for.** A record for a call that ended cleanly
confirms a good call; a record for a call that died tells you why — if it carries the one thing an
end-of-call snapshot cannot supply on its own, which is *when the packets stopped*.

**Consequence for Q2 (§3).** This retires the "resilience" argument as I framed it there and replaces
it with a stronger one. In-call sampling was scoped as debug-only, on the grounds that `maxMs`
already captures the worst moment. That reasoning holds for quality, and fails for **liveness**:
polling `rx.pkt` on the active call is the only mechanism available anywhere in this stack for
noticing that media stopped — pjmedia has no RTP inactivity detector, and
`PJMEDIA_STREAM_ENABLE_KA` only *transmits* keep-alives
(`../../swift-pjsip/docs/Build-Time-Feature-Gates.md`). The same 2 s poll therefore serves three
purposes at once: the live quality indicator, the intra-call timeline, and death detection.

That is enough to promote it from "opt-in while a debug view is visible" to **on whenever a call is
confirmed** — it is one non-blocking counter read per interval, and it is the difference between an
app that notices a dead call and one that does not. The record gains two fields:

```
CallRecord
  …
  lastRxPacketAt          // when rx.pkt last increased — the "when did it stop" the snapshot lacks
  terminationClass        // .signalled(status) | .mediaStalled(silentFor:) | .transportError | .unknown
```

`terminationClass` is the field that makes the whole store queryable for the question that matters:
*what fraction of our calls died rather than ended, and what did the network look like when they
did?* App-side work is tracked as [OH-10](./Tech-Debt.md).

## 3. Q2 — What is lost by not sampling

The brief is right to insist these are four features, not one decision. Evaluated separately:

| Want | Needs polling? | Verdict |
|---|---|---|
| *When* within the call it degraded | Yes | **Opt-in debug only** |
| Correlation with events (network change, hold, re-INVITE) | **No** | **Take it — free** |
| Live in-call quality indicator | Yes | **Earns it, scoped** |
| Resilience if the callback never fires | No — polling is the wrong fix | **Fix at the source** |

**Correlation is free and should be taken first.** Re-INVITE churn already produces a new stream
and therefore a new record (§2.3), so hold/resume and codec changes are visible as record
boundaries without any cadence. Network-path changes need only a timestamped `NWPathMonitor`
event log — already required for the macOS lifecycle work ([Roadmap](./Roadmap.md), Later — macOS)
— joined against record intervals at query time. Polling adds nothing here.

**The live indicator earns polling, and only it.** A user in a bad call wants to know now, and no
end-of-call record can tell them. Scope: only while a view showing it is visible, only the active
call, **2 s** rather than 1 Hz. At 2 s that is 0.5 actor hops/second for one call — against a
`PJSUA_LOCK`-serialised engine also carrying signalling, this is negligible, and it stops entirely
when the view disappears. `swift-pjsua` TD-3's `.bufferingNewest(64)` stream must not carry it:
samples are disposable, so they belong on their own channel where dropping the newest is correct,
whereas records are not disposable at all (§10).

**Intra-call timeline is the same machinery with a longer retention**, so it costs nothing extra
to enable in the debug view — but it must not become the foundation. `maxMs` in the end-of-call
record already answers "did this call have a bad moment"; the timeline only answers "when", which
is a debugging question, not a product one.

**The resilience argument does not survive contact.** If the process is killed mid-call the poll
loop dies with it, so polling does not save the record — it only makes the loss partial instead of
total, and a half-written record of unknown truncation is worse evidence than none. The real
failure modes are the `delay_hangup` branch (§2.2 — no stream existed) and app termination, and
the fix for the latter is to write the record synchronously on capture (§7), not to poll.

**Rejected: always-on sampling as the foundation.** The brief's own §1 analysis is correct —
`pj_math_stat` aggregates continuously, so one read captures the whole call including its worst
moment. Anything built on a cadence pays a permanent cost for a debugging convenience.

---

## 4. Q3 — Raw or derived

**Recommendation: store raw counters. Compute every derived quantity at query time.**

The brief calls this the decision most expensive to reverse, and that is the argument for raw
rather than against it: **the formula is the single most uncertain thing in this document.** §5
concludes we should not ship a MOS at all today; if that changes, or if we later enable RTCP XR
and gain a real `BurstR`, a stored-derived design silently keeps every historical record on the
old formula and makes the two eras incomparable. Storing raw makes a formula change a code change.

The usual counter-argument is query cost, and here it does not apply. Sizing it: a heavy user
makes ~50 calls/day; at 1–2 streams each that is ~100 records/day, ~36 500/year. At ~200 bytes of
JSON per record that is **~7 MB/year** — small enough to hold entirely in memory and reduce over
in microseconds. There is no query cost to trade against.

Two derived values *are* stored, because they are not derivable later: `streamDuration` (the
denominator for every rate, and `pj_math_stat` does not carry a clock), and the network interface
type at media start (a fact about the moment, unrecoverable afterwards).

**Rejected: compute at capture.** It buys cheap reads we do not need and freezes the one thing we
most expect to revise.

---

## 5. Q4 — Is a single quality scalar honest?

**Verdict: no. Do not ship a MOS or an R-factor as a headline number.** Show the components. If
the debug view wants an experimental scalar, it must be labelled as an estimate and print every
assumption beside it.

This is not conservatism; it is what the standard says about itself.

### 5.1 The standard disclaims exactly our use case

ITU-T G.107 §1 (Scope): the E-model produces estimates that are

> "only made for transmission planning purposes and not for actual customer opinion prediction
> (for which there is no agreed-upon model recommended by the ITU-T)."

Annex A adds that the model "has not been fully verified by field surveys or laboratory tests for
the very large number of possible combinations of input parameters." The E-model is a tool for
deciding whether a *network design* will satisfy users in aggregate. Offhook would be using it to
label *one call that already happened* — the use the ITU explicitly excludes.

### 5.2 The arithmetic, and where our inputs run out

`R = Ro − Is − Id − Ie-eff + A`, with `Ro − Is = 93.2` for default narrowband conditions, and

`Ie-eff = Ie + (95 − Ie) × Ppl / ((Ppl / BurstR) + Bpl)`

mapped to MOS by `MOS = 1 + 0.035R + R(R − 60)(100 − R) × 7×10⁻⁶` for `0 < R < 100` (1 below, 4.5
above). *(I checked this mapping numerically against G.107's own published table before relying on
it: R=90→4.339, 80→4.024, 70→3.597, 50→2.575, against the tabulated 4.34/4.02/3.60/2.58.)*

Term by term, against what §1 can actually supply:

| Term | Needs | Can we supply it? |
|---|---|---|
| `Ro`, `Is` | SLR/RLR loudness ratings, room and circuit noise | **No.** We use the 93.2 default, i.e. we assume the handset and the room. Fine as a constant, but it means the number never reflects the acoustic half of quality at all. |
| `Id` | **One-way** delay (G.107 Table 2: `Ta`, 0–500 ms) | **Only badly.** We have RTT from RTCP. `RTT/2` assumes a symmetric path; asymmetric routing is common and is precisely the condition that degrades calls. We would also have to add jitter-buffer and codec delay — the buffer part is available (`jb_state.avg_delay`, §1.2), the codec part is a per-codec constant we do not hold. |
| `Ie`, `Bpl` | G.113 Appendix I, per codec **and PLC state** | **Not defensibly.** G.711 is `Ie = 0, Bpl = 4.3` **without** PLC and `Bpl = 25.1` **with** it. That is a ~6× swing in the loss-robustness denominator, driven by a build-time setting in `swift-pjsip` that we do not currently record — and the resulting MOS difference at a few percent loss is larger than most of the quality differences we would be trying to show. |
| `Ppl` | Loss %, ideally including jitter-buffer discards | **Yes**, and better than most: `rtcp.rx.loss` plus `jbuf.discard` gives an effective loss closer to what was actually not played. |
| `BurstR` | Burst ratio, G.107 Table 2 range **1–2** | **No** — this is the RFC 3611 gap (§6). `avg_burst` (§1.2) is a proxy in frames, not the ratio the formula wants. |
| `A` | Advantage factor | **It is not a measurement.** G.107's provisional table: 0 wirebound, 5 cellular in-building, 10 mobile/vehicle, 20 hard-to-reach. Choosing between 0 and 10 for a call on Wi-Fi vs LTE moves R by 10 points — roughly a full MOS point — on the basis of a judgement about user expectation, not anything observed. |

G.107 Table 2 also bounds `Ppl` at 0–20% and `BurstR` at 1–2. A call with 35% loss is **outside
the model's defined domain** — and that is exactly the call a quality feature most needs to
describe.

### 5.3 What to show instead

The components, with the thresholds that make them readable, and a three-state badge derived from
them rather than from a formula:

- receive loss % (network loss + jitter-buffer discards, shown as one number and separable)
- jitter mean **and** standard deviation (§2.1) — the pair, never the mean alone
- RTT mean and max, labelled as round-trip, never silently halved
- `avg_burst` frames — "loss arrived in clumps of ~N"

A badge (good / degraded / bad) computed from thresholds on those components is honest in a way a
MOS is not: it makes no claim to be an opinion score, its inputs are visible, and changing a
threshold is obviously a product decision rather than a silent change to a number users believe is
standardised.

**Rejected: shipping MOS.** It is the single most requested VoIP number, and VoIPmonitor and every
carrier dashboard display one — from the E-model, as we would. The difference is population size:
a carrier's MOS is averaged over millions of calls where the unsupplied terms are genuinely
constant and the errors wash out, which is the aggregate use G.107 sanctions. On one device, one
call, it is a precise-looking number assembled mostly from defaults.

**Also rejected: no scalar at all.** The debug view may carry an `R̂` with its assumption set
printed inline — it is useful for A/B-ing a config change against the same endpoint. It does not
go in the product UI and it is never called MOS.

---

## 6. Q5 — Burst vs random loss, and RTCP XR

**Answer: pjproject implements RFC 3611 in full, including the Markov burst/gap model — but
behind three independent gates that are all off, and it never computes R-factor or MOS at all.
Recommendation: take the free approximation now (§6.4); defer XR until something concrete needs
it; if we ever enable it, no upstream API is required.**

### 6.1 Provenance

DeepWiki deep-mode consult on `pjsip/pjproject`, 2026-08-17 —
<https://deepwiki.com/search/on-current-master-how-does-a-p_c80688f4-93fd-4689-bd1e-9b69f823c375?mode=deep>
(logged in `../../deepwiki-log.md`; full capture in `../../deepwiki-consults/`). It was right about
the struct layout, right that `pjsua_stream_stat` has no XR member, right that `pjsua_call_dump()`
is the only pjsua1 path and that it is text-only, and it correctly located the RFC 3611 A.4 Markov
computation. It was **wrong twice** — it claimed XR "is enabled by default in current master" and
that "there is no separate runtime toggle exposed through pjsua1" — and it **missed** the
`on_stream_destroyed` path that makes its proposed upstream API unnecessary for us. Every claim
below is from the fork, not from the consult. A follow-up asking about callback-time stream
validity exhausted its tool budget and, to its credit, declined to guess rather than inventing an
ordering; §2.2 answers it from source instead.

### 6.2 Three gates, all off

| Gate | Default | Where |
|---|---|---|
| `PJMEDIA_HAS_RTCP_XR` — compile the code at all | **0** | `pjmedia/include/pjmedia/config.h:644-645` |
| `PJMEDIA_STREAM_ENABLE_XR` — default for the per-stream flag | **0** | `config.h:656-657` |
| `pjsua_acc_config.enable_rtcp_xr` — runtime, per account | **0** (derived) | `pjsua.h:5188`; defaulted from `(PJMEDIA_HAS_RTCP_XR && PJMEDIA_STREAM_ENABLE_XR)` at `pjsua_core.c:408` |

`swift-pjsip/scripts/config_site.h` sets none of them, and the `PJ_CONFIG_IPHONE` profile in
`pjlib/include/pj/config_site_sample.h:303` does not either. So **the shipped `.xcframework` has
no XR code in it** — this is an `swift-pjsip` rebuild, not a runtime switch.

The third gate is not merely a switch: enabling it makes pjsua add `a=rtcp-xr` to the SDP
(`pjsua_media.c:3352-3360`). That is a **signalling change**, visible to every registrar and SBC we
talk to, in exchange for a debug statistic. Not a reason never to do it; a strong reason not to do
it speculatively.

### 6.3 pjmedia does not compute R-factor or MOS — it relays them

This is the finding that most changes the picture, and it is unambiguous in the source.
`pjmedia_rtcp_xr_init()` sets the local quality fields to RFC 3611's "unavailable" sentinel:

```c
/* pjmedia/src/pjmedia/rtcp_xr.c:88-91 */
session->stat.rx.voip_mtc.r_factor     = 127;
session->stat.rx.voip_mtc.ext_r_factor = 127;
session->stat.rx.voip_mtc.mos_lq       = 127;
session->stat.rx.voip_mtc.mos_cq       = 127;
```

and nothing computes them thereafter. `pjmedia_rtcp_build_rtcp_xr()` copies those fields straight
into the outgoing report (`:382-385`) — so by default we transmit "unavailable". The only way they
are ever populated is by decoding a **peer's** XR block into the `tx` side (`:627-630`), or by the
application pushing its own values in through `pjmedia_rtcp_xr_update_info()` (`:801-830`).
`pjsua_dump.c` confirms the convention, printing `"(na)"` for 127 (`:515-519`).

**So enabling XR would not give us a MOS.** It would give us what pjmedia *does* compute locally:
loss rate, discard rate, and burst/gap density and duration via the RFC 3611 Appendix A.4 Markov
model, with `Gmin` defaulting to the RFC's recommended 16 (`rtcp_xr.c:52`, used at `:762`). Those
are real and are exactly the brief's gap. The quality scores are not on offer, which independently
reinforces §5: even the standards-track path expects the *application* to compute the score.

### 6.4 The free half we should take now

`jbuf.avg_burst` and `jbuf.dev_delay` (§1.2) are already inside the struct `PJSUA+Statistics.swift`
populates and discards. They are approximations — average burst length in frames rather than RFC
3611 burst density over a Gmin-thresholded Markov partition — but they answer the operative
question ("was the loss clumped?") for **zero cost, no rebuild, and no SDP change.**

Combined with `rtcp.rx.loss` and `jbuf.discard`, that gives an effective-loss figure closer to
what the user actually heard than raw network loss — the correction the literature makes as
`Pplef = 1 − (1 − Ppl)(1 − Pjitter)`.

**Rejected: enabling XR now.** Three gates, an `.xcframework` rebuild, an SDP change on every
call, and no R-factor or MOS at the end of it. Revisit if a concrete investigation needs true
burst density — the design stores raw (§4), so historical records remain comparable when a
`burstDensity` field starts appearing.

**Rejected: adding `pjsua_call_get_stream_stat_xr()` upstream** *for our purposes*. It is the
obvious API and DeepWiki proposed it, but `on_stream_destroyed` already hands us the
`pjmedia_stream *` (`pjsua.h:1580-1582`) that `pjmedia_stream_get_stat_xr()` takes
(`pjmedia/include/pjmedia/stream.h:291-301`), so at our capture point the gap does not exist. It
*does* exist for anyone wanting XR mid-call, which is why it stays in §10.2 as an upstream note
rather than being dropped.

---

## 7. Q6 — Where it lives

**Recommendation: one append-only JSON Lines file, written through the existing engine-owning
actor, loaded into memory at launch. No database, no dependency.**

The volume argument from §4 is decisive: ~36 500 records/year, ~7 MB. That is not a database
workload. It never needs an index, a query planner, a migration engine, or a relational join —
the only "join" is `CallRecord` to its streams by call id, over an in-memory array.

The workspace convention is to prefer a good library over hand-rolled code *unless the code needed
is much smaller than the library*. Here it is: append a line, read the file at launch, drop old
lines on a retention pass (§9). Roughly 80 lines. GRDB is excellent and would be the right answer
at 100× the volume or with real query needs — this is a case where taking it would be the
over-engineered choice, not the safe one.

Three properties fall out for free, and each is otherwise real work:

- **Export is the file.** Q8 wants an exportable diagnostic artifact; JSONL already is one.
- **Migration is a `schemaVersion` field per line.** Records are immutable and independent, so a
  reader skips or upgrades per line. There is no schema to migrate, because there is no schema.
- **Crash-resistance is `O_APPEND`.** A torn final line is discarded by the reader; every earlier
  record is intact. §3 noted this is the actual answer to "what if we lose the record".

**Rejected: SwiftData.** It is the default-looking choice and it is wrong here. Batch operations
are still unsupported, predicate support is incomplete, its own performance ordering is
SQLite > Core Data > SwiftData, and as of the appleOS 27 cycle `ModelActor` is still observed
running work on the main thread — which is disqualifying next to an engine whose central invariant
is thread discipline. We would be adopting a schema-migration obligation for a debug feature.

**Rejected: GRDB / raw SQLite.** Both are good; both are a dependency and a schema for a workload
that is a `reduce` over an array. Revisit when a query genuinely needs an index — the JSONL file
imports into either in an afternoon.

**Rejected: in-memory ring buffer, no persistence.** The brief offers it as a serious v1 option and
it is tempting, but it fails the feature's main question. "Is this provider worse than that one",
"did latency regress after the CallKit change" and "how often do we get connected-but-no-audio"
are all multi-session questions; a buffer that empties on relaunch answers none of them. Durability
is the feature, and it is nearly free.

---

## 8. Q7 — What the UI should answer

Judged by one test: **does the answer change what someone does?**

### Actionable

1. **Share of calls that reached `confirmed` but never got media.** The single most valuable
   number here. It is [OH-9](./Tech-Debt.md) — "connected but no audio" — turned into a rate, and
   it is the failure this stack actually has. It is also assertable in the integration suite.
2. **Setup-latency trend per account** (the four OH-9 intervals). Distinguishes a slow provider
   from a slow client, and catches regressions the smoke test would pass.
3. **Loss / jitter / burst by provider.** [SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md)
   gives several endpoints; this tells us whether a flaky test run is provider weather or ours —
   the exact ambiguity OH-9 names as a cost.
4. **Wi-Fi vs cellular.** Actionable because it changes behaviour, not just understanding: it is
   the evidence for or against the lifecycle-recovery work, and the `NWPathMonitor` feed it needs
   is already required.

### Decoration

- **By hour of day.** Meaningful at carrier scale; on one device the per-bucket n is single digits
  and the variance swamps the signal.
- **By transport (UDP/TCP/TLS).** We *choose* the transport, so this is a setting we could A/B
  deliberately, not a distribution to discover. (`PJSIP_DONT_SWITCH_TO_TCP 1` in
  `swift-pjsip/scripts/config_site.h` already pins it.)
- **A quality trend line over weeks.** Looks authoritative, moves with who you called rather than
  with anything you control.

### The consumer view, kept in its place

SashaSIP's donut — incoming/outgoing/missed plus total duration for day/week/month
([Prior-Art](./Prior-Art.md) §1.3.8) — falls out of `CallRecord` as a `reduce`, with no extra
storage. Ship it, with the **excluded-numbers filter**, which is the part that makes it usable
when half your call history is echo endpoints. It is a genuine product feature and it is not the
interesting half; it should not lead the screen.

---

## 9. Q8 — Privacy and retention

**Remote party is the only sensitive field, and it should not be stored in the clear by default.**

Everything else here is packet counters and timings. The remote URI is call metadata — who you
called and when — which is sensitive without any recording, and §8's most valuable views
(per-provider, per-account) need only the *domain*, not the user part.

**Recommendation.** `CallRecord` stores the remote **domain** in the clear (that is the provider,
and it is what the aggregates need) plus a **salted hash of the full URI** with a per-install salt
in the Keychain (which [OH-6](./Tech-Debt.md) is adding anyway). The hash supports "group calls to
the same party" and the excluded-numbers filter (§8) without storing the party. The plaintext URI
is stored **only** while the opt-in diagnostic capture is on — the same switch
[Roadmap](./Roadmap.md) already puts in front of pjsip's own log.

**Retention:** bounded by both count and age — 2 000 records or 180 days, whichever bites first —
enforced on the append path (a rewrite when the file exceeds a threshold, not on every write).
Bounded retention is already the stated policy for diagnostic capture; this matches it.

**Export:** the JSONL file, as-is, through the share sheet, with a one-line header naming what it
contains. With the diagnostic capture off, an exported file has no plaintext identifiers in it,
which makes "send me your stats" a safe request.

**Relationship to the `OSLog` decision — deliberately none.** [Roadmap](./Roadmap.md) flags an
unresolved question: whether `OSLogStore` returns `private` values to the process that wrote them
or redacts them on readback, and notes that it decides the design of log export. **This design
does not depend on that answer**, because quality records are a durable data store with their own
retention, not log lines. Records never go to `OSLog`; at most a one-line `Logger` summary per
call, with the remote party `private` per house style. Keeping these two independent means the
unresolved question blocks one feature instead of two.

---

## 10. What this asks of `swift-pjsua`

Ordered by whether the design can proceed without it.

### 10.1 Blocking

1. **Install `on_stream_destroyed`** (`pjsua.h:1580-1582`). Same G2 discipline as the existing four
   (`PJSUACallbacks.swift:73-76`): no actor reference, read POD from C, yield a `Sendable` value.
   The callback must call `pjmedia_stream_get_stat()` / `pjmedia_stream_get_info()` on the pointer
   *inside* the callback — the pointer is invalid 33 lines later (`pjsua_aud.c:573`) and must never
   be stored or forwarded.
2. **Deliver records off the `.bufferingNewest(64)` events stream.** TD-3 drops the *oldest* under
   burst. A dropped quality record is a whole call's data lost, and a burst of stream teardowns is
   exactly what a multi-line hangup or a `pjsua_destroy()` produces. Records need a channel where
   backpressure blocks or buffers rather than discards; live samples (§3) can stay on a lossy
   channel, because dropping a stale sample is correct.
3. **Record the lock context in `docs/Threading-Validation.md`.** `on_stream_destroyed` fires with
   `PJSUA_LOCK` **held** (§1.3) — stricter than any callback currently in that table, and the
   reason (2) cannot be "just `await` the actor from the callback".

### 10.2 Non-blocking but cheap, and this design uses all of them

4. **Expose `jbuf`** on `CallStreamStatistics` — `avg_burst`, `dev_delay`, `avg/min/max_delay`,
   `lost`, `discard`, `empty` (`jbuf.h:98-121`). Already populated and discarded (§1.2). This is
   the highest value-per-line item in the list.
5. **Expose jitter standard deviation** as `Distribution.sdMs`, via pjlib's existing
   `pj_math_stat_get_stddev()` (`math.h:177-181`) rather than reading `m2_` (`math.h:81`) directly.
6. **Assert the `hanging_up` ordering** (§2.2). A test that hangs up locally and asserts the record
   arrived. We depend on `pjsua_call.c:3410-3414` ordering that upstream never promised.
7. **Record the PLC / codec build configuration** somewhere readable. §5.2 shows `Bpl` swings 4.3 →
   25.1 on it; even without a MOS, a record that cannot say which codec configuration produced it
   is less comparable than it looks.

### 10.3 Upstream notes for `pjsip/pjproject` — not needed by us, worth filing

- **`pjsua_call_get_stream_stat_xr()` is genuinely missing.** With XR compiled in, a pjsua1 app can
  reach the data only by parsing `pjsua_call_dump()`'s text (`pjsua_dump.c:504-544`), or by holding
  a `pjmedia_stream *` from a callback as we do. A structured accessor alongside
  `pjsua_call_get_stream_stat()` is a small, symmetric addition. We do not need it at our capture
  point (§6.4), so this is a contribution, not a dependency.
- **The local R-factor field appears unreachable.** `PJMEDIA_RTCP_XR_INFO_R_FACTOR` writes
  `ext_r_factor` (`rtcp_xr.c:822`), and `rx.voip_mtc.r_factor` has **no** writer other than the
  `127` initialisation (`:88`) — yet `:382` transmits it. So pjproject always sends R factor =
  "unavailable" with no way for an application to populate it, while `mos_lq`/`mos_cq` have working
  setters (`:825-830`). RFC 3611 §4.7 distinguishes the two ("R factor" = quality for *this* RTP
  session; "Extended R factor" = quality carried *outside* it), and an application computing R from
  its own reception statistics is computing the former. Reported as an observation with the reading
  of intent flagged — see §11.
- **Both now live in the workspace's standard place for this,** `../../swift-pjsua/Upstream/` — as `draft-rtcp-xr-no-structured-pjsua1-accessor.md` and `draft-rtcp-xr-r-factor-has-no-writer.md`, following that folder's naming convention.
- Both are worth raising through the same channel as
  [pjproject#5178](https://github.com/pjsip/pjproject/pull/5178).

---

## 11. Unverified

Collected rather than quietly asserted.

1. **That `pjmedia_stream_get_stat_xr()` succeeds at `on_stream_destroyed` time.** §2.2 proves the
   stream is live because pjsua calls `pjmedia_stream_get_stat()` on it at `pjsua_aud.c:540`. I did
   **not** verify that the *XR* session inside it is equally intact at that moment, and could not —
   XR is not compiled into our build (§6.2). The DeepWiki follow-up that would have answered it ran
   out of tool budget. Must be checked before anyone acts on §6.
2. **That `on_stream_destroyed` fires on re-INVITE stream replacement**, not only on call teardown.
   §2.3's multi-record model assumes it. `stop_media_session()` is reached from
   `pjsua_media_channel_deinit()` (`pjsua_media.c:3628`) and `stop_media_stream()` is also called on
   media reconfiguration, but I did not trace the re-INVITE path to the callback. If it does not
   fire, re-INVITE churn produces one record covering both streams, and §2.3 needs revising.
3. **The G.113 Appendix I `Ie`/`Bpl` figures** (G.711 `Ie=0`, `Bpl=4.3` without PLC / `25.1` with;
   G.729AB `Ie=11`, `Bpl=19`) are from secondary sources, not the Recommendation text. The
   *conclusion* they support in §5.2 — that the value swings ~6× on a setting we do not record —
   survives even if the exact figures are off, but do not quote them as authoritative.
4. **G.722 has no published `Ie`/`Bpl`** in the sources I found. Since G.722 is in our codec set,
   any E-model estimate for a G.722 call would be extrapolated. Another argument for §5's verdict.
5. **The volume estimate** (~50 calls/day, ~200 bytes/record → ~7 MB/year) is a sizing assumption,
   not a measurement. §4 and §7 both lean on it. It would take a 10× error to change either
   conclusion.
6. **Whether pjmedia's G.711 runs with PLC** in our build, which is what selects between the two
   `Bpl` values. `PJMEDIA_MAX_PLC_DURATION_MSEC` and `PJMEDIA_WSOLA_PLC_NO_FADING` exist in
   `pjmedia/include/pjmedia/config.h:333-351`, but I did not trace whether the G.711 decode path
   enables PLC by default. §10.2 (7) exists to make this recordable rather than guessed.
7. **The reading of RFC 3611's intent** in §10.3's second bullet — that an application's own R
   estimate belongs in `r_factor` rather than `ext_r_factor`. The *mechanical* claim (no writer for
   `rx.voip_mtc.r_factor`) is verified; whether upstream considers that a bug is not.

---

## See Also

- [Roadmap](./Roadmap.md) · [Tech-Debt](./Tech-Debt.md) ([OH-9](./Tech-Debt.md)) ·
  [Design](./Design.md) · [Prior-Art](./Prior-Art.md) §1.3.8
- [Push-vs-Active-Socket](./Push-vs-Active-Socket.md) — the house pattern this doc follows
- `../../TASK-code-swift-pjsua-audio-and-diagnostics.md` §3 — the OH-9 setup timings this joins to
- `../../deepwiki-log.md` — the §6.1 consult
- ITU-T [G.107](https://www.itu.int/rec/T-REC-G.107) (E-model) ·
  [G.113](https://www.itu.int/rec/T-REC-G.113) (impairment factors) ·
  [RFC 3611](https://www.rfc-editor.org/rfc/rfc3611.html) §4.7 (RTCP XR VoIP Metrics)
