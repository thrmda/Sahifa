import SwiftUI
import AppKit

/// Brand color tokens. Each is a named color in Assets.xcassets with
/// Light + Dark variants, so AppKit/SwiftUI resolve appearance automatically.
enum Brand {
    // Literal fallbacks (light values) keep previews and non-bundle contexts
    // alive if the catalog can't be found; in the app the named lookup wins
    // and adapts to dark mode.
    static var paper: NSColor { NSColor(named: "Paper") ?? NSColor(srgbRed: 0.980, green: 0.965, blue: 0.925, alpha: 1) }
    static var sand: NSColor { NSColor(named: "Sand") ?? NSColor(srgbRed: 0.922, green: 0.894, blue: 0.831, alpha: 1) }
    static var ink: NSColor { NSColor(named: "Ink") ?? NSColor(srgbRed: 0.094, green: 0.149, blue: 0.259, alpha: 1) }
    static var slate: NSColor { NSColor(named: "Slate") ?? NSColor(srgbRed: 0.357, green: 0.384, blue: 0.439, alpha: 1) }
    static var sage: NSColor { NSColor(named: "Sage") ?? NSColor(srgbRed: 0.306, green: 0.443, blue: 0.408, alpha: 1) }
    static var gold: NSColor { NSColor(named: "Gold") ?? NSColor(srgbRed: 0.541, green: 0.427, blue: 0.231, alpha: 1) }
}

extension Color {
    static let paper = Color("Paper")
    static let sand = Color("Sand")
    static let ink = Color("Ink")
    static let slate = Color("Slate")
    static let sage = Color("Sage")
    static let gold = Color("Gold")

    /// A faint panel fill that groups a source and its files in the sidebar —
    /// a touch lighter than `sand` in the dark theme, a touch darker in light.
    /// A tint (not a fixed colour) so it rides on whatever `sand` resolves to.
    static let grouped = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.045)
    })
}
