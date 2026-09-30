# Changelog

## 2.0.1

### A one-page start
- **First run is one page.** Allow Accessibility, press the hotkey, done: each step gets a green check and the next opens by itself. There are no pages to step through and no detour to Setup.
- **One permission to get going.** Accessibility is all Remora asks for up front. It reads the page you're on in every supported browser, so a browser no longer asks for Automation the first time you take a note in it. Dictation, Finder, Xcode and iTerm2 still ask when you first use them.
- **A connected browser is recognised.** Setup now asks macOS directly whether a browser or app has granted Automation, so a browser showing its start page turns green as soon as you allow it, and a change made in System Settings shows within a second.
- **Setup shows everything.** The per-browser, Finder and Xcode, and microphone and speech rows are always visible; there is nothing to expand.
- **The license window comes up in front.** When the trial runs out it opens as the active window, with Buy a License as the default button, so one click or Return starts checkout.
- A browser with no page open (a start page, a new tab) attaches the note to the browser and says so, instead of reporting that the page couldn't be read.

**Requires macOS 26.2 or later.**

## 2.0.0

### Buy from the trial
- **The license window has a Buy a License button.** When the five free notes are used up, or any time from Activate License in the menu bar, it opens checkout on dylblake.dev. The key arrives by email and is pasted into the same window.

### Pinned notes are a To-Do list
- **Pinning a note puts it on your To-Do list.** The Pinned section at the top of All Notes is now **To-Do**: one compact line per note with the icon of where it lives (the app, the browser, or the file), its title and a faint first line, and a count beside the heading. Unpinned notes keep their tiles below.
- **Drag to reorder.** The list stays in the order you put it in; a newly pinned note joins at the bottom. The pin on a row (or right-click, Remove from To-Do) takes it back off the list.
- **One grid, no sections.** Everything that isn't on the To-Do list sits in a single grid, newest first, so tiles fill the width of the pane instead of each site and project getting a heading and a row of its own. All Notes is tiles only: the list/grid switch is gone.
- **Every note shows where it lives.** Tiles, To-Do rows and the note editor carry the icon of the note's context: the website's own icon, the app's, or the file's. Website icons are downloaded from the site itself the first time and kept on your Mac; until one arrives the browser's icon stands in. The Mac App Store build gains the outgoing-network permission for this.
- **Calmer tiles.** Tiles are neutral instead of tinted by kind, all the same height, and read top to bottom: source, title, the start of the note, then tags and date. A note without a title is headed by its first line. Select, pin and delete appear when the pointer or the keyboard is on a tile.
- The `#` button in the All Notes search field is gone, since focusing the field already lists every tag, and the paragraph-style menu in the editor shows just the style name.

### Tags at your fingertips, and no duplicate tabs
- **Every tag, one click away.** Put the cursor in the All Notes search field and a list of every `#tag` across your notes drops down, most-used first with a count. Typing `#he` narrows it; pick one with a click or the arrow keys and Return, and the notes filter to that tag. Escape closes the list first and the panel second.
- Tags are yellow everywhere they appear: in the editor, the search field, note cards and the new list, whatever your accent colour.
- **Reopening a note finds the tab you already have.** Clicking a note in All Notes now brings forward the browser window whose visible tab is that page, the Finder window already on that folder, or the document window already open in Preview, Xcode and other apps, instead of opening a second one. Where Remora already has Automation access to a browser, it also finds the page among that browser's background tabs and switches to it. Nothing here asks for a new permission; when nothing is open, the note opens fresh as before.
- Typing Space or Delete in the All Notes search no longer selects or offers to delete the note highlighted by the arrow keys.

### A tidier menu bar
- The menu bar popover is reorganised: the Remora wordmark heads it, **All Notes** and **New Note** sit side by side, Launch at login and the three hotkey recorders follow, then Recent, license and updates, with **Setup** and **Quit** at the bottom. "Permissions & Setup" is now just "Setup" everywhere.
- Note titles are always generated; the toggle is gone.
- Remora never shows a Dock icon, even while All Notes, Setup or About are open.
- **Holding the dictation hotkey opens a note first.** With no drawer open, the dictation hotkey (Cmd+Shift+D by default) slides the quick-note drawer in and starts listening, so dictation always has somewhere to land. Closing the drawer mid-dictation keeps what has been recognised so far.
- The About, Setup, Welcome and License windows are drawn on the same Liquid Glass as the note drawer and All Notes, with the wordmark in place of the large "Remora" heading.

