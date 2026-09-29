import Foundation

struct NoteSectionGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let notes: [ContextNote]
}

struct NoteSection: Identifiable, Hashable {
    let id: String
    let title: String
    let helperText: String?
    let groups: [NoteSectionGroup]
}

/// Builds the grouped section models shown in All Notes. A pure function
/// of the (already filtered, sorted) note list, so NotesState can cache
/// the result and recompute it only when notes or the search query change
/// — previously this ran inside the view body on every render.
enum NoteSectionBuilder {
    static func build(from notes: [ContextNote]) -> [NoteSection] {
        let pinnedNotes = notes.filter(\.isPinned)
        let unpinnedNotes = notes.filter { !$0.isPinned }
        let siteNotes = unpinnedNotes.filter { $0.context.kind == .url }
        let codeEditorFileNotes = unpinnedNotes.filter { isCodeEditorFileContext($0.context) }
        let regularFileNotes = unpinnedNotes.filter { $0.context.kind == .file && !isCodeEditorFileContext($0.context) }

        return [
            pinnedSection(notes: pinnedNotes),
            section(
                id: "applications",
                title: "Apps",
                notes: unpinnedNotes.filter { $0.context.kind == .application },
                key: { appGroupName(for: $0.context) },
                groupTitle: { notes in appGroupName(for: notes[0].context) },
                subtitle: { _ in nil }
            ),
        ] + websiteSections(for: siteNotes) + codebaseSections(for: codeEditorFileNotes) + [
            section(
                id: "files",
                title: "Files",
                notes: regularFileNotes,
                key: { fileGroupKey(for: $0.context) },
                // The file name + parent directory live inside each card
                // (see NoteTile.headerLabel / subheaderLabel) so the group
                // wrapper doesn't repeat them.
                groupTitle: { _ in "" },
                subtitle: { _ in nil }
            )
        ]
    }

    private static func pinnedSection(notes: [ContextNote]) -> NoteSection {
        let sortedNotes = notes.sorted { $0.updatedAt > $1.updatedAt }
        return NoteSection(
            id: "pinned",
            title: "Pinned",
            helperText: nil,
            groups: sortedNotes.isEmpty ? [] : [
                NoteSectionGroup(
                    id: "pinned",
                    title: "",
                    subtitle: nil,
                    notes: sortedNotes
                )
            ]
        )
    }

    private static func section(
        id: String,
        title: String,
        notes: [ContextNote],
        key: (ContextNote) -> String,
        groupTitle: ([ContextNote]) -> String,
        subtitle: ([ContextNote]) -> String?
    ) -> NoteSection {
        let grouped = Dictionary(grouping: notes, by: key)
            .map { groupKey, notes in
                NoteSectionGroup(
                    id: groupKey,
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

        return NoteSection(
            id: id,
            title: title,
            helperText: id == "applications" ? "Some apps don’t support returning to the original context (Slack, Figma, ...)" : nil,
            groups: grouped
        )
    }

    private static func websiteSections(for notes: [ContextNote]) -> [NoteSection] {
        let grouped = Dictionary(grouping: notes) { note in
            siteName(for: note.context)
        }

        return grouped
            .map { site, siteNotes in
                NoteSection(
                    id: "site::\(site)",
                    title: site,
                    helperText: nil,
                    groups: [
                        NoteSectionGroup(
                            id: site,
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

    private static func codebaseSections(for notes: [ContextNote]) -> [NoteSection] {
        let grouped = Dictionary(grouping: notes) { note in
            note.context.sourceRootPath ?? note.context.identifier
        }

        return grouped
            .map { rootPath, rootNotes in
                section(
                    id: "codebase::\(rootPath)",
                    title: shortenedPath(rootPath),
                    notes: rootNotes,
                    key: { codeEditorGroupKey(for: $0.context) },
                    // File name + project root are rendered inside the card
                    // body, so the group wrapper above the card stays empty.
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

    private static func siteName(for context: NoteContext) -> String {
        if let secondaryLabel = context.secondaryLabel,
           let url = URL(string: secondaryLabel),
           let host = url.host(),
           !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }

        return context.displayName
    }

    private static func appGroupName(for context: NoteContext) -> String {
        let components = context.displayName.components(separatedBy: " / ")
        return components.first ?? context.displayName
    }

    private static func fileGroupKey(for context: NoteContext) -> String {
        let root = context.sourceRootPath ?? context.identifier
        let editor = context.sourceBundleIdentifier ?? "unknown"
        return "\(editor)::\(root)"
    }

    private static func codeEditorGroupKey(for context: NoteContext) -> String {
        let editor = context.sourceBundleIdentifier ?? "unknown"
        return "\(editor)::\(context.identifier)"
    }

    static func isCodeEditorFileContext(_ context: NoteContext) -> Bool {
        guard context.kind == .file else { return false }
        guard let bundleIdentifier = context.sourceBundleIdentifier else { return false }
        return [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.visualstudio.code.oss"
        ].contains(bundleIdentifier)
    }

    private static func shortenedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return path }

        let components = trimmed.split(separator: "/").map(String.init)
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        }

        return components[0]
    }
}
