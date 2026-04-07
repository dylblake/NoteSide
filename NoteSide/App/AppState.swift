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

@MainActor
final class AppState: ObservableObject {
    enum BrowserPermissionState: String {
        case notInstalled
        case notGranted
        case granted
    }

    @Published var hasCompletedOnboarding: Bool
    @Published var isAccessibilityTrusted = AXIsProcessTrusted()
    @Published var isBrowserAutomationGranted = false
    @Published var onboardingContextPreview: NoteContext?
    @Published var browserAutomationMessage = "Put Safari, Chrome, or Arc in front, then test browser access."
    @Published private(set) var browserPermissionStates: [String: BrowserPermissionState] = [:]
    @Published private(set) var notes: [ContextNote] = []
    @Published var activeContext: NoteContext?
    @Published var editorText = ""
    @Published var editorAttributedText = NSAttributedString(string: "")
    @Published var editorErrorMessage: String?
    @Published var isEditorPresented = false
    @Published var searchText = ""
    @Published var hotKeyShortcut: HotKeyShortcut
    @Published var showsDockIcon: Bool
    @Published var allNotesScrollResetID = UUID()
    @Published var currentEditorTextStyle: RichTextEditorController.TextStyle = .body
    @Published var isEditorBoldActive = false
    @Published var isEditorItalicActive = false
    @Published var isEditorUnderlineActive = false
    @Published var isActiveNotePinned = false
    @Published var infoStatusMessage: String?

    private let store: NoteStore
    private let contextResolver: ContextResolver
    private let browserURLProvider = BrowserURLProvider()
    let richTextController = RichTextEditorController()
    private let hotKeyMonitor: GlobalHotKeyMonitor
    private var panelController: NoteEditorPanelController?
    private var allNotesWindowController: AllNotesWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var infoWindowController: InfoWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingAutomationRequests: Set<String> = []
    private var isAllNotesWindowVisible = false
    private var isOnboardingWindowVisible = false
    private var isInfoWindowVisible = false

    private static let onboardingDefaultsKey = "hasCompletedOnboarding"
    private static let hotKeyDefaultsKey = "globalHotKeyShortcut"
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
        hotKeyShortcut = Self.loadHotKeyShortcut()
        showsDockIcon = false
        notes = store.loadNotes()

