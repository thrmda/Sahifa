import AppKit

/// Opens a new SwiftUI window and merges it into the key window's native tab
/// group. SwiftUI has no first-class "new tab" — so: snapshot the window
/// list, open, then adopt the window that appears.
@MainActor
enum WindowTabbing {

    static func openAsTab(_ open: () -> Void) {
        let host = NSApp.keyWindow ?? NSApp.mainWindow
        let existing = Set(NSApp.windows.map(\.windowNumber))
        open()
        merge(into: host, excluding: existing, attemptsLeft: 20)
    }

    private static func merge(into host: NSWindow?, excluding: Set<Int>, attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let host,
               let newWindow = NSApp.windows.first(where: {
                   !excluding.contains($0.windowNumber) && $0.canBecomeKey
               }) {
                host.addTabbedWindow(newWindow, ordered: .above)
                newWindow.makeKeyAndOrderFront(nil)
            } else if attemptsLeft > 0 {
                merge(into: host, excluding: excluding, attemptsLeft: attemptsLeft - 1)
            }
        }
    }
}
