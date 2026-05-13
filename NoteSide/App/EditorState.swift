//
//  EditorState.swift
//  NoteSide
//
//  Created by Dylan Evans on 5/12/26.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class EditorState {
    var activeContext: NoteContext?
    var editorText = ""
    var editorAttributedText = NSAttributedString(string: "")
    var editorTitle = ""
    var editorErrorMessage: String?
    var isEditorPresented = false
    var isViewingOrphanedNote = false
    var isActiveNotePinned = false
    private var contextPollingTask: Task<Void, Never>?

    @ObservationIgnored let notesState: NotesState
    @ObservationIgnored let richTextController: RichTextEditorController
    @ObservationIgnored let contextResolver: ContextResolver
    @ObservationIgnored let browserPermissions: BrowserPermissionsState
    @ObservationIgnored let titleGenerator: NoteTitleGenerator
    @ObservationIgnored var isAutoTitleEnabled: () -> Bool

    static let intraAppPollingBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.tinyspeck.slackmacgap",
        "com.tinyspeck.slackmacgap2",
        "com.figma.Desktop"
    ]

    init(
        notesState: NotesState,
        richTextController: RichTextEditorController,
        contextResolver: ContextResolver,
        browserPermissions: BrowserPermissionsState,
        titleGenerator: NoteTitleGenerator,
        isAutoTitleEnabled: @escaping () -> Bool = { true }
    ) {
        self.notesState = notesState
        self.richTextController = richTextController
        self.contextResolver = contextResolver
        self.browserPermissions = browserPermissions
        self.titleGenerator = titleGenerator
        self.isAutoTitleEnabled = isAutoTitleEnabled
    }

    // MARK: - Editor State Loading

    func loadEditorState(for context: NoteContext) {
        let existingNote = notesState.note(for: context)
        editorAttributedText = attributedText(for: context)
        editorText = editorAttributedText.string
        editorTitle = existingNote?.title ?? ""
        editorErrorMessage = nil
        isActiveNotePinned = existingNote?.isPinned ?? false
    }

    func loadEditorState(for note: ContextNote) {
        editorAttributedText = attributedText(for: note)
        editorText = editorAttributedText.string
        editorTitle = note.title ?? ""
        editorErrorMessage = nil
        isActiveNotePinned = note.isPinned
    }

    // MARK: - Persistence

    func persistEditorStateForActiveContext() {
        persistCurrentEditorContent()
    }

    @discardableResult
    func persistCurrentEditorContent() -> Bool {
        guard let context = activeContext else { return false }

        let currentAttributedText = currentEditorAttributedTextSnapshot()
        let trimmed = currentAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            if let existing = notesState.note(for: context) {
                notesState.delete(existing)
            }
            return false
        }

        let existingNote = notesState.note(for: context)
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
        notesState.upsert(note)

        if currentTitle == nil && isAutoTitleEnabled() {
            generateTitleIfNeeded(noteID: existingID, body: trimmed, context: context)
        }

        return true
    }

    // MARK: - Rich Text Helpers

    func currentEditorAttributedTextSnapshot() -> NSAttributedString {
        richTextController.currentAttributedText() ?? editorAttributedText
    }

    func archivedRichText(from attributedText: NSAttributedString) -> Data? {
        try? attributedText.data(
            from: NSRange(location: 0, length: attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    func attributedText(for context: NoteContext) -> NSAttributedString {
        guard let note = notesState.note(for: context) else {
            return NSAttributedString(string: "")
        }
        return attributedText(for: note)
    }

    func attributedText(for note: ContextNote) -> NSAttributedString {
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

    // MARK: - Context Resolution

    func quickApplicationContext(for app: NSRunningApplication?) -> NoteContext {
        NoteContext(
            kind: .application,
            identifier: app?.bundleIdentifier ?? "unknown",
            displayName: app?.localizedName ?? "Current Context",
            secondaryLabel: app?.bundleIdentifier,
            navigationTarget: nil
        )
    }

    func resolveCurrentContext(preferredBundleIdentifier: String? = nil) -> NoteContext {
        let bundleIdentifier = preferredBundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let browserURLProvider = browserPermissions.browserURLProvider

        // Check if this is a supported browser and if we should attempt automation
        let shouldAttemptBrowserAutomation: Bool = {
            guard let bundleId = bundleIdentifier else { return false }
            guard browserURLProvider.supports(bundleIdentifier: bundleId) else { return false }

            let state = browserPermissions.browserPermissionStates[bundleId]
            // Attempt if: granted, OR never attempted before (nil)
            return state == .granted || state == nil
        }()

        // If this is a first-time browser attempt, probe it and record the result
        if shouldAttemptBrowserAutomation,
           let bundleId = bundleIdentifier,
           browserPermissions.browserPermissionStates[bundleId] == nil {
            let attempt = browserURLProvider.accessAttempt(bundleIdentifier: bundleId, activatesBrowser: false)

            switch attempt.result {
            case .success:
                browserPermissions.setBrowserPermissionState(.granted, for: bundleId)
            case .automationDenied:
                browserPermissions.setBrowserPermissionState(.notGranted, for: bundleId)
            case .noTab, .unavailable, .notBrowser:
                // Inconclusive — Safari's `exists front document` can return
                // empty without ever triggering the Apple Events permission
                // check, so an empty result is not proof of access.
                break
            }
        }

        let allowBrowserAutomation = bundleIdentifier.map { browserPermissions.browserPermissionStates[$0] == .granted } ?? false
        return contextResolver.resolveCurrentContext(allowBrowserAutomation: allowBrowserAutomation)
    }

    /// Async version of resolveCurrentContext that runs AppleScript and
    /// Accessibility API calls on a background thread, keeping the main
    /// thread free for UI work.
    func resolveCurrentContextAsync(preferredBundleIdentifier: String? = nil) async -> NoteContext {
        let bundleIdentifier = preferredBundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let permissionStates = browserPermissions.browserPermissionStates
        let browserProvider = browserPermissions.browserURLProvider
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
            browserPermissions.setBrowserPermissionState(probeSuccess ? .granted : .notGranted, for: bundleId)
        }

        return context
    }

    func resolveInitialQuickNoteContext(from fallbackContext: NoteContext, sourceBundleIdentifier: String?) {
        guard isEditorPresented, activeContext?.id == fallbackContext.id else { return }

        let context = resolveCurrentContext(preferredBundleIdentifier: sourceBundleIdentifier)
        guard context.id != fallbackContext.id else { return }

        let hasUnsavedEditorText = !editorAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !hasUnsavedEditorText else { return }

        activeContext = context
        loadEditorState(for: context)
    }

    func resolveInitialQuickNoteContextAsync(from fallbackContext: NoteContext, sourceBundleIdentifier: String?) async {
        guard isEditorPresented, activeContext?.id == fallbackContext.id else { return }

        let context = await resolveCurrentContextAsync(preferredBundleIdentifier: sourceBundleIdentifier)
        guard context.id != fallbackContext.id else { return }

        let hasUnsavedEditorText = !editorAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !hasUnsavedEditorText else { return }

        activeContext = context
        loadEditorState(for: context)
    }

    // MARK: - Context Refresh

    func applyRefreshedContext(_ context: NoteContext) {
        // When the user explicitly opened an orphaned note (whose context no
        // longer exists), don't let polling switch the editor to whatever app
        // is currently in front.
        if isViewingOrphanedNote { return }

        // Same logical note (matching id), but the file was renamed/moved or
        // some display field changed. Refresh the active context and rewrite
        // the persisted note's context so the panel shows the new name and
        // disk state stays in sync — but don't reload editor content.
        if let active = activeContext, context.id == active.id {
            guard context != active else { return }
            activeContext = context
            if let existing = notesState.note(for: context) {
                notesState.upsert(existing.copying(context: context))
            }
            return
        }

        persistEditorStateForActiveContext()
        activeContext = context
        loadEditorState(for: context)

        if isAutoTitleEnabled() && editorTitle.isEmpty {
            if let existing = notesState.note(for: context), !existing.body.isEmpty {
                generateTitleIfNeeded(noteID: existing.id, body: existing.body, context: context)
            } else {
                generateTitleFromContext(context: context)
            }
        }
    }

    func refreshEditorContextIfNeeded() {
        guard isEditorPresented else { return }
        let context = resolveCurrentContext()
        applyRefreshedContext(context)
    }

    // MARK: - Context Polling

    private var shouldRefreshDetailedContext: Bool {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }

        // Poll whenever the in-app context can change without an app switch:
        // browser tabs (granted browsers) and code editors (file focus moves
        // within the same process, so didActivateApplication never fires).
        if browserPermissions.browserPermissionStates[bundleIdentifier] == .granted {
            return true
        }
        return Self.intraAppPollingBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Starts a background polling loop that periodically re-resolves the
    /// current context for apps that support intra-app context changes
    /// (browser tabs, editor files, Slack channels, etc.). The heavy
    /// AppleScript / Accessibility work runs off the main thread.
    func startContextPolling() {
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

    func stopContextPolling() {
        contextPollingTask?.cancel()
        contextPollingTask = nil
    }

    // MARK: - Title Generation

    func generateTitleIfNeeded(noteID: UUID, body: String, context: NoteContext) {
        Task { [weak self] in
            guard let self else { return }
            if let generated = await self.titleGenerator.generateTitle(body: body, context: context) {
                guard let idx = self.notesState.notes.firstIndex(where: { $0.id == noteID }) else { return }
                let existing = self.notesState.notes[idx]
                // Don't overwrite if a title was set in the meantime
                guard existing.title == nil || existing.title?.isEmpty == true else { return }
                self.notesState.upsert(existing.copying(title: .some(generated)))

                // Update the editor title if the note is currently open
                if self.isEditorPresented,
                   self.activeContext?.id == context.id,
                   self.editorTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.editorTitle = generated
                }
            }
        }
    }

    func generateTitleFromContext(context: NoteContext) {
        Task { [weak self] in
            guard let self else { return }
            if let generated = await self.titleGenerator.generateTitle(body: "", context: context) {
                // Only apply if the user hasn't typed a title in the meantime
                guard self.editorTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.editorTitle = generated
            }
        }
    }
}
