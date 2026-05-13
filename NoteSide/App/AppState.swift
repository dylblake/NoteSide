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
    var onboardingContextPreview: NoteContext?
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
    var infoStatusMessage: String?
    var isLicensed: Bool = false
    var isDictating = false
    var dictationPartialText = ""
    var isMicrophoneAuthorized = false
    var isSpeechRecognitionAuthorized = false

    let richTextController = RichTextEditorController()
    let dictationService = DictationService()
    private let dictationHotKeyMonitor = DictationHotKeyMonitor()
    private var panelController: NoteEditorPanelController?
    private var allNotesPanelCtrl: AllNotesPanelController?
    private var onboardingWindowController: OnboardingWindowController?
    private var infoWindowController: InfoWindowController?
    private var licenseWindowController: LicenseWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var isAllNotesPanelVisible = false
    private var isOnboardingWindowVisible = false
    private var isInfoWindowVisible = false

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
        let initialAutoTitle = UserDefaults.standard.object(forKey: "autoTitleEnabled") as? Bool ?? true
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
            onAccessibilityNeeded: { [weak self] in self?.requestAccessibilityAccessIfNeeded() },
            onError: { [weak self] msg in self?.editor.editorErrorMessage = msg }
        )

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

                    if self.editor.isEditorPresented {
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
        checkStoredLicense()

    }

    convenience init() {
        self.init(
            store: NoteStore(),
            contextResolver: ContextResolver(),
            hotKeyMonitor: GlobalHotKeyMonitor()
        )
    }

    func toggleQuickNote() {
        // License gate: require a valid license before opening the editor.
        if !isLicensed {
            presentLicenseWindow()
            return
        }

        if isAllNotesPanelPresented {
            dismissAllNotesPanel()
        }

        if editor.isEditorPresented {
            saveAndDismissEditor()
            return
        }

        editor.editorErrorMessage = nil
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let sourceBundleIdentifier = frontmostApp?.bundleIdentifier
        let fallbackContext = editor.quickApplicationContext(for: frontmostApp)

        // Try to resolve the full context (URL, file, etc.) immediately
        // so the panel opens with the correct context instead of briefly
        // flashing the generic app name.
        let resolvedContext = editor.resolveCurrentContext(preferredBundleIdentifier: sourceBundleIdentifier)
        let initialContext = resolvedContext.id != fallbackContext.id ? resolvedContext : fallbackContext

        editor.activeContext = initialContext
        let existingNote = notesState.note(for: initialContext)
        editor.loadEditorState(for: initialContext)

        editor.isEditorPresented = true
        editor.startContextPolling()
        noteEditorPanelController.present()

        // Generate title asynchronously after presenting so the editor
        // appears instantly rather than waiting for AI/NLP inference.
        if isAutoTitleEnabled && editor.editorTitle.isEmpty {
            if let existingNote, !existingNote.body.isEmpty {
                editor.generateTitleIfNeeded(noteID: existingNote.id, body: existingNote.body, context: initialContext)
            } else {
                editor.generateTitleFromContext(context: initialContext)
            }
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.editor.isEditorPresented else { return }
            await self.editor.resolveInitialQuickNoteContextAsync(from: initialContext, sourceBundleIdentifier: sourceBundleIdentifier)
            self.browserPermissions.queueQuickNotePermissionRequestIfNeeded(sourceBundleIdentifier: sourceBundleIdentifier)
        }
    }

    func saveAndDismissEditor() {
        editor.persistCurrentEditorContent()
        notesState.flush()
        dismissEditor()
    }

    func dismissEditor() {
        editor.isEditorPresented = false
        editor.isViewingOrphanedNote = false
        editor.stopContextPolling()
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
        if !isLicensed {
            presentLicenseWindow()
            return
        }

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
            browserPermissions.refreshBrowserPermissionStates()
        }

        dictationService.refreshPermissionStatus()
    }

    func previewCurrentContext() {
        onboardingContextPreview = editor.resolveCurrentContext()
    }

    func edit(_ note: ContextNote) {
        editor.activeContext = note.context
        editor.loadEditorState(for: note)

        editor.isEditorPresented = true
        editor.startContextPolling()
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
                self?.editor.editorErrorMessage = "Original context is no longer available"
            }
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
        editor.editorText = ""
        editor.editorTitle = ""
        editor.editorErrorMessage = nil
        editor.isActiveNotePinned = false
        dismissEditor()
    }

    func togglePinForActiveNote() {
        guard let context = editor.activeContext else { return }

        let nextPinnedState = !editor.isActiveNotePinned
        editor.isActiveNotePinned = nextPinnedState

        let currentAttributedText = editor.currentEditorAttributedTextSnapshot()
        let trimmed = currentAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)

        // If editor has content, save it with the new pin state
        if !trimmed.isEmpty {
            let existing = notesState.note(for: context)
            let existingID = existing?.id ?? UUID()
            let createdAt = existing?.createdAt ?? .now
            let userTitle = editor.editorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentTitle: String? = userTitle.isEmpty ? existing?.title : userTitle
            let updatedNote = ContextNote(
                id: existingID,
                context: context,
                body: trimmed,
                richTextData: editor.archivedRichText(from: currentAttributedText),
                createdAt: createdAt,
                updatedAt: .now,
                isPinned: nextPinnedState,
                title: currentTitle
            )
            notesState.upsert(updatedNote)
            return
        }

        // If editor is empty but there's an existing note, just update the pin state
        if let existingNote = notesState.note(for: context) {
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

    private func applyDockIconPreference() {
        let shouldShowDockIcon = isAllNotesPanelVisible || isOnboardingWindowVisible || isInfoWindowVisible
        showsDockIcon = shouldShowDockIcon
        NSApp?.setActivationPolicy(shouldShowDockIcon ? .regular : .accessory)
    }


    private func startDictation() {
        guard editor.isEditorPresented, !isDictating else { return }

        guard dictationService.isFullyAuthorized else {
            requestDictationPermissionsIfNeeded()
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

        // Force TCC to register NoteSide in the Accessibility list by issuing
        // a real AX query on the system-wide element. Without an actual AX
        // call, the AXIsProcessTrustedWithOptions prompt sometimes fails to
        // add the app to System Settings -> Privacy & Security -> Accessibility.
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
