//
//  ContentView.swift
//  Remora
//
//  Created by Dylan Evans on 4/2/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showingBulkDeleteConfirmation = false
    @State private var searchFocusRequestID = UUID()
    /// While the search field has the caret its own key handling (tag
    /// suggestions, typing) must win over the list shortcuts below.
    @State private var isSearchFieldFocused = false
    @FocusState private var isListFocused: Bool
    var body: some View {
        @Bindable var notes = appState.notesState
        let content = ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: Spacing.sm) {
                    Text("All Notes")
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !appState.notesState.selectedNoteIDs.isEmpty {
                        bulkActionBar
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.sm)
                .animation(PanelAnimation.prefersReducedMotion ? nil : .easeOut(duration: 0.18), value: appState.notesState.selectedNoteIDs.isEmpty)

                TagSearchField(
                    text: $notes.searchText,
                    isFocused: $isSearchFieldFocused,
                    focusRequestID: searchFocusRequestID,
                    suggestions: NotesState.tagSuggestions(
                        tags: appState.notesState.allTags,
                        query: appState.notesState.searchText
                    ),
                    onMoveDown: {
                        isListFocused = true
                        if appState.notesState.keyboardFocusedNoteID == nil,
                           let first = orderedVisibleNotes.first {
                            appState.notesState.keyboardFocusedNoteID = first.id
                        }
                    }
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.sm)
                // The suggestions overlay hangs below the field; keep it
                // above the scroll view that follows.
                .zIndex(1)

                ScrollView {
                    Color.clear
                        .frame(height: 0)
                        .id("top")

                    if appState.notesState.notes.isEmpty {
                        emptyStateView
                    } else if appState.notesState.filteredNotes.isEmpty && !appState.notesState.searchText.isEmpty {
                        noResultsView
                    } else {
                        LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                            ForEach(appState.notesState.noteSections) { section in
                                if !section.notes.isEmpty {
                                    if section.id == NoteSectionBuilder.todoSectionID {
                                        TodoListSection(section: section)
                                            .environment(appState)
                                    } else {
                                        // "Notes" only needs saying when
                                        // the To-Do list sits above it.
                                        NoteGridSection(section: section, showsHeading: hasTodoNotes)
                                            .environment(appState)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.lg)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isListFocused)
            // These fire before the AppKit first responder sees the key,
            // so they step aside while the search field is being typed in.
            .onKeyPress(.downArrow) { unlessSearching { moveKeyboardFocus(by: 1, proxy: proxy) } }
            .onKeyPress(.upArrow) { unlessSearching { moveKeyboardFocus(by: -1, proxy: proxy) } }
            .onKeyPress(.rightArrow) { unlessSearching { moveKeyboardFocus(by: 1, proxy: proxy) } }
            .onKeyPress(.leftArrow) { unlessSearching { moveKeyboardFocus(by: -1, proxy: proxy) } }
            .onKeyPress(.return) { unlessSearching { openKeyboardFocusedNote() } }
            .onKeyPress(.space) { unlessSearching { toggleKeyboardFocusedSelection() } }
            .onKeyPress(.delete) { unlessSearching { confirmDeleteKeyboardFocusedNote() } }
            .onKeyPress(.deleteForward) { unlessSearching { confirmDeleteKeyboardFocusedNote() } }
            .background(
                // Hidden ⌘F target: moves focus into the search field.
                Button("") { searchFocusRequestID = UUID() }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            )
            .onChange(of: appState.notesState.allNotesScrollResetID) { _, _ in
                proxy.scrollTo("top", anchor: .top)
                isListFocused = true
            }
        }

        content
    }

    // MARK: - Keyboard navigation

    /// Notes in on-screen order (sections top to bottom, groups, then
    /// notes) so arrow keys walk the list the way it reads.
    private var orderedVisibleNotes: [ContextNote] {
        appState.notesState.noteSections.flatMap(\.notes)
    }

    private var hasTodoNotes: Bool {
        appState.notesState.noteSections.contains { $0.id == NoteSectionBuilder.todoSectionID && !$0.notes.isEmpty }
    }

    private func unlessSearching(_ action: () -> KeyPress.Result) -> KeyPress.Result {
        isSearchFieldFocused ? .ignored : action()
    }

    private func moveKeyboardFocus(by delta: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let notes = orderedVisibleNotes
        guard !notes.isEmpty else { return .ignored }

        let currentIndex = appState.notesState.keyboardFocusedNoteID
            .flatMap { id in notes.firstIndex(where: { $0.id == id }) }

        let newIndex: Int
        if let currentIndex {
            newIndex = max(0, min(notes.count - 1, currentIndex + delta))
        } else {
            newIndex = delta >= 0 ? 0 : notes.count - 1
        }

        let target = notes[newIndex]
        appState.notesState.keyboardFocusedNoteID = target.id
        proxy.scrollTo(target.id, anchor: nil)
        return .handled
    }

    private func openKeyboardFocusedNote() -> KeyPress.Result {
        guard let note = keyboardFocusedNote else { return .ignored }
        appState.open(note)
        return .handled
    }

    private func toggleKeyboardFocusedSelection() -> KeyPress.Result {
        guard let note = keyboardFocusedNote else { return .ignored }
        appState.notesState.toggleSelection(note.id)
        return .handled
    }

    private func confirmDeleteKeyboardFocusedNote() -> KeyPress.Result {
        guard let note = keyboardFocusedNote else { return .ignored }

        let alert = NSAlert()
        alert.messageText = "Delete this note?"
        alert.informativeText = "“\(NoteCardStyle.primaryTitle(for: note))” will be deleted. This can't be undone."
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            // Move the highlight to a neighbor so keyboard flow continues.
            let notes = orderedVisibleNotes
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                let neighbor = notes.indices.contains(index + 1) ? notes[index + 1]
                    : (index > 0 ? notes[index - 1] : nil)
                appState.notesState.keyboardFocusedNoteID = neighbor?.id
            }
            appState.notesState.delete(note)
        }
        return .handled
    }

    private var keyboardFocusedNote: ContextNote? {
        guard let id = appState.notesState.keyboardFocusedNoteID else { return nil }
        return orderedVisibleNotes.first { $0.id == id }
    }

    private var emptyStateView: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "note.text")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("No notes yet")
                .font(.title3.weight(.semibold))

            Text("Press \(appState.hotkeys.hotKeyDisplayString) in any app, browser tab, or file to write your first note — it stays attached to that context.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xxl)
        .padding(.horizontal, Spacing.xl)
    }

    private var noResultsView: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No notes match “\(appState.notesState.searchText)”")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xxl)
    }

    private var bulkActionBar: some View {
        HStack(spacing: Spacing.xs) {
            Text("\(appState.notesState.selectedNoteIDs.count) selected")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, Spacing.xs)

            Button("Clear") {
                appState.notesState.clearSelection()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            IconButton(systemName: "pin", accessibilityLabel: "Add or remove selected notes from To-Do", size: 13, hitSize: 30) {
                appState.togglePinForSelectedNotes()
            }

            IconButton(systemName: "trash", accessibilityLabel: "Delete selected notes", size: 13, hitSize: 30) {
                showingBulkDeleteConfirmation = true
            }
            .popover(isPresented: $showingBulkDeleteConfirmation, arrowEdge: .bottom) {
                DeleteConfirmationPopover(
                    title: "Delete \(appState.notesState.selectedNoteIDs.count) notes?",
                    onConfirm: {
                        showingBulkDeleteConfirmation = false
                        appState.notesState.deleteSelectedNotes()
                    },
                    onCancel: {
                        showingBulkDeleteConfirmation = false
                    }
                )
            }
        }
        .padding(.horizontal, Spacing.xxs)
        .padding(.vertical, Spacing.xxs)
        .glassEffect(.regular, in: Capsule(style: .continuous))
    }

}

