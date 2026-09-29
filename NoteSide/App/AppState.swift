//
//  AppState.swift
//  NoteSide
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
    var isAllNotesPanelPresented = false
    var showsDockIcon: Bool
    let formatting: FormattingState
    var isAutoTitleEnabled: Bool {
        didSet { UserDefaults.standard.set(isAutoTitleEnabled, forKey: "autoTitleEnabled") }
    }
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
    private var panelController: NoteEditorPanelController?
    private var allNotesPanelCtrl: AllNotesPanelController?
    private var onboardingWindowController: OnboardingWindowController?
    private var firstRunWindowController: FirstRunWindowController?
    private var infoWindowController: InfoWindowController?
    private var licenseWindowController: LicenseWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var isAllNotesPanelVisible = false
    private var isOnboardingWindowVisible = false
    private var isFirstRunWindowVisible = false
    private var isInfoWindowVisible = false
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
        // bool(forKey:) also understands the string form that launch
        // arguments (`-autoTitleEnabled NO`) put in NSArgumentDomain.
        let initialAutoTitle = UserDefaults.standard.object(forKey: "autoTitleEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "autoTitleEnabled")
        isAutoTitleEnabled = initialAutoTitle
        showsDockIcon = false
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
            titleGenerator: titleGen
        )

        // Wire the closure after all stored properties are initialized so
        // we can safely capture [weak self].
        editor.isAutoTitleEnabled = { [weak self] in self?.isAutoTitleEnabled ?? initialAutoTitle }

        hotkeys.configure(
            quickNoteAction: { [weak self] in self?.toggleQuickNote() },
            allNotesAction: { [weak self] in self?.toggleAllNotesPanel() },
            dictationAction: { [weak self] in self?.startDictation() },
            onError: { [weak self] msg in self?.editor.editorErrorMessage = msg }
        )

        richTextController.onOpenLink = { [weak self] url in self?.openPassageLink(url) }
        richTextController.onQuoteSelectionRequested = { [weak self] in self?.quoteCurrentSelection() }

        browserPermissions.configure(
            onEditorError: { [weak self] msg in self?.editor.editorErrorMessage = msg },
            onOpenApplication: { [weak self] bundleId in self?.openApplication(bundleIdentifier: bundleId) }
        )

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

                // Deliberate return to NoteSide (Dock / Cmd-Tab / click) while
                // setting up: refresh the automation-based permissions too and
                // bring the buried setup window back to the front.
                if self.isAnySetupWindowVisible {
                    self.browserPermissions.refreshBrowserPermissionStates()
                    self.browserPermissions.refreshAppAutomationStates()
                    self.bringSetupWindowsToFront(activate: false)
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }

                let oldSnapshot = self.panelController?.captureCurrentSnapshot()

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

                        // Suppress SwiftUI's contentTransition animation
                        // so the snapshot captured below isn't mid-fade.
                        withTransaction(Transaction(animation: nil)) {
                            self.editor.applyRefreshedContext(context)
                        }
                    }

                    // Defer the reposition by one runloop tick so SwiftUI's
                    // re-render has time to commit to the layer.
                    DispatchQueue.main.async { [weak self] in
                        self?.panelController?.repositionToActiveScreenIfNeeded(
                            oldContextSnapshot: oldSnapshot
                        )
                        self?.allNotesPanelCtrl?.repositionToActiveScreenIfNeeded()
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.notesState.flush()
            }
            .store(in: &cancellables)

        refreshPermissionStatus()
        applyDockIconPreference()

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

        #if DEBUG
        // UI-test hook: lets XCUITest drive a real window deterministically
        // instead of through the MenuBarExtra status item, which doesn't
        // reliably report its popover window to the accessibility tree.
        if let action = ProcessInfo.processInfo.environment["UITEST_LAUNCH_ACTION"] {
            DispatchQueue.main.async { [weak self] in
                self?.performUITestLaunchAction(action)
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
        if isAllNotesPanelPresented {
            dismissAllNotesPanel()
        }

        if editor.isEditorPresented {
            saveAndDismissEditor()
            return
        }

        // Trial gate: once the free-note allowance is used up, creating a
        // NEW note requires a license — but existing notes always stay
        // editable, so only block when the current context has no note.
        if !isLicensed && isTrialExhausted {
            presentQuickNoteEditorOrLicenseWall()
            return
        }

        presentQuickNoteEditor()
    }

    /// Trial-exhausted path: opens the editor when the current context
    /// already has a note, otherwise shows the license window. The full
    /// context isn't knowable synchronously (AppleScript/AX), so when the
    /// cheap app-level lookup misses we resolve first, then decide.
    private func presentQuickNoteEditorOrLicenseWall() {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let sourceBundleIdentifier = frontmostApp?.bundleIdentifier
        let fallbackContext = editor.quickApplicationContext(for: frontmostApp)

        if notesState.note(for: fallbackContext) != nil {
            presentQuickNoteEditor()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let context = await self.editor.resolveCurrentContextAsync(preferredBundleIdentifier: sourceBundleIdentifier)
            guard !self.editor.isEditorPresented else { return }
            if self.notesState.note(for: context) != nil {
                self.presentQuickNoteEditor()
            } else {
                self.presentLicenseWindow()
            }
        }
    }

    /// `passageText` supplies the selection when it arrived through the
    /// Services menu; otherwise the host app's selection is read via
    /// Accessibility while the context resolves.
    private func presentQuickNoteEditor(passageText: String? = nil) {
        editor.editorErrorMessage = nil
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let sourceBundleIdentifier = frontmostApp?.bundleIdentifier

        // Open with the cheap frontmost-app context immediately — the full
        // resolve below runs AppleScript/AX and must never gate the panel.
        // An Apple Event to a busy target can block for seconds.
        let initialContext = editor.quickApplicationContext(for: frontmostApp)

        editor.activeContext = initialContext
        editor.loadEditorState(for: initialContext)

        editor.isEditorPresented = true
        editor.startContextTracking()
        // Slide in now, but don't take key status until the host app's
        // selection has been read: Chromium only answers ⌘C while its
        // window is key.
        noteEditorPanelController.present(makeKey: false)

        Task { [weak self] in
            guard let self else { return }
            DebugTrace.log("quickNote frontmost=\(frontmostApp?.bundleIdentifier ?? "nil") passageText=\(passageText != nil)")
            let captured = passageText == nil ? await self.editor.captureSelectionText(from: frontmostApp) : nil
            DebugTrace.log("quickNote captured=\(captured.map { String($0.prefix(60)) } ?? "nil")")
            guard self.editor.isEditorPresented else { return }
            self.noteEditorPanelController.makeKeyIfVisible()
            self.richTextController.focus()

            await self.editor.resolveInitialQuickNoteContextAsync(from: initialContext, sourceBundleIdentifier: sourceBundleIdentifier)
            self.browserPermissions.queueQuickNotePermissionRequestIfNeeded(sourceBundleIdentifier: sourceBundleIdentifier)
            if let text = passageText ?? captured, self.editor.isEditorPresented {
                self.attachPassage(text: text)
            }

            // Generate the title only after the context has settled so we
            // don't title the note against the transient app-level fallback.
            guard self.editor.isEditorPresented, self.isAutoTitleEnabled, self.editor.editorTitle.isEmpty,
                  let context = self.editor.activeContext else { return }
            if let existingNote = self.notesState.note(for: context), !existingNote.body.isEmpty {
                self.editor.generateTitleIfNeeded(noteID: existingNote.id, body: existingNote.body, context: context)
            } else {
                self.editor.generateTitleFromContext(context: context)
            }
        }
    }

    // MARK: - Passages

    /// Services menu entry ("Note This in NoteSide"): open the drawer for
    /// the current context with the sent text as a quoted passage.
    func captureQuickNote(passageText: String) {
        if editor.isEditorPresented {
            attachPassage(text: passageText)
            return
        }
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let context = editor.quickApplicationContext(for: frontmostApp)
        guard canCreateNote(for: context) else {
            presentLicenseWindow()
            return
        }
        presentQuickNoteEditor(passageText: passageText)
    }

    /// Toolbar / ⇧⌘Q: quote whatever is selected in the app behind the drawer.
    func quoteCurrentSelection() {
        var trusted = AXIsProcessTrusted()
        #if DEBUG
        if ProcessInfo.processInfo.environment["UITEST_SELECTION_TEXT"] != nil { trusted = true }
        #endif
        guard trusted else {
            editor.editorErrorMessage = "Quoting a selection needs Accessibility access. Turn it on in Permissions & Setup, or use Services → Note This in NoteSide."
            return
        }
        let hostApp = NSWorkspace.shared.frontmostApplication
        noteEditorPanelController.yieldKey(to: hostApp)
        Task { [weak self] in
            guard let self else { return }
            let text = await self.editor.captureSelectionText(from: hostApp)
            self.noteEditorPanelController.makeKeyIfVisible()
            self.richTextController.focus()
            guard self.editor.isEditorPresented else { return }
            guard let text else {
                let name = hostApp?.localizedName ?? "the app in front"
                self.editor.editorErrorMessage = "Nothing is selected in \(name)."
                return
            }
            self.editor.editorErrorMessage = nil
            self.insertPassage(Passage(text: text, sourceURL: self.editor.activePageURL))
        }
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

    /// Toolbar / ⇧⌘Q path: the view is live, insert at the caret.
    private func insertPassage(_ passage: Passage) {
        richTextController.insertQuote(passage)
        editor.editorAttributedText = editor.currentEditorAttributedTextSnapshot()
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
        editor.persistCurrentEditorContent()
        notesState.flush()
        dismissEditor()
    }

    func dismissEditor() {
        editor.isEditorPresented = false
        editor.isViewingOrphanedNote = false
        editor.stopContextTracking()
        editor.cancelAutosave()
        panelController?.dismiss()
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
        if isAllNotesPanelPresented {
            dismissAllNotesPanel()
            return
        }

        if editor.isEditorPresented {
            saveAndDismissEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.presentAllNotesPanel()
            }
            return
        }

        presentAllNotesPanel()
    }

    private func presentAllNotesPanel() {
        notesState.allNotesScrollResetID = UUID()
        notesState.selectedNoteIDs.removeAll()
        notesState.keyboardFocusedNoteID = nil
        notesState.searchText = ""
        isAllNotesPanelPresented = true
        allNotesPanelController.present()
    }

    func dismissAllNotesPanel() {
        isAllNotesPanelPresented = false
        allNotesPanelCtrl?.dismiss()
    }

    private func presentOnboardingWindow() {
        refreshPermissionStatus()
        browserPermissions.refreshBrowserPermissionStates()
        browserPermissions.refreshAppAutomationStates()
        onboardingWindow.present()
        NSApp.activate(ignoringOtherApps: true)
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
        NSApp.activate(ignoringOtherApps: true)
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
        // Register NoteSide in the TCC list and fire the native prompt (macOS
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
        dismissAllNotesPanel()

        if isContextReachable(note.context) {
            navigate(to: note.context)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.edit(note)
            }
        } else {
            editor.isViewingOrphanedNote = true
            Task { [weak self] in
                self?.edit(note)
                self?.editor.editorErrorMessage = "The original file or page for this note is no longer available. Navigate to its new home, then re-attach it below."
            }
        }
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

    func setShowsDockIcon(_ showsDockIcon: Bool) {
        self.showsDockIcon = showsDockIcon
        applyDockIconPreference()
    }

    func setAllNotesPanelVisible(_ isVisible: Bool) {
        isAllNotesPanelVisible = isVisible
        applyDockIconPreference()
    }

    func setOnboardingWindowVisible(_ isVisible: Bool) {
        isOnboardingWindowVisible = isVisible
        applyDockIconPreference()
        updatePermissionPolling()
    }

    func setFirstRunWindowVisible(_ isVisible: Bool) {
        isFirstRunWindowVisible = isVisible
        applyDockIconPreference()
        updatePermissionPolling()
    }

    func setInfoWindowVisible(_ isVisible: Bool) {
        isInfoWindowVisible = isVisible
        applyDockIconPreference()
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
        // Accessibility + microphone + speech; never run browser/app-automation
        // Apple Event probes here (they block and can fire consent prompts).
        let wasAccessibilityTrusted = isAccessibilityTrusted
        refreshPermissionStatus()

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

    private func applyDockIconPreference() {
        let shouldShowDockIcon = isAllNotesPanelVisible || isAnySetupWindowVisible || isInfoWindowVisible
        showsDockIcon = shouldShowDockIcon
        NSApp?.setActivationPolicy(shouldShowDockIcon ? .regular : .accessory)
    }


    private func startDictation() {
        guard editor.isEditorPresented, !isDictating else { return }

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
            editor.editorErrorMessage = "Dictation needs Microphone and Speech Recognition access — grant both in Permissions & Setup."
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
        if let navigationTarget = context.navigationTarget,
           let url = URL(string: navigationTarget) {
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

        // Register NoteSide in the Accessibility list and fire the native
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
            alert.messageText = "NoteSide had trouble reading your notes"
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
