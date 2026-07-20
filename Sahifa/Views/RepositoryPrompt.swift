import AppKit

/// Asks for a repository to add.
///
/// A plain alert rather than a Settings pane: adding a repository is one line
/// of text, and step 1 reads public repositories anonymously, so there is
/// nothing to configure yet. When signing in arrives this becomes the natural
/// place to grow — or the point at which it earns a real sheet.
@MainActor
enum RepositoryPrompt {
    static func show(_ model: AppModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Add a GitHub Repository")
        alert.informativeText = String(localized:
            "Enter it as owner/repository — for example apple/swift-markdown. Public repositories can be read without signing in; the files are opened read-only.")
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "owner/repository"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Accept a pasted URL as readily as the short form.
        var entry = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"]
        where entry.hasPrefix(prefix) {
            entry = String(entry.dropFirst(prefix.count))
        }
        if entry.hasSuffix(".git") { entry = String(entry.dropLast(4)) }

        let parts = entry.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return }
        model.addRepository(owner: parts[0], name: parts[1], branch: nil)
    }
}
