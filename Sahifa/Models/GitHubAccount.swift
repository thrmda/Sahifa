import Foundation

/// The signed-in GitHub account, shared by every repository added.
///
/// Fine-grained tokens are already scoped by GitHub to particular
/// repositories, so scoping them again per source here would be duplicate
/// bookkeeping with nothing gained.
///
/// The credential itself lives in the Keychain; what's kept in preferences is
/// only what the Settings pane needs to show — who is connected and when it
/// expires. Connecting is deliberately a single call: today it takes a token
/// the user pasted, and a sign-in flow later replaces how the token is
/// obtained without changing anything downstream.
@MainActor
final class GitHubAccount: ObservableObject {
    static let shared = GitHubAccount(
        keychainAccount: "github",
        loginKey: "gitHubLogin",
        expiryKey: "gitHubTokenExpiry")

    enum State: Equatable {
        case disconnected
        case connecting
        /// The login name is optional: the credential is what decides whether
        /// an account is connected, and the name is only there to display. If
        /// the two ever disagree, the credential wins.
        case connected(login: String?)
        /// The credential was refused — expired, revoked, or its access to a
        /// repository withdrawn. Distinct from disconnected because there is
        /// something to fix rather than something to set up.
        case expired(login: String?)
        case failed(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var expiry: Date?

    private let keychainAccount: String
    private let loginKey: String
    private let expiryKey: String
    /// The stored credential, read from the Keychain once. Every sidebar row
    /// asks whether its source is writable, and each of those used to be a
    /// Keychain query of its own.
    private var storedToken: String?

    /// Names are injected rather than hard-coded so a test can operate on a
    /// throwaway credential. The keychain is shared with every process running
    /// as this user, so a test that reached for the real account name would
    /// delete the account a real user is signed in to — which is exactly what
    /// happened once.
    init(keychainAccount: String, loginKey: String, expiryKey: String) {
        self.keychainAccount = keychainAccount
        self.loginKey = loginKey
        self.expiryKey = expiryKey
        storedToken = Keychain.get(keychainAccount)
        guard storedToken != nil else { return }
        let login = UserDefaults.standard.string(forKey: loginKey)
        state = .connected(login: login)
        expiry = UserDefaults.standard.object(forKey: expiryKey) as? Date
        // A token whose stated expiry has passed is known-bad before any
        // request is made; say so rather than letting the first fetch fail.
        if let expiry, expiry < Date() {
            state = .expired(login: login)
        }
    }

    /// True when this instance points at the names the app itself uses. Tests
    /// assert the negative: a test binary that read or wrote the real item
    /// would sign a real user out, and would make macOS prompt for the
    /// keychain password on every run.
    var describesProductionCredential: Bool {
        keychainAccount == "github"
    }

    /// nil when nothing is connected — the stores then read anonymously,
    /// which still works for public repositories.
    var token: String? {
        guard case .connected = state else { return nil }
        return storedToken
    }

    /// A credential is kept, whatever state it's in. An expired or refused one
    /// still has to be removable, or it comes back as connected next launch.
    var hasStoredCredential: Bool { storedToken != nil }

    /// Verifies a credential before storing it, so a mistyped or already
    /// expired token fails here with a clear message rather than silently
    /// working for browsing and then refusing the first save.
    func connect(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A mistyped token pasted while signed in used to leave the account
        // "failed" with the good token still in the Keychain: every
        // repository read-only until relaunch, when it came back connected.
        // The working credential stays; the failure is reported beside it.
        let previous = state
        let attempt = connectAttempt + 1
        connectAttempt = attempt
        connectError = nil
        state = .connecting
        do {
            let (login, expires) = try await Self.verify(token: trimmed)
            // Disconnected (or connected again) while this was out.
            guard attempt == connectAttempt else { return }
            guard Keychain.set(trimmed, for: keychainAccount) else {
                let reason = String(localized:
                    "The token couldn't be saved to your Keychain, so it wasn't kept.")
                connectError = reason
                state = Self.keeps(previous) ? previous : .failed(reason)
                return
            }
            storedToken = trimmed
            UserDefaults.standard.set(login, forKey: loginKey)
            if let expires {
                UserDefaults.standard.set(expires, forKey: expiryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: expiryKey)
            }
            expiry = expires
            state = .connected(login: login)
        } catch {
            guard attempt == connectAttempt else { return }
            connectError = error.localizedDescription
            state = Self.keeps(previous) ? previous : .failed(error.localizedDescription)
        }
    }

    /// Whether a failed attempt should leave the account as it was: a
    /// credential that still works is worth more than news about one that
    /// doesn't.
    private static func keeps(_ state: State) -> Bool {
        if case .connected = state { return true }
        return false
    }

    /// Why the last connect attempt failed, when the account stayed as it was.
    @Published private(set) var connectError: String?
    private var connectAttempt = 0

    func disconnect() {
        connectAttempt += 1
        connectError = nil
        Keychain.remove(keychainAccount)
        storedToken = nil
        UserDefaults.standard.removeObject(forKey: loginKey)
        UserDefaults.standard.removeObject(forKey: expiryKey)
        expiry = nil
        state = .disconnected
    }

    /// Called when a request comes back refused, so the sidebar can show that
    /// the account needs attention rather than the failure only surfacing on
    /// whichever folder happened to be open.
    func markRefused() {
        switch state {
        case .connected(let login): state = .expired(login: login)
        default: break
        }
    }

    private static func verify(token: String) async throws -> (login: String, expiry: Date?) {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 30

        let (data, response) = try await GitHubStore.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteStoreError.server(status: 0)
        }
        guard http.statusCode != 401 else { throw RemoteStoreError.notAuthorised }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteStoreError.server(status: http.statusCode)
        }
        struct User: Decodable { let login: String }
        let user = try JSONDecoder().decode(User.self, from: data)

        // Fine-grained tokens report their own expiry in a header; classic
        // ones don't, and simply have none to show.
        var expiry: Date?
        if let raw = http.value(forHTTPHeaderField: "github-authentication-token-expiration") {
            expiry = Self.expiryFormatter.date(from: raw)
                ?? ISO8601DateFormatter().date(from: raw)
        }
        return (user.login, expiry)
    }

    /// The header's format, e.g. "2026-08-20 12:00:00 UTC".
    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter
    }()
}
