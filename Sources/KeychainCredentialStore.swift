import Foundation
import SwiftPJSUA
import SwiftSecurity

/// Reads SIP digest secrets from the Keychain, behind ``CredentialStore``.
///
/// - Important: items are stored **ungated** (`AccessPolicy.default` =
///   `.afterFirstUnlock`, no `options`) — D-CRED-1 in `docs/Credentials.md`. The engine
///   re-fetches on `reRegister`, which can run from a PushKit wake-up with the device
///   locked; a `.userPresence` item would be unreadable there. Biometry gating, if ever
///   wanted, belongs on a user-initiated settings action — never on this fetch path.
struct KeychainCredentialStore: CredentialStore {
    /// `.default` = this app's own access group. Pass `.keychainGroup(...)` to share with
    /// another signed target — `docs/Credentials.md` §6.
    var keychain: Keychain = .default

    /// `kSecAttrService` namespace, so SIP secrets can't collide with other app secrets.
    var service: String = "com.laconicman.offhook.sip"

    /// The engine's fetch — synchronous Keychain read inside an `async` witness (D-CRED-4:
    /// the absence of a suspension point inside is the safety property).
    func secret(for request: CredentialRequest) async throws -> String {
        // The query is built locally and never stored or sent — `SecItemQuery` is only
        // conditionally Sendable over its `[String: Any]` box (Credentials.md §2.1).
        var query = SecItemQuery<GenericPassword>()
        query.service = service
        query.account = Self.key(for: request)

        guard let secret: String = try keychain.retrieve(query, authenticationContext: nil)
        else {
            throw CredentialError.notFound(request)
        }
        return secret
    }

    /// App-side write — `CredentialStore` has no store requirement; the engine only reads.
    /// Called when the user saves an account.
    func store(_ secret: String, for request: CredentialRequest) throws {
        var query = SecItemQuery<GenericPassword>()
        query.service = service
        query.account = Self.key(for: request)
        _ = try? keychain.remove(query)  // SecItemAdd fails on duplicates
        try keychain.store(secret, query: query, accessPolicy: .default)
    }

    /// App-side delete — called when a saved account is removed.
    func removeSecret(for request: CredentialRequest) throws {
        var query = SecItemQuery<GenericPassword>()
        query.service = service
        query.account = Self.key(for: request)
        _ = try keychain.remove(query)
    }

    /// One item per (AOR, user, realm): the same user may hold different secrets per realm,
    /// and `realm` defaults to the wildcard `"*"` in `AccountConfiguration`.
    static func key(for request: CredentialRequest) -> String {
        "\(request.accountID)|\(request.username)|\(request.realm)"
    }
}

enum CredentialError: Error, LocalizedError {
    /// `CredentialRequest` carries no secret — safe to log.
    case notFound(CredentialRequest)

    var errorDescription: String? {
        switch self {
        case let .notFound(request):
            "no Keychain secret for \(request.accountID) (realm \(request.realm))"
        }
    }
}
