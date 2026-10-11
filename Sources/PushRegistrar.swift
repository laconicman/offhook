import Foundation
import PushKit
import SwiftPJSUAKit

/// Offhook's `PKPushRegistry` (the app owns it; SwiftPJSUAKit design §1).
///
/// A VoIP push goes to the Kit's ``VoIPPushHandler`` first, which reports the call to CallKit as
/// iOS requires, and only then to `callReported`, so the model can wake the engine and let the
/// server hand over the INVITE it parked. Token changes reach `tokenChanged` as lower-case hex,
/// the form RFC 8599's `pn-prid` carries.
///
/// Create it at launch: when iOS starts the app for a VoIP push, the push waits for a registry
/// with a delegate and must be reported to CallKit as soon as it is delivered.
final class PushRegistrar: NSObject, PKPushRegistryDelegate {
    private let registry = PKPushRegistry(queue: .main)
    private let handler: VoIPPushHandler
    private let tokenChanged: @MainActor (String?) -> Void
    private let callReported: @MainActor () async -> Void

    init(handler: VoIPPushHandler,
         tokenChanged: @escaping @MainActor (String?) -> Void,
         callReported: @escaping @MainActor () async -> Void) {
        self.handler = handler
        self.tokenChanged = tokenChanged
        self.callReported = callReported
        super.init()
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    // The registry delivers on the main queue (`queue: .main` above).

    func pushRegistry(_ registry: PKPushRegistry,
                      didUpdate pushCredentials: PKPushCredentials,
                      for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated { tokenChanged(token) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated { tokenChanged(nil) }
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType) async {
        await handler.pushRegistry(registry, didReceiveIncomingPushWith: payload, for: type)
        await callReported()
    }
}
