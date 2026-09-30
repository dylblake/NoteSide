# Remora

Remora is a macOS menu bar app for context-aware notes. It lets you attach notes to the app, browser page, or file you are currently in, then reopen that note later from the same context.

## What It Does

- Open a floating note with a global hotkey
- Rich text editing modelled on Apple Notes: Title / Heading / Subheading / Body / Monospaced styles, bold, italic, underline, strikethrough, bulleted and numbered lists with nesting, tables, and text zoom
- Attach notes to:
  - browser pages
  - files in editors like Xcode, VS Code and Cursor, and documents in Preview and other PDF readers
  - the project a terminal is in (Terminal, iTerm2, Ghostty, Warp and others)
  - app-specific contexts such as Slack channels/DMs, Figma files and Linear issues when detectable
- View all saved notes in a dedicated notes window
- Pin notes to a To-Do list at the top of All Notes and drag them into order
- See every other note in one grid, each marked with the icon of the site, app or file it belongs to
- Follow macOS light and dark mode automatically

## Current Browser Support

- Safari
- Safari Technology Preview
- Google Chrome
- Google Chrome Beta
- Google Chrome Canary
- Microsoft Edge
- Microsoft Edge Beta
- Brave
- Arc
- Vivaldi

## Permissions

Remora uses macOS permissions for a few features:

- Accessibility
  - required for the global hotkey and app/context detection
- Automation
  - required to read the active tab URL from supported browsers

The app prompts for these when needed.

## Privacy

- Notes are stored locally on your Mac
- For a note on a web page, Remora downloads that site's icon from the site itself, once, and keeps it on your Mac. Nothing about your notes is sent.
- The app does not require an account
- Accessibility is used only for hotkey handling and context detection
- Automation is used only for supported browser tab detection

## Requirements

- macOS
- Xcode 16 or later recommended
- A valid local Apple Development signing identity if you want to run signed builds from Xcode

## Run Locally

1. Open `Remora.xcodeproj` in Xcode.
2. Select the `Remora` scheme.
3. Build and run on `My Mac`.
4. Grant Accessibility and browser Automation permissions when prompted.

## Testing

- Unit tests: `RemoraTests`
- UI tests: `RemoraUITests` (XCUITest — there is no web frontend to drive with Playwright; the UI is native SwiftUI/AppKit)

Run from the command line (no need to open Xcode first):

```sh
xcodebuild -project Remora.xcodeproj -scheme Remora -destination 'platform=macOS' test
```

Run a single target:

```sh
xcodebuild -project Remora.xcodeproj -scheme Remora -destination 'platform=macOS' test -only-testing:RemoraUITests
```

Remora is a menu-bar-only (`LSUIElement`) app with no Dock icon or main window, and SwiftUI's `MenuBarExtra(.window)` popover doesn't reliably expose itself to the accessibility tree under XCUITest. So UI tests don't click the status item to reach app content — in `DEBUG` builds only, `AppState` reads a `UITEST_LAUNCH_ACTION` launch environment variable (`allNotes`, `onboarding`, `info`, `quickNote`, `license`) and opens that window directly on launch:

```swift
let app = XCUIApplication()
app.launchEnvironment["UITEST_LAUNCH_ACTION"] = "allNotes"
app.launch()
```

Two more `DEBUG`-only hooks keep automated runs isolated from real data:

- `UITEST_STORE_DIRECTORY` (launch environment) points the note store at a scratch folder instead of Application Support.
- Standard `NSArgumentDomain` launch arguments override preferences without writing them, e.g. `-hasCompletedOnboarding YES -autoTitleEnabled NO -editorTextZoom 1`. The UI tests also pass `-trialNotesCreated 0`, so an unlicensed build never hits the free-note limit mid-suite.
- `UITEST_SELECTION_TEXT` (launch environment) stands in for the host app's selected text so passage capture can be tested without a real selection.
- `REMORA_TRACE_FILE` (launch environment) appends `DebugTrace.log(...)` lines to that file, for diagnosing flows under XCUITest where the unified log is hard to reach.
- `REMORA_PANE_WIDTH` (launch environment) forces the drawer / All Notes pane width so layouts can be checked at any screen size on one display. Panel widths are otherwise a fraction of the screen clamped by `PanelLayout` (editor 440–640pt, All Notes 540–960pt).

`NoteEditorUITests` uses both to drive the editor's formatting toolbar, keyboard shortcuts, lists, tables and text size end to end. The formatting engine itself (`RichTextEditorController`) is unit-tested against an offscreen `NSTextView` in `RemoraTests/RichTextEditorControllerTests.swift`.

These hooks are compiled out of Release/MAS builds.

### Editor keyboard shortcuts

| Action | Shortcut |
|---|---|
| Title / Heading / Subheading / Body / Monospaced | ⇧⌘T / ⇧⌘H / ⇧⌘J / ⇧⌘B / ⇧⌘M |
| Bold / Italic / Underline / Strikethrough | ⌘B / ⌘I / ⌘U / ⇧⌘X |
| Bulleted list / Numbered list | ⇧⌘7 / ⇧⌘9 |
| Indent / outdent list item, next / previous table cell | Tab / ⇧Tab |
| Insert table | ⌥⌘T |
| Add / delete table rows and columns | Table button in the toolbar, or right-click inside a cell |
| Bigger / Smaller / Actual size | ⌘+ / ⌘− / ⌘0 |

## Version

<!-- VERSION_BLOCK_START -->
- Version: `1.3.1`
- Build: `17`
<!-- VERSION_BLOCK_END -->

## Notes

- Some apps support context detection better than exact navigation back to the original page or channel.
- Slack and Figma notes can be detected locally, but exact return-to-context behavior depends on what those apps expose through macOS.