/// Pinned notes as a compact, hand-ordered list above the tiles: one line
/// each, dragged into whatever order the user wants to tackle them in.
private struct TodoListSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let section: NoteSection

    private struct Drag {
        let noteID: UUID
        let fromIndex: Int
        var translation: CGFloat = 0
        /// False until the pointer travels far enough to mean a drag;
        /// a press released before that is a click.
        var isReordering = false
    }

    @State private var drag: Drag?
    /// Stays on the last dragged row so it settles above its neighbours.
    @State private var liftedNoteID: UUID?

    private static let rowHeight: CGFloat = 34
    private static let dragThreshold: CGFloat = 4

    private var settle: Animation? {
        reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    }

    var body: some View {
        let notes = section.notes

        VStack(alignment: .leading, spacing: Spacing.sm) {
            CountedSectionHeading(title: section.title, count: notes.count)

            VStack(spacing: 0) {
                ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                    let isDragged = drag?.noteID == note.id && drag?.isReordering == true
                    TodoRow(
                        note: note,
                        isPressed: drag?.noteID == note.id && drag?.isReordering == false,
                        isDragged: isDragged,
                        canMoveUp: index > 0,
                        canMoveDown: index < notes.count - 1,
                        onMove: { delta in move(note, by: delta, in: notes) },
                        reorderGesture: reorderGesture(for: note, at: index, in: notes)
                    )
                    .environment(appState)
                    .frame(height: Self.rowHeight)
                    .offset(y: offset(for: note, at: index, count: notes.count))
                    .zIndex(liftedNoteID == note.id ? 1 : 0)
                    // The dragged row tracks the pointer exactly; the rows
                    // it passes ease out of its way.
                    .animation(isDragged ? nil : settle, value: targetIndex(count: notes.count))
                    .id(note.id)
                }
            }
            .padding(Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(RemoraTheme.secondaryBackground.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                            .stroke(RemoraTheme.border.opacity(0.6), lineWidth: 1)
                    )
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("todoList")
        }
    }

    // MARK: Drag to reorder

    /// Slot the dragged row would land in if released now.
    private func targetIndex(count: Int) -> Int? {
        guard let drag, drag.isReordering else { return nil }
        let steps = Int((drag.translation / Self.rowHeight).rounded())
        return min(max(drag.fromIndex + steps, 0), count - 1)
    }

    private func offset(for note: ContextNote, at index: Int, count: Int) -> CGFloat {
        guard let drag, let target = targetIndex(count: count) else { return 0 }

        if note.id == drag.noteID {
            // Held inside the list: it can't be dropped anywhere else.
            let lowest = -CGFloat(drag.fromIndex) * Self.rowHeight
            let highest = CGFloat(count - 1 - drag.fromIndex) * Self.rowHeight
            return min(max(drag.translation, lowest), highest)
        }
        if drag.fromIndex < target, index > drag.fromIndex, index <= target {
            return -Self.rowHeight
        }
        if target < drag.fromIndex, index >= target, index < drag.fromIndex {
            return Self.rowHeight
        }
        return 0
    }

    /// Global coordinates: the row moves under the pointer while it is
    /// dragged, so a local translation would feed back on itself.
    private func reorderGesture(for note: ContextNote, at index: Int, in notes: [ContextNote]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                var current = drag ?? Drag(noteID: note.id, fromIndex: index)
                guard current.noteID == note.id else { return }
                current.translation = value.translation.height
                if !current.isReordering,
                   notes.count > 1,
                   abs(value.translation.height) > Self.dragThreshold {
                    current.isReordering = true
                    liftedNoteID = note.id
                }
                drag = current
            }
            .onEnded { value in
                guard let finished = drag, finished.noteID == note.id else { return }

                guard finished.isReordering else {
                    drag = nil
                    // Released where it was pressed: a click.
                    if abs(value.translation.width) <= Self.dragThreshold {
                        appState.open(note)
                    }
                    return
                }

                let target = targetIndex(count: notes.count) ?? finished.fromIndex
                var ids = notes.map(\.id)
                ids.move(fromOffsets: IndexSet(integer: finished.fromIndex), toOffset: target > finished.fromIndex ? target + 1 : target)
                // One transaction: the rows' new slots and the cleared
                // offsets cancel out, so only the dropped row travels.
                withAnimation(settle) {
                    appState.notesState.reorderTodo(visibleOrder: ids)
                    drag = nil
                }
            }
    }

    /// VoiceOver's Move Up / Move Down.
    private func move(_ note: ContextNote, by delta: Int, in notes: [ContextNote]) {
        var ids = notes.map(\.id)
        guard let index = ids.firstIndex(of: note.id), ids.indices.contains(index + delta) else { return }
        ids.swapAt(index, index + delta)
        withAnimation(settle) {
            appState.notesState.reorderTodo(visibleOrder: ids)
        }
    }
}

