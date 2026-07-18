import SwiftUI

/// Live word/character count. Counting uses the system word enumerator
/// (ICU-backed), which segments Arabic text correctly — no whitespace
/// splitting.
struct StatusBarView: View {
    let text: String
    var errorMessage: String?
    @Binding var showPreview: Bool
    @AppStorage("focusMode") private var focusMode = false
    @AppStorage("showFormatBar") private var showFormatBar = true

    @EnvironmentObject private var windowState: WindowState

    var body: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation { windowState.sidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .help(Text("Toggle Sidebar"))
            Text("Words: \(wordCount)")
            Text("Characters: \(text.count)")
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
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
            Button {
                focusMode.toggle()
            } label: {
                Image(systemName: focusMode ? "circle.circle.fill" : "circle.circle")
            }
            .buttonStyle(.borderless)
            .help(focusMode ? Text("Exit Focus Mode") : Text("Focus Mode"))
            Button {
                showPreview.toggle()
            } label: {
                Image(systemName: showPreview
                    ? "rectangle.righthalf.inset.filled"
                    : "rectangle.split.2x1")
            }
            .buttonStyle(.borderless)
            .help(showPreview ? Text("Hide Preview") : Text("Show Preview"))
        }
        .font(.custom("IBMPlexSans", size: 11))
        .foregroundStyle(Color.slate)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.sand)
    }

    private var wordCount: Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .substringNotRequired, .localized]) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
