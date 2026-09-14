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
    /// back rather than leave a menu-bar-only app — but only then. Answering
    /// `true` unconditionally let AppKit add a second window on every reopen,
    /// including a plain `open -a` while a window was already up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // `hasVisibleWindows` is not trustworthy here: AppKit reports true for
        // an app whose only window is miniaturized, which would leave a Dock
        // click doing nothing at all. Work it out from the windows themselves.
        if sender.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) {
            return false
        }
        // Nothing on screen but something in the Dock: restoring that is
        // plainly what the click meant, rather than a fresh window beside it.
        if let miniaturized = sender.windows.first(where: \.isMiniaturized) {
            miniaturized.deminiaturize(nil)
            return false
        }
        return true
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
        // One tab concept only. The app has its own in-window document tabs, so
        // turn off macOS's native window-tabbing — no "Show Tab Bar" / "Merge
        // All Windows", and new windows never merge into a title-bar tab group.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .applyUILanguage(uiLanguage)
                .frame(minWidth: 760, minHeight: 460)
        }
        // Opening a file from Finder used to produce a stray SECOND window: a
        // WindowGroup spawns a fresh one for every external open event, on top
        // of the tab AppDelegate.application(_:open:) had already added to the
        // window in front. Matching nothing stops that and leaves the delegate
        // as the single route in — it opens a window itself when none exists.
        .handlesExternalEvents(matching: [])
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
            // An in-window tab, not a native window-tab: a fresh blank tab in
            // the current window (same as the tab bar's +). Pick a file into it
            // from the sidebar, or ⌘O to open one.
            Button("New Tab") { windowState?.newBlankTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(windowState == nil)
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
        // SwiftUI puts Close (⌘W) and Close All (⌥⌘W) in .saveItem, immediately
        // before the app's own Save. Replacing the whole group is the only way
        // to take ⌘W off "close the window" — so Save is re-added here rather
        // than in a group of its own.
        CommandGroup(replacing: .saveItem) {
            // Browser-style: ⌘W closes the active tab, and closing the last tab
            // closes the window rather than leaving an empty one behind.
            // Never disabled: replacing .saveItem also removed the system Close
            // item, so a window with no tabs to close — Settings, most of all —
            // would be left with a dead ⌘W. Anything without a focused
            // WindowState closes the window instead.
            Button("Close Tab") {
                guard let windowState, let active = windowState.selection else {
                    NSApp.keyWindow?.performClose(nil)
                    return
                }
                windowState.closeTab(active)
                if windowState.openTabs.isEmpty {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Close All") {
                for window in NSApp.windows where window.isVisible {
                    window.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            Divider()
            Button("Save") { model.saveAll() }
                .keyboardShortcut("s", modifiers: .command)
            Divider()
            Button("Export as HTML…") {
                if let document = windowState?.document {
                    Exporter.shared.exportHTML(text: document.text, kind: document.kind,
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
            // A wide table would be cut off at the edge of an A4 page, so
            // tables export as HTML only.
            .disabled(windowState?.document == nil || windowState?.document?.kind.isTable == true)
        }
        CommandGroup(after: .sidebar) {
            Button(windowState?.sidebarVisible == true ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation { windowState?.sidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(windowState == nil)
            // Radio group (inline picker → checkmarked items) so the menu
            // shows which layout is current, not just a single on/off toggle.
            // ⇧⌘P advances through the three, keeping the old preview shortcut.
            Picker("View", selection: Binding(
                get: { windowState?.activeViewMode ?? .editOnly },
                set: { windowState?.activeViewMode = $0 }
            )) {
                Text("Edit Only").tag(ViewMode.editOnly)
                Text("Dual View").tag(ViewMode.split)
                Text("View Only").tag(ViewMode.previewOnly)
            }
            .pickerStyle(.inline)
            .disabled(windowState == nil)
            Button("Cycle View") {
                if let windowState {
                    let modes = ViewMode.allCases
                    let next = (modes.firstIndex(of: windowState.activeViewMode)! + 1) % modes.count
                    windowState.activeViewMode = modes[next]
                }
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
            // Every item here works on Markdown source. In a CSV file it would
            // only put markup into the data, so the group is off there.
            Group {
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
                Divider()
                Button("Paste as Table") { send(#selector(BidiTextView.sahifaPasteAsTable(_:))) }
                Button("Convert Selection to Table") {
                    send(#selector(BidiTextView.sahifaConvertSelectionToTable(_:)))
                }
                Button("Copy Table as CSV") { send(#selector(BidiTextView.sahifaCopyTableAsCSV(_:))) }
            }
            .disabled(windowState?.document?.kind.isTable == true)
            Divider()
            // The whole file, and straight from the document rather than
            // through the editor: View Only, where a table opens, has none.
            Button("Copy as Markdown Table") {
                guard let document = windowState?.document, document.kind.isTable else { return }
                let rows = DelimitedText(parsing: document.text, kind: document.kind).rows
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MarkdownTable.markdown(from: rows), forType: .string)
            }
            .disabled(windowState?.document?.kind.isTable != true)
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
    return "\(item.name) - \(item.parentName)"
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
