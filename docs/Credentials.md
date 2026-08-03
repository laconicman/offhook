# Credentials — Keychain behind `CredentialStore`

**Status: research complete, 2026-07-26.** Answers `TASK-cowork-async-keychain-library.md`
("can we make our own `@KeychainStorage`-style **async** SPM library?").

**Verdict: adopt [dm-zharov/swift-security][sws] as-is; write one ~70-line file in Offhook;
build no library.** Closes the app half of `swift-pjsua` **OH-6** / **TD-11**.

[sws]: https://github.com/dm-zharov/swift-security

---

## 1. The question is smaller than it looks — twice over

The brief already narrowed "async Keychain" to the only case that blocks: **user-presence /
biometry-gated items**, where `SecItemCopyMatching` sits behind a Face ID prompt for seconds.
Two further narrowings fall out of the research, and together they dissolve the library idea.

### 1.1 The blocking call is not the Keychain call — it is the *authentication*

`LAContext.evaluatePolicy(_:localizedReason:)` is **already async** (completion-handler form,
auto-imported as `async throws -> Bool`). Authenticate first, then the `SecItem` read is a
fast, ordinary synchronous call:

```swift
try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "…")  // seconds, async
try keychain.retrieve(query, authenticationContext: context)                        // microseconds
```

An "async Keychain wrapper" would be wrapping the wrong call. LocalAuthentication already owns
the slow half and already exposes it as `async`. **Nothing needs to be built for this.**

### 1.2 The engine's credential path must never be gated at all — D-CRED-1

`CredentialStore.secret(for:)` is consulted at `addAccount` **and again on `reRegister`**, which
can run from a **PushKit wake-up with the device locked and no user present**. An item written
with `.userPresence` cannot be read there — background re-REGISTER would simply fail.

> **D-CRED-1.** SIP secrets the engine fetches are stored with `AccessPolicy.default`
> (`kSecAttrAccessibleAfterFirstUnlock`, **no** access-control options). Biometry gating, if we
> ever want it, belongs on a *user-initiated* settings action (reveal / edit / export), never on
> the engine's fetch path. That call site is a SwiftUI `.task`, where `async` is free.

So for our actual consumer the async question is **pure ceremony** — `secret(for:)` is `async`
only because the protocol says so. The gated machinery in §5.2 is written down for the settings
path and is **not** built now (YAGNI).

---

## 2. Prior art — what actually exists

Verified against source at HEAD, not READMEs. Keychain-library comparison via DeepWiki deep
consult ([conversation][dw], file-cited).

[dw]: https://deepwiki.com/search/comparing-these-two-establishe_52a9d2a8-d758-41c6-86e1-0ed4fffd3f00?mode=deep

| | **swift-security** | Valet | KeychainAccess |
|---|---|---|---|
| Tools / language mode | 5.9, `StrictConcurrency` upcoming-feature **on** | 6.0, `.swiftLanguageMode(.v6)` | 5.0, none |
| Dependencies | **none** | none | none |
| Main type `Sendable` | ✅ `struct Keychain: Sendable` | ✅ (`SinglePrompt…` is `@unchecked`) | ❌ none at all |
| Caller-injectable `LAContext` | ✅ | ❌ **no** | ✅ |
| `async` API | ❌ | ❌ | ❌ |
| `kSecUseDataProtectionKeychain` | ✅ always, baked into every query | ✅ auto | partial, undocumented |
| Typed errors | ✅ `.userCanceled` / `.authFailed` / `.interactionNotAllowed` / `.missingEntitlement` | OSStatus-ish | OSStatus-ish |
| Last substantive commit | active | 2026-07-12 | **2023-11** (unmaintained) |
| Min deployment | iOS 14 | — | — |

**None of the three has an async API.** That is not a gap in the ecosystem; it is §1.1.

