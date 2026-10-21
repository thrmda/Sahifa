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
        var entry = ""
        var problem: String?
        // Asks again, keeping what was typed, until it names a repository or
        // the user cancels: an Add that silently did nothing read as broken.
        while true {
            let alert = NSAlert()
            alert.messageText = String(localized: "Add a GitHub Repository")
            alert.informativeText = problem ?? String(localized:
                "Enter it as owner/repository, or paste its address - for example apple/swift-markdown. Public repositories can be read without signing in; connect an account in Settings to save changes.")
            alert.addButton(withTitle: String(localized: "Add"))
            alert.addButton(withTitle: String(localized: "Cancel"))

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = "owner/repository"
            field.stringValue = entry
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            entry = field.stringValue
            if let repository = GitHubStore.parseRepository(entry) {
                model.addRepository(owner: repository.owner, name: repository.name, branch: nil)
                return
            }
            problem = String(localized:
                "That isn't a repository name. Enter it as owner/repository, for example apple/swift-markdown.")
        }
    }
}
