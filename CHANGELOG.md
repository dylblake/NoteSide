# Changelog

## Unreleased

### Passages: quote the selection, reopen the exact spot
- Select text in any app, press the hotkey, and the selection lands in the note as a **quoted passage**. On a web page the quote links to that exact passage, and clicking it reopens the page in the browser it came from, scrolled to and highlighting the text.
- Every capture on the same page, app or file lands in that context's one note: a second selection is appended beneath the first, never replacing it. **Quote Selection** (⇧⌘Q or the toolbar) grabs the current selection at any time.
- **Note This in NoteSide** appears in every app's Services menu, so a selection can be sent over without Accessibility access.
- Safari and native apps hand the selection over through Accessibility. Chromium browsers (Chrome, Edge, Brave, Arc, Vivaldi) don't expose it that way, so NoteSide briefly copies the selection and then restores whatever was on your clipboard.
- Clicking a NoteSide window while the drawer is open no longer re-attaches the note to NoteSide itself.
- With automatic titles on, an empty title shows nothing (no "Title" placeholder waiting to be replaced) unless you're typing in it; the generated title simply fades in when it's ready. Stored titles still appear instantly.
- **Click outside to close.** A click elsewhere on the same display saves and dismisses the note drawer, and closes All Notes; a click on another display moves the panel there, as before.
- Web notes now reopen in the browser they were captured in, not the default browser.

### The drawer answers the hotkey
- **The drawer slides in the moment you press the hotkey** (about 40 ms, including the first press after launch), on the app you're in; the page, file or channel and any selected passage land within its first frames.
- A **natural slide**: the drawer moves as one opaque sheet, laid out once at its final width, and slows evenly to a stop — no pop, no creep, no text reflowing mid-slide. It closes the same way, and pressing the hotkey mid-slide reverses it from where it is.
- **Looks active from its first frame**, rather than in the lighter inactive style until it settles — Chromium browsers get their copy request first, so the drawer can take focus almost at once.
- **Follows you to another display with the same slide**, instead of jumping into place; All Notes does too.
- All Notes cards respond to hover and press.
- The drawer's motion is covered by frame-by-frame UI tests, so a change that makes it lag, lurch or flash fails the build.

### Notes stay attached to the page, not the link
- Web notes now key on a **canonical page identity**: session tokens (Figma's `t=`), analytics tags (`utm_*`, `fbclid`, …), renamed slugs (Figma, Notion, Google Docs) and share suffixes no longer split one page into several notes or hide the note you already wrote. Hash-routed apps such as Gmail keep their fragment.
- On first launch after updating, notes that had been split across variants of the same URL are **merged into one** (newest first, separated by a divider). The notes file moves to schema version 2.

### A native, Liquid Glass interface
- The note drawer and All Notes are now a single **Liquid Glass** sheet that refracts whatever is behind it, with glass capsules for the formatting toolbar, footer actions and dismiss hint.
- Every window uses system buttons, semantic fonts and system colours, so the app follows your accent colour, Increase Contrast and light/dark mode exactly like the rest of macOS.
- Note cards are tinted with system colours; the view switcher is a native segmented control.
- The drawer and All Notes keep a usable width on portrait, laptop and ultra-wide displays; the formatting toolbar folds into an overflow menu when the pane is narrow, and note cards flow into one, two or three columns.
- **Permissions & Setup** is one row per capability with a status glyph; individual browsers, Finder / Xcode and microphone / speech live behind disclosures that open only when something needs attention.
- The **menu bar popover** leads with All Notes and New Note (with their shortcuts) and recent notes, with settings and hotkeys beneath.
- Every screen shares the same 4/8/12/16/24/32/48pt spacing scale and reads correctly in light and dark mode.

### A real text editor
- **Paragraph styles** like Apple Notes — Title, Heading, Subheading, Body and Monospaced — from the toolbar or ⇧⌘T / ⇧⌘H / ⇧⌘J / ⇧⌘B / ⇧⌘M. Return after a heading drops back to Body.
- **Lists that behave**: wrapped lines align under the text, Tab / ⇧Tab nest items (1. → a. → i.), numbering is recomputed after every edit, Return on an empty item ends the list, Delete after the marker removes it, and `- `, `* ` or `1. ` starts a list as you type.
- **Tables** (⌥⌘T): Tab moves between cells and adds a row at the end; the toolbar's table button (or a right-click inside a cell) adds or deletes rows and columns, or removes the table. Tables are saved with the note.
- **Strikethrough** (⇧⌘X) alongside bold, italic and underline.
- **Text size** with ⌘+ / ⌘− / ⌘0 or the Aa menu — the whole note scales while headings keep their proportions, and the setting is remembered.
- Reopened notes now render in the system font again instead of falling back to Helvetica Neue.

## 1.3.1

The biggest update yet — a rebuilt first-run experience, a free trial so you can try before you buy, instant context detection, and a long list of reliability and polish fixes.

### Try before you buy
- **New 5-note free trial.** Take your first five notes with everything unlocked — no license required. After that, a license unlocks unlimited new notes, and **all of your existing notes stay fully readable and editable, always.**
- **Guided setup.** First launch now walks you through it in three quick steps: press the hotkey and watch the drawer appear, connect your browser with one click, and turn on optional extras only if you want them.

### Faster and smarter
- **The drawer opens instantly.** Pressing the hotkey no longer waits on anything — the note pane is there the moment you press it.
- **Live context tracking.** Switch browser tabs, Slack channels, or files in your editor with the drawer open and the note follows along immediately, instead of after a pause.
- **All Notes handles large collections smoothly**, even with thousands of notes, and search stays responsive as you type.

### All Notes, keyboard-first
- Full keyboard navigation: **arrow keys** to move, **Return** to open, **Space** to select, **Delete** to remove, and **⌘F** to jump to search.
- Clear empty states — a friendly starting screen when you have no notes yet, and a proper "no matches" message when a search comes up empty.

### Permissions that make sense
- A complete **Permissions & Setup** screen covering browsers, Finder, and Xcode, each explaining exactly what it unlocks.
- **Hotkeys now work immediately** — no Accessibility permission required just to take a note.
- Honest, accurate guidance when macOS has denied a permission, with a direct link to the right settings pane.

### Your notes are safer
- **Autosave** while you type — a crash or force-quit no longer loses the note you're working on.
- Automatic backups of your notes file, with recovery if the file is ever damaged.
- Notes are stored more robustly, with a versioned format for safe future upgrades.

### Fixes and refinements
- Arc now reads the **active** tab correctly instead of the first tab.
- A browser with no open tab no longer mistakenly says permission is missing.
- Notes whose original page or file has moved can now be **re-attached** to your current context in one click.
- Dictation problems are now shown clearly instead of failing silently.
- More reliable Slack and Figma detection, including non-English setups.
- Respects **Reduce Motion**, adds **VoiceOver** labels throughout, and cleans up the menu bar layout.
- **Secure updates:** NoteSide now verifies an update's signature before installing it.

### Upgrading from 1.2.x
On first launch after updating, NoteSide moves its storage to a new folder automatically (your notes come with it), and the welcome screen may appear once — just click through it.

**Note on the shortcut:** the default **⌘⇧N** is also "New Private Window" in Safari and Chrome. While NoteSide is running it takes priority; if you use that browser shortcut, change NoteSide's hotkey on the first setup screen or in the menu bar.

**Requires macOS 26 or later.**
