import AppKit

/// IBM Plex superfamily access. Latin prose runs use IBM Plex Sans; Arabic
/// runs fall through to IBM Plex Sans Arabic via the font cascade list, so a
/// single "font" transparently covers both scripts at matched x-height.
/// Code uses IBM Plex Mono.
enum FontLibrary {

    enum ProseWeight {
        case regular, medium, semibold, bold
    }

    /// Fonts are bundled in Resources/fonts and declared via
    /// ATSApplicationFontsPath. This fallback registers them explicitly in
    /// case the Info.plist route ever fails (e.g. odd build setups), so the
    /// app never silently renders Arabic in a system fallback face.
    static func registerBundledFontsIfNeeded() {
        guard NSFont(name: "IBMPlexSans", size: 12) == nil else { return }
        guard let fontsDir = Bundle.main.resourceURL?.appendingPathComponent("fonts", isDirectory: true),
              let contents = try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil)
        else { return }
        // CTFontManagerRegisterFontsForURL is synchronous, so the fonts are
        // usable immediately (the plural URLs variant registers on a
        // background queue and would race the first layout).
        for url in contents where ["otf", "ttf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Prose font: Plex Sans with Plex Sans Arabic as first cascade fallback.
    static func prose(size: CGFloat, weight: ProseWeight = .regular, italic: Bool = false) -> NSFont {
        let latin: String
        let arabic: String
        switch weight {
        case .regular:
            latin = italic ? "IBMPlexSans-Italic" : "IBMPlexSans"
            arabic = "IBMPlexSansArabic-Regular"
        case .medium:
            latin = "IBMPlexSans-Medm"
            arabic = "IBMPlexSansArabic-Medium"
        case .semibold:
            latin = "IBMPlexSans-SmBld"
            arabic = "IBMPlexSansArabic-SemiBold"
        case .bold:
            latin = italic ? "IBMPlexSans-BoldItalic" : "IBMPlexSans-Bold"
            arabic = "IBMPlexSansArabic-Bold"
        }
        return named(latin, arabicFallback: arabic, size: size)
    }

    /// Code font: Plex Mono. Code is always LTR; no Arabic cascade needed,
    /// but the system still falls back gracefully for stray Arabic in strings.
    static func mono(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let name: String
        switch (bold, italic) {
        case (true, _): name = "IBMPlexMono-Bold"
        case (false, true): name = "IBMPlexMono-Italic"
        case (false, false): name = "IBMPlexMono"
        }
        return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    private static func named(_ latin: String, arabicFallback: String, size: CGFloat) -> NSFont {
        let cascade = NSFontDescriptor(name: arabicFallback, size: size)
        let descriptor = NSFontDescriptor(name: latin, size: size)
            .addingAttributes([.cascadeList: [cascade]])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
    }

    /// True when the Plex faces actually resolved (used to surface a warning
    /// if the bundled fonts are missing).
    static var plexAvailable: Bool {
        NSFont(name: "IBMPlexSans", size: 12) != nil
            && NSFont(name: "IBMPlexSansArabic-Regular", size: 12) != nil
            && NSFont(name: "IBMPlexMono", size: 12) != nil
    }
}
