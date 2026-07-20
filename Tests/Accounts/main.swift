import Foundation

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !condition { failures += 1 }
}

// MARK: Keychain round trip
//
// Uses a throwaway account name so a developer's real credential is never
// touched, and removes it again at the end.

let testAccount = "sahifa-accounts-test-\(getpid())"

do {
    check("nothing stored to begin with", Keychain.get(testAccount) == nil)

    Keychain.set("first-secret", for: testAccount)
    check("a secret can be stored and read back",
          Keychain.get(testAccount) == "first-secret",
          Keychain.get(testAccount) ?? "nil")

    // Reconnecting is the common case, and SecItemAdd refuses an existing
    // item — so replacing has to work, not just adding.
    Keychain.set("second-secret", for: testAccount)
    check("storing again replaces rather than fails",
          Keychain.get(testAccount) == "second-secret",
          Keychain.get(testAccount) ?? "nil")

    Keychain.remove(testAccount)
    check("removing clears it", Keychain.get(testAccount) == nil)
}

// MARK: Connecting with a credential GitHub refuses

func main() async {
    let account = await MainActor.run { GitHubAccount.shared }

    let before = await MainActor.run { account.token }
    check("no token is offered while disconnected", before == nil,
          before == nil ? "" : "a token was returned")

    await account.connect(token: "ghp_ThisTokenIsNotRealAndMustBeRefused")
    let state = await MainActor.run { account.state }
    if case .failed(let reason) = state {
        check("a refused token fails at connect time, with a reason", !reason.isEmpty, reason)
    } else if case .disconnected = state {
        check("a refused token fails at connect time", false, "silently ignored")
    } else {
        check("a refused token is not treated as connected", false,
              String(describing: state))
    }

    let after = await MainActor.run { account.token }
    check("…and nothing is stored for it", after == nil)

    await MainActor.run {
        // Whitespace-only input shouldn't even reach the network.
        account.disconnect()
        check("disconnect leaves nothing behind", account.token == nil)
    }
}

await main()
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
