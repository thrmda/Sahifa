import SwiftUI
import AppKit

/// Brand color tokens. Each is a named color in Assets.xcassets with
/// Light + Dark variants, so AppKit/SwiftUI resolve appearance automatically.
///
/// Naming rule, since these invert between modes: a token is named for the
/// ROLE it plays, or for a hue only when that hue survives the inversion.
/// `paper` and `ink` are role metaphors — the surface you write on and the
/// marks you make — and stay true whatever colour they resolve to. `sage`,
/// `gold` and `slate` really are those hues in both modes. `sand` was the odd
/// one out: a pure colour name that rendered navy at night, describing only
/// half the app, so it is now `panel`, after the job it does.
enum Brand {
    // Literal fallbacks (light values) keep previews and non-bundle contexts
    // alive if the catalog can't be found; in the app the named lookup wins
    // and adapts to dark mode.
    static var paper: NSColor { NSColor(named: "Paper") ?? NSColor(srgbRed: 0.980, green: 0.965, blue: 0.925, alpha: 1) }
    /// The fill that sets chrome and code apart from the page: sidebar,
    /// status bar, tab strip, code blocks, table headers. Named for that role
    /// rather than for a colour — it is sand in light mode but navy in dark,
    /// so the old name `Sand` described only half the app.
    static var panel: NSColor { NSColor(named: "Panel") ?? NSColor(srgbRed: 0.922, green: 0.894, blue: 0.831, alpha: 1) }
    static var ink: NSColor { NSColor(named: "Ink") ?? NSColor(srgbRed: 0.094, green: 0.149, blue: 0.259, alpha: 1) }
    static var slate: NSColor { NSColor(named: "Slate") ?? NSColor(srgbRed: 0.357, green: 0.384, blue: 0.439, alpha: 1) }
    /// Accents and affordances. In light mode Sage is 5.01:1 on Paper but only
    /// 4.27:1 on Panel — under AA for text. Audited: on Panel it only ever
    /// colours icons and the active-tab underline, where the 3:1 non-text
    /// threshold applies; as text it appears solely on Paper, on blockquote
    /// and list markers in the editor. Keep it that way — running text on
    /// Panel wants Slate or Ink.
    static var sage: NSColor { NSColor(named: "Sage") ?? NSColor(srgbRed: 0.306, green: 0.443, blue: 0.408, alpha: 1) }
    /// Links, and only links. Gold used to carry warnings too, which made a
    /// dead link and a failed save look like the same thing.
    static var gold: NSColor { NSColor(named: "Gold") ?? NSColor(srgbRed: 0.490, green: 0.384, blue: 0.192, alpha: 1) }
    /// Something needs attention: a save that couldn't land, an expired
    /// account, a folder that has gone missing.
    static var warning: NSColor { NSColor(named: "Warning") ?? NSColor(srgbRed: 0.639, green: 0.227, blue: 0.165, alpha: 1) }
}

/// Spacing scale. Chrome padding and gaps come from here rather than from
/// numbers typed at each call site, so a row in the sidebar and a tab in the
/// strip stay on the same rhythm.
///
/// Derived from what the chrome already used, not invented: the first cut of
/// this scale (4/8/12/16/24/32) missed 2, 6, 7, 10 and 14 entirely, which is
/// how call sites ended up writing `Space.xs - 2` to mean 6 — an expression
/// less readable than the literal it replaced. Tight chrome genuinely needs
/// 2pt steps at the bottom of the range, so the scale carries them and the
/// gaps widen as the values grow.
enum Space {
    static let hair: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner radii, also taken from what the app draws. The previous values (6
/// and 10) matched nothing on screen and had no call sites at all; the only
/// radii the design actually uses are the 8pt sidebar panels and code blocks,
/// and the 4pt inline-code chip.
enum Radius {
    static let chip: CGFloat = 4
    static let panel: CGFloat = 8
}

/// Chrome type. Body text lives in the editor and is set by FontLibrary from
/// the user's font-size setting; these are the fixed sizes the UI around it
/// uses.
///
/// Named Typography rather than Type: the latter is legal but reads as the
/// language's own `.Type`, and a bare `TextStyle` would sit awkwardly beside
/// SwiftUI's `Font.TextStyle`.
enum Typography {
    /// Status bar, sidebar counts and captions.
    static let caption = Font.custom("IBMPlexSans", size: 11)
    /// Tab labels, sidebar rows.
    static let label = Font.custom("IBMPlexSans", size: 12)
    /// The larger sidebar rows.
    static let body = Font.custom("IBMPlexSans", size: 13)
    /// Sidebar source headers.
    static let sectionHeader = Font.custom("IBMPlexSans-SmBld", size: 11)

    /// Heading ramp, shared with the export CSS so a heading is the same size
    /// in the editor, the preview and the PDF. A 1.15 ratio per level: the
    /// editor and the stylesheet used to disagree (1.7/1.45/1.25/1.1 against
    /// 1.9/1.55/1.28/1.1), which showed up as headings shifting between panes.
    static func headingScale(level: Int) -> CGFloat {
        switch level {
        case 1: return 1.75
        case 2: return 1.52
        case 3: return 1.32
        case 4: return 1.15
        default: return 1.0
        }
    }
}

extension Color {
    static let paper = Color("Paper")
    static let panel = Color("Panel")
    static let ink = Color("Ink")
    static let slate = Color("Slate")
    static let sage = Color("Sage")
    static let gold = Color("Gold")
    static let warning = Color("Warning")

    /// A faint panel fill that groups a source and its files in the sidebar —
    /// a touch lighter than `panel` in the dark theme, a touch darker in light.
    /// A tint (not a fixed colour) so it rides on whatever `panel` resolves to.
    static let grouped = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.045)
    })
}
