import AppKit
import Foundation

/// One-time transformations applied when `notes.json` is older than the
/// current schema. Pure functions over `[ContextNote]` so they can be
/// unit-tested without touching disk.
nonisolated enum NoteMigration {

    static let mergeDivider = "— — —"

    /// Schema 1 → 2: web identities were the full URL including session
    /// and tracking parameters, so one page could own several notes.
    /// Recompute every `.url` identifier with `URLCanonicalizer` and merge
    /// the notes that now collide into one.
    static func canonicalizeWebIdentifiers(_ notes: [ContextNote]) -> [ContextNote] {
        var groups: [String: [ContextNote]] = [:]
        var order: [String] = []

        for note in notes {
            let rewritten = rewrittenWebIdentity(note)
            let key = rewritten.context.id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(rewritten)
        }

        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            return group.count == 1 ? group[0] : merged(group)
        }
    }

    private static func rewrittenWebIdentity(_ note: ContextNote) -> ContextNote {
        guard note.context.kind == .url,
              let urlString = note.context.secondaryLabel ?? Optional(note.context.identifier),
              let url = URL(string: urlString) else {
            return note
        }
        let canonical = URLCanonicalizer.canonicalIdentifier(for: url)
        guard canonical != note.context.identifier else { return note }

        let context = NoteContext(
            kind: .url,
            identifier: canonical,
            displayName: note.context.displayName,
            secondaryLabel: URLCanonicalizer.navigationURL(for: url).absoluteString,
            navigationTarget: note.context.navigationTarget.map { target in
                URL(string: target).map { URLCanonicalizer.navigationURL(for: $0).absoluteString } ?? target
            },
            sourceBundleIdentifier: note.context.sourceBundleIdentifier,
            sourceRootPath: note.context.sourceRootPath,
            fileSystemIdentifier: note.context.fileSystemIdentifier,
            fileBookmarkData: note.context.fileBookmarkData
        )
        return note.copying(context: context)
    }

    /// Newest note first, others appended beneath a divider. The newest
    /// note's id survives so anything that referenced it still resolves.
    private static func merged(_ group: [ContextNote]) -> ContextNote {
        let ordered = group.sorted { $0.updatedAt > $1.updatedAt }
        let newest = ordered[0]

        let bodies = ordered.map(\.body).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let body = bodies.joined(separator: "\n\n\(mergeDivider)\n\n")

        let attributed = NSMutableAttributedString()
        for note in ordered {
            let piece = attributedText(for: note)
            guard piece.length > 0 else { continue }
            if attributed.length > 0 {
                let dividerAttributes = piece.attributes(at: 0, effectiveRange: nil)
                attributed.append(NSAttributedString(string: "\n\n\(mergeDivider)\n\n", attributes: dividerAttributes))
            }
            attributed.append(piece)
        }
        let richTextData = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )

        let title = ordered.first { !($0.title ?? "").isEmpty }?.title

        return ContextNote(
            id: newest.id,
            context: newest.context,
            body: body,
            richTextData: richTextData,
            createdAt: ordered.map(\.createdAt).min() ?? newest.createdAt,
            updatedAt: newest.updatedAt,
            isPinned: ordered.contains { $0.isPinned },
            title: title
        )
    }

    private static func attributedText(for note: ContextNote) -> NSAttributedString {
        if let data = note.richTextData,
           let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return attributed
        }
        return NSAttributedString(string: note.body)
    }
}
