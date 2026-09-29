import Foundation

final class NoteStore {
    /// On-disk envelope. The version field exists so future format changes
    /// can migrate explicitly instead of guessing from shape.
    private struct NotesFile: Codable {
        var version: Int
        var notes: [ContextNote]
    }

    /// 1: original envelope. 2: web identities canonicalised (see
    /// `NoteMigration.canonicalizeWebIdentifiers`).
    private static let currentSchemaVersion = 2

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
    private var debounceWorkItem: DispatchWorkItem?
    private let writeQueue = DispatchQueue(label: "com.noteside.notestore.write")

    /// Set during loadNotes() when the notes file was unreadable and a
    /// recovery action was taken. The app surfaces this to the user once.
    private(set) var loadRecoveryMessage: String?

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

        // The storage folder predates the app's rename and was still
        // called "SideNote". Move it once; if the move fails, keep using
        // the legacy folder rather than presenting an empty library.
        let legacyDirectory = appSupport.appending(path: "SideNote", directoryHint: .isDirectory)
        let preferredDirectory = appSupport.appending(path: "NoteSide", directoryHint: .isDirectory)

        if !fileManager.fileExists(atPath: preferredDirectory.path),
           fileManager.fileExists(atPath: legacyDirectory.path) {
            try? fileManager.moveItem(at: legacyDirectory, to: preferredDirectory)
        }

        if !fileManager.fileExists(atPath: preferredDirectory.path),
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

    func save(notes: [ContextNote]) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.pendingNotes = notes
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
    }

    private func decodeNotes(from data: Data) -> DecodedNotes? {
        if let file = try? decoder.decode(NotesFile.self, from: data) {
            return DecodedNotes(version: file.version, notes: file.notes)
        }
        // Legacy format: a bare top-level array of notes (pre-envelope).
        if let notes = try? decoder.decode([ContextNote].self, from: data) {
            return DecodedNotes(version: 0, notes: notes)
        }
        return nil
    }

    /// Applies schema migrations in order and persists the result so the
    /// next launch loads the current version directly.
    private func migrateIfNeeded(_ decoded: DecodedNotes, forceSave: Bool = false) -> [ContextNote] {
        var notes = decoded.notes
        var version = decoded.version

        if version < 2 {
            notes = NoteMigration.canonicalizeWebIdentifiers(notes)
            version = 2
        }

        if version != decoded.version || forceSave {
            save(notes: notes)
            flush()
        }
        return notes
    }

    /// Must only run on writeQueue.
    private func writePendingToDisk() {
        guard let notes = pendingNotes else { return }
        pendingNotes = nil
        let file = NotesFile(version: Self.currentSchemaVersion, notes: notes)
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
        var message = "Your notes file was damaged, so NoteSide restored your notes from the most recent backup."
        if let quarantineURL {
            message += " The damaged file was kept at \(quarantineURL.path) in case you need it."
        }
        return message
    }

    private func recoveryMessageForUnrecoverableFile(quarantineURL: URL?) -> String {
        var message = "Your notes file was damaged and no usable backup was found, so NoteSide is starting with an empty note list."
        if let quarantineURL {
            message += " The damaged file was kept at \(quarantineURL.path) — it may be possible to recover notes from it manually."
        } else {
            message += " The damaged file could not be moved aside; it remains at \(fileURL.path)."
        }
        return message
    }
}