- **KeychainAccess is out**: unmaintained since Nov 2023, zero `Sendable` annotations, tools 5.0
  → warnings under any strict-concurrency posture, errors in Swift 6 mode.
- **Valet is out** despite being the best-maintained and only Swift-6-mode package: it gives you
  **no way to inject your own `LAContext`** (it always creates or internally holds one). That
  injection is the single capability §1.1 depends on.
- **swift-security is in**: zero dependencies, `Sendable` value types, injectable `LAContext`,
  and the only one whose error enum lets us pattern-match "user cancelled" apart from
  "not stored".

### 2.1 The finding the README would have hidden

`Keychain.retrieve(_:query:authenticationContext:)` sets **both** keys when you pass a context:

```swift
if let authenticationContext {
    query[kSecUseAuthenticationContext as String] = authenticationContext
    query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip   // ← this
}
```
<sub>`Sources/SwiftSecurity/Keychain/Keychain.swift`</sub>

Apple: `kSecUseAuthenticationUISkip` = *"Silently skip any items that require user
authentication."* Consequences, none of them in the README:

1. ✅ **Pre-authenticated context → fast, non-blocking read.** Exactly the §1.1 shape. Good.
2. ⚠️ **Passing `nil` is the only way to get the system prompt** — and that path blocks, with
   **no prompt-string control** (`kSecUseOperationPrompt` is not exposed). A reason to always
   pre-authenticate: `evaluatePolicy` takes `localizedReason`.
3. ❓ **Fresh, un-evaluated context → unresolved.** See below.

#### The unresolved bit — and an explicit disagreement

An earlier draft of this doc claimed that passing a fresh, un-evaluated `LAContext` makes a
gated item return `nil`, indistinguishable from "not stored", and called it the headline
finding. **A DeepWiki deep consult refuted that** ([conversation][dw-sws]): it says the read
returns `errSecInteractionNotAllowed`, which the `case let status:` arm re-throws as
`SwiftSecurityError.interactionNotAllowed` — so absent and auth-refused *are* distinguishable,
`nil` versus `throw`.

**Neither of us has actually established this, and the doc should say so.** DeepWiki cited the
package's error-mapping arm, which only shows what happens *if* that status comes back; it
cannot show which `OSStatus` Security.framework actually returns. And Apple's own wording
("silently skip") points the other way. The two plausible behaviours — skip-then-`errSecItemNotFound`
versus `errSecInteractionNotAllowed` — differ by whether `kSecMatchLimitOne` treats a skipped
sole match as no-match.

> **Open, deliberately unresolved.** It is **moot under D-CRED-1**: ungated items have no
> authentication gate, so `UISkip` never applies on our path. If we ever gate an item (§5.2),
> settle it with a five-minute device test before relying on either behaviour. Do not propagate
> either claim as fact in the meantime.

Confirmed by the same consult, and worth keeping:

- `SwiftSecurityError` also has **`.interactionRequired`** (system needs UI) distinct from
  `.interactionNotAllowed` (UI was suppressed) — my original list omitted it.
- `@Credential` caches the first **non-nil** value; an absent item is re-queried each access.
- `kSecUseDataProtectionKeychain: true` "cannot be changed" is **design intent, not
  enforcement** — the public `String`-keyed subscript can overwrite any key, including that one.
- The `SecItemQuery` `Sendable` hole is **reachable, not theoretical**: that same public
  subscript lets a caller stuff a non-`Sendable` `LAContext` into the `[String: Any]` box and
  then send the query across an isolation boundary with no diagnostic. Reinforces §4's rule —
  build queries locally, never store or send them.

[dw-sws]: https://deepwiki.com/search/i-read-this-packages-source-di_eb8c9c08-09f3-4275-9fcc-304de0dedda9?mode=deep

### 2.2 `@Credential` is not a candidate

