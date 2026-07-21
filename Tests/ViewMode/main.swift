// Regression tests for the three-way ViewMode: the editor/preview layout
// selector and the migration off the old boolean `showPreview` preference.
//
// WindowState reads UserDefaults.standard in its initialiser, so each case
// seeds the two keys first, then checks the resolved mode. Runs headlessly —
// no Xcode, no UI.

import Foundation

@MainActor
func run() {
    var failures = 0
    func check(_ label: String, _ got: ViewMode, _ want: ViewMode) {
        if got == want {
            print("  ok  \(label): \(got)")
        } else {
            print("  FAIL \(label): got \(got), want \(want)")
            failures += 1
        }
    }
    func expect(_ label: String, _ cond: Bool) {
        if cond { print("  ok  \(label)") }
        else { print("  FAIL \(label)"); failures += 1 }
    }

    let d = UserDefaults.standard

    // Fresh install: nothing stored → editor only.
    d.removeObject(forKey: "viewMode")
    d.removeObject(forKey: "showPreview")
    check("fresh default", WindowState().viewMode, .editOnly)

    // Upgrade from a version that only had the boolean.
    d.removeObject(forKey: "viewMode")
    d.set(true, forKey: "showPreview")
    check("migrate showPreview=true", WindowState().viewMode, .split)

    d.removeObject(forKey: "viewMode")
    d.set(false, forKey: "showPreview")
    check("migrate showPreview=false", WindowState().viewMode, .editOnly)

    // A stored viewMode wins over any leftover boolean.
    d.set("previewOnly", forKey: "viewMode")
    d.set(true, forKey: "showPreview")
    check("stored viewMode wins", WindowState().viewMode, .previewOnly)

    // A garbage value falls back to the boolean rather than crashing.
    d.set("nonsense", forKey: "viewMode")
    d.set(true, forKey: "showPreview")
    check("garbage falls back", WindowState().viewMode, .split)

    // Round-trips: setting the mode persists its rawValue.
    d.removeObject(forKey: "viewMode")
    let ws = WindowState()
    ws.viewMode = .previewOnly
    check("assignment persists", WindowState().viewMode, .previewOnly)

    // Pane visibility per mode.
    expect("editOnly shows editor", ViewMode.editOnly.showsEditor)
    expect("editOnly hides preview", !ViewMode.editOnly.showsPreview)
    expect("split shows editor", ViewMode.split.showsEditor)
    expect("split shows preview", ViewMode.split.showsPreview)
    expect("previewOnly hides editor", !ViewMode.previewOnly.showsEditor)
    expect("previewOnly shows preview", ViewMode.previewOnly.showsPreview)

    // Clean up so the test never leaves state behind.
    d.removeObject(forKey: "viewMode")
    d.removeObject(forKey: "showPreview")

    if failures == 0 {
        print("\nAll ViewMode tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}

MainActor.assumeIsolated { run() }
