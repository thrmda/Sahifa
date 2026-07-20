import SwiftUI
import AppKit

/// The connected GitHub account. One button whose meaning changes with the
/// state — connecting today means pasting a token, and a browser sign-in
/// later replaces only what happens behind it.
private struct GitHubAccountRow: View {
    @ObservedObject private var account = GitHubAccount.shared
    @State private var showingConnect = false

    var body: some View {
        LabeledContent {
            switch account.state {
            case .connecting:
                ProgressView().controlSize(.small)
            case .connected:
                Button("Disconnect") { account.disconnect() }
            case .disconnected, .failed:
                Button("Connect…") { showingConnect = true }
            case .expired:
                Button("Reconnect…") { showingConnect = true }
            }
        } label: {
            Text(verbatim: "GitHub")
            summary
        }
        .sheet(isPresented: $showingConnect) {
            GitHubConnectSheet(account: account)
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch account.state {
        case .disconnected:
            Text("Not connected. Public repositories can still be read.")
        case .connecting:
            Text("Checking…")
        case .connected(let login):
            // The name is optional — the credential is what decides whether an
            // account is connected — so each combination gets its own sentence
            // rather than interpolating an optional into one.
            switch (login, account.expiry) {
            case (.some(let name), .some(let expiry)):
                Text("Connected as \(name) · expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
            case (.some(let name), .none):
                Text("Connected as \(name)")
            case (.none, .some(let expiry)):
                Text("Connected · expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
            case (.none, .none):
                Text("Connected")
            }
        case .expired(let login):
            if let login {
                Text("\(login) no longer has access. Reconnect to keep saving.")
                    .foregroundStyle(Color.gold)
            } else {
                Text("The token no longer has access. Reconnect to keep saving.")
                    .foregroundStyle(Color.gold)
            }
        case .failed(let reason):
            Text(verbatim: reason).foregroundStyle(Color.gold)
        }
    }
}

/// Pasting a token is the temporary shape of connecting. The sheet says
/// exactly what to create so nobody grants more access than is needed.
private struct GitHubConnectSheet: View {
    @ObservedObject var account: GitHubAccount
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    private var isChecking: Bool {
        if case .connecting = account.state { return true }
        return false
    }

    private static let tokenPage =
        URL(string: "https://github.com/settings/personal-access-tokens/new")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect GitHub")
                .font(.headline)
            Text("Create a fine-grained token limited to the repositories you want Sahifa to reach, with Contents set to Read and write. Give it a short expiry — you can always make another.")
                .foregroundStyle(Color.slate)
                .fixedSize(horizontal: false, vertical: true)
            Link("Create a token on GitHub…", destination: Self.tokenPage)
            SecureField("Paste the token here", text: $token)
                .textFieldStyle(.roundedBorder)
                .disabled(isChecking)
            if case .failed(let reason) = account.state {
                Text(verbatim: reason)
                    .foregroundStyle(Color.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text("The token is kept in your Mac's Keychain.")
                    .font(.footnote)
                    .foregroundStyle(Color.slate)
                Spacer(minLength: 12)
                // Checking the token is a network round trip. Without this the
                // sheet just sits there after the click, which reads as the
                // button not having worked.
                if isChecking {
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                        .font(.footnote)
                        .foregroundStyle(Color.slate)
                }
                Button("Cancel") { dismiss() }
                    .disabled(isChecking)
                Button("Connect") {
                    Task {
                        await account.connect(token: token)
                        if case .connected = account.state { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.sage)
                .disabled(isChecking
                          || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// A macOS `Slider` is backed by NSSlider, whose track fill/min side follows
/// the *process* UI direction (set at launch from AppleLanguages), not the
/// SwiftUI environment. When the language is overridden in-app without a
/// matching launch language ("env-only RTL"), the slider stays LTR while the
/// rest of the chrome mirrors. Flip it horizontally exactly when the two
/// disagree — the transform also mirrors hit-testing, so dragging stays
/// consistent with what's drawn. When env and process agree (the normal case,
/// including a genuine RTL launch) nothing is flipped.
private struct MatchSliderToChromeDirection: ViewModifier {
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        let environmentRTL = layoutDirection == .rightToLeft
        let processRTL = NSApplication.shared.userInterfaceLayoutDirection == .rightToLeft
        if environmentRTL != processRTL {
            content.scaleEffect(x: -1, y: 1, anchor: .center)
        } else {
            content
        }
    }
}

private extension View {
    func matchSliderToChromeDirection() -> some View {
        modifier(MatchSliderToChromeDirection())
    }
}

struct SettingsView: View {
    @AppStorage("uiLanguage") private var uiLanguage = "system"
    @AppStorage("editorFontSize") private var fontSize = 16.0
    @AppStorage("editorLineSpacing") private var lineSpacing = 1.4

    var body: some View {
        Form {
            Section("Accounts") {
                GitHubAccountRow()
            }
            Section("General") {
                Picker("Language", selection: $uiLanguage) {
                    Text("System").tag("system")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "العربية").tag("ar")
                }
                Text("Language changes fully apply after relaunching Sahifa.")
                    .font(.footnote)
                    .foregroundStyle(Color.slate)
            }
            Section("Editor") {
                LabeledContent {
                    Slider(value: $fontSize, in: 12...24, step: 1)
                        .matchSliderToChromeDirection()
                } label: {
                    Text("Font Size")
                    Text(verbatim: "\(Int(fontSize)) pt")
                }
                LabeledContent {
                    Slider(value: $lineSpacing, in: 1.0...2.0, step: 0.05)
                        .matchSliderToChromeDirection()
                } label: {
                    Text("Line Spacing")
                    Text(verbatim: String(format: "%.2f×", lineSpacing))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: uiLanguage) { _, newValue in
            // The main menu is built by AppKit from the launch language;
            // persist the choice so it follows on relaunch.
            if newValue == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            }
        }
    }
}
