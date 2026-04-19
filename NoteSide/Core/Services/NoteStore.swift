import Foundation
import os.log

final class NoteStore {
    enum StoreError: LocalizedError {
        case encodingFailed(Error)
        case writeFailed(Error)
        case readFailed(Error)
        case decodingFailed(Error)

        var errorDescription: String? {
            switch self {
            case .encodingFailed(let error):
                return "Failed to encode notes: \(error.localizedDescription)"
            case .writeFailed(let error):
                return "Failed to save notes to disk: \(error.localizedDescription)"
            case .readFailed(let error):
                return "Failed to read notes file: \(error.localizedDescription)"
            case .decodingFailed(let error):
                return "Failed to decode notes: \(error.localizedDescription)"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.dylblake.noteside", category: "NoteStore")

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let fileURL: URL
    private let backupURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let directory = appSupport
            .appending(path: "SideNote", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "notes.json")
        backupURL = directory.appending(path: "notes.backup.json")
    }

    func loadNotes() -> [ContextNote] {
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([ContextNote].self, from: data)
        } catch {
            Self.logger.error("Failed to load notes: \(error.localizedDescription)")

            // Try the backup file
            if let backupData = try? Data(contentsOf: backupURL),
               let backupNotes = try? decoder.decode([ContextNote].self, from: backupData) {
                Self.logger.info("Recovered \(backupNotes.count) notes from backup")
                return backupNotes
            }

            return []
        }
    }

    func save(notes: [ContextNote]) throws {
        let data: Data
        do {
            data = try encoder.encode(notes)
        } catch {
            Self.logger.error("Failed to encode notes: \(error.localizedDescription)")
            throw StoreError.encodingFailed(error)
        }

        // Keep a backup of the previous save
        if fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: fileURL, to: backupURL)
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to write notes: \(error.localizedDescription)")
            throw StoreError.writeFailed(error)
        }
    }
}
