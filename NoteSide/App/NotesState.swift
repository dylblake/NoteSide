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
    private(set) var recentNotes: [ContextNote] = []
    var searchText = "" {
        didSet { if searchText != oldValue { recomputeFilteredNotes() } }
    }
    var selectedNoteIDs: Set<UUID> = []
    var allNotesScrollResetID = UUID()

    @ObservationIgnored private let store: NoteStore

    init(store: NoteStore) {
        self.store = store
        let loaded = store.loadNotes()
        // Assign without triggering didSet (properties aren't initialized yet
        // during init, so we set the backing stores directly).
        notes = loaded
        _sortedNotes = loaded.sorted { $0.updatedAt > $1.updatedAt }
        _notesByContextID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.context.id, $0) })
        filteredNotes = _sortedNotes
        recentNotes = Array(_sortedNotes.prefix(5))
    }

    func note(for context: NoteContext) -> ContextNote? {
        _notesByContextID[context.id]
    }

    func upsert(_ note: ContextNote) {
        var updated = notes.filter { $0.context.id != note.context.id }
        updated.append(note)
        notes = updated
        store.save(notes: notes)
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
        recentNotes = Array(_sortedNotes.prefix(5))

        guard !searchText.isEmpty else {
            filteredNotes = _sortedNotes
            return
        }

        if searchText.hasPrefix("#") {
            let tagQuery = String(searchText.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
            if !tagQuery.isEmpty {
                filteredNotes = _sortedNotes.filter { note in
                    note.tags.contains { $0.localizedCaseInsensitiveContains(tagQuery) }
                }
                return
            }
        }

        filteredNotes = _sortedNotes.filter { note in
            note.context.displayName.localizedCaseInsensitiveContains(searchText)
                || note.context.identifier.localizedCaseInsensitiveContains(searchText)
                || (note.context.secondaryLabel?.localizedCaseInsensitiveContains(searchText) ?? false)
                || note.body.localizedCaseInsensitiveContains(searchText)
                || (note.title?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
}