swift-security's property wrapper is `DynamicProperty` + `@StateObject`, SwiftUI-only, and its
getter calls `retrieve(query, authenticationContext: nil)` **synchronously during view update**.
For a gated item that blocks the main actor behind a Face ID prompt inside `body`. It is fine
for ungated settings display; it is unusable for the engine and unusable for gated items.

### 2.3 Residual risk, already priced

swift-security is a single-maintainer package. The mitigation is the seam we already built:
`CredentialStore` is one method, so replacing the library is a one-file change. That
reversibility is precisely why the protocol exists (`swift-pjsua/docs/Configuration-Design.md`
§4, D-CONFIG-1).

**`laconicman/swift-security` is currently an unmodified mirror.** The consult found every
commit authored by `dm-zharov`, one merged external PR (`f6a71a71`, Sendable conformances, also
upstream), and a `Package.swift` identical to upstream's. So the fork carries **no delta today**
— it is a mirror, not a fork in any load-bearing sense. Useful as a pin against upstream
disappearing; not yet a codebase we maintain. Keep it that way unless §3.3 changes.

### 2.4 Do we need our own Keychain SPM? — D-CRED-5

Asked directly, after the first draft. The consult answered the mechanical half: all three
things we might want — (i) async read that pre-authenticates then does the fast read,
(ii) telling "absent" from "auth refused", (iii) reusing one authenticated `LAContext` across
reads — are **achievable through the public API with no patching**. `retrieve` takes
`LAContext?` on every call and never consumes or invalidates it; the error enum already
separates the cases. So there is no *capability* argument for building or forking.

The better question is what a package of ours would be **for**. Not Keychain mechanics — that
is a solved, someone-else's problem. What is genuinely ours is **credential policy**: D-CRED-1
(never gate what the engine reads), the `(accountID|username|realm)` key scheme, the access
group, and the `CredentialStore` conformance itself. None of that belongs to swift-security, and
all of it is the kind of thing that gets re-derived wrongly in a second app.

> **D-CRED-5.** Do **not** build or fork a Keychain library. If a package is ever warranted, it
> is a thin `Credentials` package that owns our *policy* and depends on swift-security for the
> *mechanics* — not a wrapper that re-implements `SecItem`. Trigger is unchanged from §7: a
> second signed target. Until then the policy fits in one file and a package would be structure
> without a second client.

This is the DRY-versus-coupling call (Metz): one consumer, no duplicated knowledge yet, so
extracting an abstraction now would couple a future second caller to a shape we invented before
we had one.

---

## 3. The four shapes

| | Shape | Verdict |
|---|---|---|
| 1 | **Swift macro** generating async accessors | ❌ rejected — §3.1 |
| 2 | **Property wrapper returning a handle** (`await $password.load()`) | ❌ rejected — solves an ergonomics problem we don't have |
| 3 | **Actor-backed store** | ⚠️ almost — the actor is the wrong granularity |
| 4 | **Sync + async only where gated** | ✅ **recommended**, refined by §1.1 |

### 3.1 The macro option — and a correction to the brief

The brief says *"macros can't make `get` async either"*. **That premise is wrong**, and worth
recording: [SE-0310][se310] (Swift 5.5) added **effectful read-only properties**, so
`var secret: String { get async throws }` is legal Swift today, and an `@attached(accessor)`
macro could generate one. What is genuinely impossible:

- **through `@propertyWrapper`** — `wrappedValue`'s requirement is a plain, non-effectful `get`,
  and a witness may not add effects the requirement lacks. So literal `@KeychainStorage var
  password: String` that awaits still cannot exist. The brief's *conclusion* holds; its reason
  does not.
- **with a setter** — SE-0310 is read-only by construction. No `store`.
- **via key paths** — SE-0310 explicitly disallows key-path access to effectful properties.

[se310]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0310-effectful-readonly-properties.md

Even granting the achievable version, the cost is disqualifying:

