import AppKit
import SwiftUI

/// Finder integration. SwiftUI's `WindowGroup` has no hook for "the user
/// double-clicked a file" / "Open With" / a Dock-icon drop — those arrive as
/// AppKit delegate callbacks, so the app keeps a delegate purely to forward
/// them to AppModel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppModel.shared.openExternal(urls)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Reopening from the Dock with all windows closed should bring a window
    /// back rather than leave a menu-bar-only app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }

    /// A local save finishes before the app can quit anyway. A save going over
    /// a network does not, so quitting waits for it rather than dropping the
    /// last thing typed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppModel.shared.hasPendingSaves else { return .terminateNow }
            Task {
                await AppModel.shared.flushAll()
                // A local save always lands, so anything still unsaved here is a
                // remote save that couldn't reach the server. Quitting would
                // drop it, so ask rather than lose work silently.
                let stranded = AppModel.shared.documentsWithUnsavedChanges
                let reply = stranded.isEmpty || Self.confirmQuitWithUnsaved(stranded)
                NSApp.reply(toApplicationShouldTerminate: reply)
            }
            return .terminateLater
        }
    }

    @MainActor
    private static func confirmQuitWithUnsaved(_ documents: [DocumentModel]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let names = documents.map(\.displayName).joined(separator: ", ")
        alert.messageText = documents.count == 1
            ? String(localized: "“\(names)” has unsaved changes that couldn't be saved.")
            : String(localized: "\(documents.count) documents have unsaved changes that couldn't be saved.")
        alert.informativeText = String(localized:
            "The server couldn't be reached. If you quit now, these changes are lost.")
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        alert.addButton(withTitle: String(localized: "Don't Quit"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@main
struct SahifaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @AppStorage("uiLanguage") private var uiLanguage = "system"

    init() {
        FontLibrary.registerBundledFontsIfNeeded()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .applyUILanguage(uiLanguage)
                .frame(minWidth: 760, minHeight: 460)
        }
        .commands {
            SahifaCommands(model: model)
        }

        Settings {
            SettingsView()
                .applyUILanguage(uiLanguage)
        }
    }
}

/// App menus. File/document actions target the focused window's state so
/// every window (or tab) behaves independently.
struct SahifaCommands: Commands {
    // Observed, not just held: the Open Recent menu has to rebuild as the
    // list changes.
    @ObservedObject var model: AppModel
    @FocusedObject private var windowState: WindowState?
    @Environment(\.openWindow) private var openWindow
    @AppStorage("focusMode") private var focusMode = false
    @AppStorage("showFormatBar") private var showFormatBar = true

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New File") {
                Task {
                    if let id = await model.newFile(in: windowState?.newFileTarget) {
                        windowState?.selection = id
                    }
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!model.canCreateFiles)
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Tab") { WindowTabbing.openAsTab { openWindow(id: "main") } }
                .keyboardShortcut("t", modifiers: .command)
            Divider()
            Button("Open File…") { model.chooseFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Add Folder…") { model.chooseFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Add GitHub Repository…") { RepositoryPrompt.show(model) }
            Menu("Open Recent") {
                ForEach(model.recentFolders) { item in
                    Button(recentLabel(item, among: model.recentFolders)) {
                        model.openRecent(item)
                    }
                }
                if !model.recentFolders.isEmpty && !model.recentFiles.isEmpty {
                    Divider()
                }
                ForEach(model.recentFiles) { item in
                    Button(recentLabel(item, among: model.recentFiles)) {
                        model.openRecent(item)
                    }
                }
                Divider()
                Button("Clear Menu") { model.clearRecents() }
            }
            .disabled(model.recentItems.isEmpty)
        }
        CommandGroup(after: .saveItem) {
            Button("Save") { model.saveAll() }
                .keyboardShortcut("s", modifiers: .command)
            Divider()
            Button("Export as HTML…") {
                if let document = windowState?.document {
                    Exporter.shared.exportHTML(markdown: document.text,
                                               suggestedName: document.exportName)
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(windowState?.document == nil)
            Button("Export as PDF…") {
                if let document = windowState?.document {
                    Exporter.shared.exportPDF(markdown: document.text,
                                              suggestedName: document.exportName)
                }
            }
            .disabled(windowState?.document == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(windowState?.sidebarVisible == true ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation { windowState?.sidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(windowState == nil)
            Button(windowState?.showPreview == true ? "Hide Preview" : "Show Preview") {
                windowState?.showPreview.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(windowState == nil)
            Button(focusMode ? "Exit Focus Mode" : "Focus Mode") {
                focusMode.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Button(showFormatBar ? "Hide Format Bar" : "Show Format Bar") {
                showFormatBar.toggle()
            }
        }
        CommandMenu("Format") {
            Button("Bold") { send(#selector(BidiTextView.sahifaToggleBold(_:))) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { send(#selector(BidiTextView.sahifaToggleItalic(_:))) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Strikethrough") { send(#selector(BidiTextView.sahifaToggleStrikethrough(_:))) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Divider()
            Button("Heading 1") { send(#selector(BidiTextView.sahifaHeading1(_:))) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Heading 2") { send(#selector(BidiTextView.sahifaHeading2(_:))) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Heading 3") { send(#selector(BidiTextView.sahifaHeading3(_:))) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Heading 4") { send(#selector(BidiTextView.sahifaHeading4(_:))) }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Bulleted List") { send(#selector(BidiTextView.sahifaToggleBulletList(_:))) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Numbered List") { send(#selector(BidiTextView.sahifaToggleNumberedList(_:))) }
                .keyboardShortcut("7", modifiers: [.command, .shift])
            Button("Quote") { send(#selector(BidiTextView.sahifaToggleQuote(_:))) }
            Divider()
            Button("Inline Code") { send(#selector(BidiTextView.sahifaToggleInlineCode(_:))) }
                .keyboardShortcut("e", modifiers: .command)
            Button("Code Block") { send(#selector(BidiTextView.sahifaInsertCodeBlock(_:))) }
            Divider()
            Button("Link") { send(#selector(BidiTextView.sahifaInsertLink(_:))) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Image") { send(#selector(BidiTextView.sahifaInsertImage(_:))) }
            Button("Horizontal Rule") { send(#selector(BidiTextView.sahifaInsertHorizontalRule(_:))) }
            Button("Table") { send(#selector(BidiTextView.sahifaInsertTable(_:))) }
        }
    }
}

/// Sends a formatting selector down the responder chain to the focused editor.
private func send(_ selector: Selector) {
    NSApp.sendAction(selector, to: nil, from: nil)
}

/// Menu title for a recent item: its own name, qualified by the enclosing
/// folder only when that name appears more than once — two files both called
/// `notes.md` are otherwise indistinguishable.
private func recentLabel(_ item: AppModel.RecentItem,
                         among items: [AppModel.RecentItem]) -> String {
    guard items.filter({ $0.name == item.name }).count > 1 else { return item.name }
    return "\(item.name) — \(item.parentName)"
}

extension View {
    /// APP CHROME direction and language. Follows the system by default; an
    /// explicit in-app override applies live to all SwiftUI chrome (the main
    /// menu follows on next launch, via AppleLanguages). Document content
    /// direction is per-paragraph and entirely independent of this.
    @ViewBuilder
    func applyUILanguage(_ language: String) -> some View {
        switch language {
        case "en":
            self
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.layoutDirection, .leftToRight)
        case "ar":
            self
                .environment(\.locale, Locale(identifier: "ar"))
                .environment(\.layoutDirection, .rightToLeft)
        default:
            self
        }
    }
}
