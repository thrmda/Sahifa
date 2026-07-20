# صحيفة · Sahifa

A calm, native macOS Markdown editor where English and Arabic are **equal
citizens** on one page. Two scripts, two directions, one surface. Plain text
on disk.

- **Native bidi.** The editor is a real `NSTextView` on **TextKit 2** — the
  system engine handles Unicode bidi, Arabic shaping, caret and selection.
  No web view, no reimplemented text layout.
- **Per-paragraph auto direction.** Each paragraph detects its base direction
  from its first strong character (like HTML `dir="auto"`): English paragraphs
  flow LTR, Arabic paragraphs flow RTL — in the same document, live. Code is
  always LTR + monospace. A thin margin bar marks each paragraph's direction:
  Ink on the left for LTR, Sage on the right for RTL.
- **Chrome follows the app language, not the content.** In English UI an
  Arabic-named file like `مقالة.md` still lays out LTR in the sidebar (icon
  left, `.md` trailing); switch the app language to Arabic and the whole
  chrome mirrors RTL. Fully localized in English and Arabic.
- **Live in-place Markdown styling** (headings, bold/italic, links, code,
  lists, quotes) over the raw source — markers stay visible and editable.
  Parsed with [apple/swift-markdown](https://github.com/swiftlang/swift-markdown).
- **Live side-by-side preview.** A rendered HTML pane updates as you type and
  keeps its scroll position; editor and preview scroll in sync. Every block
  carries its own resolved direction so the preview mirrors the editor's
  per-paragraph bidi exactly.
- **Export to HTML & PDF.** Self-contained HTML with IBM Plex embedded as
  `data:` URIs (no missing fonts on other machines), and paginated A4 PDF with
  a light “paper” palette. Arabic text in the PDF copies out as clean logical
  Unicode, not garbled presentation forms.
- **Formatting without leaving the keyboard.** Full **Format** menu with
  shortcuts (⌘B, ⌘I, ⌘1–4, lists, quote, code, link, image, rule, table) plus
  an optional icon toolbar over the editor for the no-shortcut path.
- **Focus mode** dims everything but the paragraph you're writing (⇧⌘F).
- **Multiple windows and native tabs**, each with its own selection, preview,
  and sidebar state; two views of the same file share one document.
- **Resizable panes.** Drag to resize the sidebar and the editor/preview split;
  positions persist across launches and mirror correctly in RTL.
- **IBM Plex everywhere** (bundled, SIL OFL): Plex Sans for Latin, Plex Sans
  Arabic for Arabic — matched as one superfamily per script run — and Plex
  Mono for code.
- **GitHub repositories.** Add a repository from the File menu and browse its
  Markdown alongside your local folders — files are fetched as you open them,
  and edits save back. Public repositories can be read without an account;
  connect one in Settings → Accounts to reach private repositories and to save.
  The token is kept in the macOS Keychain. If someone else changes a file while
  you have it open, you get the same conflict prompt as for a local file.
- **Folders you add, browsed as a tree.** Add as many folders as you like;
  each stays in the sidebar and expands into its subfolders, loading them as
  you open them, and updating live when anything changes on disk. Files opened on their own sit under *Opened Files* instead of
  replacing what you were looking at.
- **Plain `.md` files** in a folder you choose. No library format, no
  database, no accounts, no telemetry, no network calls.

## Requirements

- macOS 14 (Sonoma) or later — universal binary (Apple Silicon + Intel)
- Xcode 16 or later to build from source

## Build & run

```bash
git clone <this repo>
cd Sahifa
open Sahifa.xcodeproj   # then ⌘R in Xcode
```

or from the terminal:

```bash
xcodebuild -project Sahifa.xcodeproj -scheme Sahifa -configuration Release build
```

The first build resolves one Swift package (swift-markdown) from GitHub.
Fonts, icon and colors are already in the repo — no other setup.

Regression tests for the trickiest non-UI behaviour run without Xcode or an
app bundle — the model layer compiles on its own:

```bash
scripts/test-document-conflicts.sh   # files changed on disk while open
scripts/test-tree-operations.sh      # source/tree ids, rename, move to trash
scripts/test-formatting.sh           # formatting actions, selection, undo
scripts/test-github-store.sh         # reading a GitHub repository (no login)
scripts/test-accounts.sh             # Keychain storage, refused credentials
scripts/test-github-write.sh         # saving back (opt-in, see the script)
```

`test-formatting.sh` links the swift-markdown objects from a prior Debug
build, so run a normal build once before it.

On first launch, click **Add Folder…** (⇧⌘O) and pick any folder of `.md`
files — try the bundled `Samples/` folder, which contains a mixed
English/Arabic document and an Arabic-named file.

## Using Sahifa

### Files & windows

| Action | Shortcut |
| --- | --- |
| Open File… | ⌘O |
| Add Folder… (adds a sidebar source) | ⇧⌘O |
| Open Recent (folders and files) | File menu |
| Rename / Move to Trash | right-click in sidebar |
| New file | ⌘N |
| New window | ⇧⌘N |
| New tab | ⌘T |
| Save (also autosaves after 1 s) | ⌘S |
| Find / find & replace | ⌘F / ⌥⌘F |
| Settings (UI language, font size, line spacing) | ⌘, |

### View

| Action | Shortcut |
| --- | --- |
| Show / hide sidebar | ⌃⌘S |
| Show / hide preview | ⇧⌘P |
| Focus mode | ⇧⌘F |
| Show / hide format bar | View menu |
| Export as HTML… | ⇧⌘E |
| Export as PDF… | File menu |

### Format

| Action | Shortcut |
| --- | --- |
| Bold / Italic / Strikethrough | ⌘B / ⌘I / ⇧⌘X |
| Heading 1–4 | ⌘1 – ⌘4 |
| Bulleted / Numbered list | ⇧⌘8 / ⇧⌘7 |
| Inline code | ⌘E |
| Link | ⌘K |
| Quote, Code block, Image, Rule, Table | Format menu |

The UI language follows the system by default; you can pin it to English or
العربية in Settings — the window chrome (including the sidebar side) switches
immediately, the menu bar after relaunch.

## Project layout

```
Sahifa/                 app sources (SwiftUI shell + TextKit 2 editor)
  Editor/               BidiTextView, MarkdownStyler, direction detection,
                        fonts, formatting commands, editor↔preview scroll sync
  Export/               Markdown→HTML renderer, HTML/PDF export, Arabic PDF
                        text-layer repair
  Models/               sources, tree, document store, document (autosave, bookmarks)
  Views/                sidebar, format bar, status bar, preview, settings
  Assets.xcassets       brand colors (light/dark) + app icon
  Localizable.xcstrings en / ar string catalog
Brand/                  brand kit; Brand/fonts holds the bundled IBM Plex OTFs
Samples/                mixed-direction demo documents
```

## Releases

To build a distributable `.app` / DMG, see [RELEASE.md](RELEASE.md) and the
`scripts/release.sh` helper.

Prebuilt DMGs are **not notarized** — that needs a paid Apple Developer
Program membership. macOS will therefore refuse to open a downloaded build
with *“Apple could not verify ‘Sahifa’ is free of malware”*, and on macOS 15
and later Control-clicking the app no longer bypasses this. To run it, either
open  → System Settings → Privacy & Security and click **Open Anyway**, or
remove the quarantine flag:

```bash
xattr -d com.apple.quarantine /Applications/Sahifa.app
```

Building from source (above) sidesteps all of this and is the recommended
route until the project is notarized.

## License

MIT — see [LICENSE](LICENSE). The bundled IBM Plex fonts are licensed under
the SIL Open Font License 1.1 (`Brand/fonts/OFL-LICENSE.txt`).
