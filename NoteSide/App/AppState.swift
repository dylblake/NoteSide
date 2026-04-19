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
    enum BrowserPermissionState: String {
        case notInstalled
        case notGranted
        case granted
    }

    var hasCompletedOnboarding: Bool
    var isAccessibilityTrusted = AXIsProcessTrusted()
    var isBrowserAutomationGranted = false
    var onboardingContextPreview: NoteContext?
    var browserAutomationMessage = "Put Safari, Chrome, or Arc in front, then test browser access."
    private(set) var browserPermissionStates: [String: BrowserPermissionState] = [:]
    private(set) var notes: [ContextNote] = [] {
        didSet { _sortedNotes = notes.sorted { $0.updatedAt > $1.updatedAt } }
    }
    private var _sortedNotes: [ContextNote] = []
    var activeContext: NoteContext?
    var editorText = ""
    var editorAttributedText = NSAttributedString(string: "")
    var editorErrorMessage: String?
    var isEditorPresented = false
    var searchText = ""
    var hotKeyShortcut: HotKeyShortcut
    var allNotesHotKeyShortcut: HotKeyShortcut
    var isAllNotesPanelPresented = false
    var showsDockIcon: Bool
    var allNotesScrollResetID = UUID()
    var currentEditorTextStyle: RichTextEditorController.TextStyle = .body
    var isEditorBoldActive = false
    var isEditorItalicActive = false
    var isEditorUnderlineActive = false
    var isActiveNotePinned = false
    var editorTitle = ""
    var isAutoTitleEnabled: Bool {
        didSet { UserDefaults.standard.set(isAutoTitleEnabled, forKey: "autoTitleEnabled") }
    }
    var infoStatusMessage: String?
    var selectedNoteIDs: Set<UUID> = []
    var isLicensed: Bool = false
    var isDictating = false
    var dictationPartialText = ""
    var dictationHotKeyShortcut: HotKeyShortcut
    var isMicrophoneAuthorized = false
    var isSpeechRecognitionAuthorized = false

    private let store: NoteStore
    private let titleGenerator = NoteTitleGenerator()
    private let contextResolver: ContextResolver
    private let browserURLProvider = BrowserURLProvider()
    let richTextController = RichTextEditorController()
    private let hotKeyMonitor: GlobalHotKeyMonitor
    let dictationService = DictationService()
    private let dictationHotKeyMonitor = DictationHotKeyMonitor()
    private var panelController: NoteEditorPanelController?
    private var allNotesPanelCtrl: AllNotesPanelController?
    private var onboardingWindowController: OnboardingWindowController?
    private var infoWindowController: InfoWindowController?
    private var licenseWindowController: LicenseWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingAutomationRequests: Set<String> = []
    private var contextPollingTask: Task<Void, Never>?
    private var isAllNotesPanelVisible = false
    private var isOnboardingWindowVisible = false
    private var isInfoWindowVisible = false

    private static let onboardingDefaultsKey = "hasCompletedOnboarding"
    private static let hotKeyDefaultsKey = "globalHotKeyShortcut"
    private static let allNotesHotKeyDefaultsKey = "allNotesHotKeyShortcut"
    private static let dictationHotKeyDefaultsKey = "dictationHotKeyShortcut"
    private static let browserPermissionDefaultsPrefix = "browserPermissionState."
    private static let browserPermissionMigrationKey = "browserPermissionStatesMigratedV2"
    static let supportedBrowsers = BrowserURLProvider.supportedBrowsers

    init(
        store: NoteStore,
        contextResolver: ContextResolver,
        hotKeyMonitor: GlobalHotKeyMonitor
    ) {
        self.store = store
        self.contextResolver = contextResolver
        self.hotKeyMonitor = hotKeyMonitor
        Self.migrateBrowserPermissionStatesIfNeeded()
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingDefaultsKey)
        isAutoTitleEnabled = UserDefaults.standard.object(forKey: "autoTitleEnabled") as? Bool ?? true
        hotKeyShortcut = Self.loadHotKeyShortcut()
        allNotesHotKeyShortcut = Self.loadAllNotesHotKeyShortcut()
        dictationHotKeyShortcut = Self.loadDictationHotKeyShortcut()
        showsDockIcon = false
        notes = store.loadNotes()
        _sortedNotes = notes.sorted { $0.updatedAt > $1.updatedAt }

        richTextController.onSelectionAttributesChange = { [weak self] formattingState in
            self?.currentEditorTextStyle = formattingState.textStyle
            self?.isEditorBoldActive = formattingState.isBold
            self?.isEditorItalicActive = formattingState.isItalic
            self?.isEditorUnderlineActive = formattingState.isUnderlined
        }

        registerHotKey()
        registerAllNotesHotKey()
        registerDictationHotKey()

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

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshPermissionStatus()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }

                let oldSnapshot = self.panelController?.captureCurrentSnapshot()

                Task { [weak self] in
                    guard let self else { return }

                    if self.isEditorPresented {
                        // Resolve context on a background thread so
                        // AppleScript / Accessibility API calls don't
                        // block the UI.
                        let context = await self.resolveCurrentContextAsync()
                        guard self.isEditorPresented else { return }

                        // Suppress SwiftUI's contentTransition animation
                        // so the snapshot captured below isn't mid-fade.
                        withTransaction(Transaction(animation: nil)) {
                            self.applyRefreshedContext(context)
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

        refreshPermissionStatus()
        applyDockIconPreference()
        checkStoredLicense()

    }

    convenience init() {
        self.init(
            store: NoteStore(),
            contextResolver: ContextResolver(),
            hotKeyMonitor: GlobalHotKeyMonitor()
        )
    }

    func toggleQuickNote() async {
        // License gate: require a valid license before opening the editor.
        if !isLicensed {
            presentLicenseWindow()
            return
        }

        if isAllNotesPanelPresented {
            dismissAllNotesPanel()
        }

        if isEditorPresented {
            saveAndDismissEditor()
            return
        }

        editorErrorMessage = nil
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let sourceBundleIdentifier = frontmostApp?.bundleIdentifier
        let fallbackContext = quickApplicationContext(for: frontmostApp)

        // Try to resolve the full context (URL, file, etc.) immediately
        // so the panel opens with the correct context instead of briefly
        // flashing the generic app name.
        let resolvedContext = resolveCurrentContext(preferredBundleIdentifier: sourceBundleIdentifier)
        let initialContext = resolvedContext.id != fallbackContext.id ? resolvedContext : fallbackContext

        activeContext = initialContext
        let existingNote = note(for: initialContext)
        editorAttributedText = attributedText(for: initialContext)
        editorText = editorAttributedText.string
        editorTitle = existingNote?.title ?? ""
        isActiveNotePinned = existingNote?.isPinned ?? false
        isEditorPresented = true
        startContextPolling()
        noteEditorPanelController.present()

        // Generate a title if the note has none and auto-title is on.
        if isAutoTitleEnabled && editorTitle.isEmpty {
            if let existingNote, !existingNote.body.isEmpty {
                generateTitleIfNeeded(noteID: existingNote.id, body: existingNote.body, context: initialContext)
            } else {
                generateTitleFromContext(context: initialContext)
            }
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.isEditorPresented else { return }
            await self.resolveInitialQuickNoteContextAsync(from: initialContext, sourceBundleIdentifier: sourceBundleIdentifier)
            self.queueQuickNotePermissionRequestIfNeeded(sourceBundleIdentifier: sourceBundleIdentifier)
        }
    }

    func saveAndDismissEditor() {
        guard let context = activeContext else {
            dismissEditor()
            return
        }

        let currentAttributedText = currentEditorAttributedTextSnapshot()
        let trimmed = currentAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let existing = note(for: context) {
                notes.removeAll { $0.id == existing.id }
                persistNotes()
            }
        } else {
            let existingNote = note(for: context)
            let existingID = existingNote?.id ?? UUID()
            let createdAt = existingNote?.createdAt ?? .now
            let userTitle = editorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentTitle: String? = userTitle.isEmpty ? existingNote?.title : userTitle
            let note = ContextNote(
                id: existingID,
                context: context,
                body: trimmed,
                richTextData: archivedRichText(from: currentAttributedText),
                createdAt: createdAt,
                updatedAt: .now,
                isPinned: existingNote?.isPinned ?? isActiveNotePinned,
                title: currentTitle
            )
            upsert(note)

            if currentTitle == nil && isAutoTitleEnabled {
                generateTitleIfNeeded(noteID: existingID, body: trimmed, context: context)
            }
        }

        dismissEditor()
    }

    func dismissEditor() {
        isEditorPresented = false
        stopContextPolling()
        panelController?.dismiss()
    }

    func openAllNotes() {
        toggleAllNotesPanel()
    }

    func showOnboarding() {
        if isEditorPresented {
            saveAndDismissEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.presentOnboardingWindow()
            }
            return
        }
        presentOnboardingWindow()
    }

    func showInfoWindow() {
        if isEditorPresented {
            saveAndDismissEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.presentInfoWindow()
            }
            return
        }
        presentInfoWindow()
    }

    func toggleAllNotesPanel() {
        if !isLicensed {
            presentLicenseWindow()
            return
        }

        if isAllNotesPanelPresented {
            dismissAllNotesPanel()
            return
        }

        if isEditorPresented {
            saveAndDismissEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.presentAllNotesPanel()
            }
            return
        }

        presentAllNotesPanel()
    }

    private func presentAllNotesPanel() {
        allNotesScrollResetID = UUID()
        selectedNoteIDs.removeAll()
        isAllNotesPanelPresented = true
        allNotesPanelController.present()
    }

    func dismissAllNotesPanel() {
        isAllNotesPanelPresented = false
        allNotesPanelCtrl?.dismiss()
    }

    private func presentOnboardingWindow() {
        refreshPermissionStatus()
        refreshBrowserPermissionStates()
        hasCompletedOnboarding = false
        onboardingWindow.present()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentInfoWindow() {
        infoWindow.present()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Self.onboardingDefaultsKey)
    }

    func openAccessibilitySettings() {
        requestAccessibilityAccessIfNeeded()
        refreshPermissionStatus()
    }

    func refreshPermissionStatus() {
        let wasAccessibilityTrusted = isAccessibilityTrusted
        isAccessibilityTrusted = AXIsProcessTrusted()

        if !wasAccessibilityTrusted && isAccessibilityTrusted {
            refreshBrowserPermissionStates()
        }

        dictationService.refreshPermissionStatus()
    }

    func previewCurrentContext() {
        onboardingContextPreview = resolveCurrentContext()
    }

    func probeBrowserAutomation() {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let attempt = browserURLProvider.probeFrontmostBrowserAttempt(frontmostBundleIdentifier: frontmostBundleIdentifier)
        applyBrowserAutomationAttempt(attempt)
    }

    func requestAutomationAccess(for bundleIdentifier: String) {
        let browserName = browserName(for: bundleIdentifier)
        browserAutomationMessage = "Requesting Automation access for \(browserName)..."
        queueAutomationRequest(for: bundleIdentifier, activatesBrowser: true)
    }

    func openAutomationSettings() {
        openSettingsPane(candidates: [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security"
        ])
    }

    func edit(_ note: ContextNote) {
        activeContext = note.context
        editorAttributedText = attributedText(for: note)
        editorText = editorAttributedText.string
        editorTitle = note.title ?? ""
        editorErrorMessage = nil
        isActiveNotePinned = note.isPinned
        isEditorPresented = true
        startContextPolling()
        noteEditorPanelController.present()

        if isAutoTitleEnabled && editorTitle.isEmpty && !note.body.isEmpty {
            generateTitleIfNeeded(noteID: note.id, body: note.body, context: note.context)
        }
    }

    func open(_ note: ContextNote) {
        dismissAllNotesPanel()
        navigate(to: note.context)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.edit(note)
        }
    }

    func delete(_ note: ContextNote) {
        notes.removeAll { $0.id == note.id }
        persistNotes()
    }

    func toggleSelection(_ noteID: UUID) {
        if selectedNoteIDs.contains(noteID) {
            selectedNoteIDs.remove(noteID)
        } else {
            selectedNoteIDs.insert(noteID)
        }
    }

    func clearSelection() {
        selectedNoteIDs.removeAll()
    }

    func deleteSelectedNotes() {
        guard !selectedNoteIDs.isEmpty else { return }
        let toDelete = selectedNoteIDs
        notes.removeAll { toDelete.contains($0.id) }
        persistNotes()
        selectedNoteIDs.removeAll()
    }

    func togglePinForSelectedNotes() {
        guard !selectedNoteIDs.isEmpty else { return }
        let selected = selectedNoteIDs
        // If everything in the selection is already pinned, unpin all.
        // Otherwise, pin everything (so a mixed selection becomes all-pinned).
        let selectedNotes = notes.filter { selected.contains($0.id) }
        let allPinned = selectedNotes.allSatisfy(\.isPinned)
        let nextPinned = !allPinned

        notes = notes.map { note in
            guard selected.contains(note.id) else { return note }
            return ContextNote(
                id: note.id,
                context: note.context,
                body: note.body,
                richTextData: note.richTextData,
                createdAt: note.createdAt,
                updatedAt: .now,
                isPinned: nextPinned,
                title: note.title
            )
        }
        persistNotes()

        // Sync the editor's pin state if its active note was in the selection.
        if let context = activeContext,
           let active = note(for: context),
           selected.contains(active.id) {
            isActiveNotePinned = nextPinned
        }

        selectedNoteIDs.removeAll()
    }

    func togglePin(_ note: ContextNote) {
        let updatedNote = ContextNote(
            id: note.id,
            context: note.context,
            body: note.body,
            richTextData: note.richTextData,
            createdAt: note.createdAt,
            updatedAt: .now,
            isPinned: !note.isPinned,
            title: note.title
        )
        upsert(updatedNote)

        if activeContext?.id == note.context.id {
            isActiveNotePinned = updatedNote.isPinned
        }
    }

    func deleteActiveNote() {
        if let context = activeContext, let existing = note(for: context) {
            delete(existing)
        }

        editorAttributedText = NSAttributedString(string: "")
        editorText = ""
        editorTitle = ""
        editorErrorMessage = nil
        isActiveNotePinned = false
        dismissEditor()
    }

    func togglePinForActiveNote() {
        guard let context = activeContext else { return }

        let nextPinnedState = !isActiveNotePinned
        isActiveNotePinned = nextPinnedState

        let currentAttributedText = currentEditorAttributedTextSnapshot()
        let trimmed = currentAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)

        // If editor has content, save it with the new pin state
        if !trimmed.isEmpty {
            let existing = note(for: context)
            let existingID = existing?.id ?? UUID()
            let createdAt = existing?.createdAt ?? .now
            let userTitle = editorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentTitle: String? = userTitle.isEmpty ? existing?.title : userTitle
            let updatedNote = ContextNote(
                id: existingID,
                context: context,
                body: trimmed,
                richTextData: archivedRichText(from: currentAttributedText),
                createdAt: createdAt,
                updatedAt: .now,
                isPinned: nextPinnedState,
                title: currentTitle
            )
            upsert(updatedNote)
            return
        }

        // If editor is empty but there's an existing note, just update the pin state
        if let existingNote = note(for: context) {
            let updatedNote = ContextNote(
                id: existingNote.id,
                context: existingNote.context,
                body: existingNote.body,
                richTextData: existingNote.richTextData,
                createdAt: existingNote.createdAt,
                updatedAt: .now,
                isPinned: nextPinnedState,
                title: existingNote.title
            )
            upsert(updatedNote)
        }
    }

    func applyHeadingStyle() {
        richTextController.apply(style: .heading)
    }

    func applySubheadingStyle() {
        richTextController.apply(style: .subheading)
    }

    func applyBodyStyle() {
        richTextController.apply(style: .body)
    }

    func toggleBold() {
        richTextController.toggleBold()
    }

    func toggleItalic() {
        richTextController.toggleItalic()
    }

    func toggleUnderline() {
        richTextController.toggleUnderline()
    }

    func insertBulletedList() {
        richTextController.insertBulletedList()
    }

    func insertNumberedList() {
        richTextController.insertNumberedList()
    }

    func updateHotKeyKeyCode(_ keyCode: UInt32) {
        hotKeyShortcut = hotKeyShortcut.updating(keyCode: keyCode)
        persistAndRegisterHotKey()
    }

    func setHotKeyShortcut(_ shortcut: HotKeyShortcut) {
        hotKeyShortcut = shortcut
        persistAndRegisterHotKey()
    }

    func setHotKeyModifier(_ modifier: UInt32, enabled: Bool) {
        hotKeyShortcut = hotKeyShortcut.updating(set: modifier, enabled: enabled)
        persistAndRegisterHotKey()
    }

    func setAllNotesHotKeyShortcut(_ shortcut: HotKeyShortcut) {
        allNotesHotKeyShortcut = shortcut
        persistAndRegisterAllNotesHotKey()
    }

    func setDictationHotKeyShortcut(_ shortcut: HotKeyShortcut) {
        dictationHotKeyShortcut = shortcut
        persistAndRegisterDictationHotKey()
    }

    var allNotesHotKeyDisplayString: String {
        allNotesHotKeyShortcut.displayString
    }

    var dictationHotKeyDisplayString: String {
        dictationHotKeyShortcut.displayString
    }

    func setShowsDockIcon(_ showsDockIcon: Bool) {
        self.showsDockIcon = false
        applyDockIconPreference()
    }

    func setAllNotesPanelVisible(_ isVisible: Bool) {
        isAllNotesPanelVisible = isVisible
        applyDockIconPreference()
    }

    func setOnboardingWindowVisible(_ isVisible: Bool) {
        isOnboardingWindowVisible = isVisible
        applyDockIconPreference()
    }

    func setInfoWindowVisible(_ isVisible: Bool) {
        isInfoWindowVisible = isVisible
        applyDockIconPreference()
    }

    var appVersionDisplay: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    func checkForUpdates() {
        infoStatusMessage = "Automatic update checks are not configured in this build yet."
    }

    // MARK: - License

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
                self?.presentOnboardingWindow()
            }
        }
    }

    func deactivateLicense() {
        LicenseValidator.removeLicenseKey()
        isLicensed = false
    }

    var hotKeyDisplayString: String {
        hotKeyShortcut.displayString
    }

    var availableHotKeyKeys: [HotKeyShortcut.KeyOption] {
        HotKeyShortcut.availableKeys
    }

    var filteredNotes: [ContextNote] {
        guard !searchText.isEmpty else { return sortedNotes }

        // Tag-specific search: when the query is "#tag", match against extracted tags
        if searchText.hasPrefix("#") {
            let tagQuery = String(searchText.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
            if !tagQuery.isEmpty {
                return sortedNotes.filter { note in
                    note.tags.contains { $0.localizedCaseInsensitiveContains(tagQuery) }
                }
            }
        }

        return sortedNotes.filter { note in
            note.context.displayName.localizedCaseInsensitiveContains(searchText)
                || note.context.identifier.localizedCaseInsensitiveContains(searchText)
                || (note.context.secondaryLabel?.localizedCaseInsensitiveContains(searchText) ?? false)
                || note.body.localizedCaseInsensitiveContains(searchText)
                || (note.title?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var groupedNotes: [(kind: NoteContext.Kind, notes: [ContextNote])] {
        Dictionary(grouping: filteredNotes, by: \.context.kind)
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { ($0.key, $0.value) }
    }

    var recentNotes: [ContextNote] {
        Array(sortedNotes.prefix(5))
    }

    private var sortedNotes: [ContextNote] { _sortedNotes }

    private static func migrateBrowserPermissionStatesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: browserPermissionMigrationKey) else { return }

        // Earlier builds promoted browsers to `.granted` based on a no-tab
        // AppleScript response that didn't actually exercise the Apple Events
        // permission check. Wipe those stale values so the new conservative
        // logic can re-derive accurate state.
        for browser in supportedBrowsers {
            defaults.removeObject(forKey: browserPermissionDefaultsPrefix + browser.bundleIdentifier)
        }
        defaults.set(true, forKey: browserPermissionMigrationKey)
    }

    private static func loadHotKeyShortcut() -> HotKeyShortcut {
        guard
            let data = UserDefaults.standard.data(forKey: hotKeyDefaultsKey),
            let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
        else {
            return .default
        }

        return shortcut
    }

    private static func loadAllNotesHotKeyShortcut() -> HotKeyShortcut {
        guard
            let data = UserDefaults.standard.data(forKey: allNotesHotKeyDefaultsKey),
            let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
        else {
            return .allNotesDefault
        }

        return shortcut
    }

    private static func loadDictationHotKeyShortcut() -> HotKeyShortcut {
        guard
            let data = UserDefaults.standard.data(forKey: dictationHotKeyDefaultsKey),
            let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
        else {
            return .dictationDefault
        }

        return shortcut
    }

    private func note(for context: NoteContext) -> ContextNote? {
        notes.first { $0.context.id == context.id }
    }

    private func quickApplicationContext(for app: NSRunningApplication?) -> NoteContext {
        NoteContext(
            kind: .application,
            identifier: app?.bundleIdentifier ?? "unknown",
            displayName: app?.localizedName ?? "Current Context",
            secondaryLabel: app?.bundleIdentifier,
            navigationTarget: nil
        )
    }

    private func resolveInitialQuickNoteContext(from fallbackContext: NoteContext, sourceBundleIdentifier: String?) {
        guard isEditorPresented, activeContext?.id == fallbackContext.id else { return }

        let context = resolveCurrentContext(preferredBundleIdentifier: sourceBundleIdentifier)
        guard context.id != fallbackContext.id else { return }

        let hasUnsavedEditorText = !editorAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !hasUnsavedEditorText else { return }

        activeContext = context
        editorAttributedText = attributedText(for: context)
        editorText = editorAttributedText.string
        editorTitle = note(for: context)?.title ?? ""
        editorErrorMessage = nil
        isActiveNotePinned = note(for: context)?.isPinned ?? false
    }

    private func resolveInitialQuickNoteContextAsync(from fallbackContext: NoteContext, sourceBundleIdentifier: String?) async {
        guard isEditorPresented, activeContext?.id == fallbackContext.id else { return }

        let context = await resolveCurrentContextAsync(preferredBundleIdentifier: sourceBundleIdentifier)
        guard context.id != fallbackContext.id else { return }

        let hasUnsavedEditorText = !editorAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !hasUnsavedEditorText else { return }

        activeContext = context
        editorAttributedText = attributedText(for: context)
        editorText = editorAttributedText.string
        editorTitle = note(for: context)?.title ?? ""
        editorErrorMessage = nil
        isActiveNotePinned = note(for: context)?.isPinned ?? false
    }

    private func refreshEditorContextIfNeeded() {
        guard isEditorPresented else { return }
        let context = resolveCurrentContext()
        applyRefreshedContext(context)
    }

    private func applyRefreshedContext(_ context: NoteContext) {
        // Same logical note (matching id), but the file was renamed/moved or
        // some display field changed. Refresh the active context and rewrite
        // the persisted note's context so the panel shows the new name and
        // disk state stays in sync — but don't reload editor content.
        if let active = activeContext, context.id == active.id {
            guard context != active else { return }
            activeContext = context
            if let existing = note(for: context) {
                let updated = ContextNote(
                    id: existing.id,
                    context: context,
                    body: existing.body,
                    richTextData: existing.richTextData,
                    createdAt: existing.createdAt,
                    updatedAt: existing.updatedAt,
                    isPinned: existing.isPinned,
                    title: existing.title
                )
                upsert(updated)
            }
            return
        }

        persistEditorStateForActiveContext()
        activeContext = context
        let existingNote = note(for: context)
        editorAttributedText = attributedText(for: context)
        editorText = editorAttributedText.string
        editorTitle = existingNote?.title ?? ""
        editorErrorMessage = nil
        isActiveNotePinned = existingNote?.isPinned ?? false

        // Generate a title for the new context if it doesn't have one.
        if isAutoTitleEnabled && editorTitle.isEmpty {
            if let existingNote, !existingNote.body.isEmpty {
                generateTitleIfNeeded(noteID: existingNote.id, body: existingNote.body, context: context)
            } else {
                generateTitleFromContext(context: context)
            }
        }
    }

    private func resolveCurrentContext(preferredBundleIdentifier: String? = nil) -> NoteContext {
        let bundleIdentifier = preferredBundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Check if this is a supported browser and if we should attempt automation
        let shouldAttemptBrowserAutomation: Bool = {
            guard let bundleId = bundleIdentifier else { return false }
            guard browserURLProvider.supports(bundleIdentifier: bundleId) else { return false }

            let state = browserPermissionStates[bundleId]
            // Attempt if: granted, OR never attempted before (nil)
            return state == .granted || state == nil
        }()

        // If this is a first-time browser attempt, probe it and record the result
        if shouldAttemptBrowserAutomation,
           let bundleId = bundleIdentifier,
           browserPermissionStates[bundleId] == nil {
            let attempt = browserURLProvider.accessAttempt(bundleIdentifier: bundleId, activatesBrowser: false)

            switch attempt.result {
            case .success:
                setBrowserPermissionState(.granted, for: bundleId)
            case .automationDenied:
                setBrowserPermissionState(.notGranted, for: bundleId)
            case .noTab, .unavailable, .notBrowser:
                // Inconclusive — Safari's `exists front document` can return
                // empty without ever triggering the Apple Events permission
                // check, so an empty result is not proof of access.
                break
            }
        }

        let allowBrowserAutomation = bundleIdentifier.map { browserPermissionStates[$0] == .granted } ?? false
        return contextResolver.resolveCurrentContext(allowBrowserAutomation: allowBrowserAutomation)
    }

    /// Async version of resolveCurrentContext that runs AppleScript and
    /// Accessibility API calls on a background thread, keeping the main
    /// thread free for UI work.
    private func resolveCurrentContextAsync(preferredBundleIdentifier: String? = nil) async -> NoteContext {
        let bundleIdentifier = preferredBundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let permissionStates = browserPermissionStates
        let browserProvider = browserURLProvider
        let resolver = contextResolver

        let shouldAttemptBrowserAutomation: Bool = {
            guard let bundleId = bundleIdentifier else { return false }
            guard browserProvider.supports(bundleIdentifier: bundleId) else { return false }
            let state = permissionStates[bundleId]
            return state == .granted || state == nil
        }()
        let isFirstAttempt = shouldAttemptBrowserAutomation
            && (bundleIdentifier.map { permissionStates[$0] == nil } ?? false)

        // Run the heavy AppleScript / Accessibility work off the main thread
        let (context, probeSuccess): (NoteContext, Bool?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var probeSuccess: Bool? = nil

                if isFirstAttempt, let bundleId = bundleIdentifier {
                    let attempt = browserProvider.accessAttempt(bundleIdentifier: bundleId, activatesBrowser: false)
                    switch attempt.result {
                    case .success: probeSuccess = true
                    case .automationDenied: probeSuccess = false
                    default: break
                    }
                }

                var allowBrowserAutomation = bundleIdentifier.map { permissionStates[$0] == .granted } ?? false
                if probeSuccess == true {
                    allowBrowserAutomation = true
                }

                let resolved = resolver.resolveCurrentContext(allowBrowserAutomation: allowBrowserAutomation)
                continuation.resume(returning: (resolved, probeSuccess))
            }
        }

        // Apply probe results back on main actor
        if let probeSuccess, let bundleId = bundleIdentifier {
            setBrowserPermissionState(probeSuccess ? .granted : .notGranted, for: bundleId)
        }

        return context
    }

    private var shouldRefreshDetailedContext: Bool {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }

        // Poll whenever the in-app context can change without an app switch:
        // browser tabs (granted browsers) and code editors (file focus moves
        // within the same process, so didActivateApplication never fires).
        if browserPermissionStates[bundleIdentifier] == .granted {
            return true
        }
        return Self.intraAppPollingBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Starts a background polling loop that periodically re-resolves the
    /// current context for apps that support intra-app context changes
    /// (browser tabs, editor files, Slack channels, etc.). The heavy
    /// AppleScript / Accessibility work runs off the main thread.
    private func startContextPolling() {
        stopContextPolling()
        contextPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { break }
                guard let self, self.isEditorPresented, self.shouldRefreshDetailedContext else {
                    if self == nil { break }
                    continue
                }
                let context = await self.resolveCurrentContextAsync()
                guard !Task.isCancelled, self.isEditorPresented else { break }
                self.applyRefreshedContext(context)
            }
        }
    }

    private func stopContextPolling() {
        contextPollingTask?.cancel()
        contextPollingTask = nil
    }

    private static let intraAppPollingBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.tinyspeck.slackmacgap",
        "com.tinyspeck.slackmacgap2",
        "com.figma.Desktop"
    ]

    private func attributedText(for context: NoteContext) -> NSAttributedString {
        guard let note = note(for: context) else {
            return NSAttributedString(string: "")
        }
        return attributedText(for: note)
    }

    private func attributedText(for note: ContextNote) -> NSAttributedString {
        if
            let richTextData = note.richTextData,
            let attributed = try? NSAttributedString(
                data: richTextData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        {
            return attributed
        }

        return NSAttributedString(string: note.body)
    }

    private func upsert(_ note: ContextNote) {
        notes.removeAll { $0.context.id == note.context.id }
        notes.append(note)
        persistNotes()
    }

    private func persistNotes() {
        do {
            try store.save(notes: notes)
        } catch {
            editorErrorMessage = "Could not save notes: \(error.localizedDescription)"
        }
    }

    private func persistEditorStateForActiveContext() {
        guard let context = activeContext else { return }

        let currentAttributedText = currentEditorAttributedTextSnapshot()
        let trimmed = currentAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let existing = note(for: context) {
                notes.removeAll { $0.id == existing.id }
                persistNotes()
            }
            return
        }

        let existingNote = note(for: context)
        let existingID = existingNote?.id ?? UUID()
        let createdAt = existingNote?.createdAt ?? .now
        let userTitle = editorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTitle: String? = userTitle.isEmpty ? existingNote?.title : userTitle
        let note = ContextNote(
            id: existingID,
            context: context,
            body: trimmed,
            richTextData: archivedRichText(from: currentAttributedText),
            createdAt: createdAt,
            updatedAt: .now,
            isPinned: existingNote?.isPinned ?? isActiveNotePinned,
            title: currentTitle
        )
        upsert(note)

        if currentTitle == nil && isAutoTitleEnabled {
            generateTitleIfNeeded(noteID: existingID, body: trimmed, context: context)
        }
    }

    private func generateTitleIfNeeded(noteID: UUID, body: String, context: NoteContext) {
        Task { [weak self] in
            guard let self else { return }
            if let generated = await self.titleGenerator.generateTitle(body: body, context: context) {
                guard let idx = self.notes.firstIndex(where: { $0.id == noteID }) else { return }
                let existing = self.notes[idx]
                // Don't overwrite if a title was set in the meantime
                guard existing.title == nil || existing.title?.isEmpty == true else { return }
                let updated = ContextNote(
                    id: existing.id,
                    context: existing.context,
                    body: existing.body,
                    richTextData: existing.richTextData,
                    createdAt: existing.createdAt,
                    updatedAt: existing.updatedAt,
                    isPinned: existing.isPinned,
                    title: generated
                )
                self.upsert(updated)

                // Update the editor title if the note is currently open
                if self.isEditorPresented,
                   self.activeContext?.id == context.id,
                   self.editorTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.editorTitle = generated
                }
            }
        }
    }

    private func generateTitleFromContext(context: NoteContext) {
        Task { [weak self] in
            guard let self else { return }
            if let generated = await self.titleGenerator.generateTitle(body: "", context: context) {
                // Only apply if the user hasn't typed a title in the meantime
                guard self.editorTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.editorTitle = generated
            }
        }
    }

    private func currentEditorAttributedTextSnapshot() -> NSAttributedString {
        richTextController.currentAttributedText() ?? editorAttributedText
    }

    private func archivedRichText(from attributedText: NSAttributedString) -> Data? {
        try? attributedText.data(
            from: NSRange(location: 0, length: attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    private func persistAndRegisterHotKey() {
        if let data = try? JSONEncoder().encode(hotKeyShortcut) {
            UserDefaults.standard.set(data, forKey: Self.hotKeyDefaultsKey)
        }

        registerHotKey()
    }

    private func persistAndRegisterAllNotesHotKey() {
        if let data = try? JSONEncoder().encode(allNotesHotKeyShortcut) {
            UserDefaults.standard.set(data, forKey: Self.allNotesHotKeyDefaultsKey)
        }

        registerAllNotesHotKey()
    }

    private func persistAndRegisterDictationHotKey() {
        if let data = try? JSONEncoder().encode(dictationHotKeyShortcut) {
            UserDefaults.standard.set(data, forKey: Self.dictationHotKeyDefaultsKey)
        }

        registerDictationHotKey()
    }

    private func applyDockIconPreference() {
        let shouldShowDockIcon = isAllNotesPanelVisible || isOnboardingWindowVisible || isInfoWindowVisible
        showsDockIcon = shouldShowDockIcon
        NSApp?.setActivationPolicy(shouldShowDockIcon ? .regular : .accessory)
    }

    private func registerHotKey() {
        do {
            try hotKeyMonitor.register(id: 1, shortcut: hotKeyShortcut) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !AXIsProcessTrusted() {
                        self.requestAccessibilityAccessIfNeeded()
                        return
                    }
                    await self.toggleQuickNote()
                }
            }
            editorErrorMessage = nil
        } catch {
            editorErrorMessage = error.localizedDescription
        }
    }

    private func registerAllNotesHotKey() {
        do {
            try hotKeyMonitor.register(id: 2, shortcut: allNotesHotKeyShortcut) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !AXIsProcessTrusted() {
                        self.requestAccessibilityAccessIfNeeded()
                        return
                    }
                    self.toggleAllNotesPanel()
                }
            }
        } catch {
            editorErrorMessage = error.localizedDescription
        }
    }

    private func registerDictationHotKey() {
        do {
            try hotKeyMonitor.register(id: 3, shortcut: dictationHotKeyShortcut) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !AXIsProcessTrusted() {
                        self.requestAccessibilityAccessIfNeeded()
                        return
                    }
                    self.startDictation()
                }
            }
        } catch {
            editorErrorMessage = error.localizedDescription
        }
    }

    private func startDictation() {
        guard isEditorPresented, !isDictating else { return }

        guard dictationService.isFullyAuthorized else {
            requestDictationPermissionsIfNeeded()
            return
        }

        dictationService.startListening()

        guard dictationService.state == .listening else { return }

        isDictating = true
        dictationHotKeyMonitor.startMonitoringRelease(
            modifiers: dictationHotKeyShortcut.nsEventModifierFlags
        )
    }

    private func stopDictation() {
        guard isDictating else { return }
        let transcript = dictationService.stopListening()
        isDictating = false
        dictationPartialText = ""

        if !transcript.isEmpty {
            richTextController.insertDictatedText(transcript)
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
            NSWorkspace.shared.open(url)
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

        NSWorkspace.shared.open(url)
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

    private func browserName(for bundleIdentifier: String) -> String {
        browserURLProvider.descriptor(for: bundleIdentifier)?.title ?? "browser"
    }

    private func openSettingsPane(candidates: [String]) {
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func queueQuickNotePermissionRequestIfNeeded(sourceBundleIdentifier: String?) {
        guard let sourceBundleIdentifier, browserURLProvider.supports(bundleIdentifier: sourceBundleIdentifier) else {
            return
        }

        if browserPermissionStates[sourceBundleIdentifier] != .granted {
            let browserName = browserName(for: sourceBundleIdentifier)
            browserAutomationMessage = "Browser access is not enabled for \(browserName) yet. Use Permissions & Setup to request it."
        }
    }

    private func applyBrowserAutomationAttempt(_ attempt: BrowserAutomationAttemptResult) {
        print("Browser automation debug: \(attempt.debugDetails)")
        applyBrowserAutomationResult(attempt.result)
    }

    private func applyBrowserAutomationResult(_ result: BrowserAutomationProbeResult) {
        browserAutomationMessage = result.message

        switch result {
        case .success(let browserName, _):
            isBrowserAutomationGranted = true
            editorErrorMessage = nil
            setBrowserPermissionState(.granted, for: bundleIdentifier(for: browserName))
        case .automationDenied(let browserName), .unavailable(let browserName):
            isBrowserAutomationGranted = false
            editorErrorMessage = result.message
            setBrowserPermissionState(.notGranted, for: bundleIdentifier(for: browserName))
        case .noTab, .notBrowser:
            // Inconclusive — empty/no-tab responses can occur without an
            // actual Apple Events permission grant, so don't change state.
            break
        }
    }

    private func refreshBrowserPermissionStates() {
        for browser in Self.supportedBrowsers {
            // Check if we've previously attempted this browser
            let storedState = storedBrowserPermissionState(for: browser.bundleIdentifier)

            // If not installed, mark as such
            if !isBrowserInstalled(browser.bundleIdentifier) {
                // Only set to notInstalled if we've tracked this browser before
                if storedState != .notInstalled {
                    browserPermissionStates[browser.bundleIdentifier] = .notInstalled
                }
                continue
            }

            // Only refresh state for browsers we've attempted before
            guard storedState != .notInstalled else {
                // Browser hasn't been attempted yet - don't set any state
                continue
            }

            // If browser is running, probe it to check actual permission state
            if browserURLProvider.isRunning(bundleIdentifier: browser.bundleIdentifier) {
                let attempt = browserURLProvider.accessAttempt(
                    bundleIdentifier: browser.bundleIdentifier,
                    activatesBrowser: false
                )

                switch attempt.result {
                case .success:
                    // Browser is accessible - permission is granted
                    browserPermissionStates[browser.bundleIdentifier] = .granted
                    setBrowserPermissionState(.granted, for: browser.bundleIdentifier)
                case .automationDenied, .unavailable:
                    // Browser denied automation or unavailable - permission not granted
                    browserPermissionStates[browser.bundleIdentifier] = .notGranted
                    setBrowserPermissionState(.notGranted, for: browser.bundleIdentifier)
                case .noTab:
                    // Inconclusive — fall back to whatever was previously
                    // stored rather than promoting to granted on an empty
                    // response that may not have hit the permission check.
                    browserPermissionStates[browser.bundleIdentifier] = storedState
                case .notBrowser:
                    // Shouldn't happen for supported browsers
                    browserPermissionStates[browser.bundleIdentifier] = .notGranted
                }
            } else {
                // Browser not running - use stored state
                browserPermissionStates[browser.bundleIdentifier] = storedState
            }
        }
    }

    private func requestAccessibilityAccessIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        // Force TCC to register NoteSide in the Accessibility list by issuing
        // a real AX query on the system-wide element. Without an actual AX
        // call, the AXIsProcessTrustedWithOptions prompt sometimes fails to
        // add the app to System Settings → Privacy & Security → Accessibility.
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    private func storedBrowserPermissionState(for bundleIdentifier: String) -> BrowserPermissionState {
        let defaultsKey = Self.browserPermissionDefaultsPrefix + bundleIdentifier
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else {
            return .notInstalled
        }

        return BrowserPermissionState(rawValue: rawValue) ?? .notInstalled
    }

    private func queueAutomationRequest(for bundleIdentifier: String, activatesBrowser: Bool) {
        guard pendingAutomationRequests.insert(bundleIdentifier).inserted else { return }

        if activatesBrowser {
            openApplication(bundleIdentifier: bundleIdentifier)
        }

        performAutomationRequest(
            for: bundleIdentifier,
            activatesBrowser: activatesBrowser,
            retriesRemaining: activatesBrowser ? 4 : 2,
            delay: activatesBrowser ? 0.8 : 0.25
        )
    }

    private func performAutomationRequest(
        for bundleIdentifier: String,
        activatesBrowser: Bool,
        retriesRemaining: Int,
        delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            let attempt = self.browserURLProvider.accessAttempt(
                bundleIdentifier: bundleIdentifier,
                activatesBrowser: activatesBrowser
            )
            self.applyBrowserAutomationAttempt(attempt)

            switch attempt.result {
            case .success, .noTab, .automationDenied:
                self.pendingAutomationRequests.remove(bundleIdentifier)
            case .unavailable, .notBrowser:
                guard retriesRemaining > 0 else {
                    self.pendingAutomationRequests.remove(bundleIdentifier)
                    return
                }

                self.performAutomationRequest(
                    for: bundleIdentifier,
                    activatesBrowser: activatesBrowser,
                    retriesRemaining: retriesRemaining - 1,
                    delay: 0.5
                )
            }
        }
    }

    private func setBrowserPermissionState(_ state: BrowserPermissionState, for bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }

        browserPermissionStates[bundleIdentifier] = isBrowserInstalled(bundleIdentifier) ? state : .notInstalled

        let defaultsKey = Self.browserPermissionDefaultsPrefix + bundleIdentifier
        switch browserPermissionStates[bundleIdentifier] {
        case .granted?:
            UserDefaults.standard.set(BrowserPermissionState.granted.rawValue, forKey: defaultsKey)
        case .notGranted?:
            UserDefaults.standard.set(BrowserPermissionState.notGranted.rawValue, forKey: defaultsKey)
        case .notInstalled?, nil:
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    private func isBrowserInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    private func bundleIdentifier(for browserName: String) -> String? {
        Self.supportedBrowsers.first(where: { $0.title == browserName })?.bundleIdentifier
    }

    private var noteEditorPanelController: NoteEditorPanelController {
        if let panelController {
            return panelController
        }

        let controller = NoteEditorPanelController()
        controller.install(appState: self)
        panelController = controller
        return controller
    }

    private var allNotesPanelController: AllNotesPanelController {
        if let allNotesPanelCtrl {
            return allNotesPanelCtrl
        }

        let controller = AllNotesPanelController()
        controller.install(appState: self)
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
