import Foundation

struct NoteSection: Identifiable, Hashable {
    let id: String
    let title: String
    let notes: [ContextNote]
}

/// Builds the two sections shown in All Notes: the To-Do list (pinned
/// notes, in the user's order) and everything else as one grid. A pure
/// function of the (already filtered, sorted) note list, so NotesState can
/// cache the result and recompute it only when notes or the search query
/// change.
enum NoteSectionBuilder {
    /// The pinned notes' section, drawn as the To-Do list rather than tiles.
    static let todoSectionID = "todo"
    /// Every unpinned note, in the order given (newest first).
    static let notesSectionID = "notes"

    static func build(from notes: [ContextNote], todoOrder: [UUID] = []) -> [NoteSection] {
        [
            todoSection(notes: notes.filter(\.isPinned), order: todoOrder),
            NoteSection(id: notesSectionID, title: "Notes", notes: notes.filter { !$0.isPinned })
        ]
    }

    /// Pinned notes in the user's manual order. A note missing from
    /// `order` sorts after the ordered ones, most recently updated first.
    private static func todoSection(notes: [ContextNote], order: [UUID]) -> NoteSection {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let sortedNotes = notes.sorted { lhs, rhs in
            switch (rank[lhs.id], rank[rhs.id]) {
            case let (lhsRank?, rhsRank?): return lhsRank < rhsRank
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.updatedAt > rhs.updatedAt
            }
        }
        return NoteSection(id: todoSectionID, title: "To-Do", notes: sortedNotes)
    }
}
