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
    static let shared = GitHubAccount()

    enum State: Equatable {
        case disconnected
        case connecting
        case connected(login: String)
        /// The credential was refused — expired, revoked, or its access to a
        /// repository withdrawn. Distinct from disconnected because there is
        /// something to fix rather than something to set up.
        case expired(login: String?)
        case failed(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var expiry: Date?

    private static let keychainAccount = "github"
    private static let loginKey = "gitHubLogin"
    private static let expiryKey = "gitHubTokenExpiry"

    private init() {
        guard Keychain.get(Self.keychainAccount) != nil,
              let login = UserDefaults.standard.string(forKey: Self.loginKey)
        else { return }
        state = .connected(login: login)
        expiry = UserDefaults.standard.object(forKey: Self.expiryKey) as? Date
        // A token whose stated expiry has passed is known-bad before any
        // request is made; say so rather than letting the first fetch fail.
        if let expiry, expiry < Date() {
            state = .expired(login: login)
        }
    }

    /// nil when nothing is connected — the stores then read anonymously,
    /// which still works for public repositories.
    var token: String? {
        guard case .connected = state else { return nil }
        return Keychain.get(Self.keychainAccount)
    }

    /// Verifies a credential before storing it, so a mistyped or already
    /// expired token fails here with a clear message rather than silently
    /// working for browsing and then refusing the first save.
    func connect(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .connecting
        do {
            let (login, expires) = try await Self.verify(token: trimmed)
            Keychain.set(trimmed, for: Self.keychainAccount)
            UserDefaults.standard.set(login, forKey: Self.loginKey)
            if let expires {
                UserDefaults.standard.set(expires, forKey: Self.expiryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.expiryKey)
            }
            expiry = expires
            state = .connected(login: login)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        Keychain.remove(Self.keychainAccount)
        UserDefaults.standard.removeObject(forKey: Self.loginKey)
        UserDefaults.standard.removeObject(forKey: Self.expiryKey)
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

        let (data, response) = try await URLSession.shared.data(for: request)
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
