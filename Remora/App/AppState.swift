//
//  AppState.swift
//  Remora
//
//  Created by Dylan Evans on 4/2/26.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    var hasCompletedOnboarding: Bool
    var isAccessibilityTrusted = AXIsProcessTrusted()
    let browserPermissions: BrowserPermissionsState
    let notesState: NotesState
    let editor: EditorState
    let hotkeys: HotKeyState
    /// Where All Notes is: not shown, alone at the screen edge, or out
    /// from under the open note drawer, beside it.
    enum AllNotesMode {
        case hidden
        case alone
        case stacked
    }
    private(set) var allNotesMode: AllNotesMode = .hidden
    var isAllNotesPanelPresented: Bool { allNotesMode != .hidden }
    var isAllNotesStacked: Bool { allNotesMode == .stacked }
    /// Which layout the list was last opened in. It changes only when the
    /// list opens, never as it closes, so the content doesn't reflow
    /// while the list is sliding or fading away.
    private(set) var allNotesUsesStackedLayout = false
    /// Counts quick-note requests, whatever they lead to (the drawer, or
    /// the license window once the trial is used up). First run watches
    /// it to tick off "take your first note".
    private(set) var quickNoteHotkeyPressCount = 0
    let formatting: FormattingState
    /// Titles are always generated; this is not a user preference. UI tests
    /// switch generation off with the `-autoTitleEnabled NO` launch
    /// argument (Debug builds only).
    let isAutoTitleEnabled: Bool
    var isLicensed: Bool = false
    var isDictating = false
    var dictationPartialText = ""
    var isMicrophoneAuthorized = false
    var isSpeechRecognitionAuthorized = false

    let richTextController = RichTextEditorController()
    #if MAS_BUILD
    let storeService = StoreService()
    #endif
    let dictationService = DictationService()
    private let dictationHotKeyMonitor = DictationHotKeyMonitor()
    private let openContextLocator = OpenContextLocator()
    /// Bumped per `open(_:)`; a stale generation stops navigating/editing.
    private var openNoteGeneration = 0
    private var panelController: NoteEditorPanelController?
    private var allNotesPanelCtrl: AllNotesPanelController?
    private var onboardingWindowController: OnboardingWindowController?
    private var firstRunWindowController: FirstRunWindowController?
    private var infoWindowController: InfoWindowController?
    private var licenseWindowController: LicenseWindowController?
    private var cancellables: Set<AnyCancellable> = []
    /// The last app other than Remora to come to the front.
    private var lastExternalApp: NSRunningApplication?
    private var isOnboardingWindowVisible = false
    private var isFirstRunWindowVisible = false
    private var permissionPollTask: Task<Void, Never>?

    private var isAnySetupWindowVisible: Bool {
        isFirstRunWindowVisible || isOnboardingWindowVisible
    }

    private static let onboardingDefaultsKey = "hasCompletedOnboarding"
    static let supportedBrowsers = BrowserURLProvider.supportedBrowsers

    init(
        store: NoteStore,
        contextResolver: ContextResolver,
        hotKeyMonitor: GlobalHotKeyMonitor
    ) {
        let browserURLProvider = BrowserURLProvider()
        let browserPerms = BrowserPermissionsState(browserURLProvider: browserURLProvider)
        self.browserPermissions = browserPerms
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingDefaultsKey)
        let autoTitle = Self.resolveAutoTitleEnabled()
        isAutoTitleEnabled = autoTitle
        let ns = NotesState(store: store)
        notesState = ns
        let rtc = richTextController
        formatting = FormattingState(richTextController: rtc)
        hotkeys = HotKeyState(hotKeyMonitor: hotKeyMonitor)

        let titleGen = NoteTitleGenerator()
        editor = EditorState(
            notesState: ns,
            richTextController: rtc,
            contextResolver: contextResolver,
            browserPermissions: browserPerms,
            titleGenerator: titleGen,
            isAutoTitleEnabled: { autoTitle }
        )

        // Launched from the Dock or Spotlight, Remora isn't in front yet:
        // whatever is becomes the app a note opened from the menu bar is for.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApp = frontmost
        }

        hotkeys.configure(
            quickNoteAction: { [weak self] in self?.toggleQuickNote() },
            allNotesAction: { [weak self] in self?.toggleAllNotesPanel() },
            dictationAction: { [weak self] in self?.startDictation() },
            onError: { [weak self] msg in self?.editor.editorErrorMessage = msg }
        )

        richTextController.onOpenLink = { [weak self] url in self?.openPassageLink(url) }

        browserPermissions.configure(
            onEditorError: { [weak self] msg in self?.editor.editorErrorMessage = msg },
            onOpenApplication: { [weak self] bundleId in self?.openApplication(bundleIdentifier: bundleId) },
            onAutomationGranted: { [weak self] in self?.bringSetupWindowsToFront(activate: true) }
        )

        editor.canCreateNote = { [weak self] context in
            self?.canCreateNote(for: context) ?? true
        }

        notesState.onNotesDeleted = { [weak self] notes in
            self?.releaseDeletedNotesFromEditor(notes)
        }

        dictationHotKeyMonitor.onRelease = { [weak self] in
            self?.stopDictation()
        }

        dictationService.$partialTranscript
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.dictationPartialText = value }
            .store(in: &cancellables)

        dictationService.$isMicrophoneAuthorized
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.isMicrophoneAuthorized = value }
            .store(in: &cancellables)

        dictationService.$isSpeechRecognitionAuthorized
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.isSpeechRecognitionAuthorized = value }
            .store(in: &cancellables)

        // Dictation failures (recognizer unavailable, audio engine errors)
        // previously died silently inside the service; show them where the
        // user is looking.
        dictationService.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                if case .failed(let message) = state {
                    self?.editor.editorErrorMessage = message
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshPermissionStatus()

                // Deliberate return to Remora (Dock / Cmd-Tab / click) while
                // setting up: refresh the automation-based permissions too and
                // bring the buried setup window back to the front. Not
                // while the license window is up: activation is how that
                // window becomes key, and re-fronting Setup here would
                // take key straight back.
                if self.isAnySetupWindowVisible {
                    self.browserPermissions.refreshBrowserPermissionStates()
                    self.browserPermissions.refreshAppAutomationStates()
                    if self.licenseWindowController?.isVisible != true {
                        self.bringSetupWindowsToFront(activate: false)
                    }
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }

                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self.lastExternalApp = app
                }
                // The hotkey path brought this app forward itself and is
                // opening the drawer on the pointer's display: no follow.
                let isExpectedActivation = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier == self.expectedActivationPID

                Task { [weak self] in
                    guard let self else { return }

                    if self.editor.isEditorPresented {
                        // Follow the newly activated app with the AX
                        // observer so intra-app changes keep arriving
                        // as events.
                        self.editor.retargetContextObserver()

                        // Resolve context on a background thread so
                        // AppleScript / Accessibility API calls don't
                        // block the UI.
                        let context = await self.editor.resolveCurrentContextAsync()
                        guard self.editor.isEditorPresented else { return }

                        // No animation: if the drawer follows to another
                        // display, it slides in with the new context.
                        withTransaction(Transaction(animation: nil)) {
                            self.editor.applyRefreshedContext(context)
                        }
                    }

                    // Defer the reposition by one runloop tick so SwiftUI's
                    // re-render has time to commit to the layer.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        // While a picked note is on its way to its page,
                        // the apps coming forward aren't the destination;
                        // the drawer moves once, when it gets there.
                        if !self.editor.isContextFrozen, !isExpectedActivation,
                           self.panelController?.repositionToActiveScreenIfNeeded() == true,
                           self.isAllNotesStacked {
                            // The list doesn't cross displays with the
                            // note; it goes back under before the move.
                            self.closeStackedAllNotes()
                        }
                        self.allNotesPanelCtrl?.repositionToActiveScreenIfNeeded()
                    }
                }
            }
            .store(in: &cancellables)

        // While a picked note's page is coming forward, the app that
        // activates takes the keyboard and clears the main window; the
        // drawer holds the picked note through it and should look it,
        // so it takes main back until it can take key at the end.
        NotificationCenter.default.publisher(for: NSWindow.didResignMainNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, self.editor.isContextFrozen,
                      let window = notification.object as? NSWindow, window === self.panelController?.window,
                      window.isVisible, NSApp.mainWindow == nil else { return }
                window.makeMain()
            }
            .store(in: &cancellables)

        // An app the hotkey path just brought forward may take the
        // keyboard back a moment after the drawer opened; for that moment
        // the drawer takes it again.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, Date() < self.retakeKeyUntil,
                      let window = notification.object as? NSWindow, window === self.panelController?.window,
                      self.editor.isEditorPresented else { return }
                self.panelController?.makeKeyIfVisible()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.notesState.flush()
            }
            .store(in: &cancellables)

        refreshPermissionStatus()

        #if MAS_BUILD
        // The App Store purchase is the unlock; license keys don't exist
        // in this channel.
        storeService.$isUnlocked
            .receive(on: RunLoop.main)
            .sink { [weak self] unlocked in self?.isLicensed = unlocked }
            .store(in: &cancellables)
        storeService.start()
        #else
        checkStoredLicense()
        #endif

        if let recoveryMessage = store.loadRecoveryMessage {
            presentStorageRecoveryAlert(recoveryMessage)
        }

        // First launch: the app is a menu bar accessory with no window, so
        // without this a new user sees nothing happen at all. Defer a tick
        // so we're not presenting from inside init.
        if !hasCompletedOnboarding {
            DispatchQueue.main.async { [weak self] in
                self?.presentFirstRunWindow()
            }
        }

        // Build and draw the drawer now, invisibly, so the first hotkey
        // press after launch is as quick as every other (building it on
        // demand cost ~130 ms, and a slow first `makeKey` let the drawer's
        // first frames draw in the inactive style).
        DispatchQueue.main.async { [weak self] in
            self?.noteEditorPanelController.prewarm()
        }
        // All Notes too, a moment later: its first open is usually beside
        // a note that's already on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isAllNotesPanelPresented else { return }
            self.allNotesPanelController.prewarm()
        }

        #if DEBUG
        // UI-test hook: lets XCUITest drive a real window deterministically
        // instead of through the MenuBarExtra status item, which doesn't
        // reliably report its popover window to the accessibility tree.
        if let action = ProcessInfo.processInfo.environment["UITEST_LAUNCH_ACTION"] {
            DispatchQueue.main.async { [weak self] in
                self?.performUITestLaunchAction(action)
            }
        }
        // UI-test hook: moves the open drawer to the other display, as
        // switching to an app there would.
        if ProcessInfo.processInfo.environment["UITEST_REMOTE_TOGGLE"] != nil {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.remora.uitest.moveDrawerToOtherScreen"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelController?.moveToOtherScreenForTesting() }
            }
        }
        // UI-test hook: stands in for the quick-note hotkey, so motion
        // tests can open and close the drawer on demand.
        if ProcessInfo.processInfo.environment["UITEST_REMOTE_TOGGLE"] != nil {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.remora.uitest.toggleQuickNote"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.toggleQuickNote() }
            }
            // And for the All Notes hotkey, so the list's slide beside
            // the note can be measured the same way.
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.remora.uitest.toggleAllNotes"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.toggleAllNotesPanel() }
            }
            // And for picking a note in the list: the notification's
            // object is the note's context identifier.
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.remora.uitest.openNote"),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let identifier = notification.object as? String
                MainActor.assumeIsolated {
                    guard let self,
                          let note = self.notesState.notes.first(where: { $0.context.identifier == identifier }) else { return }
                    self.open(note)
                }
            }
        }
        #endif
    }

    #if DEBUG
    private func performUITestLaunchAction(_ action: String) {
        switch action {
        case "allNotes":
            openAllNotes()
        case "onboarding":
            showOnboarding()
        case "info":
            showInfoWindow()
        case "quickNote":
            toggleQuickNote()
        case "license":
            presentLicenseWindow()
        default:
            break
        }
    }
    #endif

    convenience init() {
        var storeDirectory: URL?
        #if DEBUG
        // UI tests point the store at a scratch folder so they never read
        // or modify the user's real notes. Compiled out of Release/MAS.
        if let path = ProcessInfo.processInfo.environment["UITEST_STORE_DIRECTORY"], !path.isEmpty {
            storeDirectory = URL(filePath: path, directoryHint: .isDirectory)
        }
        #endif
        self.init(
            store: NoteStore(directoryOverride: storeDirectory),
            contextResolver: ContextResolver(),
            hotKeyMonitor: GlobalHotKeyMonitor()
        )
    }

    func toggleQuickNote() {
        PanelMotionTrace.mark("hotkey")
        quickNoteHotkeyPressCount += 1
        // With the drawer open the hotkey closes it, and the list beside
        // it goes too.
        if editor.isEditorPresented {
            saveAndDismissEditor()
            return
        }

        if isAllNotesPanelPresented {
            dismissAllNotesPanel()
        }

        openQuickNoteWherePointerIs()
    }

    private var quickNoteRequestGeneration = 0
    /// The app the hotkey path brought forward, while its activation is
    /// expected: the display-follow that activation triggers is skipped,
    /// since the drawer is being opened on the pointer's display anyway.
    private var expectedActivationPID: pid_t?
    /// Until when the drawer takes the keyboard back if the app just
    /// brought forward grabs it a moment after the drawer opened.
    private var retakeKeyUntil: Date = .distantPast

    /// The drawer opens on the display the pointer is on. When the app in
    /// front has its window on another display, the window under the
    /// pointer is what the user is looking at: it is brought forward
    /// first, the note is for it, and the drawer opens beside it. With
    /// the pointer on the front app's own display, or over nothing, the
    /// front app keeps the note.
    private func openQuickNoteWherePointerIs() {
        quickNoteRequestGeneration += 1
        let generation = quickNoteRequestGeneration

        guard let pointer = PointerWindowLocator.pointerLocation(),
              let pointerScreen = PointerWindowLocator.screen(containing: pointer) else {
            openQuickNote(on: nil)
            return
        }

        let decision = PointerWindowLocator.decide(
            windows: PointerWindowLocator.onScreenWindows(),
            pointer: pointer,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        let frontScreen = decision.frontmostWindow.map { PointerWindowLocator.screen(containing: CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) } ?? nil
        guard let frontScreen, frontScreen.frame != pointerScreen.frame,
              let target = decision.windowUnderPointer,
              AXIsProcessTrusted(),
              let app = NSRunningApplication(processIdentifier: target.ownerPID) else {
            openQuickNote(on: pointerScreen)
            return
        }

        // Another display: bring the window under the pointer forward,
        // wait for its app to be in front, then open. Opening first would
        // hand the keyboard to the drawer only to lose it to the
        // activation a moment later, with the glass going light and back.
        let needsActivation = app.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier
        if needsActivation {
            expectedActivationPID = app.processIdentifier
        }
        Task { [weak self] in
            _ = await Task.detached(priority: .userInitiated) {
                PointerWindowLocator.raise(target)
            }.value
            guard let self else { return }
            defer { self.expectedActivationPID = nil }
            guard self.quickNoteRequestGeneration == generation else { return }
            if needsActivation {
                PointerWindowLocator.activate(app)
                let deadline = Date().addingTimeInterval(0.15)
                while Date() < deadline,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            guard self.quickNoteRequestGeneration == generation, !self.editor.isEditorPresented else { return }
            self.retakeKeyUntil = Date().addingTimeInterval(0.5)
            self.openQuickNote(on: pointerScreen, readsSelection: false)
        }
    }

    private func openQuickNote(on screen: NSScreen?, readsSelection: Bool = true) {
        // Trial gate: once the free-note allowance is used up, creating a
        // NEW note requires a license — but existing notes always stay
        // editable, so only block when the current context has no note.
        if !isLicensed && isTrialExhausted {
            presentQuickNoteEditorOrLicenseWall(readsSelection: readsSelection, screen: screen)
            return
        }

        presentQuickNoteEditor(readsSelection: readsSelection, screen: screen)
    }

    /// Trial-exhausted path: opens the editor when the current context
    /// already has a note, otherwise shows the license window. The
    /// decision needs the real context (the page, file or channel), which
    /// isn't knowable synchronously, so this always resolves first. The
    /// app-level context is no shortcut: a note attached to the browser
    /// itself would otherwise open the drawer on every page in it, and
    /// the drawer would then settle on the page as a new note.
    private func presentQuickNoteEditorOrLicenseWall(
        passageText: String? = nil,
        readsSelection: Bool = true,
        screen: NSScreen? = nil
    ) {
        let sourceApp = noteSourceApp()

        Task { [weak self] in
            guard let self else { return }
            let context = await self.editor.resolveCurrentContextAsync(for: sourceApp)
            guard !self.editor.isEditorPresented else { return }
            if self.notesState.note(for: context) != nil {
                self.presentQuickNoteEditor(
                    passageText: passageText,
                    resolvedContext: context,
                    readsSelection: readsSelection,
                    screen: screen
                )
            } else {
                self.presentLicenseWindow()
            }
        }
    }

    /// Slides the drawer in at once, on the app-level context, and lets
    /// the precise context (page, file, channel) and any selected passage
    /// land as they resolve — usually within the slide's first frames.
    /// Nothing waits before the slide: the drawer answers the hotkey.
    /// `passageText` supplies the selection when it arrived through the
    /// Services menu; `resolvedContext` skips resolution when the caller
    /// already has it. `readsSelection: false` skips the host selection
    /// read entirely (dictation: a held ⌘⇧D means "listen", not "quote",
    /// and the ⌘C fallback would fire while those modifiers are down).
    /// `screen` is the display the caller has chosen (the pointer's, from
    /// the hotkey); without it the drawer goes beside the front app.
    private func presentQuickNoteEditor(
        passageText: String? = nil,
        resolvedContext: NoteContext? = nil,
        readsSelection: Bool = true,
        screen: NSScreen? = nil
    ) {
        editor.editorErrorMessage = nil
        let sourceApp = noteSourceApp()
        let sourceBundleIdentifier = sourceApp?.bundleIdentifier
        let initialContext = resolvedContext ?? editor.quickApplicationContext(for: sourceApp)
        // A selection is only live in the app in front; the app behind
        // Remora would ignore the ⌘C.
        let sourceIsFrontmost = sourceApp?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Start both reads before the drawer takes anything from the host.
        let editorState = editor
        let contextTask: Task<NoteContext, Never>? = resolvedContext == nil
            ? Task { @MainActor in await editorState.resolveCurrentContextAsync(for: sourceApp) }
            : nil
        let panelController = noteEditorPanelController
        let richText = richTextController
        // Starts now, before the drawer does anything, so a Chromium host
        // gets its ⌘C straight away.
        let selectionRead: SelectionRead? = readsSelection && passageText == nil && sourceIsFrontmost
            ? EditorState.startSelectionRead(from: sourceApp) {
                // The host has handled its ⌘C: take key so typing lands here.
                guard editorState.isEditorPresented else { return }
                panelController.makeKeyIfVisible()
                richText.focus()
            }
            : nil

        editor.applyResolvedContextBeforePresenting(initialContext)
        if let passageText {
            attachPassage(text: passageText)
        }
        editor.isEditorPresented = true
        editor.startContextTracking()
        // The host must stay key until its selection has been read through
        // Accessibility or it has handled a ⌘C (it ignores one otherwise).
        // By now (the drawer took ~35 ms to set up) it almost always has, so
        // the drawer is key from its first frame — a non-key window draws
        // its glass in the lighter inactive style. Otherwise it takes key
        // when the host is done.
        let hostMustStayKey = selectionRead?.isHostDone == false
        noteEditorPanelController.present(makeKey: !hostMustStayKey, on: screen)
        browserPermissions.queueQuickNotePermissionRequestIfNeeded(sourceBundleIdentifier: sourceBundleIdentifier)

        // The context first, then the passage: a passage attached to the
        // app-level note would pin the drawer to it (a late context only
        // replaces an untouched note).
        Task { [weak self] in
            if let contextTask {
                let context = await contextTask.value
                guard let self, self.editor.isEditorPresented else { return }
                self.editor.applyLateResolvedContext(context, fallback: initialContext)
            }
            guard let self, self.editor.isEditorPresented else { return }
            self.generateQuickNoteTitleIfNeeded()
            if let selectionRead, let text = await selectionRead.text, self.editor.isEditorPresented {
                self.attachPassage(text: text)
            }
            DebugTrace.log("quickNote open: context=\(self.editor.activeContext?.identifier ?? "none")")
        }
    }

    /// Only once the context has settled, so the note isn't titled against
    /// the transient app-level fallback.
    private func generateQuickNoteTitleIfNeeded() {
        guard editor.isEditorPresented, isAutoTitleEnabled, editor.editorTitle.isEmpty,
              let context = editor.activeContext else { return }
        if let existingNote = notesState.note(for: context), !existingNote.body.isEmpty {
            editor.generateTitleIfNeeded(noteID: existingNote.id, body: existingNote.body, context: context)
        } else {
            editor.generateTitleFromContext(context: context)
        }
    }

    // MARK: - Passages

    /// The app a new note is for. When Remora itself is in front (its
    /// menu bar item, All Notes or Settings was just used, or it was just
    /// launched), the note is still for the app the user was working in,
    /// not for Remora.
    private func noteSourceApp() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return frontmost }
        if let lastExternalApp, !lastExternalApp.isTerminated { return lastExternalApp }
        return frontmost
    }

    /// Services menu entry ("Note This in Remora"): open the drawer for
    /// the current context with the sent text as a quoted passage.
    func captureQuickNote(passageText: String) {
        if editor.isEditorPresented {
            attachPassage(text: passageText)
            return
        }
        if !isLicensed && isTrialExhausted {
            presentQuickNoteEditorOrLicenseWall(passageText: passageText)
            return
        }
        presentQuickNoteEditor(passageText: passageText)
    }

    /// Every capture on the same context lands in the same note: append
    /// to the model (the source of truth after a context switch, which
    /// the text view may not have caught up with yet) and let SwiftUI
    /// push it to the view.
    private func attachPassage(text: String) {
        let passage = Passage(text: text, sourceURL: editor.activePageURL)
        editor.editorAttributedText = richTextController.appendingQuote(passage, to: editor.editorAttributedText)
        richTextController.wantsCaretAtEndAfterSync = true
        editor.scheduleAutosave()
    }

    /// A passage link was clicked: reopen in the browser the page was
    /// captured in, falling back to the default handler.
    func openPassageLink(_ url: URL) {
        open(url, preferringApplication: editor.activeContext?.sourceBundleIdentifier)
    }

    private func open(_ url: URL, preferringApplication bundleIdentifier: String?) {
        if let bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, _ in }
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Creating a note needs a license once the trial is used up; a
    /// context that already has a note is always editable.
    func canCreateNote(for context: NoteContext) -> Bool {
        isLicensed || !isTrialExhausted || notesState.note(for: context) != nil
    }

    func saveAndDismissEditor() {
        endDictationForDismiss()
        // Start the slide-out before the save: the flush writes
        // synchronously, and the close should answer the keypress, not
        // wait for the disk. The slide runs in the render server meanwhile.
        panelController?.dismiss()
        closeStackedAllNotes()
        editor.persistCurrentEditorContent()
        notesState.flush()
        resetEditorAfterDismiss()
    }

    func dismissEditor() {
        endDictationForDismiss()
        panelController?.dismiss()
        closeStackedAllNotes()
        resetEditorAfterDismiss()
    }

    /// The note is leaving, so the list beside it leaves with it. It fades
    /// rather than slides: the note's sheet is what hides the line the
    /// list slides behind.
    private func closeStackedAllNotes() {
        guard allNotesMode == .stacked else { return }
        allNotesMode = .hidden
        // The note slides out holding the keyboard, as it does when it
        // closes alone; the list, made main by that, leaves still active,
        // sliding off the display with it.
        panelController?.makeKeyIfVisible()
        allNotesPanelCtrl?.dismiss(style: .slideOffDisplay)
        pairStackPanels(false)
    }

    /// The drawer is closing under a live dictation (click outside, Escape,
    /// the quick-note hotkey, delete). Keep what has been recognised so far
    /// so it's saved with the note, and stop listening without waiting for
    /// the recogniser's final pass — the release hotkey has nothing left to
    /// do, so its monitor comes down too.
    private func endDictationForDismiss() {
        guard isDictating else { return }
        isDictating = false
        dictationPartialText = ""
        dictationHotKeyMonitor.stopMonitoring()
        let partial = dictationService.partialTranscript
        if !partial.isEmpty {
            richTextController.insertDictatedText(partial)
        }
        Task { [dictationService] in
            _ = await dictationService.stopListening()
        }
    }

    private func resetEditorAfterDismiss() {
        editor.isEditorPresented = false
        editor.isViewingOrphanedNote = false
        editor.isContextFrozen = false
        editor.stopContextTracking()
        editor.cancelAutosave()
    }

    func openAllNotes() {
        toggleAllNotesPanel()
    }

    func showOnboarding() {
        if editor.isEditorPresented {
            saveAndDismissEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.presentOnboardingWindow()
            }
            return
        }
        presentOnboardingWindow()
    }

    func showInfoWindow() {
        if editor.isEditorPresented {
            saveAndDismissEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.presentInfoWindow()
            }
            return
        }
        presentInfoWindow()
    }

    func toggleAllNotesPanel() {
        PanelMotionTrace.mark("listToggle", label: PanelMotionTrace.listLabel)
        // The note is sampled too while the list moves beside it.
        PanelMotionTrace.mark("listToggle", panel: panelController?.window)
        if isAllNotesPanelPresented {
            dismissAllNotesPanel()
            return
        }

        if editor.isEditorPresented {
            if revealAllNotesBesideEditor() { return }

            // The display is too narrow for the pair: swap them.
            saveAndDismissEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.presentAllNotesPanel()
            }
            return
        }

        presentAllNotesPanel()
    }

    private func presentAllNotesPanel() {
        resetAllNotesBrowsing()
        allNotesUsesStackedLayout = false
        allNotesMode = .alone
        allNotesPanelController.present()
    }

    /// Slides the list out from under the open note drawer, to its left.
    /// The note doesn't move. False when the display can't fit the pair.
    private func revealAllNotesBesideEditor() -> Bool {
        guard let anchor = noteEditorPanelController.stackAnchor,
              let frame = PanelLayout.stackedAllNotesFrame(
                editorFrame: anchor.frame,
                visibleFrame: anchor.visibleFrame
              ) else { return false }

        // So the list shows what has just been typed. An empty drawer
        // isn't a note yet, and isn't a reason to delete one either.
        editor.persistCurrentEditorContent(deleteIfEmpty: false)
        resetAllNotesBrowsing()
        allNotesUsesStackedLayout = true
        allNotesMode = .stacked
        // Beside each other the two sheets stay active by one being key
        // and the other main (see `NoteEditorPanel.stackSibling`). The
        // note is key now; it takes main before the list takes key, so it
        // never has a frame without either.
        pairStackPanels(true)
        panelController?.window?.makeMain()
        allNotesPanelController.present(placement: .stacked(frame: frame))
        return true
    }

    private func pairStackPanels(_ paired: Bool) {
        let note = panelController?.window as? NoteEditorPanel
        // Through the creating accessor: the first reveal pairs before the
        // list has ever been built.
        let list = (paired ? allNotesPanelController : allNotesPanelCtrl)?.window as? NoteEditorPanel
        note?.stackSibling = paired ? list : nil
        list?.stackSibling = paired ? note : nil
    }

    private func resetAllNotesBrowsing() {
        notesState.allNotesScrollResetID = UUID()
        notesState.selectedNoteIDs.removeAll()
        notesState.keyboardFocusedNoteID = nil
        notesState.searchText = ""
    }

    /// Closes the list: off the screen edge when it's alone, back under
    /// the note when it's beside it. The list had the keyboard; the note
    /// takes it back at once (the list becomes main for its slide out, so
    /// neither sheet changes look) unless the caller is about to hand it
    /// on.
    func dismissAllNotesPanel(returningKeyToEditor: Bool = true) {
        let wasStacked = allNotesMode == .stacked
        allNotesMode = .hidden
        allNotesPanelCtrl?.dismiss()
        guard wasStacked, editor.isEditorPresented else {
            pairStackPanels(false)
            return
        }
        if returningKeyToEditor {
            panelController?.makeKeyIfVisible()
            richTextController.focus()
        }
        // Unpair once the list is gone; until then its last key change
        // still has to keep the note main.
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelAnimation.dismissDuration + 0.05) { [weak self] in
            guard let self, !self.isAllNotesStacked else { return }
            self.pairStackPanels(false)
        }
    }

    private func presentOnboardingWindow() {
        refreshPermissionStatus()
        browserPermissions.refreshBrowserPermissionStates()
        browserPermissions.refreshAppAutomationStates()
        onboardingWindow.present()
    }

    private func presentFirstRunWindow() {
        refreshPermissionStatus()
        browserPermissions.refreshBrowserPermissionStates()

        if firstRunWindowController == nil {
            let controller = FirstRunWindowController()
            controller.install(appState: self)
            firstRunWindowController = controller
        }
        firstRunWindowController?.present()
    }

    private func presentInfoWindow() {
        infoWindow.present()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Self.onboardingDefaultsKey)
        firstRunWindowController?.dismiss()
        onboardingWindowController?.dismiss()
    }

    func openAccessibilitySettings() {
        // Register Remora in the TCC list and fire the native prompt (macOS
        // shows it at most once ever). Then always open the Accessibility
        // pane when access still isn't granted — otherwise a second click,
        // once the app is already listed, would be a silent no-op.
        requestAccessibilityAccessIfNeeded()
        if !isAccessibilityTrusted {
            SystemSettingsOpener.openPrivacyPane(.accessibility)
        }
        refreshPermissionStatus()
    }

    func refreshPermissionStatus() {
        let wasAccessibilityTrusted = isAccessibilityTrusted
        isAccessibilityTrusted = AXIsProcessTrusted()

        if !wasAccessibilityTrusted && isAccessibilityTrusted {
            browserPermissions.refreshBrowserPermissionStates()
        }

        dictationService.refreshPermissionStatus()
    }

    func edit(_ note: ContextNote) {
        editor.isContextFrozen = false
        editor.activeContext = note.context
        editor.loadEditorState(for: note)

        editor.isEditorPresented = true
        editor.startContextTracking()
        noteEditorPanelController.present()

        // Generate title asynchronously after presenting so the editor
        // appears instantly.
        if isAutoTitleEnabled && editor.editorTitle.isEmpty && !note.body.isEmpty {
            editor.generateTitleIfNeeded(noteID: note.id, body: note.body, context: note.context)
        }
    }

    func open(_ note: ContextNote) {
        // With the drawer already up (the list beside it, or a Recent row
        // in the menu bar), the picked note takes over the drawer in
        // place; nothing is closed and reopened.
        let drawerIsOpen = editor.isEditorPresented
        PanelMotionTrace.mark("pick", panel: panelController?.window)
        if drawerIsOpen {
            // The note that's already open: just put the list away.
            if editor.activeContext?.id == note.context.id, !editor.isViewingOrphanedNote {
                dismissAllNotesPanel()
                return
            }
            endDictationForDismiss()
            editor.persistCurrentEditorContent()
            notesState.flush()
            editor.isViewingOrphanedNote = false
            // Hold the drawer on the picked note while its page or file
            // comes forward; `edit` releases it and takes the keyboard.
            editor.isContextFrozen = true
            editor.activeContext = note.context
            editor.loadEditorState(for: note)
        }
        dismissAllNotesPanel()

        guard isContextReachable(note.context) else {
            editor.isViewingOrphanedNote = true
            Task { [weak self] in
                self?.edit(note)
                self?.editor.editorErrorMessage = "The original file or page for this note is no longer available. Navigate to its new home, then re-attach it below."
            }
            return
        }

        // A second click while the first is still looking for an open tab
        // supersedes it: only the latest one navigates and edits.
        openNoteGeneration += 1
        let generation = openNoteGeneration
        Task { [weak self] in
            guard let self else { return }
            if drawerIsOpen {
                // Let the list finish sliding under first: the app coming
                // forward takes the keyboard, and a list still on its way
                // would lose its active look for the rest of the slide.
                try? await Task.sleep(for: .milliseconds(Int(PanelAnimation.dismissDuration * 1000) + 60))
                guard openNoteGeneration == generation else { return }
            }
            let revealed = await revealIfAlreadyOpen(note.context)
            guard openNoteGeneration == generation else { return }
            if !revealed {
                navigate(to: note.context)
            }
            if drawerIsOpen {
                // The app coming forward takes the keyboard; the drawer,
                // still up with the picked note, takes it straight back
                // and keeps it for the moment the app may grab it again.
                retakeKeyUntil = Date().addingTimeInterval(0.5)
                panelController?.makeKeyIfVisible()
            }
            // Lets the front app settle so the editor's context tracking
            // sees the page or file the note belongs to.
            try? await Task.sleep(for: .milliseconds(350))
            guard openNoteGeneration == generation else { return }
            if drawerIsOpen, editor.isEditorPresented, editor.activeContext?.id == note.context.id {
                settleOpenDrawer(on: note)
            } else {
                edit(note)
            }
        }
    }

    /// The drawer already shows the picked note and its page has come
    /// forward: follow it to its display if it moved, and take the
    /// keyboard. The note isn't reloaded, so nothing typed meanwhile is
    /// lost.
    private func settleOpenDrawer(on note: ContextNote) {
        editor.isContextFrozen = false
        // Key first: the app that came forward took it, and a drawer that
        // follows to another display slides in with whatever it had.
        panelController?.makeKeyIfVisible()
        richTextController.focus()
        panelController?.repositionToActiveScreenIfNeeded()
        if isAutoTitleEnabled && editor.editorTitle.isEmpty && !note.body.isEmpty {
            editor.generateTitleIfNeeded(noteID: note.id, body: note.body, context: note.context)
        }
    }

    /// A note deleted from the list while it is open in the drawer: empty
    /// the drawer, or closing it would save the note straight back.
    private func releaseDeletedNotesFromEditor(_ notes: [ContextNote]) {
        // Only when it was this drawer's note that went: a drawer on a
        // context with no saved note yet keeps what is being typed.
        guard editor.isEditorPresented, let context = editor.activeContext,
              notes.contains(where: { $0.context.id == context.id }),
              notesState.note(for: context) == nil else { return }
        editor.cancelAutosave()
        editor.editorAttributedText = NSAttributedString(string: "")
        editor.editorTitle = ""
        editor.isActiveNotePinned = false
    }

    /// Brings the note's page, document or folder forward if it's already
    /// open somewhere, rather than opening a duplicate. Permission
    /// snapshots are taken here so the locator never triggers a prompt.
    private func revealIfAlreadyOpen(_ context: NoteContext) async -> Bool {
        var fileURL: URL?
        var stopAccessing = false
        if context.kind == .file, let resolved = resolvedFileURL(for: context) {
            fileURL = resolved.url
            stopAccessing = resolved.stopAccessing
        }
        defer {
            if stopAccessing {
                fileURL?.stopAccessingSecurityScopedResource()
            }
        }

        let scriptableBrowsers: Set<String> = {
            #if MAS_BUILD
            // Sandboxed builds have no browser Apple Events entitlement.
            return []
            #else
            return Set(
                BrowserURLProvider.supportedBrowsers
                    .map(\.bundleIdentifier)
                    .filter { browserPermissions.isBrowserAutomationKnownGranted($0) }
            )
            #endif
        }()

        let request = OpenContextLocator.Request(
            context: context,
            fileURL: fileURL,
            scriptableBrowserBundleIDs: scriptableBrowsers,
            // Context detection already scripts Finder whenever it's in
            // front (ContextResolver.currentFinderContextURL), so a Finder
            // note only exists if that works; the reveal adds no new prompt.
            finderScriptable: context.sourceBundleIdentifier == OpenContextLocator.finderBundleIdentifier
        )
        return await openContextLocator.revealIfOpen(request)
    }

    /// Rewrites an orphaned note's context to whatever the user is
    /// currently viewing. The panel is non-activating, so the frontmost
    /// app is still the one under the drawer.
    func relinkOrphanedNoteToCurrentContext() {
        guard editor.isViewingOrphanedNote,
              let oldContext = editor.activeContext,
              let note = notesState.note(for: oldContext) else { return }

        Task { [weak self] in
            guard let self else { return }
            let newContext = await self.editor.resolveCurrentContextAsync()
            guard self.editor.isEditorPresented, self.editor.isViewingOrphanedNote else { return }
            guard newContext.id != oldContext.id else { return }

            guard self.notesState.note(for: newContext) == nil else {
                self.editor.editorErrorMessage = "Couldn't re-attach: \(newContext.displayName) already has its own note."
                return
            }

            self.notesState.upsert(note.copying(context: newContext, updatedAt: .now))
            self.editor.activeContext = newContext
            self.editor.isViewingOrphanedNote = false
            self.editor.editorErrorMessage = nil
        }
    }

    func togglePinForSelectedNotes() {
        let selected = notesState.selectedNoteIDs
        guard let nextPinned = notesState.togglePinForSelectedNotes() else { return }

        if let context = editor.activeContext,
           let active = notesState.note(for: context),
           selected.contains(active.id) {
            editor.isActiveNotePinned = nextPinned
        }
    }

    func togglePin(_ note: ContextNote) {
        notesState.togglePin(note)

        if editor.activeContext?.id == note.context.id {
            editor.isActiveNotePinned = !note.isPinned
        }
    }

    func deleteActiveNote() {
        if let context = editor.activeContext, let existing = notesState.note(for: context) {
            notesState.delete(existing)
        }

        editor.editorAttributedText = NSAttributedString(string: "")
        editor.editorTitle = ""
        editor.editorErrorMessage = nil
        editor.isActiveNotePinned = false
        dismissEditor()
    }

    func togglePinForActiveNote() {
        guard let context = editor.activeContext else { return }

        let nextPinnedState = !editor.isActiveNotePinned
        editor.isActiveNotePinned = nextPinnedState

        // Persist writes the editor's content with the new pin state; when
        // the editor is empty it declines (returning false) — in that case
        // just flip the pin on an existing note, if any.
        if !editor.persistCurrentEditorContent(deleteIfEmpty: false),
           let existingNote = notesState.note(for: context) {
            notesState.upsert(existingNote.copying(updatedAt: .now, isPinned: nextPinnedState))
        }
    }

    func setOnboardingWindowVisible(_ isVisible: Bool) {
        isOnboardingWindowVisible = isVisible
        updatePermissionPolling()
    }

    func setFirstRunWindowVisible(_ isVisible: Bool) {
        isFirstRunWindowVisible = isVisible
        updatePermissionPolling()
    }

    // MARK: - Permission Polling & Window Fronting

    /// While a setup window is visible, poll permission status once a second
    /// so cards flip to "granted" on their own after the user toggles a
    /// switch in System Settings — no manual re-click needed. Idle cost is
    /// zero: the task exists only while a setup window is open.
    private func updatePermissionPolling() {
        if isAnySetupWindowVisible {
            startPermissionPolling()
        } else {
            stopPermissionPolling()
        }
    }

    private func startPermissionPolling() {
        guard permissionPollTask == nil else { return }
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.pollPermissionsTick()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = nil
    }

    private func pollPermissionsTick() {
        // Cheap, non-prompting reads only. refreshPermissionStatus covers
        // Accessibility + microphone + speech, and the Automation refresh
        // asks macOS for the grant itself; never run Apple Event probes
        // here (they block and can fire consent prompts).
        let wasAccessibilityTrusted = isAccessibilityTrusted
        refreshPermissionStatus()
        browserPermissions.refreshAutomationStatuses()

        // The payoff moment: the instant Accessibility flips on, pop the
        // wizard back to the front with its now-green card. Trust only flips
        // after the System Settings auth completes, so this never fights the
        // auth sheet.
        if !wasAccessibilityTrusted && isAccessibilityTrusted {
            bringSetupWindowsToFront(activate: true)
        }
    }

    /// Re-fronts whichever setup window is visible. `activate` also pulls the
    /// whole app forward (used on the grant transition); the reactivation
    /// path passes false since the app is already frontmost.
    private func bringSetupWindowsToFront(activate: Bool) {
        guard isAnySetupWindowVisible else { return }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
        firstRunWindowController?.bringToFrontIfVisible()
        onboardingWindowController?.bringToFrontIfVisible()
    }

    var appVersionDisplay: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - License & Trial

    static let trialNoteLimit = 5

    var trialNotesUsed: Int {
        min(notesState.trialNotesCreated, Self.trialNoteLimit)
    }

    var isTrialExhausted: Bool {
        notesState.trialNotesCreated >= Self.trialNoteLimit
    }

    #if !MAS_BUILD
    private func checkStoredLicense() {
        guard let key = LicenseValidator.storedLicenseKey() else {
            isLicensed = false
            return
        }
        do {
            try LicenseValidator.validate(key)
            isLicensed = true
        } catch {
            isLicensed = false
        }
    }
    #endif

    func presentLicenseWindow() {
        guard !isLicensed else { return }
        if licenseWindowController == nil {
            let controller = LicenseWindowController()
            controller.install(appState: self)
            licenseWindowController = controller
        }
        licenseWindowController?.present()
    }

    func dismissLicenseWindow() {
        licenseWindowController?.dismiss()

        if isLicensed && !hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.presentFirstRunWindow()
            }
        }
    }

    #if MAS_BUILD
    func restorePurchases() {
        Task { [weak self] in
            await self?.storeService.restorePurchases()
        }
    }
    #else
    func deactivateLicense() {
        LicenseValidator.removeLicenseKey()
        isLicensed = false
    }
    #endif

    /// Remora is an accessory app (`LSUIElement`) and never shows a Dock
    /// icon, so nothing here touches the activation policy.
    private static func resolveAutoTitleEnabled() -> Bool {
        let defaults = UserDefaults.standard
        // Clear what the old "Generate note titles automatically" toggle
        // persisted, so a stale `false` can't keep titles off now that there
        // is no toggle to turn them back on. This only touches the app's
        // domain; the launch argument lives in NSArgumentDomain.
        defaults.removeObject(forKey: "autoTitleEnabled")
        #if DEBUG
        // bool(forKey:) understands the string form (`-autoTitleEnabled NO`)
        // that launch arguments put in NSArgumentDomain.
        if defaults.object(forKey: "autoTitleEnabled") != nil {
            return defaults.bool(forKey: "autoTitleEnabled")
        }
        #endif
        return true
    }

    /// Hold-to-talk. With no drawer open, the hotkey opens one first — the
    /// same entry rules as the quick-note hotkey minus the toggle — so
    /// dictation always has a note to land in.
    private func startDictation() {
        guard !isDictating else { return }

        if !editor.isEditorPresented {
            if isAllNotesPanelPresented {
                dismissAllNotesPanel()
            }
            if !isLicensed && isTrialExhausted {
                presentQuickNoteEditorOrLicenseWall(readsSelection: false)
                // Past the trial the drawer (or the license window)
                // only appears once the context has resolved, so there
                // is nothing to dictate into on this press.
                guard editor.isEditorPresented else { return }
            } else {
                presentQuickNoteEditor(readsSelection: false)
            }
        }

        // Dictation is hold-to-talk: release detection uses a global
        // flagsChanged monitor, which only receives events from other apps
        // when Accessibility is granted. Without it, dictation would never
        // stop — so this is a hard requirement at point of use.
        guard AXIsProcessTrusted() else {
            requestAccessibilityAccessIfNeeded()
            editor.editorErrorMessage = "Dictation needs Accessibility access to detect when you release the hotkey."
            return
        }

        guard dictationService.isFullyAuthorized else {
            requestDictationPermissionsIfNeeded()
            editor.editorErrorMessage = "Dictation needs Microphone and Speech Recognition access — grant both in Setup."
            return
        }

        dictationService.startListening()

        guard dictationService.state == .listening else { return }

        isDictating = true
        dictationHotKeyMonitor.startMonitoringRelease(
            modifiers: hotkeys.dictationHotKeyShortcut.nsEventModifierFlags
        )
    }

    private func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        dictationPartialText = ""

        Task { [weak self] in
            guard let self else { return }
            let transcript = await self.dictationService.stopListening()
            if !transcript.isEmpty {
                self.richTextController.insertDictatedText(transcript)
            }
        }
    }

    func requestDictationPermissionsIfNeeded() {
        if !dictationService.isMicrophoneAuthorized {
            dictationService.requestMicrophonePermission()
        }
        if !dictationService.isSpeechRecognitionAuthorized {
            dictationService.requestSpeechRecognitionPermission()
        }
    }

    func requestMicrophoneAccess() {
        dictationService.requestMicrophonePermission()
    }

    func requestSpeechRecognitionAccess() {
        dictationService.requestSpeechRecognitionPermission()
    }

    private func navigate(to context: NoteContext) {
        // An app-scheme target (`linear://`) whose app has since been
        // removed falls through to the context's web URL.
        if let navigationTarget = context.navigationTarget,
           let url = URL(string: navigationTarget),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            open(url, preferringApplication: context.kind == .url ? context.sourceBundleIdentifier : nil)
            return
        }

        switch context.kind {
        case .application:
            if let bundleIdentifier = launchBundleIdentifier(for: context) {
                openApplication(bundleIdentifier: bundleIdentifier)
            }
        case .url:
            openURLContext(context)
        case .file:
            openFileContext(context)
        }
    }

    private func launchBundleIdentifier(for context: NoteContext) -> String? {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: context.identifier) != nil {
            return context.identifier
        }

        if context.identifier.hasPrefix("slack:") || context.displayName.hasPrefix("Slack") {
            return "com.tinyspeck.slackmacgap"
        }

        if context.identifier.hasPrefix("figma:") || context.displayName.hasPrefix("Figma") {
            return "com.figma.Desktop"
        }

        if context.identifier.hasPrefix("linear:") {
            return "com.linear"
        }

        return nil
    }

    private func openApplication(bundleIdentifier: String) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return
        }

        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?
            .activate(options: [.activateAllWindows])
    }

    private func openURLContext(_ context: NoteContext) {
        let urlString = context.secondaryLabel ?? context.identifier

        guard let url = URL(string: urlString) else {
            return
        }

        open(url, preferringApplication: context.sourceBundleIdentifier)
    }

    private func openFileContext(_ context: NoteContext) {
        guard let (fileURL, stopAccessing) = resolvedFileURL(for: context) else { return }
        defer {
            if stopAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        if let sourceBundleIdentifier = context.sourceBundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sourceBundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            var urlsToOpen: [URL] = []
            if let sourceRootPath = context.sourceRootPath, !sourceRootPath.isEmpty {
                let rootURL = URL(fileURLWithPath: sourceRootPath)
                if rootURL.path != fileURL.path {
                    urlsToOpen.append(rootURL)
                }
            }
            urlsToOpen.append(fileURL)
            NSWorkspace.shared.open(urlsToOpen, withApplicationAt: appURL, configuration: configuration) { _, _ in }
            return
        }

        NSWorkspace.shared.open(fileURL)
    }

    private func isContextReachable(_ context: NoteContext) -> Bool {
        switch context.kind {
        case .file:
            if let bookmarkData = context.fileBookmarkData {
                var isStale = false
                if let resolvedURL = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withoutUI, .withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    let didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                    let exists = FileManager.default.fileExists(atPath: resolvedURL.path)
                    if didStartAccessing { resolvedURL.stopAccessingSecurityScopedResource() }
                    return exists
                }
            }
            let path = context.secondaryLabel ?? context.identifier
            return FileManager.default.fileExists(atPath: path)
        case .url:
            let urlString = context.secondaryLabel ?? context.identifier
            if let url = URL(string: urlString), url.isFileURL {
                return FileManager.default.fileExists(atPath: url.path)
            }
            return true
        case .application:
            return true
        }
    }

    private func resolvedFileURL(for context: NoteContext) -> (url: URL, stopAccessing: Bool)? {
        if let bookmarkData = context.fileBookmarkData {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                return (resolvedURL, didStartAccessing)
            }
        }

        if let secondaryLabel = context.secondaryLabel, !secondaryLabel.isEmpty {
            return (URL(fileURLWithPath: secondaryLabel), false)
        }

        guard context.identifier.hasPrefix("/") else { return nil }
        return (URL(fileURLWithPath: context.identifier), false)
    }

    private func requestAccessibilityAccessIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        // Register Remora in the Accessibility list and fire the native
        // prompt. AXIsProcessTrustedWithOptions is a local trust check — it
        // does no cross-process messaging, so it's safe on the main thread.
        //
        // We deliberately do NOT issue a cross-process AX query here (e.g.
        // AXUIElementCopyAttributeValue on the system-wide element): while the
        // app is untrusted, that call blocks on an AX IPC timeout — and under
        // the App Sandbox it can hang the main thread indefinitely, beachballing
        // the app. If the prompt doesn't auto-list the app, the onboarding copy
        // points the user to the System Settings "＋" button as the fallback.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    private func presentStorageRecoveryAlert(_ message: String) {
        // Defer past init so the alert doesn't run inside AppState's
        // construction, and activate first — as an accessory app we have
        // no window for the alert to attach to otherwise.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Remora had trouble reading your notes"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private var noteEditorPanelController: NoteEditorPanelController {
        if let panelController {
            return panelController
        }

        let controller = NoteEditorPanelController()
        controller.install(appState: self)
        controller.onClickOutside = { [weak self] in
            guard let self, self.editor.isEditorPresented else { return }
            self.saveAndDismissEditor()
        }
        // Beside the note, the list is part of the drawer: a click in it
        // is not a click outside.
        controller.stackFrames = { [weak self] in
            guard let self, self.isAllNotesStacked,
                  let frame = self.allNotesPanelCtrl?.visibleFrame else { return [] }
            return [frame]
        }
        panelController = controller
        return controller
    }

    private var allNotesPanelController: AllNotesPanelController {
        if let allNotesPanelCtrl {
            return allNotesPanelCtrl
        }

        let controller = AllNotesPanelController()
        controller.install(appState: self)
        controller.onClickOutside = { [weak self] in
            guard let self, self.isAllNotesPanelPresented else { return }
            self.dismissAllNotesPanel()
        }
        allNotesPanelCtrl = controller
        return controller
    }

    private var onboardingWindow: OnboardingWindowController {
        if let onboardingWindowController {
            return onboardingWindowController
        }

        let controller = OnboardingWindowController()
        controller.install(appState: self)
        onboardingWindowController = controller
        return controller
    }

    private var infoWindow: InfoWindowController {
        if let infoWindowController {
            return infoWindowController
        }

        let controller = InfoWindowController()
        controller.install(appState: self)
        infoWindowController = controller
        return controller
    }

}