### NoteSide is now Remora
- The app has a new name and a new bundle identifier (`com.dylblake.remora`). Your notes come with it: on first launch, the NoteSide storage folder moves to `~/Library/Application Support/Remora`.
- Because macOS sees Remora as a new app, it asks again for Accessibility and Automation access, the hotkey and other preferences return to their defaults, and a license key needs to be entered again. NoteSide 1.3.x can't update itself to Remora; install Remora from the new download.

### Designer, developer and student workflows
- **Terminals**: notes in Terminal, iTerm2, Ghostty, Warp, kitty, WezTerm and Alacritty attach to the project the shell is in (the enclosing repository, so `cd src` keeps the same note) and reopen as a new terminal window there. iTerm2 asks once for Automation access to read the session's directory.
- **Slack notes reopen their conversation**: clicking one in All Notes switches Slack to the channel or DM it was written in, so the note opens in place instead of on whatever channel Slack last showed. A note written with a thread open reopens on that thread's channel, since Slack has no link that opens a thread. Existing Slack notes gain the link the next time they're opened in Slack.
- **Slack names are read reliably**: a conversation whose name contains "Slack" (Slackbot) no longer swaps places with the workspace, and a workspace view such as Activity no longer picks up a tooltip ("This button also has an action to zoom the window") as its name.
- **The hotkey never files a note under Remora itself**: pressed while Remora is the active app, the note is for the app you were working in.
- **Cursor**, Windsurf and VSCodium are recognised as code editors, like VS Code.
- **Linear**: the desktop app attaches notes per issue or project, sharing one note with the same issue opened in a browser, and reopens it in the desktop app. Renaming an issue or project no longer orphans its note.
- **GitHub**: a pull request, issue or discussion is one note across its tabs (Conversation, Files, Commits), and owner/repo case no longer matters.
- **Google Docs, Sheets, Slides and Drive**: documents opened from a second signed-in account (`/u/1/`) each get their own note — previously they all shared one — and published docs are told apart.
- **YouTube**: `youtu.be` links, Shorts, live streams and m.youtube.com share the video's one note.
- **PDFs opened in a browser** (a local file in Chrome or Safari) attach as the file, following renames, rather than as a `file://` "page".
- The notes file moves to schema version 3; notes split under the old rules are merged on first launch, as in version 2.

### Passages: quote the selection, reopen the exact spot
- Select text in any app, press the hotkey, and the selection lands in the note as a **quoted passage**. On a web page the quote links to that exact passage, and clicking it reopens the page in the browser it came from, scrolled to and highlighting the text.
- Every capture on the same page, app or file lands in that context's one note: a second selection is appended beneath the first, never replacing it.
- **Note This in Remora** appears in every app's Services menu, so a selection can be sent over without Accessibility access.
- Works in **any app**: Safari and many native apps hand the selection over through Accessibility; where an app doesn't (Chromium browsers, Electron apps such as Slack or VS Code, and many others), Remora briefly copies the selection and then restores whatever was on your clipboard.
- Clicking a Remora window while the drawer is open no longer re-attaches the note to Remora itself.
- With automatic titles on, an empty title shows nothing (no "Title" placeholder waiting to be replaced) unless you're typing in it; the generated title simply fades in when it's ready. Stored titles still appear instantly.
- **Click outside to close.** A click elsewhere on the same display saves and dismisses the note drawer, and closes All Notes; a click on another display moves the panel there, as before.
- Web notes now reopen in the browser they were captured in, not the default browser.

### The drawer answers the hotkey
- **The drawer slides in the moment you press the hotkey** (about 40 ms, including the first press after launch), on the app you're in; the page, file or channel and any selected passage land within its first frames.
- A **natural slide**: the drawer moves as one opaque sheet, laid out once at its final width, and slows evenly to a stop — no pop, no creep, no text reflowing mid-slide. It closes the same way, and pressing the hotkey mid-slide reverses it from where it is.
- **Looks active from its first frame**, rather than in the lighter inactive style until it settles — Chromium browsers get their copy request first, so the drawer can take focus almost at once.
- **Follows you to another display with the same slide**, instead of jumping into place; All Notes does too.
- All Notes cards respond to hover and press.
- The formatting toolbar drops its text-size and quote buttons: text size is ⌘+ / ⌘− / ⌘0, and a selection is quoted when the drawer opens.
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

**Requires macOS 26.2 or later.**

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
