//
//  NotesState.swift
//  NoteSide
//

import Foundation
import Observation

@MainActor
@Observable
final class NotesState {
    private(set) var notes: [ContextNote] = [] {
        didSet {
            _sortedNotes = notes.sorted { $0.updatedAt > $1.updatedAt }
            _notesByContextID = Dictionary(uniqueKeysWithValues: notes.map { ($0.context.id, $0) })
            recomputeFilteredNotes()
        }
    }
    private var _sortedNotes: [ContextNote] = []
    private var _notesByContextID: [String: ContextNote] = [:]
    private(set) var filteredNotes: [ContextNote] = []
    private(set) var noteSections: [NoteSection] = []
    private(set) var recentNotes: [ContextNote] = []
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearchRecompute() } }
    }
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    var selectedNoteIDs: Set<UUID> = []
    var allNotesScrollResetID = UUID()

    /// Notes ever created, for the free-trial gate. Monotonic: deleting
    /// notes doesn't refund trial slots.
    private(set) var trialNotesCreated: Int

    @ObservationIgnored private let store: NoteStore

    private static let trialNotesCreatedKey = "trialNotesCreated"

    init(store: NoteStore) {
        self.store = store
        let loaded = store.loadNotes()

        // Seed with the on-disk note count so the counter survives fresh
        // preference files when notes already exist.
        let storedCount = UserDefaults.standard.integer(forKey: Self.trialNotesCreatedKey)
        let seededCount = max(storedCount, loaded.count)
        trialNotesCreated = seededCount

        // Assign without triggering didSet (properties aren't initialized yet
        // during init, so we set the backing stores directly).
        notes = loaded
        _sortedNotes = loaded.sorted { $0.updatedAt > $1.updatedAt }
        _notesByContextID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.context.id, $0) })
        filteredNotes = _sortedNotes
        noteSections = NoteSectionBuilder.build(from: _sortedNotes)
        recentNotes = Array(_sortedNotes.prefix(5))

        if seededCount != storedCount {
            UserDefaults.standard.set(seededCount, forKey: Self.trialNotesCreatedKey)
        }
    }

    func note(for context: NoteContext) -> ContextNote? {
        _notesByContextID[context.id]
    }

    func upsert(_ note: ContextNote) {
        // A note ID we've never seen is a creation (context rewrites and
        // edits reuse the existing ID) — count it toward the trial.
        let isNewNote = !notes.contains { $0.id == note.id }

        var updated = notes.filter { $0.context.id != note.context.id }
        updated.append(note)
        notes = updated
        store.save(notes: notes)

        if isNewNote {
            trialNotesCreated += 1
            UserDefaults.standard.set(trialNotesCreated, forKey: Self.trialNotesCreatedKey)
        }
    }

    func delete(_ note: ContextNote) {
        notes.removeAll { $0.id == note.id }
        store.save(notes: notes)
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
        store.save(notes: notes)
        selectedNoteIDs.removeAll()
    }

    /// Toggles pin for a single note (note-level only — does NOT sync editor state).
    /// The AppState coordinator wrapper handles `isActiveNotePinned` sync.
    func togglePin(_ note: ContextNote) {
        let updatedNote = note.copying(updatedAt: .now, isPinned: !note.isPinned)
        upsert(updatedNote)
    }

    /// Toggles pin for all selected notes (note-level only).
    /// Returns the new pin state so the coordinator can sync editor state.
    @discardableResult
    func togglePinForSelectedNotes() -> Bool? {
        guard !selectedNoteIDs.isEmpty else { return nil }
        let selected = selectedNoteIDs
        let selectedNotes = notes.filter { selected.contains($0.id) }
        let allPinned = selectedNotes.allSatisfy(\.isPinned)
        let nextPinned = !allPinned

        notes = notes.map { note in
            guard selected.contains(note.id) else { return note }
            return note.copying(updatedAt: .now, isPinned: nextPinned)
        }
        store.save(notes: notes)
        selectedNoteIDs.removeAll()
        return nextPinned
    }

    func flush() {
        store.flush()
    }

    private func recomputeFilteredNotes() {
        // Note mutations recompute synchronously so deletes/pins reflect
        // immediately; a pending search recompute would apply stale data.
        searchTask?.cancel()
        recentNotes = Array(_sortedNotes.prefix(5))
        filteredNotes = Self.filter(notes: _sortedNotes, query: searchText)
        noteSections = NoteSectionBuilder.build(from: filteredNotes)
    }

    /// Typing path: debounced, with matching and section building off the
    /// main thread — full-body substring search over every note is too
    /// heavy to run per keystroke at large note counts.
    private func scheduleSearchRecompute() {
        searchTask?.cancel()
        let query = searchText
        let source = _sortedNotes

        guard !query.isEmpty else {
            filteredNotes = source
            noteSections = NoteSectionBuilder.build(from: source)
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            let result: ([ContextNote], [NoteSection]) = await Task.detached(priority: .userInitiated) {
                let filtered = NotesState.filter(notes: source, query: query)
                return (filtered, NoteSectionBuilder.build(from: filtered))
            }.value

            guard let self, !Task.isCancelled, self.searchText == query else { return }
            self.filteredNotes = result.0
            self.noteSections = result.1
        }
    }

    nonisolated static func filter(notes: [ContextNote], query: String) -> [ContextNote] {
        guard !query.isEmpty else { return notes }

        if query.hasPrefix("#") {
            let tagQuery = String(query.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
            if !tagQuery.isEmpty {
                return notes.filter { note in
                    note.tags.contains { $0.localizedCaseInsensitiveContains(tagQuery) }
                }
            }
        }

        return notes.filter { note in
            note.context.displayName.localizedCaseInsensitiveContains(query)
                || note.context.identifier.localizedCaseInsensitiveContains(query)
                || (note.context.secondaryLabel?.localizedCaseInsensitiveContains(query) ?? false)
                || note.body.localizedCaseInsensitiveContains(query)
                || (note.title?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}