/// One To-Do line: where the note lives, its title, and a faint first
/// line. The pin (shown on hover) takes it back off the list.
private struct TodoRow<ReorderGesture: Gesture>: View {
    @Environment(AppState.self) private var appState

    let note: ContextNote
    let isPressed: Bool
    let isDragged: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let reorderGesture: ReorderGesture

    @State private var isHovered = false

    private static var cornerRadius: CGFloat { CornerRadius.card - Spacing.xxs }

    var body: some View {
        let title = NoteCardStyle.primaryTitle(for: note)
        let preview = NoteCardStyle.firstLinePreview(for: note)

        HStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                NoteContextIcon(context: note.context, size: 18)

                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if !preview.isEmpty {
                    Text(preview)
                        .font(.body)
                        .foregroundStyle(RemoraTheme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, Spacing.xs)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(reorderGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(preview.isEmpty ? title : "\(title), \(preview)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { appState.open(note) }
            .accessibilityActions {
                if canMoveUp { Button("Move Up") { onMove(-1) } }
                if canMoveDown { Button("Move Down") { onMove(1) } }
            }
            .accessibilityIdentifier("todoRow")

            NotePinButton(note: note)
                .environment(appState)
                .opacity(isHovered || isKeyboardFocused ? 1 : 0)
                .padding(.trailing, Spacing.xxs)
        }
        .background(rowBackground)
        .scaleEffect(isDragged ? 1.01 : 1)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open") { appState.open(note) }
            Button("Remove from To-Do") { appState.togglePin(note) }
        }
    }

    private var isKeyboardFocused: Bool {
        appState.notesState.keyboardFocusedNoteID == note.id
    }

    private var isSelected: Bool {
        appState.notesState.selectedNoteIDs.contains(note.id)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(
                        isKeyboardFocused ? RemoraTheme.accent : isDragged ? RemoraTheme.border : Color.clear,
                        lineWidth: isKeyboardFocused ? 2 : 1
                    )
            )
            .shadow(color: .black.opacity(isDragged ? 0.18 : 0), radius: 8, y: 3)
    }