- A `.macro` target pulls in **swift-syntax**, which is compiled from source on every clean
  build unless the toolchain ships the prebuilt — **Swift 6.1.1 / Xcode 16.4+**. That raises our
  floor from tools 5.9 to 6.1.1 purely for sugar, plus Xcode's macro-trust prompt in CI.
- Macro expansion is invisible in review. On a path whose bugs are *silently wrong security
  posture* (§2.1), the generated `SecItem` query is exactly the code you most want to read.
- It buys one line, once. We have **one** call site.

KISS, Occam, YAGNI all point the same way. A build-system dependency is not a fair price for
sugar on a single call site.

### 3.2 Why not a whole actor (shape 3)

`Keychain` is already a `Sendable` value type and the keychain daemon serializes access, so an
actor buys no safety — only a hop. The *one* thing that genuinely needs serializing is the
`LAContext` (so two concurrent registrations don't double-prompt), and `LAContext` is a
non-`Sendable` class. So the actor should wrap **the context**, not the store — §5.2. This is
cohesion: the actor exists for the one piece of state that needs it.

---

## 4. Recommended shape

A plain `Sendable` struct. `async` because the protocol is; no ceremony beyond that.

```swift
import Foundation
import SwiftSecurity
import SwiftPJSUA

/// Reads SIP digest secrets from the Keychain, behind ``CredentialStore``.
///
/// - Important: items are stored **ungated** (`AccessPolicy.default` =
///   `.afterFirstUnlock`, no `options`) — see D-CRED-1. The engine re-fetches on
///   `reRegister`, which can run from a PushKit wake-up with the device locked; a
///   `.userPresence` item would be unreadable there.
struct KeychainCredentialStore: CredentialStore {
    /// `.default` = this app's own access group. Pass `.keychainGroup(teamID:nameID:)`
    /// to share with another signed target — see §6.
    var keychain: Keychain = .default

    /// `kSecAttrService` namespace, so SIP secrets can't collide with other app secrets.
    var service: String = "com.laconicman.offhook.sip"

    func secret(for request: CredentialRequest) async throws -> String {
        // Build the query locally. `SecItemQuery` is only conditionally `Sendable` over a
        // `[String: Any]` box — never store one or send it across an isolation boundary.
        var query = SecItemQuery<GenericPassword>()
        query.service = service
        query.account = Self.account(for: request)

        guard let secret: String = try keychain.retrieve(query, authenticationContext: nil) else {
            throw CredentialError.notFound(request)
        }
        return secret
    }

    func store(_ secret: String, for request: CredentialRequest) throws {
        var query = SecItemQuery<GenericPassword>()
        query.service = service
        query.account = Self.account(for: request)
        _ = try? keychain.remove(query)                // SecItemAdd fails on duplicates
        try keychain.store(secret, query: query, accessPolicy: .default)
    }

    /// One item per (AOR, user, realm): the same user may hold different secrets per realm,
    /// and `realm` defaults to the wildcard `"*"` in `AccountConfiguration`.
    private static func account(for r: CredentialRequest) -> String {
        "\(r.accountID)|\(r.username)|\(r.realm)"
    }
}

enum CredentialError: Error {
    case notFound(CredentialRequest)          // CredentialRequest carries no secret — safe to log
}
```

Call site is unchanged from today's `InlineCredentialStore` — that is the point of the seam:

```swift
let accountID = try await phone.addAccount(config, credentials: KeychainCredentialStore())
```

### 4.1 The synchronous read is a feature, not a tolerated flaw — D-CRED-4

> **Corrects an earlier draft**, which framed the sync `SecItem` call as a hazard to be watched.
> That was backwards.

`secret(for:)` contains **no `await`**. It is `async` only because the protocol is. An actor
interleaves *only* at a suspension point, so a witness with no internal suspension is **atomic
with respect to reentrancy** — a second caller cannot interleave partway through a read, and a
concurrent `store` cannot land between this read's query construction and its result. This is
the same argument that shaped **D-CONFIG-2** (capacity check + `pjsua_acc_add` in a private
non-`async` function): *the absence of a suspension point is the safety property.*

> **D-CRED-4.** Keep `secret(for:)` free of internal `await`. Any future implementation that
> needs to suspend (network fetch, biometric prompt) must take its suspension **up front** and
> leave the `SecItem` call in a synchronous tail — the D-CONFIG-2 shape.

Two honest bounds on that claim:

- **It does not remove the engine's own reentrancy window.** `await store.secret(for:)` is still
  a suspension point inside `addAccount`, which is precisely why D-CONFIG-2 exists. What sync
  buys us is the absence of a *second, nested* window inside the store.
- **The cooperative pool still dislikes long blocks.** A synchronous call inside an `async`
  function occupies a pool thread sized to core count. At ~200 µs–1 ms for an ungated read this
  is irrelevant. It would only matter for a seconds-long gated read — which **D-CRED-1 forbids
  on this path**, so the case cannot arise.

Because of D-CRED-1, the `NonisolatedNonsendingByDefault` note on `CredentialStore` also relaxes
for *this* implementation: if a future language mode makes the witness inherit caller isolation
and run on the pinned PJLIB thread, a sub-millisecond read on a non-media path is tolerable, not
fatal. Measure before adding `@concurrent`; don't add it reflexively. The gated path (§5.2) runs
inside an actor and is structurally immune either way.

---

## 5. Not building now (recorded so we don't re-derive it)

### 5.1 Nothing at all for the engine path
§1.2. Ungated items, plain synchronous read. Done.

### 5.2 If a settings screen ever gates a secret

~20 lines, no library, prior art = Valet's `SinglePromptSecureEnclaveValet`:

```swift
/// Owns the one non-`Sendable` thing here — an `LAContext` — and reuses it so a session
/// prompts once. Reading *inside* the actor keeps the blocking `evaluatePolicy` off every
/// other executor, in any language mode.
actor BiometricGate {
    private var context = LAContext()

    /// Takes the query's *components*, not a `SecItemQuery` — see the `Sendable` caveat in
    /// §4. The query is built inside the actor, so nothing unsound crosses the boundary.
    func secret(service: String,
                account: String,
                from keychain: Keychain,
                reason: String) async throws -> String? {
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                               localizedReason: reason) else { return nil }

        var query = SecItemQuery<GenericPassword>()
        query.service = service
        query.account = account
        // Pre-authenticated ⇒ `kSecUseAuthenticationUISkip` returns the item without
        // prompting. An *un*-evaluated context here would silently return nil (§2.1).
        return try keychain.retrieve(query, authenticationContext: context)
    }

    /// Force the next access to prompt again.
    func invalidate() { context.invalidate(); context = LAContext() }
}
```

Store those items with `AccessPolicy(.whenUnlocked, options: .userPresence)`.

---

## 6. Sharing / entitlement matrix

Apple's access-group list for an app, **in this order** — the first entry is the default group
for writes ([Sharing access to keychain items][apple-share]):

1. strings in the **Keychain Access Groups** entitlement (Xcode **prefixes these with the team ID**)
2. the **app ID** — `$(AppIdentifierPrefix)com.laconicman.offhook`
3. strings in the **App Groups** entitlement (Xcode does **not** prefix these)

An *app* can be in many groups; an *item* is in exactly **one** (`kSecAttrAccessGroup`).

[apple-share]: https://developer.apple.com/documentation/Security/sharing-access-to-keychain-items-among-a-collection-of-apps

| Mechanism | iOS | macOS | Notes |
|---|---|---|---|
| **App ID** (implicit, no capability) | ✅ default group | ✅ | Private to the one app. This is what `.default` resolves to today. |
| **Keychain Sharing** capability (`keychain-access-groups`) | ✅ | ✅ **the portable choice** | Team-ID prefixed by Xcode. First entry becomes the app's default group. |
| **App Groups** (`com.apple.security.application-groups`) | ✅ since iOS 8 | ⚠️ **only the registered `group.*` form** | macOS also allows an unregistered `<teamID>.<name>` form, which does **not** act as a keychain group. swift-security marks `.appGroupID` `@available(macOS, unavailable)` for exactly this. |
| macOS data-protection keychain | n/a | **required** for any of the above | Access-group sharing applies to macOS items only when the query sets `kSecUseDataProtectionKeychain` (or `kSecAttrSynchronizable`). swift-security bakes it into **every** query — one less way to get macOS wrong. |
| Sandbox | n/a | group must be team-prefixed and in the signed entitlements | Missing entitlement ⇒ `errSecMissingEntitlement` ⇒ `SwiftSecurityError.missingEntitlement`. |

**A Swift package has no entitlements** — entitlements belong to signed executables. So the
package must take the access group as a *parameter* and never hardcode one. swift-security does
(`Keychain(accessGroup:)`), and so does `KeychainCredentialStore.keychain`. Nothing to design.

**`$(AppIdentifierPrefix)` is a build-setting placeholder** that expands *with a trailing dot*
inside `.entitlements`. The Swift side needs the bare team ID:
`.keychainGroup(teamID: "J42EP42PB2", nameID: "com.laconicman.offhook.shared")` → `"J42EP42PB2.com.laconicman.offhook.shared"`.

### 6.1 Practical upshot for Offhook and its test target

`OffhookTests` is a **hostless** `bundle.unit-test` (`project.yml` — no `host:`), so on the
simulator it runs in a generic test-runner app with **its own app ID and its own entitlements**.
It therefore *cannot* see Offhook's default-group items, and making it able to would mean adding
a Keychain Sharing capability to a generated test runner.

> **D-CRED-2.** Don't. The integration suite keeps its current credential source —
> `OFFHOOK_TEST_ACC<n>_*` env vars, then `../secrets/test-accounts.env` outside the repo
> (`Tests/TestAccounts.swift`). It is CI-friendly, needs no entitlements, and keeps test
> credentials out of the device keychain. Keychain is the **app's** persistence, not the tests'.

Sharing becomes real when a **PushKit / Notification Service extension** needs the same
credentials — an extension has its own app ID. At that point: enable Keychain Sharing on both
targets with a common group and switch `KeychainCredentialStore.keychain` to
`.keychainGroup(teamID:nameID:)`. One line, no redesign — which is the test that the shape above
is right.

---

## 7. Where it lives

Offhook is an **XcodeGen project, not an SPM package**; there is no local package for app code.

> **D-CRED-3.** `offhook/Sources/Credentials/KeychainCredentialStore.swift`, in the app target.
> Add `.package(url: "https://github.com/dm-zharov/swift-security", from: "2.0.0")` to
> `project.yml`'s `packages:` and the product to the `Offhook` target only.
>
> **Not** a package, **not** a product in `swift-pjsua` (that boundary is decided), **not** its
> own repo. One consumer, one file — a package would be structure without a second client.
>
> **Promotion trigger:** the day a *second signed target* needs it (extension, macOS app, or a
> test target that stops using env vars), extract to a local `offhook/Packages/Credentials`
> package and add it to `packages:`. ~20 minutes, and the `CredentialStore` seam means nothing
> upstream changes.

---

## 8. Sequencing

1. Add the swift-security dependency to `project.yml`; write
   `Sources/Credentials/KeychainCredentialStore.swift` (§4). Closes **OH-6**.
2. Settings UI writes secrets via `store(_:for:)`; `@Credential` is acceptable for *ungated*
   display-only fields, but not for the engine path (§2.2).
3. Only if a real requirement appears: `BiometricGate` (§5.2) on user-initiated actions.
4. At any language-mode bump past Swift 6.2, re-read §4.1.
