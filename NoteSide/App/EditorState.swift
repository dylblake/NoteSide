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
    var editorAttributedText = NSAttributedString(string: "")
    var editorTitle = ""
    var editorErrorMessage: String?
    var isEditorPresented = false
    var isViewingOrphanedNote = false
    var isActiveNotePinned = false
    private var contextPollingTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var isResolvingContext = false
    @ObservationIgnored private let contextObserver = AXContextObserver()

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

        contextObserver.onContextMayHaveChanged = { [weak self] in
            self?.handleObservedContextChange()
        }
    }

    // MARK: - Editor State Loading

    func loadEditorState(for context: NoteContext) {
        cancelAutosave()
        let existingNote = notesState.note(for: context)
        editorAttributedText = attributedText(for: context)
        editorTitle = existingNote?.title ?? ""
        editorErrorMessage = nil
        isActiveNotePinned = existingNote?.isPinned ?? false
    }

    func loadEditorState(for note: ContextNote) {
        cancelAutosave()
        editorAttributedText = attributedText(for: note)
        editorTitle = note.title ?? ""
        editorErrorMessage = nil
        isActiveNotePinned = note.isPinned
    }

    // MARK: - Persistence

    @discardableResult
    func persistCurrentEditorContent(deleteIfEmpty: Bool = true) -> Bool {
        guard let context = activeContext else { return false }

        let currentAttributedText = currentEditorAttributedTextSnapshot()
        let trimmed = currentAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            if deleteIfEmpty, let existing = notesState.note(for: context) {
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
            isPinned: isActiveNotePinned,
            title: currentTitle
        )
        notesState.upsert(note)

        if currentTitle == nil && isAutoTitleEnabled() {
            generateTitleIfNeeded(noteID: existingID, body: trimmed, context: context)
        }

        return true
    }

    // MARK: - Autosave

    /// Called on every edit; persists the note a couple of seconds after
    /// the user stops typing so a crash or force-quit while the editor is
    /// open can't lose the whole session.
    func scheduleAutosave() {
        guard isEditorPresented else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.isEditorPresented else { return }
            self.autosaveNow()
        }
    }

    func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    private func autosaveNow() {
        guard let context = activeContext else { return }

        let currentAttributedText = currentEditorAttributedTextSnapshot()
        let trimmed = currentAttributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Autosave never deletes: clearing the text and pausing shouldn't
        // destroy the note. Deletion stays an explicit dismiss-time action.
        guard !trimmed.isEmpty else { return }
        guard hasUnpersistedChanges(context: context, attributedText: currentAttributedText, trimmedBody: trimmed) else {
            return
        }

        persistCurrentEditorContent(deleteIfEmpty: false)
    }

    /// True when the editor buffer differs from what's stored for this
    /// context. Prevents autosave from bumping updatedAt (and re-sorting
    /// every list) when nothing actually changed, e.g. right after a note
    /// is loaded into the editor.
    private func hasUnpersistedChanges(
        context: NoteContext,
        attributedText: NSAttributedString,
        trimmedBody: String
    ) -> Bool {
        guard let existing = notesState.note(for: context) else { return true }

        let userTitle = editorTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = userTitle.isEmpty ? existing.title : userTitle

        if existing.body != trimmedBody { return true }
        if existing.title != effectiveTitle { return true }
        return existing.richTextData != archivedRichText(from: attributedText)
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

    /// Async version of resolveCurrentContext that runs AppleScript and
    /// Accessibility API calls on a background thread, keeping the main
    /// thread free for UI work.
    func resolveCurrentContextAsync(preferredBundleIdentifier: String? = nil) async -> NoteContext {
        isResolvingContext = true
        defer { isResolvingContext = false }

        let bundleIdentifier = preferredBundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let permissionStates = browserPermissions.browserPermissionStates
        let browserProvider = browserPermissions.browserURLProvider
        let resolver = contextResolver

        let shouldAttemptBrowserAutomation: Bool = {
            guard let bundleId = bundleIdentifier else { return false }
            guard browserProvider.supports(bundleIdentifier: bundleId) else { return false }
            let state = permissionStates[bundleId]
            return state == .granted || state == nil || state == .undetermined
        }()
        let isFirstAttempt = shouldAttemptBrowserAutomation
            && (bundleIdentifier.map { permissionStates[$0] == nil || permissionStates[$0] == .undetermined } ?? false)

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

        persistCurrentEditorContent()
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

    // MARK: - Context Tracking (AX events + fallback polling)

    /// True when the in-app context of this bundle can change without an
    /// app switch: browser tabs (granted browsers) and apps whose file /
    /// channel focus moves within the same process, so
    /// didActivateApplication never fires.
    private func isTrackableForIntraAppChanges(_ bundleIdentifier: String) -> Bool {
        browserPermissions.browserPermissionStates[bundleIdentifier] == .granted
            || Self.intraAppPollingBundleIdentifiers.contains(bundleIdentifier)
    }

    private var shouldRefreshDetailedContext: Bool {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return isTrackableForIntraAppChanges(bundleIdentifier)
    }

    /// Starts event-driven context tracking: an AXObserver on the frontmost
    /// app catches focus/title changes the moment they happen, and a
    /// polling loop remains as a safety net — slow when observation is
    /// live, at the old 1.5s cadence when it isn't (e.g. no Accessibility
    /// permission).
    func startContextTracking() {
        stopContextTracking()
        retargetContextObserver()
        contextPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.fallbackPollingInterval() ?? .seconds(1.5)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                guard let self, self.isEditorPresented, self.shouldRefreshDetailedContext else {
                    if self == nil { break }
                    continue
                }
                // Skip this tick if another resolution (app switch, initial
                // quick-note refine, AX event) is already in flight —
                // queueing a second one behind it on the script executor
                // would only apply a staler context afterwards.
                guard !self.isResolvingContext else { continue }
                let context = await self.resolveCurrentContextAsync()
                guard !Task.isCancelled, self.isEditorPresented else { break }
                self.applyRefreshedContext(context)
            }
        }
    }

    func stopContextTracking() {
        contextPollingTask?.cancel()
        contextPollingTask = nil
        contextObserver.stop()
    }

    /// Points the AXObserver at the current frontmost app. Called when
    /// tracking starts and after every app switch while the editor is
    /// open. Observing is skipped for our own process and for apps whose
    /// context can't change intra-app.
    func retargetContextObserver() {
        guard isEditorPresented,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleIdentifier = app.bundleIdentifier,
              isTrackableForIntraAppChanges(bundleIdentifier)
        else {
            contextObserver.stop()
            return
        }
        contextObserver.observe(app: app)
    }

    private func handleObservedContextChange() {
        guard isEditorPresented, shouldRefreshDetailedContext, !isResolvingContext else { return }
        Task { [weak self] in
            guard let self else { return }
            let context = await self.resolveCurrentContextAsync()
            guard self.isEditorPresented else { return }
            self.applyRefreshedContext(context)
        }
    }

    private func fallbackPollingInterval() -> Duration {
        guard contextObserver.isObserving else { return .seconds(1.5) }

        // Observation is live, so polling is only a safety net. Browsers
        // keep a moderate cadence because a same-title URL change (SPA
        // navigation) doesn't fire any AX notification.
        if let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           browserPermissions.browserPermissionStates[bundleIdentifier] == .granted {
            return .seconds(3)
        }
        return .seconds(10)
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