    private var fill: Color {
        if isDragged { return RemoraTheme.contentBackground }
        if isSelected { return RemoraTheme.accent.opacity(0.15) }
        if isPressed { return Color.primary.opacity(0.08) }
        if isHovered { return Color.primary.opacity(0.04) }
        return .clear
    }
}

/// A section title with how many notes it holds, e.g. "To-Do 3".
private struct CountedSectionHeading: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(title)
                .font(.title2.weight(.bold))
            Text("\(count)")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "note" : "notes")")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Every unpinned note in one grid, newest first. Nothing is grouped: the
/// icon and source line on each tile say where a note lives, so tiles
/// from different places share rows and fill the pane's width.
private struct NoteGridSection: View {
    @Environment(AppState.self) private var appState

    let section: NoteSection
    let showsHeading: Bool

    // Adaptive so a narrow pane gets two columns and a wide one three.
    private let columns = [
        GridItem(.adaptive(minimum: 210), spacing: Spacing.sm, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if showsHeading {
                CountedSectionHeading(title: section.title, count: section.notes.count)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.sm) {
                ForEach(section.notes) { note in
                    NoteTile(note: note)
                        .environment(appState)
                        .id(note.id)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("notesGrid")
        }
    }
}

/// One note in the grid. Read top to bottom: where it lives, what it is
/// called, how it starts, then tags and date. Every tile is the same
/// height, and the actions stay out of sight until the pointer or the
/// keyboard is on the tile.
private struct NoteTile: View {
    @Environment(AppState.self) private var appState

    let note: ContextNote

    @State private var isHovered = false

    private static let headerHeight: CGFloat = 26
    private static let footerHeight: CGFloat = 22
    private static let checkboxWidth: CGFloat = 22
    /// Pin (26) + delete (26) + checkbox.
    private static let actionsWidth: CGFloat = 52 + checkboxWidth

    var body: some View {
        let text = NoteCardStyle.tileText(for: note)

        VStack(alignment: .leading, spacing: Spacing.xs) {
            sourceLine

            Text(text.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            // An empty Text reserves nothing; a space keeps tiles level.
            Text(text.preview.isEmpty ? " " : text.preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            footer
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileBackground)
        .pressableCard(cornerRadius: CornerRadius.card) {
            appState.open(note)
        }
        .onHover { isHovered = $0 }
        .help(NoteCardStyle.returnCaveat(for: note) ?? "")
        .accessibilityIdentifier("noteTile")
    }

    /// The marker: the context's icon and its name. The actions lie over
    /// its trailing end, and the name gives way to them when they show.
    private var sourceLine: some View {
        HStack(spacing: Spacing.xs) {
            NoteContextIcon(context: note.context, size: 18)

            Text(NoteCardStyle.sourceLabel(for: note))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.trailing, reservedActionsWidth)
        .frame(height: Self.headerHeight)
        .overlay(alignment: .trailing) { actions }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            Group {
                NotePinButton(note: note)
                    .environment(appState)

                NoteDeleteButton(note: note)
                    .environment(appState)
            }
            .opacity(showsActions ? 1 : 0)

            // Trailing, so it stays put when it is the only one showing.
            NoteSelectionCheckbox(noteID: note.id)
                .environment(appState)
                .opacity(showsActions || isSelecting ? 1 : 0)
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.xs) {
            if !note.tags.isEmpty {
                NoteTagPills(tags: note.tags, limit: 2)
            }

            Spacer(minLength: 0)

            Text(NoteCardStyle.dateLabel(for: note.updatedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: Self.footerHeight)
    }

    private var showsActions: Bool { isHovered || isKeyboardFocused }

    /// Once anything is selected, every tile offers its checkbox.
    private var isSelecting: Bool { !appState.notesState.selectedNoteIDs.isEmpty }

    private var reservedActionsWidth: CGFloat {
        if showsActions { return Self.actionsWidth }
        return isSelecting ? Self.checkboxWidth : 0
    }

    private var isSelected: Bool {
        appState.notesState.selectedNoteIDs.contains(note.id)
    }

    private var isKeyboardFocused: Bool {
        appState.notesState.keyboardFocusedNoteID == note.id
    }

    /// Neutral on purpose: the icon carries the note's identity, and the
    /// accent colour is kept for focus and selection.
    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
            .fill(RemoraTheme.glassCardFill)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(RemoraTheme.accent.opacity(isSelected ? 0.12 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .stroke(
                        isKeyboardFocused ? RemoraTheme.accent : RemoraTheme.border.opacity(0.8),
                        lineWidth: isKeyboardFocused ? 2 : 1
                    )
            )
    }
}

/// Shared visual + label helpers used by both the tile and the To-Do row
/// renderings of a note in the All Notes window.
private enum NoteCardStyle {
    /// Plain-text preview: list markers keep their glyph but lose the
    /// layout tab, and table cells collapse onto one line.
    static func preview(of body: some StringProtocol) -> String {
        body
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: "  ")
    }

    /// A tile's headline and preview. A note without a title of its own
    /// would be headed by its context's name, which the source line just
    /// above already shows; its first line heads it instead and the
    /// preview carries on from there.
    static func tileText(for note: ContextNote) -> (title: String, preview: String) {
        let title = primaryTitle(for: note)
        guard title == sourceLabel(for: note) else {
            return (title, preview(of: note.body))
        }

        let firstLine = firstLinePreview(for: note)
        guard !firstLine.isEmpty else { return (title, "") }
        let fromFirstLine = note.body.drop(while: { $0.isWhitespace })
        let afterFirstLine = fromFirstLine.drop(while: { !$0.isNewline })
        return (firstLine, preview(of: afterFirstLine.drop(while: { $0.isWhitespace })))
    }

    /// The first line with anything on it, for the one-line To-Do rows.
    static func firstLinePreview(for note: ContextNote) -> String {
        let line = note.body
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? ""
    }

    /// Bold top line. Shows the note's custom title if set, otherwise
    /// identifies *what* the note is attached to.
    static func primaryTitle(for note: ContextNote) -> String {
        if let title = note.title, !title.isEmpty {
            return title
        }
        return contextDerivedTitle(for: note)
    }

    /// The short name beside the icon, chosen to add to the title rather
    /// than repeat it: the site for a page, the app (and channel, file or
    /// issue within it) for an app note, and for a file either its name
    /// (when the note has its own title) or the project it belongs to.
    static func sourceLabel(for note: ContextNote) -> String {
        let context = note.context
        let hasOwnTitle = !(note.title ?? "").isEmpty

        switch context.kind {
        case .url:
            return context.siteHost ?? context.displayName
        case .application:
            let parts = context.displayName.components(separatedBy: " / ")
            if hasOwnTitle || parts.count == 1 {
                return parts.joined(separator: " · ")
            }
            return parts.dropFirst().joined(separator: " · ")
        case .file:
            if hasOwnTitle { return context.displayName }
            if let root = context.sourceRootPath { return shortenedPath(root) }
            return editorName(for: context.sourceBundleIdentifier) ?? "File"
        }
    }

    /// Tooltip for app notes that can only reopen the app, not the place
    /// inside it the note was written.
    static func returnCaveat(for note: ContextNote) -> String? {
        let context = note.context
        guard context.kind == .application,
              context.navigationTarget == nil,
              context.identifier.contains(":") else {
            return nil
        }
        let app = context.displayName.components(separatedBy: " / ").first ?? context.displayName
        return "Opens \(app). It can't return to the exact place this note was written."
    }

    /// "Sep 29", with the year once it isn't this one.
    static func dateLabel(for date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear
            ? .dateTime.month(.abbreviated).day()
            : .dateTime.month(.abbreviated).day().year())
    }

    /// Last two folders of a path: enough to recognise a project.
    private static func shortenedPath(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return path }
        return components.suffix(2).joined(separator: "/")
    }

    /// The original context-based title (file name, page title, app name).
    private static func contextDerivedTitle(for note: ContextNote) -> String {
        switch note.context.kind {
        case .file:
            if let editorName = editorName(for: note.context.sourceBundleIdentifier) {
                return "\(note.context.displayName) · \(editorName)"
            }
            return note.context.displayName
        case .url:
            return note.context.displayName
        case .application:
            let components = note.context.displayName.components(separatedBy: " / ")
            return components.first ?? note.context.displayName
        }
    }

    private static var editorNameCache: [String: String] = [:]

    static func editorName(for bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        switch bundleIdentifier {
        case "com.apple.dt.Xcode":
            return "Xcode"
        case "com.microsoft.VSCode":
            return "VSCode"
        case "com.microsoft.VSCodeInsiders":
            return "VSCode Insiders"
        case "com.visualstudio.code.oss":
            return "Code OSS"
        case "com.apple.finder":
            return nil
        default:
            if let cached = editorNameCache[bundleIdentifier] {
                return cached
            }
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
                  let bundle = Bundle(url: appURL) else {
                return nil
            }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            if let name {
                editorNameCache[bundleIdentifier] = name
            }
            return name
        }
    }
}

private struct TagSearchField: View {
    @Binding var text: String
    /// Reported the moment the caret enters or leaves the field, so the
    /// caller can hand keys to the field instead of the note list.
    @Binding var isFocused: Bool
    var focusRequestID = UUID()
    /// Tags to offer while the field is focused (already narrowed to the
    /// current query by `NotesState.tagSuggestions`).
    var suggestions: [TagSummary] = []
    /// Down arrow with no suggestions showing: move focus into the notes.
    var onMoveDown: (() -> Void)?
    @State private var shouldPlaceCursor = false
    @State private var isFieldFocused = false
    /// Escape or picking a tag hides the suggestions until the next edit
    /// or the next time the field is focused.
    @State private var isSuppressed = false
    @State private var highlightedIndex: Int?
    @State private var blurHideTask: Task<Void, Never>?
    @State private var fieldHeight: CGFloat = 0
    /// Picking re-focuses the field to place the caret; that refocus must
    /// not re-open the list it just closed.
    @State private var pickedAt: Date?
    @State private var pickedText: String?

    private var isDropdownVisible: Bool {
        isFieldFocused && !isSuppressed && !suggestions.isEmpty
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TagColoredTextField(
                text: $text,
                placeCursorAtEnd: shouldPlaceCursor,
                focusRequestID: focusRequestID,
                onFocusChange: handleFocusChange,
                onMoveDown: handleMoveDown,
                onMoveUp: handleMoveUp,
                onCommit: handleCommit,
                onEscape: handleEscape
            )
                .onChange(of: shouldPlaceCursor) { _, newValue in
                    if newValue {
                        DispatchQueue.main.async { shouldPlaceCursor = false }
                    }
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Spacing.xs + 2)
        .padding(.vertical, Spacing.xs - 1)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                .fill(RemoraTheme.secondaryBackground.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                        .stroke(RemoraTheme.border.opacity(0.6), lineWidth: 1)
                )
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            fieldHeight = height
        }
        .onChange(of: text) { _, newValue in
            highlightedIndex = nil
            if newValue != pickedText {
                isSuppressed = false
                pickedText = nil
            }
        }
        .onChange(of: suggestions.count) { _, _ in
            highlightedIndex = nil
        }
        // Floats below the field rather than pushing the notes down. The
        // caller raises this view's zIndex so it paints over the list.
        .overlay(alignment: .top) {
            if isDropdownVisible {
                TagSuggestionDropdown(
                    suggestions: suggestions,
                    highlightedIndex: highlightedIndex,
                    onPick: pick
                )
                .offset(y: fieldHeight + Spacing.xxs)
                .transition(.opacity)
            }
        }
        .animation(PanelAnimation.prefersReducedMotion ? nil : .easeOut(duration: 0.12), value: isDropdownVisible)
        .accessibilityIdentifier("allNotesSearchField")
    }

    // MARK: - Field events

    private func handleFocusChange(_ focused: Bool) {
        blurHideTask?.cancel()
        isFocused = focused
        guard focused else {
            // Defer so a click on a suggestion lands before the list hides.
            blurHideTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                isFieldFocused = false
            }
            return
        }

        isFieldFocused = true
        let justPicked = pickedAt.map { Date().timeIntervalSince($0) < 0.5 } ?? false
        if !justPicked {
            isSuppressed = false
        }
    }