        hotKeyMonitor.onKeyDown = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.toggleQuickNote()
            }
        }

        richTextController.onSelectionAttributesChange = { [weak self] formattingState in
            self?.currentEditorTextStyle = formattingState.textStyle
            self?.isEditorBoldActive = formattingState.isBold
            self?.isEditorItalicActive = formattingState.isItalic
            self?.isEditorUnderlineActive = formattingState.isUnderlined
        }

        registerHotKey()

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshPermissionStatus()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshEditorContextIfNeeded()
            }
            .store(in: &cancellables)

        Timer.publish(every: 0.6, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.isEditorPresented, self.shouldRefreshDetailedContext else { return }
                self.refreshEditorContextIfNeeded()
            }
            .store(in: &cancellables)

        refreshPermissionStatus()
        applyDockIconPreference()

    }

    convenience init() {
        self.init(
            store: NoteStore(),
            contextResolver: ContextResolver(),
            hotKeyMonitor: GlobalHotKeyMonitor()
        )
    }

    func toggleQuickNote() async {
        // Check if accessibility permission is granted, if not the native macOS prompt will appear
        if !AXIsProcessTrusted() {
            requestAccessibilityAccessIfNeeded()
            return
        }

        if isEditorPresented {
            saveAndDismissEditor()
            return
        }

        editorErrorMessage = nil
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let sourceBundleIdentifier = frontmostApp?.bundleIdentifier
        let fallbackContext = quickApplicationContext(for: frontmostApp)

        activeContext = fallbackContext
        editorAttributedText = attributedText(for: fallbackContext)
        editorText = editorAttributedText.string
        isActiveNotePinned = note(for: fallbackContext)?.isPinned ?? false
        isEditorPresented = true
        noteEditorPanelController.present()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.resolveInitialQuickNoteContext(from: fallbackContext, sourceBundleIdentifier: sourceBundleIdentifier)
            self?.queueQuickNotePermissionRequestIfNeeded(sourceBundleIdentifier: sourceBundleIdentifier)
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
                store.save(notes: notes)
            }
        } else {
            let existingID = note(for: context)?.id ?? UUID()
            let createdAt = note(for: context)?.createdAt ?? .now
            let note = ContextNote(
                id: existingID,
                context: context,
                body: trimmed,
                richTextData: archivedRichText(from: currentAttributedText),
                createdAt: createdAt,
                updatedAt: .now,
                isPinned: note(for: context)?.isPinned ?? isActiveNotePinned
            )
            upsert(note)
        }

        dismissEditor()
    }

    func dismissEditor() {
        isEditorPresented = false
        isActiveNotePinned = false
        panelController?.dismiss()
    }

    func openAllNotes() {
        if isEditorPresented {
            saveAndDismissEditor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.presentAllNotesWindow()
            }
            return
        }
        presentAllNotesWindow()
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

    private func presentAllNotesWindow() {
        allNotesScrollResetID = UUID()
        allNotesWindow.present()
        NSApp.activate(ignoringOtherApps: true)
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

        openSettingsPane(candidates: [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security"
        ])

        refreshPermissionStatus()
    }

    func refreshPermissionStatus() {
        let wasAccessibilityTrusted = isAccessibilityTrusted
        isAccessibilityTrusted = AXIsProcessTrusted()

        if !wasAccessibilityTrusted && isAccessibilityTrusted {
            refreshBrowserPermissionStates()
        }
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
        editorErrorMessage = nil
        isActiveNotePinned = note.isPinned
        isEditorPresented = true
        noteEditorPanelController.present()
    }

    func open(_ note: ContextNote) {
        allNotesWindow.dismiss()
        navigate(to: note.context)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.edit(note)
        }
    }

    func delete(_ note: ContextNote) {
        notes.removeAll { $0.id == note.id }
        store.save(notes: notes)
    }

    func togglePin(_ note: ContextNote) {
        let updatedNote = ContextNote(
            id: note.id,
            context: note.context,
            body: note.body,
            richTextData: note.richTextData,
            createdAt: note.createdAt,
            updatedAt: .now,
            isPinned: !note.isPinned
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
            let existingID = note(for: context)?.id ?? UUID()
            let createdAt = note(for: context)?.createdAt ?? .now
            let updatedNote = ContextNote(
                id: existingID,
                context: context,
                body: trimmed,
                richTextData: archivedRichText(from: currentAttributedText),
                createdAt: createdAt,
                updatedAt: .now,
                isPinned: nextPinnedState
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
                isPinned: nextPinnedState
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

    func setShowsDockIcon(_ showsDockIcon: Bool) {
        self.showsDockIcon = false
        applyDockIconPreference()
    }

    func setAllNotesWindowVisible(_ isVisible: Bool) {
        isAllNotesWindowVisible = isVisible
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

    var hotKeyDisplayString: String {
        hotKeyShortcut.displayString
    }

    var availableHotKeyKeys: [HotKeyShortcut.KeyOption] {
        HotKeyShortcut.availableKeys
    }

    var filteredNotes: [ContextNote] {
        guard !searchText.isEmpty else { return sortedNotes }
        return sortedNotes.filter { note in
            note.context.displayName.localizedCaseInsensitiveContains(searchText)
                || note.context.identifier.localizedCaseInsensitiveContains(searchText)
                || (note.context.secondaryLabel?.localizedCaseInsensitiveContains(searchText) ?? false)
                || note.body.localizedCaseInsensitiveContains(searchText)
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

    private var sortedNotes: [ContextNote] {
        notes.sorted { $0.updatedAt > $1.updatedAt }
    }

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
        editorErrorMessage = nil
        isActiveNotePinned = note(for: context)?.isPinned ?? false
    }

    private func refreshEditorContextIfNeeded() {
        guard isEditorPresented else { return }

        let context = resolveCurrentContext()
        guard context.id != activeContext?.id else { return }

        persistEditorStateForActiveContext()
        activeContext = context
        editorAttributedText = attributedText(for: context)
        editorText = editorAttributedText.string
        editorErrorMessage = nil
        isActiveNotePinned = note(for: context)?.isPinned ?? false
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
        store.save(notes: notes)
    }

    private func persistEditorStateForActiveContext() {
        guard let context = activeContext else { return }

        let currentAttributedText = currentEditorAttributedTextSnapshot()
        let trimmed = currentAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let existing = note(for: context) {
                notes.removeAll { $0.id == existing.id }
                store.save(notes: notes)
            }
            return
        }

        let existingID = note(for: context)?.id ?? UUID()
        let createdAt = note(for: context)?.createdAt ?? .now
        let note = ContextNote(
            id: existingID,
            context: context,
            body: trimmed,
            richTextData: archivedRichText(from: currentAttributedText),
            createdAt: createdAt,
            updatedAt: .now,
            isPinned: note(for: context)?.isPinned ?? isActiveNotePinned
        )
        upsert(note)
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

    private func applyDockIconPreference() {
        let shouldShowDockIcon = isAllNotesWindowVisible || isOnboardingWindowVisible || isInfoWindowVisible
        showsDockIcon = shouldShowDockIcon
        NSApp.setActivationPolicy(shouldShowDockIcon ? .regular : .accessory)
    }

    private func registerHotKey() {
        do {
            try hotKeyMonitor.start(shortcut: hotKeyShortcut)
            editorErrorMessage = nil
        } catch {
            editorErrorMessage = error.localizedDescription
        }
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

    private var allNotesWindow: AllNotesWindowController {
        if let allNotesWindowController {
            return allNotesWindowController
        }

        let controller = AllNotesWindowController()
        controller.install(appState: self)
        allNotesWindowController = controller
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
