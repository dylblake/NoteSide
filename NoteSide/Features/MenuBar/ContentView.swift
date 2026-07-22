//
//  ContentView.swift
//  NoteSide
//
//  Created by Dylan Evans on 4/2/26.
//

import AppKit
import SwiftUI

private enum AllNotesViewMode: String {
    case grid
    case list
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showingBulkDeleteConfirmation = false
    @State private var searchFocusRequestID = UUID()
    @FocusState private var isListFocused: Bool
    @AppStorage("allNotesViewMode") private var viewModeRaw: String = AllNotesViewMode.grid.rawValue

    private var viewMode: AllNotesViewMode {
        AllNotesViewMode(rawValue: viewModeRaw) ?? .grid
    }

    private let columns = [
        GridItem(.flexible(), spacing: 18, alignment: .top),
        GridItem(.flexible(), spacing: 18, alignment: .top)
    ]

    var body: some View {
        @Bindable var notes = appState.notesState
        let content = ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("All Notes")
                        .font(.title2.weight(.bold))
                    viewModeToggle
                    Spacer()
                    if !appState.notesState.selectedNoteIDs.isEmpty {
                        bulkActionBar
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)
                .animation(.easeInOut(duration: 0.15), value: appState.notesState.selectedNoteIDs.isEmpty)

                TagSearchField(
                    text: $notes.searchText,
                    focusRequestID: searchFocusRequestID,
                    onMoveDown: {
                        isListFocused = true
                        if appState.notesState.keyboardFocusedNoteID == nil,
                           let first = orderedVisibleNotes.first {
                            appState.notesState.keyboardFocusedNoteID = first.id
                        }
                    }
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

                ScrollView {
                    Color.clear
                        .frame(height: 0)
                        .id("top")

                    if appState.notesState.notes.isEmpty {
                        emptyStateView
                    } else if appState.notesState.filteredNotes.isEmpty && !appState.notesState.searchText.isEmpty {
                        noResultsView
                    } else {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            ForEach(appState.notesState.noteSections) { section in
                                if !section.groups.isEmpty {
                                    switch viewMode {
                                    case .grid:
                                        NoteTileSection(section: section)
                                                .environment(appState)
                                    case .list:
                                        NoteListSection(section: section)
                                            .environment(appState)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isListFocused)
            .onKeyPress(.downArrow) { moveKeyboardFocus(by: 1, proxy: proxy) }
            .onKeyPress(.upArrow) { moveKeyboardFocus(by: -1, proxy: proxy) }
            .onKeyPress(.rightArrow) { moveKeyboardFocus(by: 1, proxy: proxy) }
            .onKeyPress(.leftArrow) { moveKeyboardFocus(by: -1, proxy: proxy) }
            .onKeyPress(.return) { openKeyboardFocusedNote() }
            .onKeyPress(.space) { toggleKeyboardFocusedSelection() }
            .onKeyPress(.delete) { confirmDeleteKeyboardFocusedNote() }
            .onKeyPress(.deleteForward) { confirmDeleteKeyboardFocusedNote() }
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
        appState.notesState.noteSections.flatMap { $0.groups.flatMap(\.notes) }
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
        VStack(spacing: 10) {
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
        .padding(.top, 80)
        .padding(.horizontal, 40)
    }

    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No notes match “\(appState.notesState.searchText)”")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var viewModeToggle: some View {
        HStack(spacing: 2) {
            viewModeButton(
                mode: .list,
                systemImage: "line.3.horizontal",
                help: "List view"
            )
            viewModeButton(
                mode: .grid,
                systemImage: "square.grid.2x2",
                help: "Grid view"
            )
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func viewModeButton(mode: AllNotesViewMode, systemImage: String, help: String) -> some View {
        let isActive = viewMode == mode
        return Button {
            viewModeRaw = mode.rawValue
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : NoteSideTheme.secondaryText)
                .frame(width: 30, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? NoteSideTheme.accent : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private var bulkActionBar: some View {
        HStack(spacing: 14) {
            Text("\(appState.notesState.selectedNoteIDs.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                appState.notesState.clearSelection()
            } label: {
                Text("Clear")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)

            Button {
                appState.togglePinForSelectedNotes()
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Pin or unpin selected")
            .accessibilityLabel("Pin or unpin selected notes")

            Button(role: .destructive) {
                showingBulkDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Delete selected")
            .accessibilityLabel("Delete selected notes")
            .popover(isPresented: $showingBulkDeleteConfirmation, arrowEdge: .bottom) {
                DeleteConfirmationPopover(
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
    }

}

private struct NoteTileSection: View {
    @Environment(AppState.self) private var appState

    let section: NoteSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title)
                .font(.title2.weight(.bold))

            if let helperText = section.helperText, !helperText.isEmpty {
                Text(helperText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 18) {
                ForEach(section.groups) { group in
                    NoteGroupTile(group: group)
                        .environment(appState)
                }
            }
        }
    }
}

private struct NoteGroupTile: View {
    @Environment(AppState.self) private var appState

    let group: NoteSectionGroup

    private let columns = [
        GridItem(.flexible(), spacing: 18, alignment: .top),
        GridItem(.flexible(), spacing: 18, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !group.title.isEmpty {
                Text(group.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let subtitle = group.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(group.notes) { note in
                    NoteTile(note: note)
                        .environment(appState)
                        .id(note.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct NoteTile: View {
    @Environment(AppState.self) private var appState

    let note: ContextNote

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            NoteSelectionCheckbox(noteID: note.id)
                .environment(appState)

            cardContent
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if !note.body.isEmpty {
                Text(note.body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !note.tags.isEmpty {
                NoteTagPills(tags: note.tags)
            }

            Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.open(note)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle = secondarySubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NotePinButton(note: note)
                .environment(appState)

            NoteDeleteButton(note: note)
                .environment(appState)
        }
    }

    private var tileColor: Color { NoteCardStyle.tint(for: note) }

    private var isKeyboardFocused: Bool {
        appState.notesState.keyboardFocusedNoteID == note.id
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(NoteSideTheme.tintedTileFill(for: tileColor))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isKeyboardFocused ? NoteSideTheme.accent : NoteSideTheme.tintedTileStroke(for: tileColor),
                        lineWidth: isKeyboardFocused ? 2 : 1
                    )
            )
    }

    private var primaryTitle: String { NoteCardStyle.primaryTitle(for: note) }
    private var secondarySubtitle: String? { NoteCardStyle.secondarySubtitle(for: note) }
}

/// Shared visual + label helpers used by both the grid card and the list row
/// renderings of a note in the All Notes window.
private enum NoteCardStyle {
    static func tint(for note: ContextNote) -> Color {
        switch note.context.kind {
        case .application:
            return Color(red: 0.32, green: 0.56, blue: 0.92)
        case .url:
            return Color(red: 0.18, green: 0.68, blue: 0.47)
        case .file:
            return Color(red: 0.88, green: 0.58, blue: 0.18)
        }
    }

    /// Bold top line. Shows the note's custom title if set, otherwise
    /// identifies *what* the note is attached to.
    static func primaryTitle(for note: ContextNote) -> String {
        if let title = note.title, !title.isEmpty {
            return title
        }
        return contextDerivedTitle(for: note)
    }

    /// Caption line under the title. When a note has an explicit title,
    /// the context-derived name becomes the subtitle. Otherwise falls back
    /// to source location (project root, host, or app sub-context).
    static func secondarySubtitle(for note: ContextNote) -> String? {
        if let title = note.title, !title.isEmpty {
            return contextDerivedTitle(for: note)
        }

        switch note.context.kind {
        case .file:
            return note.context.sourceRootPath ?? note.context.secondaryLabel
        case .url:
            guard let secondaryLabel = note.context.secondaryLabel,
                  !secondaryLabel.isEmpty else {
                return nil
            }
            if let url = URL(string: secondaryLabel),
               let host = url.host(),
               !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            return secondaryLabel
        case .application:
            let components = note.context.displayName.components(separatedBy: " / ")
            guard components.count > 1 else { return nil }
            return components.dropFirst().joined(separator: " / ")
        }
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

private struct NoteListSection: View {
    @Environment(AppState.self) private var appState

    let section: NoteSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title)
                .font(.title2.weight(.bold))

            if let helperText = section.helperText, !helperText.isEmpty {
                Text(helperText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(section.groups) { group in
                    NoteListGroup(group: group)
                        .environment(appState)
                }
            }
        }
    }
}

private struct NoteListGroup: View {
    @Environment(AppState.self) private var appState

    let group: NoteSectionGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !group.title.isEmpty {
                Text(group.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let subtitle = group.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            VStack(spacing: 6) {
                ForEach(group.notes) { note in
                    NoteListRow(note: note)
                        .environment(appState)
                        .id(note.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct NoteListRow: View {
    @Environment(AppState.self) private var appState

    let note: ContextNote

    private var tint: Color { NoteCardStyle.tint(for: note) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            NoteSelectionCheckbox(noteID: note.id)
                .environment(appState)

            rowContent
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(NoteCardStyle.primaryTitle(for: note))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let subtitle = NoteCardStyle.secondarySubtitle(for: note), !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                .frame(width: 220, alignment: .leading)

                Spacer(minLength: 0)

                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            NotePinButton(note: note)
                .environment(appState)

            NoteDeleteButton(note: note)
                .environment(appState)
            }

            if !note.body.isEmpty {
                Text(note.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 20)
            }

            if !note.tags.isEmpty {
                NoteTagPills(tags: note.tags, limit: 3)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(NoteSideTheme.tintedTileFill(for: tint))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isKeyboardFocused ? NoteSideTheme.accent : NoteSideTheme.tintedTileStroke(for: tint),
                            lineWidth: isKeyboardFocused ? 2 : 1
                        )
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            appState.open(note)
        }
    }

    private var isKeyboardFocused: Bool {
        appState.notesState.keyboardFocusedNoteID == note.id
    }
}

private struct TagSearchField: View {
    @Binding var text: String
    var focusRequestID = UUID()
    var onMoveDown: (() -> Void)?
    @State private var shouldPlaceCursor = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TagColoredTextField(
                text: $text,
                placeCursorAtEnd: shouldPlaceCursor,
                focusRequestID: focusRequestID,
                onMoveDown: onMoveDown
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

            Button {
                if !text.hasPrefix("#") {
                    text = "#"
                }
                shouldPlaceCursor = true
            } label: {
                Text("#")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(text.hasPrefix("#") ? NoteSideTheme.accent : NoteSideTheme.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(text.hasPrefix("#") ? NoteSideTheme.accent.opacity(0.15) : Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Search by tag")
            .accessibilityLabel("Search by tag")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

private struct TagColoredTextField: NSViewRepresentable {
    @Binding var text: String
    var placeCursorAtEnd: Bool = false
    var focusRequestID = UUID()
    var onMoveDown: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Search notes"
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
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

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveDown(_:)), let onMoveDown = parent.onMoveDown {
                onMoveDown()
                return true
            }
            return false
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
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range)
            }
            storage.endEditing()
        }
    }
}

private struct NoteTagPills: View {
    let tags: [String]
    var limit: Int = 10

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags.prefix(limit), id: \.self) { tag in
                Text("#\(tag)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(NoteSideTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(NoteSideTheme.accent.opacity(0.15))
                    )
            }
            if tags.count > limit {
                Text("+\(tags.count - limit)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(NoteSideTheme.secondaryText)
            }
        }
    }
}