    private func handleMoveDown() -> Bool {
        guard isDropdownVisible else {
            onMoveDown?()
            return true
        }
        highlightedIndex = min((highlightedIndex ?? -1) + 1, suggestions.count - 1)
        return true
    }

    private func handleMoveUp() -> Bool {
        guard isDropdownVisible, let index = highlightedIndex else { return false }
        highlightedIndex = index == 0 ? nil : index - 1
        return true
    }

    private func handleCommit() -> Bool {
        guard isDropdownVisible, let index = highlightedIndex, index < suggestions.count else { return false }
        pick(suggestions[index])
        return true
    }

    /// Consumes Escape only while the list is showing; otherwise it
    /// propagates to `onExitCommand`, which dismisses the panel.
    private func handleEscape() -> Bool {
        guard isDropdownVisible else { return false }
        isSuppressed = true
        highlightedIndex = nil
        return true
    }

    private func pick(_ tag: TagSummary) {
        blurHideTask?.cancel()
        let picked = "#\(tag.name)"
        pickedText = picked
        pickedAt = .now
        text = picked
        isSuppressed = true
        highlightedIndex = nil
        shouldPlaceCursor = true
    }
}

/// The tag list under the search field: every known tag, most-used first,
/// each in the tag colour with its note count.
private struct TagSuggestionDropdown: View {
    let suggestions: [TagSummary]
    let highlightedIndex: Int?
    let onPick: (TagSummary) -> Void

