//
//  ContentView.swift
//  NoteSide
//
//  Created by Dylan Evans on 4/2/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingBulkDeleteConfirmation = false

    private let columns = [
        GridItem(.flexible(), spacing: 18, alignment: .top),
        GridItem(.flexible(), spacing: 18, alignment: .top)
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("All Notes")
                            .font(.largeTitle.weight(.bold))
                        Spacer()
                        if !appState.selectedNoteIDs.isEmpty {
                            bulkActionBar
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 18)
                    .animation(.easeInOut(duration: 0.15), value: appState.selectedNoteIDs.isEmpty)

                    ScrollView {
                        Color.clear
                            .frame(height: 0)
                            .id("top")

                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(noteSections) { section in
                                if !section.groups.isEmpty {
                                    NoteTileSection(section: section)
                                        .environmentObject(appState)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                    .searchable(text: $appState.searchText, prompt: "Search notes")
                }
                .onChange(of: appState.allNotesScrollResetID) { _, _ in
                    proxy.scrollTo("top", anchor: .top)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
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
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
                  let bundle = Bundle(url: appURL) else {
                return nil
            }

            return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
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
    @EnvironmentObject private var appState: AppState

    let section: NoteTileSectionModel

    private let columns = [
        GridItem(.flexible(), spacing: 18, alignment: .top),
        GridItem(.flexible(), spacing: 18, alignment: .top)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title)
                .font(.title2.weight(.bold))

            if let helperText = section.helperText, !helperText.isEmpty {
                Text(helperText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(section.groups) { group in
                    NoteGroupTile(group: group)
                        .environmentObject(appState)
                }
            }
        }
    }
}

private struct NoteGroupTile: View {
    @EnvironmentObject private var appState: AppState

    let group: NoteTileGroup

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

            ForEach(group.notes) { note in
                NoteTile(note: note)
                    .environmentObject(appState)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct NoteTile: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingDeleteConfirmation = false

    let note: ContextNote

    private var isSelected: Bool {
        appState.selectedNoteIDs.contains(note.id)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {
                appState.open(note)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    if let headerLabel, !headerLabel.isEmpty {
                        Text(headerLabel)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let subheaderLabel, !subheaderLabel.isEmpty {
                        Text(subheaderLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    if let siteLabel, !siteLabel.isEmpty {
                        Text(siteLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Text(note.body)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, 2)

                    if let detailLabel, !detailLabel.isEmpty {
                        Text(detailLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        // Reserve enough vertical space for the 44×44 pin and
                        // trash overlays so they don't ride up over the path
                        // / detail line above the date.
                        Color.clear
                            .frame(width: 96, height: 44)
                    }
                    .padding(.top, 4)
                }
                .padding(.top, 14)
                // Extra left padding so the checkbox overlay doesn't overlap
                // the header / preview text.
                .padding(.leading, 40)
                .padding(.trailing, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tileBackground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Checkbox overlay anchored to the top-left of the colored tile.
            // Drawn after the card button so it sits on top in z-order and
            // intercepts taps before they reach the underlying open action.
            Button {
                appState.toggleSelection(note.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? NoteSideTheme.accent : NoteSideTheme.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.leading, 6)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(spacing: 4) {
                Button {
                    appState.togglePin(note)
                } label: {
                    ZStack {
                        Color.clear
                        Image(systemName: note.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(note.isPinned ? NoteSideTheme.accent : NoteSideTheme.secondaryText)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    ZStack {
                        Color.clear
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NoteSideTheme.secondaryText)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
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
            .padding(.trailing, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private var tileColor: Color {
        switch note.context.kind {
        case .application:
            return Color(red: 0.32, green: 0.56, blue: 0.92)
        case .url:
            return Color(red: 0.18, green: 0.68, blue: 0.47)
        case .file:
            return Color(red: 0.88, green: 0.58, blue: 0.18)
        }
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(NoteSideTheme.tintedTileFill(for: tileColor))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(NoteSideTheme.tintedTileStroke(for: tileColor), lineWidth: 1)
            )
    }

    private var siteLabel: String? {
        switch note.context.kind {
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
        case .file:
            return nil
        }
    }

    /// Small detail line shown under the preview body, giving extra context
    /// about where the note belongs (full URL for web notes, file path for
    /// file notes). Hidden when nothing useful is available.
    private var detailLabel: String? {
        switch note.context.kind {
        case .url:
            return note.context.secondaryLabel ?? note.context.identifier
        case .file:
            return note.context.secondaryLabel ?? note.context.identifier
        case .application:
            return nil
        }
    }

    /// Bold top line for file notes — file name plus the source editor
    /// (e.g. "gradlew.bat (VSCode)"). Other note kinds rely on siteLabel.
    private var headerLabel: String? {
        guard note.context.kind == .file else { return nil }
        if let editorName = NoteTile.editorName(for: note.context.sourceBundleIdentifier) {
            return "\(note.context.displayName) (\(editorName))"
        }
        return note.context.displayName
    }

    /// Caption line directly under the header — the project root or parent
    /// directory the file lives in.
    private var subheaderLabel: String? {
        guard note.context.kind == .file else { return nil }
        return note.context.sourceRootPath
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
