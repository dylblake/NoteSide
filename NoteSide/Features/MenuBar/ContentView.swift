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
    @AppStorage("allNotesViewMode") private var viewModeRaw: String = AllNotesViewMode.grid.rawValue

    var isFloatingPanel = false

    private var viewMode: AllNotesViewMode {
        AllNotesViewMode(rawValue: viewModeRaw) ?? .grid
    }

    private let columns = [
        GridItem(.flexible(), spacing: 18, alignment: .top),
        GridItem(.flexible(), spacing: 18, alignment: .top)
    ]

    var body: some View {
        @Bindable var appState = appState
        let content = ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("All Notes")
                        .font(isFloatingPanel ? .title2.weight(.bold) : .largeTitle.weight(.bold))
                    viewModeToggle
                    Spacer()
                    if !appState.selectedNoteIDs.isEmpty {
                        bulkActionBar
                    }
                }
                .padding(.horizontal, isFloatingPanel ? 18 : 24)
                .padding(.top, isFloatingPanel ? 18 : 24)
                .padding(.bottom, isFloatingPanel ? 14 : 18)
                .animation(.easeInOut(duration: 0.15), value: appState.selectedNoteIDs.isEmpty)

                TagSearchField(text: $appState.searchText)
                    .padding(.horizontal, isFloatingPanel ? 18 : 24)
                    .padding(.bottom, 10)

                ScrollView {
                    Color.clear
                        .frame(height: 0)
                        .id("top")

                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(noteSections) { section in
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
                    .padding(.horizontal, isFloatingPanel ? 18 : 24)
                    .padding(.bottom, isFloatingPanel ? 18 : 24)
                }
            }
            .onChange(of: appState.allNotesScrollResetID) { _, _ in
                proxy.scrollTo("top", anchor: .top)
            }
        }

        if isFloatingPanel {
            content
        } else {
            NavigationStack {
                content
            }
            .frame(minWidth: 820, minHeight: 560)
            .background(Color(nsColor: .windowBackgroundColor))
        }
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
    }

    private var bulkActionBar: some View {
        HStack(spacing: 14) {
            Text("\(appState.selectedNoteIDs.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                appState.clearSelection()
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
            .popover(isPresented: $showingBulkDeleteConfirmation, arrowEdge: .bottom) {
                DeleteConfirmationPopover(
                    onConfirm: {
                        showingBulkDeleteConfirmation = false
                        appState.deleteSelectedNotes()
                    },
                    onCancel: {
                        showingBulkDeleteConfirmation = false
                    }
                )
            }
        }
    }

    private var noteSections: [NoteTileSectionModel] {
        let notes = appState.filteredNotes
        let pinnedNotes = notes.filter(\.isPinned)
        let unpinnedNotes = notes.filter { !$0.isPinned }
        let siteNotes = unpinnedNotes.filter { $0.context.kind == .url }
        let codeEditorFileNotes = unpinnedNotes.filter { isCodeEditorFileContext($0.context) }
        let regularFileNotes = unpinnedNotes.filter { $0.context.kind == .file && !isCodeEditorFileContext($0.context) }

        return [
            makePinnedSection(notes: pinnedNotes),
            makeSection(
                id: "applications",
                title: "Apps",
                notes: unpinnedNotes.filter { $0.context.kind == .application },
                key: { appGroupName(for: $0.context) },
                groupTitle: { notes in
                    appGroupName(for: notes[0].context)
                },
                subtitle: { _ in nil }
            ),
        ] + websiteSections(for: siteNotes) + codebaseSections(for: codeEditorFileNotes) + [
            makeSection(
                id: "files",
                title: "Files",
                notes: regularFileNotes,
                key: { fileGroupKey(for: $0.context) },
                // The file name + parent directory now live inside each card
                // (see NoteTile.headerLabel / subheaderLabel) so the group
                // wrapper doesn't repeat them.
                groupTitle: { _ in "" },
                subtitle: { _ in nil }
            )
        ]
    }

    private func makePinnedSection(notes: [ContextNote]) -> NoteTileSectionModel {
        let sortedNotes = notes.sorted { $0.updatedAt > $1.updatedAt }
        return NoteTileSectionModel(
            id: "pinned",
            title: "Pinned",
            helperText: nil,
            groups: sortedNotes.isEmpty ? [] : [
                NoteTileGroup(
                    title: "",
                    subtitle: nil,
                    notes: sortedNotes
                )
            ]
        )
    }

    private func makeSection(
        id: String,
        title: String,
        notes: [ContextNote],
        key: (ContextNote) -> String,
        groupTitle: ([ContextNote]) -> String,
        subtitle: ([ContextNote]) -> String?
    ) -> NoteTileSectionModel {
        let grouped = Dictionary(grouping: notes, by: key)
            .map { _, notes in
                NoteTileGroup(
                    title: groupTitle(notes),
                    subtitle: subtitle(notes),
                    notes: notes.sorted { $0.updatedAt > $1.updatedAt }
                )
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.notes.first?.updatedAt ?? .distantPast
                let rhsDate = rhs.notes.first?.updatedAt ?? .distantPast
                return lhsDate > rhsDate
            }

        return NoteTileSectionModel(
            id: id,
            title: title,
            helperText: id == "applications" ? "Some apps don’t support returning to the original context (Slack, Figma, ...)" : nil,
            groups: grouped
        )
    }

    private func siteName(for context: NoteContext) -> String {
        if let secondaryLabel = context.secondaryLabel,
           let url = URL(string: secondaryLabel),
           let host = url.host(),
           !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }

        return context.displayName
    }

    private func appGroupName(for context: NoteContext) -> String {
        let components = context.displayName.components(separatedBy: " / ")
        return components.first ?? context.displayName
    }

    private func fileGroupKey(for context: NoteContext) -> String {
        let root = context.sourceRootPath ?? context.identifier
        let editor = context.sourceBundleIdentifier ?? "unknown"
        return "\(editor)::\(root)"
    }

    private func fileGroupTitle(for context: NoteContext) -> String {
        let rootPath = context.sourceRootPath ?? context.secondaryLabel ?? context.identifier
        let displayRoot = shortenedPath(rootPath)

        if let editorName = editorName(for: context.sourceBundleIdentifier) {
            return "\(displayRoot) (\(editorName))"
        }

        return displayRoot
    }

    private func fileGroupSubtitle(for context: NoteContext) -> String? {
        context.sourceRootPath ?? context.secondaryLabel
    }

    private func codebaseSections(for notes: [ContextNote]) -> [NoteTileSectionModel] {
        let grouped = Dictionary(grouping: notes) { note in
            note.context.sourceRootPath ?? note.context.identifier
        }

        return grouped
            .map { rootPath, rootNotes in
                makeSection(
                    id: "codebase::\(rootPath)",
                    title: shortenedPath(rootPath),
                    notes: rootNotes,
                    key: { codeEditorGroupKey(for: $0.context) },
                    // File name + project root are now rendered inside the
                    // card body (NoteTile.headerLabel / subheaderLabel), so
                    // the group wrapper above the card stays empty.
                    groupTitle: { _ in "" },
                    subtitle: { _ in nil }
                )
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.groups.flatMap(\.notes).map(\.updatedAt).max() ?? .distantPast
                let rhsDate = rhs.groups.flatMap(\.notes).map(\.updatedAt).max() ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    private func websiteSections(for notes: [ContextNote]) -> [NoteTileSectionModel] {
        let grouped = Dictionary(grouping: notes) { note in
            siteName(for: note.context)
        }

        return grouped
            .map { site, siteNotes in
                NoteTileSectionModel(
                    id: "site::\(site)",
                    title: site,
                    helperText: nil,
                    groups: [
                        NoteTileGroup(
                            title: "",
                            subtitle: nil,
                            notes: siteNotes.sorted { $0.updatedAt > $1.updatedAt }
                        )
                    ]
                )
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.groups.flatMap(\.notes).map(\.updatedAt).max() ?? .distantPast
                let rhsDate = rhs.groups.flatMap(\.notes).map(\.updatedAt).max() ?? .distantPast
                return lhsDate > rhsDate
            }
    }

    private func isCodeEditorFileContext(_ context: NoteContext) -> Bool {
        guard context.kind == .file else { return false }
        guard let bundleIdentifier = context.sourceBundleIdentifier else { return false }
        return [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.visualstudio.code.oss"
        ].contains(bundleIdentifier)
    }

    private func codeEditorGroupKey(for context: NoteContext) -> String {
        let editor = context.sourceBundleIdentifier ?? "unknown"
        return "\(editor)::\(context.identifier)"
    }

    private func codeEditorGroupTitle(for context: NoteContext) -> String {
        if let editorName = editorName(for: context.sourceBundleIdentifier) {
            return "\(context.displayName) (\(editorName))"
        }
        return context.displayName
    }

    private func shortenedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return path }

        let components = trimmed.split(separator: "/").map(String.init)
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        }

        return components[0]
    }

    private static var editorNameCache: [String: String] = [:]

    private func editorName(for bundleIdentifier: String?) -> String? {
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
        default:
            if let cached = Self.editorNameCache[bundleIdentifier] {
                return cached
            }
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
                  let bundle = Bundle(url: appURL) else {
                return nil
            }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            if let name {
                Self.editorNameCache[bundleIdentifier] = name
            }
            return name
        }
    }
}