    private static let rowHeight: CGFloat = 28
    private static let maxVisibleRows = 8

    private var listHeight: CGFloat {
        CGFloat(min(suggestions.count, Self.maxVisibleRows)) * Self.rowHeight + Spacing.xs
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, tag in
                        Button {
                            onPick(tag)
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Text("#\(tag.name)")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(RemoraTheme.tag)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(tag.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(RemoraTheme.tertiaryText)
                            }
                            .padding(.horizontal, Spacing.sm)
                            .frame(height: Self.rowHeight)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(index == highlightedIndex ? RemoraTheme.tag.opacity(0.18) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityIdentifier("tagSuggestion-\(tag.name)")
                    }
                }
                .padding(Spacing.xxs)
            }
            .frame(height: listHeight)
            .onChange(of: highlightedIndex) { _, index in
                if let index {
                    proxy.scrollTo(index)
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Opaque: the section headers underneath otherwise bleed through.
        .cardSurface(cornerRadius: CornerRadius.control)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tagSuggestionsList")
    }
}

/// Reports focus the moment the field takes it. `controlTextDidBeginEditing`
/// only fires on the first keystroke, too late to show suggestions.
private final class FocusReportingTextField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
        }
        return accepted
    }
}

private struct TagColoredTextField: NSViewRepresentable {
    @Binding var text: String
    var placeCursorAtEnd: Bool = false
    var focusRequestID = UUID()
    var onFocusChange: ((Bool) -> Void)?
    /// Key handlers return true when they consumed the key; false lets
    /// AppKit (and then SwiftUI, for Escape) handle it as usual.
    var onMoveDown: (() -> Bool)?
    var onMoveUp: (() -> Bool)?
    var onCommit: (() -> Bool)?
    var onEscape: (() -> Bool)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusReportingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Search notes"
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
        field.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onFocusChange?(true)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self

        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }

        if field.stringValue != text {
            field.stringValue = text
            Coordinator.applyTagColoring(to: field)

            if placeCursorAtEnd {
                DispatchQueue.main.async {
                    field.window?.makeFirstResponder(field)
                    if let editor = field.currentEditor() {
                        editor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
                    }
                    Coordinator.applyTagColoring(to: field)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TagColoredTextField
        var lastFocusRequestID: UUID?
        private static let tagPattern = try! NSRegularExpression(pattern: #"#\w+"#)

        init(_ parent: TagColoredTextField) {
            self.parent = parent
            self.lastFocusRequestID = parent.focusRequestID
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            Self.applyTagColoring(to: field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange?(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMoveDown?() ?? false
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMoveUp?() ?? false
            case #selector(NSResponder.insertNewline(_:)):
                return parent.onCommit?() ?? false
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape?() ?? false
            default:
                return false
            }
        }

        static func applyTagColoring(to field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView,
                  let storage = editor.textStorage else { return }
            let text = storage.string
            let fullRange = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
            let matches = tagPattern.matches(in: text, range: fullRange)
            for match in matches {
                storage.addAttribute(.foregroundColor, value: RemoraTheme.tagNSColor, range: match.range)
            }
            storage.endEditing()
        }
    }
}

private struct NoteTagPills: View {
    let tags: [String]
    var limit: Int = 10

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(tags.prefix(limit), id: \.self) { tag in
                Text("#\(tag)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(RemoraTheme.tag)
                    .lineLimit(1)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xxs)
                    .background(
                        Capsule(style: .continuous)
                            .fill(RemoraTheme.tag.opacity(0.15))
                    )
            }
            if tags.count > limit {
                Text("+\(tags.count - limit)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(RemoraTheme.secondaryText)
            }
        }
    }
}
