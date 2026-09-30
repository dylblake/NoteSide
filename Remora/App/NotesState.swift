//
//  NotesState.swift
//  Remora
//

import Foundation
import Observation

/// One `#tag` across the whole store, with how many notes carry it.
nonisolated struct TagSummary: Hashable, Sendable, Identifiable {
    /// Lowercased, without the leading `#`.
    let name: String
    let count: Int
    var id: String { name }
}

@MainActor
@Observable
final class NotesState {
    private(set) var notes: [ContextNote] = [] {
        didSet {
            _sortedNotes = notes.sorted { $0.updatedAt > $1.updatedAt }
            _notesByContextID = Dictionary(uniqueKeysWithValues: notes.map { ($0.context.id, $0) })
            allTags = Self.aggregateTags(notes)
            todoOrder = Self.reconciledTodoOrder(todoOrder, notes: notes)
            recomputeFilteredNotes()
        }
    }
    /// IDs of the pinned notes in the user's manual To-Do order. Kept in
    /// step with `notes`: unpinned and deleted notes drop out, newly
    /// pinned ones join at the end.
    private(set) var todoOrder: [UUID] = []
    /// How many notes are on the To-Do list (pinned), whatever the search.
    var todoCount: Int { todoOrder.count }
    private var _sortedNotes: [ContextNote] = []
    private var _notesByContextID: [String: ContextNote] = [:]
    /// Every tag in the store, most-used first, for the search suggestions.
    private(set) var allTags: [TagSummary] = []
    private(set) var filteredNotes: [ContextNote] = []
    private(set) var noteSections: [NoteSection] = []
    private(set) var recentNotes: [ContextNote] = []
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearchRecompute() } }
    }
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    var selectedNoteIDs: Set<UUID> = []
    var allNotesScrollResetID = UUID()
    /// Row highlighted by keyboard navigation in All Notes (distinct from
    /// the checkbox multi-selection).
    var keyboardFocusedNoteID: UUID?

    /// Notes ever created, for the free-trial gate. Monotonic: deleting
    /// notes doesn't refund trial slots.
    private(set) var trialNotesCreated: Int

    @ObservationIgnored private let store: NoteStore

    private static let trialNotesCreatedKey = "trialNotesCreated"
    /// A scratch store (tests, UI-test launches) still reads the count,
    /// so a launch argument can set it, but never writes it: test notes
    /// must not move the real trial counter.
    @ObservationIgnored private let persistsTrialCount: Bool

    init(store: NoteStore) {
        self.store = store
        let loaded = store.loadNotes()

        // Seed with the on-disk note count so the counter survives fresh
        // preference files when notes already exist.
        persistsTrialCount = !store.usesScratchDirectory
        let storedCount = UserDefaults.standard.integer(forKey: Self.trialNotesCreatedKey)
        let seededCount = max(storedCount, loaded.count)
        trialNotesCreated = seededCount

        // Assign without triggering didSet (properties aren't initialized yet
        // during init, so we set the backing stores directly).
        notes = loaded
        _sortedNotes = loaded.sorted { $0.updatedAt > $1.updatedAt }
        _notesByContextID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.context.id, $0) })
        allTags = Self.aggregateTags(loaded)
        todoOrder = Self.reconciledTodoOrder(store.loadedTodoOrder, notes: loaded)
        filteredNotes = _sortedNotes
        noteSections = NoteSectionBuilder.build(from: _sortedNotes, todoOrder: todoOrder)
        recentNotes = Array(_sortedNotes.prefix(5))

        if persistsTrialCount && seededCount != storedCount {
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
        save()

        if isNewNote {
            trialNotesCreated += 1
            if persistsTrialCount {
                UserDefaults.standard.set(trialNotesCreated, forKey: Self.trialNotesCreatedKey)
            }
        }
    }

    func delete(_ note: ContextNote) {
        notes.removeAll { $0.id == note.id }
        save()
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
        save()
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
        save()
        selectedNoteIDs.removeAll()
        return nextPinned
    }

    /// Applies a drag in the To-Do list. `visibleOrder` is the new order
    /// of the rows on screen; while a search hides some pinned notes, the
    /// visible ones trade places among the slots they already held.
    func reorderTodo(visibleOrder: [UUID]) {
        let moving = Set(visibleOrder)
        guard moving.count == visibleOrder.count, moving.isSubset(of: todoOrder) else { return }

        var replacements = visibleOrder.makeIterator()
        let reordered = todoOrder.map { moving.contains($0) ? (replacements.next() ?? $0) : $0 }
        guard reordered != todoOrder else { return }

        todoOrder = reordered
        noteSections = NoteSectionBuilder.build(from: filteredNotes, todoOrder: todoOrder)
        save()
    }

    func flush() {
        store.flush()
    }

    private func save() {
        store.save(notes: notes, todoOrder: todoOrder)
    }

    /// Drops IDs that are no longer pinned and appends newly pinned notes
    /// (most recently updated first among themselves).
    nonisolated static func reconciledTodoOrder(_ order: [UUID], notes: [ContextNote]) -> [UUID] {
        let pinned = notes.filter(\.isPinned)
        let pinnedIDs = Set(pinned.map(\.id))
        var seen = Set<UUID>()
        let kept = order.filter { pinnedIDs.contains($0) && seen.insert($0).inserted }
        let added = pinned
            .filter { !seen.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.id)
        return kept + added
    }

    private func recomputeFilteredNotes() {
        // Note mutations recompute synchronously so deletes/pins reflect
        // immediately; a pending search recompute would apply stale data.
        searchTask?.cancel()
        recentNotes = Array(_sortedNotes.prefix(5))
        filteredNotes = Self.filter(notes: _sortedNotes, query: searchText)
        noteSections = NoteSectionBuilder.build(from: filteredNotes, todoOrder: todoOrder)
    }

    /// Typing path: debounced, with matching and section building off the
    /// main thread — full-body substring search over every note is too
    /// heavy to run per keystroke at large note counts.
    private func scheduleSearchRecompute() {
        searchTask?.cancel()
        let query = searchText
        let source = _sortedNotes
        let order = todoOrder

        guard !query.isEmpty else {
            filteredNotes = source
            noteSections = NoteSectionBuilder.build(from: source, todoOrder: order)
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            let result: ([ContextNote], [NoteSection]) = await Task.detached(priority: .userInitiated) {
                let filtered = NotesState.filter(notes: source, query: query)
                return (filtered, NoteSectionBuilder.build(from: filtered, todoOrder: order))
            }.value

            guard let self, !Task.isCancelled, self.searchText == query else { return }
            self.filteredNotes = result.0
            self.noteSections = result.1
        }
    }

    /// Counts each tag once per note (a note's `tags` are already deduped),
    /// most-used first, ties alphabetical.
    nonisolated static func aggregateTags(_ notes: [ContextNote]) -> [TagSummary] {
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags {
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .map { TagSummary(name: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.name < rhs.name
            }
    }

    /// Tags to offer under the search field. An empty query or a bare `#`
    /// offers everything; `#he` narrows to prefix matches first, then
    /// substring matches. A plain-text query (no `#`) is a body search,
    /// so nothing is suggested; likewise once a space follows the tag.
    nonisolated static func tagSuggestions(tags: [TagSummary], query: String) -> [TagSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return tags }
        guard trimmed.hasPrefix("#") else { return [] }

        let needle = String(trimmed.dropFirst()).lowercased()
        guard !needle.contains(where: \.isWhitespace) else { return [] }
        if needle.isEmpty { return tags }

        let prefixed = tags.filter { $0.name.hasPrefix(needle) }
        let contained = tags.filter { !$0.name.hasPrefix(needle) && $0.name.contains(needle) }
        return prefixed + contained
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
