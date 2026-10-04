# Instance ID — `+sip.instance` on iOS

**Status: proposed, 2026-10-02; upstream shape decided 2026-10-04 (§2.1).** Two decisions are
still open (§6). Nothing here is built in Offhook:
neither Offhook nor `swift-pjsua` sets `rfc5626_instance_id` today
([OH-11](./Tech-Debt.md#oh-11--no-instance-id-of-our-own--open)).

Written from the experience of a production iOS softphone on the same pjsua stack, and from the
research behind [pjsip/pjproject#5292](https://github.com/pjsip/pjproject/issues/5292).

---

## 1. Why the instance ID matters

`+sip.instance` is a Contact header parameter naming the device (RFC 5626 §4.1). It is what lets
a registrar recognise that a REGISTER from a new connection is the *same* phone, which is the
normal case for a mobile client that reconnects after every wake-up.

| Registrar | With an instance ID and no `reg-id` |
|---|---|
| Kamailio | the binding is matched on it; the same instance from a new address updates the old binding |
| Flexisip | the binding is keyed on it alone; it is the first of its `unique-id-parameters` |
| IMS (3GPP TS 24.229) | mandatory for a UE with an IMEI; `reg-id` only with multiple registrations |
| OpenSIPS | stored, not used for matching |
| Asterisk, FreeSWITCH | never read |

Without it (or with a wrong one) those that key on it accumulate stale bindings, or let one
device replace another.

## 2. What pjsua does on its own

- If `rfc5626_instance_id` is empty, pjsua generates
  `urn:uuid:00000000-0000-0000-0000-0000XXXXXXXX` from a 32-bit hash of the host name. On iOS the
  host name is not the device's (the production client saw `localhost`), so phones would share
  one instance ID. It must be set by the app.
- pjsua sends the parameter only together with `reg-id`, while SIP outbound is wanted (TCP/TLS),
  and drops both when the registrar does not confirm outbound. Sending it regardless is the
  subject of the upstream issue above.

### 2.1 The upstream change, and why it is narrow

The change we propose ([pjsip/pjproject#5313](https://github.com/pjsip/pjproject/pull/5313)) sends
an instance ID **the application configured** in every REGISTER, with or without outbound, and
logs it once per account (`Acc N: instance ID … is sent in every
REGISTER`). The generated one stays outbound-only, as since 2010.

A first version added an account switch that also widened the generated ID. Review caught what
that means: two pjsua processes on one host, or any two iPhones, would advertise the same instance
ID everywhere, and a registrar keying on it would let one replace the other. Narrowing to the
configured ID removes the error class instead of documenting it.

pjsua cannot fix its default itself, in a minor release or otherwise. Explored with DeepWiki
([consult](https://deepwiki.com/search/pjsua-generates-a-default-sip_cfb1d46e-d9d2-41d2-95b2-88d8fb50aeb1?mode=deep)),
claims checked against source:

| Option | Verdict |
|---|---|
| Keep the generated ID outbound-only; send only a configured one wider | done |
| Document it next to `rfc5626_instance_id` | done, three lines |
| Log the instance ID | done for a configured one only; most users never set it |
| Change how the default is generated (random, machine ID, a proper 128-bit UUID) | major release at best: every deployment's wire value changes; no machine ID exists on iOS or Android; a random one per process is not persistent |
| Return the effective ID through an API | not now, see below |

pjlib has no persistent store, and the stable identifiers on phones live above C. liblinphone
solves it with its own config: a random UUID generated once and kept as `[misc] uuid` (`uuid=0`
turns `+sip.instance` off). sofia-sip sends no instance ID unless the application gives one.
A read-back API would be the pjsua counterpart of liblinphone's model only if pjsua first
generated something worth keeping (a random UUID); the application would then persist it and
pass it back. That may be the remedy for the persistence problem, but it is a design of its own,
not part of this change. DeepWiki said the generated ID is already readable through
`pjsua_acc_get_config()`; it is not, it lives only in a private field of the account.

## 3. What the value has to be

RFC 5626 §4.1: a URN, "persistent across power cycles of the device", that "MUST NOT change as the
device moves from one network to another", and preferably a UUID URN. The RFC's own advice for a
soft phone is to generate a UUID when first installed and keep it in persistent storage.

So the requirement is **persistent and unique per installed UA**. It is not "derived from a
hardware identifier".

## 4. iOS: every obvious source can be missing

| Source | Failure |
|---|---|
| `UIDevice.identifierForVendor` | `nil` "after the device has been restarted but before the user has unlocked the device" (Apple). Changes when all of the vendor's apps are removed and one is reinstalled. Identical for every app of the vendor on the device, so two of our apps on one AOR would share it |
| `UserDefaults` | its file is `completeUntilFirstUserAuthentication`. Before first unlock a read returns `nil`, indistinguishable from "never stored", and the empty state stays cached for the life of the process (Apple DTS, [forums thread 15685](https://developer.apple.com/forums/thread/15685)) |
| Keychain, `AfterFirstUnlock…` | also unreadable before first unlock, but the failure is an error distinct from "not found" |
| A file with `FileProtectionType.none` | readable at any time; the only store that is |
| `UIDevice.name`, the host name | the name is the generic `"iPhone"` since iOS 16 unless the app holds a special entitlement, and the host name was `localhost` in production. Neither is unique or stable. Not candidates |

Whether a VoIP push launches the app in exactly that window (restarted, not yet unlocked) is
still an open device test ([Push-vs-Active-Socket](./Push-vs-Active-Socket.md) U4). Any
background launch there, including that one, has to cope with the failures above.

### 4.1 What went wrong in production

1. **`identifierForVendor`, cached in `UserDefaults`, with `""` as the fallback.** Before first
   unlock both were unavailable and the client registered with an empty instance ID.
2. **A second writer.** An asynchronous copy-modify-write of the whole account config raced the
   code that set the instance ID, and sometimes wrote back a snapshot without it. pjsua then fell
   back to its host-name default. The instance ID has to be set in one place, on the path that
   builds the account config, not patched in afterwards.
3. **A stored UUID, seeded from `identifierForVendor`, with a random UUID as the fallback.** Better,
   but the fallback breaks determinism: a launch before first unlock reads nothing, falls through
   to a random value and uses it for the life of that process. The instance ID is then sometimes
   the device's and sometimes a stranger's.
4. **Length or format.** One deployment's SBC (believed to be OpenSIPS-based, lightly customised)
   did not accept the canonical form from iOS and did accept shorter ones:

   | Client | `+sip.instance` value | URN length | Result |
   |---|---|---|---|
   | Android | `<urn:uuid:` + 16 lower-case hex (`ANDROID_ID`) + `>` | 25 | accepted |
   | iOS, shortened | `<urn:uuid:` + 26 lower-case base32 (the UUID's 128 bits) + `>` | 35 | accepted |
   | iOS, canonical | `<urn:uuid:` + `uuidString` (36, upper-case, hyphens) + `>` | 45 | not accepted |

   Three things differ between the accepted and the refused forms: length, hyphens and case. Which
   one mattered was never isolated. Neither accepted form is a valid UUID URN; registrars that
   treat the value as opaque do not care, and Kamailio, Flexisip and OpenSIPS all do.

Android never had the first three problems: `ANDROID_ID` is available at any time.

## 5. Proposed design

**D-INST-1. One stored device ID, written once, never re-derived.** On the first launch that
finds none, the app stores a UUID in the Keychain beside the SIP secrets, with the same class
they already use (`kSecAttrAccessibleAfterFirstUnlock`, see [Credentials](./Credentials.md)
D-CRED-1), in its `ThisDeviceOnly` variant so that a restore onto another device does not clone it.
The UUID is `identifierForVendor` if the system has one at that moment, otherwise random. The
system is not asked again.

**D-INST-2. "Unreadable" is not "absent".** A new value is generated only when the store answers
"not found" *and* the device is unlocked. Any other failure means wait. No random fallback, no
empty value, no registration without an instance ID.

**D-INST-3. The wait is the one we already have.** Before first unlock the SIP secret is
unreadable too, so no REGISTER can be sent in that window whatever the instance ID does. Both
become readable at the same moment. The instance ID adds no pause of its own.

**D-INST-4. The wire value is a hash of the stored device ID, per app and per account.**
`+sip.instance` carries a version-5 UUID computed from the stored device ID, the bundle identifier
and the AOR, printed in canonical lower case. It is as stable as the stored ID, is a valid UUID
URN, differs between two of our apps on one phone, and cannot be linked across providers.

*Why.* It meets §3 exactly and removes the first three failures in §4.1. Seeding from
`identifierForVendor` keeps what is useful about a device ID: one value for the backend, the logs
and SIP, and a second source if the Keychain item is ever lost while the vendor identifier
survives. The first launch is started by the user, so the device is unlocked and the identifier
is there; nothing has to wait for it. D-INST-4 removes what is harmful about it: sent as is, two
apps of one vendor on one AOR would share an instance ID and take each other's binding on a
registrar that keys on it.

*Rejected.* Deriving the value on every launch (§4.1 items 1 and 3). Storing it in `UserDefaults`
(cannot tell locked from empty). A `FileProtectionType.none` file: it would make the instance ID
readable before first unlock, which buys nothing while the secret is not.

### 5.1 What the user sees before first unlock

*Assumes iOS launches the app for a VoIP push before first unlock, which is unverified
([Push-vs-Active-Socket](./Push-vs-Active-Socket.md) U4).* If it does, the push must still be
reported to CallKit. The call can ring, but answering it cannot register or accept the INVITE
until the device has been unlocked once. The app has to fail
that answer cleanly and say why, not hang. An outgoing call does not arise there: the app cannot
be opened. After the first unlock none of this applies until the next restart.

Avoiding it would mean keeping the SIP secret readable before first unlock, i.e. unprotected at
rest. Not proposed.

### 5.2 What the engine needs

`swift-pjsua` does not expose `rfc5626_instance_id`. It needs an account-level instance ID that the
app supplies. With the upstream change (§2.1) that ID is then sent in every REGISTER, with or
without outbound, and the pjsua log shows it once per account.

### 5.3 To verify on a device

- Whether iOS launches the app for a VoIP push before first unlock at all (U4 in
  [Push-vs-Active-Socket](./Push-vs-Active-Socket.md)); §5.1 depends on it.
- What a Keychain query for a *missing* `AfterFirstUnlock` item returns before first unlock. If it
  is "not found", D-INST-2's "and the device is unlocked" is what keeps it safe.
- Which of length, hyphens and case the SBC in §4.1 item 4 objects to
  (`urn:uuid:` + canonical lower-case, upper-case, 32 hex without hyphens, base32).

## 6. Open decisions

1. **Seed from `identifierForVendor` (D-INST-1), or always random?** Proposed: seed. Random is
   the simpler rule and loses only the second source and the match with the vendor identifier.
   If the wire value were ever sent unhashed, random would be the safer seed.
2. **Hashed (D-INST-4), or the stored ID in full?** Proposed: hashed. In full is simpler to
   correlate by eye in a trace and is what a backend that already knows the device ID can match
   without computing anything; such a backend can compute the same hash.
3. **A short form.** A per-account override for a deployment that needs a shorter or differently
   shaped value (§4.1 item 4), off by default because it is not a UUID URN. Not needed until a
   provider asks for it.

## See Also

- [Credentials](./Credentials.md) · [Push-vs-Active-Socket](./Push-vs-Active-Socket.md) ·
  [Roadmap](./Roadmap.md) · [Tech-Debt](./Tech-Debt.md)
- RFC 5626 §4.1 and §6; RFC 5627; 3GPP TS 24.229 §5.1.1.2.1
- [pjsip/pjproject#5292](https://github.com/pjsip/pjproject/issues/5292)
