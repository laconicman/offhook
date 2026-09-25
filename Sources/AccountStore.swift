import Foundation
import SwiftPJSUA

/// A SIP account the user has saved — everything **except** the secret, which lives in the
/// Keychain under ``KeychainCredentialStore``'s `(AOR|username|realm)` key. Codable so the
/// list survives app restarts; the password never touches this file.
struct SavedAccount: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Address of record, `sip:user@domain` — also the `AccountConfiguration.id`.
    var aor: String
    /// Registrar URI as the user typed it, `sip:host[;transport=…]` — kept verbatim because
    /// URI parameters carry meaning (TCP upgrade, TLS) that a rebuilt host would drop.
    var registrar: String
    var username: String
    /// Digest realm — `"*"` matches whatever the server challenges with.
    var realm = "*"

    /// The key the Keychain item is stored under — must mirror
    /// ``KeychainCredentialStore/key(for:)`` so the engine's fetch finds what we wrote.
    var credentialRequest: CredentialRequest {
        CredentialRequest(accountID: aor, username: username, realm: realm)
    }
}

/// Persisted list of ``SavedAccount``s — a JSON document in the app's container.
///
/// Deliberately dumb: load once at launch, write-through on every mutation, keep everything
/// in memory. The list is a dozen records at most; a database would be structure without a
/// second access pattern. The file is not a credential store — it holds no secrets.
struct AccountStore {

    private(set) var accounts: [SavedAccount] = []
    private let url: URL

    init(url: URL = AccountStore.defaultURL) {
        self.url = url
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([SavedAccount].self, from: data)
        else { return } // absent or unreadable file → empty store, not an error
        accounts = loaded
    }

    /// Replace-or-append by AOR — re-saving an account updates its fields in place.
    /// Persist first, commit second: a failed write must not leave an in-memory row that a
    /// later successful persist would silently write (or a removal that resurrects on the
    /// next save).
    mutating func save(_ account: SavedAccount) throws {
        var updated = accounts
        if let index = updated.firstIndex(where: { $0.aor == account.aor }) {
            var stored = account
            stored.id = updated[index].id // keep the stored identity — stable for the UI
            updated[index] = stored
        } else {
            updated.append(account)
        }
        try persist(updated)
        accounts = updated
    }

    mutating func remove(_ account: SavedAccount) throws {
        var updated = accounts
        updated.removeAll { $0.id == account.id }
        try persist(updated)
        accounts = updated
    }

    private func persist(_ accounts: [SavedAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        try data.write(to: url, options: .atomic)
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("accounts.json")
    }
}
