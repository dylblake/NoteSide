import Foundation

final class NoteStore {
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

    private let fileURL: URL
    private var pendingNotes: [ContextNote]?
    private var debounceWorkItem: DispatchWorkItem?
    private let writeQueue = DispatchQueue(label: "com.noteside.notestore.write")

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let directory = appSupport
            .appending(path: "SideNote", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "notes.json")
    }

    func loadNotes() -> [ContextNote] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([ContextNote].self, from: data)) ?? []
    }

    func save(notes: [ContextNote]) {
        debounceWorkItem?.cancel()
        pendingNotes = notes

        let workItem = DispatchWorkItem { [weak self] in
            self?.writePendingToDisk()
        }
        debounceWorkItem = workItem
        writeQueue.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func flush() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        writePendingToDisk()
    }

    private func writePendingToDisk() {
        guard let notes = pendingNotes else { return }
        pendingNotes = nil
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
