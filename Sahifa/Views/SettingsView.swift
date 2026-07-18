import SwiftUI
import AppKit

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
        .frame(width: 440)
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
