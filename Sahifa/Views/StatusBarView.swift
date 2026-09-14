import SwiftUI

/// Live counts plus the view toggles: words and characters for prose, rows and
/// columns for a table.
///
/// Counting uses the system word enumerator (ICU-backed), which segments
/// Arabic correctly — no whitespace splitting. It walks the whole document,
/// so it runs off the main thread and settles shortly after typing stops
/// rather than on every keystroke: at 500k characters the walk costs ~33 ms,
/// twice a 60 Hz frame, and the editor is already restyling on that keystroke.
struct StatusBarView: View {
    let text: String
    var kind: DocumentKind = .markdown
    /// Shown only while a save is actually in flight. A local save finishes
    /// too fast to ever appear; one going over a network is worth seeing.
    var isSaving: Bool = false
    /// A save failed and is waiting to try again. The banner explains it; this
    /// is the quiet reminder once the banner has been read.
    var isRetrying: Bool = false
    @Binding var viewMode: ViewMode
    @AppStorage("focusMode") private var focusMode = false
    @AppStorage("showFormatBar") private var showFormatBar = true

    @EnvironmentObject private var windowState: WindowState
    @State private var counts: TextCounts?

    var body: some View {
        HStack(spacing: Space.l) {
            Button {
                withAnimation { windowState.sidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .help(Text("Toggle Sidebar"))
            .accessibilityLabel(Text("Toggle Sidebar"))
            .pointerCursor(.pointingHand)
            if kind.isTable {
                Text("Rows: \(counts?.rows ?? 0)")
                Text("Columns: \(counts?.columns ?? 0)")
            } else {
                Text("Words: \(counts?.words ?? 0)")
                Text("Characters: \(counts?.characters ?? 0)")
            }
            if isSaving {
                Text("Saving…")
            } else if isRetrying {
                Text("Save pending…")
                    .foregroundStyle(Color.warning)
            }
            Spacer(minLength: 0)
            // A table never shows the Format Bar, so a toggle for it would do
            // nothing visible.
            if !kind.isTable {
                Button {
                    showFormatBar.toggle()
                } label: {
                    // Not `textformat`/`textformat.alt` — both carry a letterform
                    // that localizes by process language and clashes with the
                    // chrome under an in-app language override. The pilcrow (¶) is
                    // a script-neutral formatting mark.
                    Image(systemName: "paragraphsign")
                        .foregroundStyle(showFormatBar ? Color.sage : Color.slate)
                }
                .buttonStyle(.borderless)
                .help(showFormatBar ? Text("Hide Format Bar") : Text("Show Format Bar"))
                .accessibilityLabel(showFormatBar ? Text("Hide Format Bar") : Text("Show Format Bar"))
                .pointerCursor(.pointingHand)
            }
            Button {
                focusMode.toggle()
            } label: {
                Image(systemName: focusMode ? "circle.circle.fill" : "circle.circle")
            }
            .buttonStyle(.borderless)
            .help(focusMode ? Text("Exit Focus Mode") : Text("Focus Mode"))
            .accessibilityLabel(focusMode ? Text("Exit Focus Mode") : Text("Focus Mode"))
            .pointerCursor(.pointingHand)
            // Three-way view control: editor only, both panes, preview only.
            // Grouped tighter than the surrounding items so it reads as one
            // segmented control, with the active segment tinted.
            HStack(spacing: Space.xs) {
                viewModeButton(.editOnly, "square.lefthalf.filled", Text("Edit Only"))
                viewModeButton(.split, "rectangle.split.2x1", Text("Dual View"))
                viewModeButton(.previewOnly, "eye", Text("View Only"))
            }
        }
        .font(Typography.caption)
        .foregroundStyle(Color.slate)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xxs)
        .background(Color.panel)
        // Restarts on every edit, so the sleep coalesces a burst of typing
        // into one count. The first count for a document skips the wait.
        .task(id: CountRequest(text: text, kind: kind)) {
            if counts != nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            let snapshot = text
            let kind = kind
            let computed = await Task.detached(priority: .utility) {
                TextCounts(snapshot, kind: kind)
            }.value
            guard !Task.isCancelled else { return }
            counts = computed
        }
    }

    /// One segment of the view-mode control. Selecting the active segment is a
    /// no-op; the tint (sage vs slate) shows which layout is current.
    private func viewModeButton(_ mode: ViewMode, _ symbol: String,
                                _ label: Text) -> some View {
        Button {
            viewMode = mode
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(viewMode == mode ? Color.sage : Color.slate)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(viewMode == mode ? .isSelected : [])
        .pointerCursor(.pointingHand)
    }
}

/// What a count is taken of. The kind is part of it: the same text counts
/// differently as a table.
private struct CountRequest: Equatable {
    let text: String
    let kind: DocumentKind
}

/// Totals for one document: words and characters for prose, rows and columns
/// for a table. A value type so it can be computed off the main actor and
/// handed back.
private struct TextCounts: Equatable, Sendable {
    var words = 0
    var characters = 0
    var rows = 0
    var columns = 0

    init(_ text: String, kind: DocumentKind) {
        if kind.isTable {
            let table = DelimitedText(parsing: text, kind: kind)
            // The header isn't a row of data — the same count the preview's
            // "Showing the first N of M rows" uses.
            rows = max(table.rows.count - 1, 0)
            columns = table.rows.map(\.count).max() ?? 0
            return
        }
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .substringNotRequired, .localized]) { _, _, _, _ in
            words += 1
        }
        self.words = words
        self.characters = text.count
    }
}
