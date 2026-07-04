# Offhook — Roadmap

Priority-ordered milestone summary. Rationale lives in [Design](./Design.md); debt that each
milestone discharges is in [Tech-Debt](./Tech-Debt.md).

## Now — Phase 0 smoke test

Prove the stack runs end-to-end before building breadth:
start → register → echo call → **hear audio**, driven directly by `PhoneModel` with manual
`AVAudioSession` activation. Green run validates the `SerialExecutor`/one-thread model, the
callback bridge, registration parsing, and the media → `pjsua_conf_connect` audio wiring.
See the smoke procedure in [README](../README.md) and endpoints in
[SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md).

## Next — CallKit / PushKit

- **CallKit outgoing + incoming** via `SwiftPJSUAKit` (`CallKitController` + `CallSessionRouter`).
  The router becomes the **sole** `engine.events` consumer, replacing `PhoneModel`'s event loop
  and the Phase-0 `AudioSession` (discharges [OH-1](./Tech-Debt.md), [OH-2](./Tech-Debt.md),
  [OH-3](./Tech-Debt.md)).
- **PushKit / hybrid VoIP push** (RFC 8599) — persisted-connection + push with no double ring.
  End-to-end push needs a self-hosted Flexisip/OpenSIPS with our APNs key
  ([SIP-Test-Infrastructure](./SIP-Test-Infrastructure.md) §3).

## Later — debug tooling & the Swiss-knife

- **Debug / SIP tooling UI** — raw event stream, conference-slot inspector, live SIP log.
- **Feature demos** — hold, parallel calls, local-mix and server-focus conference, video.
- **Swiss-knife settings** — STUN/DNS/codec configuration (gated on `swift-pjsua` TD-14 exposing
  the STUN/ICE surface; see [OH-4](./Tech-Debt.md)).
- **Credential persistence** — Keychain-backed accounts ([OH-6](./Tech-Debt.md); `../Phone` has a
  reference Keychain implementation).

## See Also

- [Design](./Design.md) · [Tech-Debt](./Tech-Debt.md)