private struct NoteTileSectionModel: Identifiable {
    let id: String
    let title: String
    let helperText: String?
    let groups: [NoteTileGroup]
}

private struct NoteTileGroup: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let notes: [ContextNote]
}

private struct NoteTileSection: View {
    @Environment(AppState.self) private var appState

    let section: NoteTileSectionModel

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

    let group: NoteTileGroup

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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct NoteTile: View {
    @Environment(AppState.self) private var appState
    @State private var showingDeleteConfirmation = false

    let note: ContextNote

    private var isSelected: Bool {
        appState.selectedNoteIDs.contains(note.id)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                appState.toggleSelection(note.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? NoteSideTheme.accent : NoteSideTheme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

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

            Button {
                appState.togglePin(note)
            } label: {
                Image(systemName: note.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(note.isPinned ? NoteSideTheme.accent : NoteSideTheme.secondaryText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(note.isPinned ? "Unpin" : "Pin")

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NoteSideTheme.secondaryText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .popover(isPresented: $showingDeleteConfirmation, arrowEdge: .bottom) {
                DeleteConfirmationPopover(
                    onConfirm: {
                        showingDeleteConfirmation = false
                        appState.delete(note)
                    },
                    onCancel: {
                        showingDeleteConfirmation = false
                    }
                )
            }
        }
    }

    private var tileColor: Color { NoteCardStyle.tint(for: note) }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(NoteSideTheme.tintedTileFill(for: tileColor))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(NoteSideTheme.tintedTileStroke(for: tileColor), lineWidth: 1)
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

    private static func editorName(for bundleIdentifier: String?) -> String? {
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
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
                  let bundle = Bundle(url: appURL) else {
                return nil
            }
            return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        }
    }
}

private struct NoteListSection: View {
    @Environment(AppState.self) private var appState

    let section: NoteTileSectionModel

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

    let group: NoteTileGroup

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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct NoteListRow: View {
    @Environment(AppState.self) private var appState
    @State private var showingDeleteConfirmation = false

    let note: ContextNote

    private var isSelected: Bool {
        appState.selectedNoteIDs.contains(note.id)
    }

    private var tint: Color { NoteCardStyle.tint(for: note) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                appState.toggleSelection(note.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? NoteSideTheme.accent : NoteSideTheme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

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

            Button {
                appState.togglePin(note)
            } label: {
                Image(systemName: note.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(note.isPinned ? NoteSideTheme.accent : NoteSideTheme.secondaryText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(note.isPinned ? "Unpin" : "Pin")

            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NoteSideTheme.secondaryText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .popover(isPresented: $showingDeleteConfirmation, arrowEdge: .bottom) {
                DeleteConfirmationPopover(
                    onConfirm: {
                        showingDeleteConfirmation = false
                        appState.delete(note)
                    },
                    onCancel: {
                        showingDeleteConfirmation = false
                    }
                )
            }
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
                        .stroke(NoteSideTheme.tintedTileStroke(for: tint), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            appState.open(note)
        }
    }
}

private struct TagSearchField: View {
    @Binding var text: String
    @State private var shouldPlaceCursor = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TagColoredTextField(text: $text, placeCursorAtEnd: shouldPlaceCursor)
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
        private let parent: TagColoredTextField
        private static let tagPattern = try! NSRegularExpression(pattern: #"#\w+"#)

        init(_ parent: TagColoredTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            Self.applyTagColoring(to: field)
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
