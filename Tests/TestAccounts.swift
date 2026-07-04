import Foundation
import XCTest

/// One SIP test account resolved from `OFFHOOK_TEST_ACC<n>_AOR` / `_PASSWORD`
/// (+ optional `_REGISTRAR` override).
struct TestAccount {
    /// Full AOR, e.g. `"sip:offhook1@sip.linphone.org"`.
    let aor: String
    let password: String
    let username: String
    let domain: String
    /// Optional registrar URI override (e.g. `"sip:sip.linphone.org;transport=tcp"`) for
    /// server-specific transport needs; defaults to `"sip:<domain>"`.
    let registrarOverride: String?

    var registrar: String { registrarOverride ?? "sip:\(domain)" }

    /// The registrar override's transport param (e.g. `";transport=tcp"`), for appending to
    /// dial URIs that target this account's server. Explicit transport in the request URI is
    /// the reliable way to keep big INVITEs off UDP: pjsip's size-based UDP→TCP auto-switch
    /// does **not** re-resolve on a 407-authenticated resend (observed live — the resend
    /// reuses the already-resolved UDP destination and fragments). Empty for default UDP.
    var transportSuffix: String {
        guard let registrar = registrarOverride?.lowercased(),
              let range = registrar.range(of: ";transport=") else { return "" }
        return ";transport=" + registrar[range.upperBound...].prefix { $0.isLetter }
    }

    /// The AOR as a dial target, carrying the server's transport param.
    var dialURI: String { aor + transportSuffix }

    /// Parses `"sip:user@domain"`; returns `nil` for anything else.
    init?(aor: String, password: String, registrarOverride: String? = nil) {
        let stripped = aor.hasPrefix("sip:") ? String(aor.dropFirst(4)) : aor
        let parts = stripped.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        self.aor = aor.hasPrefix("sip:") ? aor : "sip:\(aor)"
        self.password = password
        self.username = String(parts[0])
        self.domain = String(parts[1])
        self.registrarOverride = registrarOverride
    }
}

/// Credential source for the integration suite. **Environment variables first** (CI-friendly;
/// `xcodebuild test TEST_RUNNER_OFFHOOK_TEST_ACC1_AOR=… …` forwards them to the runner), then
/// the local secrets file `../../secrets/test-accounts.env` — which lives **outside** the repo
/// tree, so credentials can never be committed. Same keys either way:
///
///     OFFHOOK_TEST_ACC1_AOR=sip:user@domain
///     OFFHOOK_TEST_ACC1_PASSWORD=…
///
/// Convention: ACC1 + ACC2 are a **same-domain pair** (loopback call tests route ACC1 → ACC2
/// through their shared registrar); ACC3+ are extra independent domains.
enum TestAccounts {
    static let all: [Int: TestAccount] = load()

    /// The account for slot `n`, or skip the test when it isn't configured.
    static func require(_ n: Int) throws -> TestAccount {
        guard let account = all[n] else {
            throw XCTSkip("test account ACC\(n) not configured (env vars or secrets file)")
        }
        return account
    }

    // MARK: loading

    private static func load() -> [Int: TestAccount] {
        let env = ProcessInfo.processInfo.environment
        let file = loadSecretsFile()
        func value(_ key: String) -> String? { env[key] ?? file[key] }

        var accounts: [Int: TestAccount] = [:]
        for n in 1...8 {
            guard let aor = value("OFFHOOK_TEST_ACC\(n)_AOR"),
                  let password = value("OFFHOOK_TEST_ACC\(n)_PASSWORD"),
                  let account = TestAccount(aor: aor, password: password,
                                            registrarOverride: value("OFFHOOK_TEST_ACC\(n)_REGISTRAR"))
            else { continue }
            accounts[n] = account
        }
        return accounts
    }

    /// `#filePath` = …/offhook/Tests/TestAccounts.swift → three levels up is the workspace
    /// root, whose `secrets/` holds the git-untracked credentials file.
    private static func loadSecretsFile() -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // offhook/
            .deletingLastPathComponent()   // workspace root
            .appendingPathComponent("secrets/test-accounts.env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
            values[key] = value
        }
        return values
    }
}
