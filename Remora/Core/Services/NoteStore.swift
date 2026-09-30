import Foundation

final class NoteStore {
    /// On-disk envelope. The version field exists so future format changes
    /// can migrate explicitly instead of guessing from shape.
    private struct NotesFile: Codable {
        var version: Int
        var notes: [ContextNote]
        /// IDs of the To-Do (pinned) notes in the user's manual order.
        /// Optional so files written before the To-Do list still decode.
        var todoOrder: [UUID]?
    }

    /// 1: original envelope. 2: web identities canonicalised (see
    /// `NoteMigration.canonicalizeWebIdentifiers`).
    private static let currentSchemaVersion = 3

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let fileManager: FileManager
    private let directory: URL
    private let fileURL: URL
    private let backupURL: URL

    // pendingNotes and debounceWorkItem are confined to writeQueue: save()
    // and flush() are called from the main thread, writePendingToDisk from
    // the queue's own work items, so unsynchronized access would race.
    private var pendingNotes: [ContextNote]?
    private var pendingTodoOrder: [UUID] = []
    private var debounceWorkItem: DispatchWorkItem?
    private let writeQueue = DispatchQueue(label: "com.remora.notestore.write")

    /// Set during loadNotes() when the notes file was unreadable and a
    /// recovery action was taken. The app surfaces this to the user once.
    private(set) var loadRecoveryMessage: String?

    /// The To-Do order stored alongside the notes, set by `loadNotes()`.
    private(set) var loadedTodoOrder: [UUID] = []

    /// `directoryOverride` bypasses Application Support entirely — used by
    /// the UI-test launch hook so automated runs never touch real notes.
    init(fileManager: FileManager = .default, directoryOverride: URL? = nil) {
        self.fileManager = fileManager

        if let directoryOverride {
            directory = directoryOverride
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appending(path: "notes.json")
            backupURL = directory.appending(path: "notes.json.bak")
            return
        }

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())

        // The app was called NoteSide before Remora, and SideNote before
        // that; the storage folder followed each name. Move the newest
        // legacy folder once; if the move fails, keep using it rather than
        // presenting an empty library.
        let preferredDirectory = appSupport.appending(path: "Remora", directoryHint: .isDirectory)
        let legacyDirectory = ["NoteSide", "SideNote"]
            .map { appSupport.appending(path: $0, directoryHint: .isDirectory) }
            .first { fileManager.fileExists(atPath: $0.path) }

        if let legacyDirectory, !fileManager.fileExists(atPath: preferredDirectory.path) {
            try? fileManager.moveItem(at: legacyDirectory, to: preferredDirectory)
        }

        if let legacyDirectory,
           !fileManager.fileExists(atPath: preferredDirectory.path),
           fileManager.fileExists(atPath: legacyDirectory.path) {
            directory = legacyDirectory
        } else {
            directory = preferredDirectory
        }

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "notes.json")
        backupURL = directory.appending(path: "notes.json.bak")
    }

    func loadNotes() -> [ContextNote] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        if let data = try? Data(contentsOf: fileURL),
           let decoded = decodeNotes(from: data) {
            return migrateIfNeeded(decoded)
        }

        // The main file exists but couldn't be read or decoded. Quarantine
        // it (never overwrite the user's only copy of their data) and try
        // the backup from the previous successful write.
        let quarantineURL = quarantineCorruptFile()

        if let backupData = try? Data(contentsOf: backupURL),
           let backupDecoded = decodeNotes(from: backupData) {
            loadRecoveryMessage = recoveryMessageForRestoredBackup(quarantineURL: quarantineURL)
            // Re-establish notes.json from the backup so the next launch
            // doesn't go through recovery again.
            let backupNotes = migrateIfNeeded(backupDecoded, forceSave: true)
            return backupNotes
        }

        loadRecoveryMessage = recoveryMessageForUnrecoverableFile(quarantineURL: quarantineURL)
        return []
    }

    func save(notes: [ContextNote], todoOrder: [UUID]) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.pendingNotes = notes
            self.pendingTodoOrder = todoOrder
            self.debounceWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                self?.writePendingToDisk()
            }
            self.debounceWorkItem = workItem
            self.writeQueue.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }

    func flush() {
        writeQueue.sync {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            writePendingToDisk()
        }
    }

    private struct DecodedNotes {
        let version: Int
        let notes: [ContextNote]
        let todoOrder: [UUID]
    }

    private func decodeNotes(from data: Data) -> DecodedNotes? {
        if let file = try? decoder.decode(NotesFile.self, from: data) {
            return DecodedNotes(version: file.version, notes: file.notes, todoOrder: file.todoOrder ?? [])
        }
        // Legacy format: a bare top-level array of notes (pre-envelope).
        if let notes = try? decoder.decode([ContextNote].self, from: data) {
            return DecodedNotes(version: 0, notes: notes, todoOrder: [])
        }
        return nil
    }

    /// Applies schema migrations in order and persists the result so the
    /// next launch loads the current version directly.
    private func migrateIfNeeded(_ decoded: DecodedNotes, forceSave: Bool = false) -> [ContextNote] {
        var notes = decoded.notes
        var version = decoded.version
        loadedTodoOrder = decoded.todoOrder

        // 2: first canonicalisation. 3: Google account slots, GitHub PR
        // tabs, Linear slugs and YouTube aliases. The pass is idempotent,
        // so re-running it under the current rules covers both.
        if version < 3 {
            notes = NoteMigration.canonicalizeWebIdentifiers(notes)
            version = 3
        }

        if version != decoded.version || forceSave {
            save(notes: notes, todoOrder: decoded.todoOrder)
            flush()
        }
        return notes
    }

    /// Must only run on writeQueue.
    private func writePendingToDisk() {
        guard let notes = pendingNotes else { return }
        pendingNotes = nil
        let file = NotesFile(version: Self.currentSchemaVersion, notes: notes, todoOrder: pendingTodoOrder)
        guard let data = try? encoder.encode(file) else { return }

        // Keep the previous good copy as a backup before overwriting, so a
        // corrupted or interrupted write never destroys the only copy.
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: fileURL, to: backupURL)
        }

        try? data.write(to: fileURL, options: .atomic)
    }

    private func quarantineCorruptFile() -> URL? {
        let timestamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let quarantineURL = directory.appending(path: "notes.corrupt-\(timestamp).json")
        do {
            try fileManager.moveItem(at: fileURL, to: quarantineURL)
            return quarantineURL
        } catch {
            return nil
        }
    }

    private func recoveryMessageForRestoredBackup(quarantineURL: URL?) -> String {
        var message = "Your notes file was damaged, so Remora restored your notes from the most recent backup."
        if let quarantineURL {
            message += " The damaged file was kept at \(quarantineURL.path) in case you need it."
        }
        return message
    }

    private func recoveryMessageForUnrecoverableFile(quarantineURL: URL?) -> String {
        var message = "Your notes file was damaged and no usable backup was found, so Remora is starting with an empty note list."
        if let quarantineURL {
            message += " The damaged file was kept at \(quarantineURL.path) — it may be possible to recover notes from it manually."
        } else {
            message += " The damaged file could not be moved aside; it remains at \(fileURL.path)."
        }
        return message
    }
}
