import Foundation

/// DEBUG-only trace to a file named by `REMORA_TRACE_FILE`, for
/// diagnosing flows under XCUITest where the unified log is awkward.
nonisolated enum DebugTrace {
    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["REMORA_TRACE_FILE"], !path.isEmpty else { return }
        let line = "\(Date().timeIntervalSince1970) \(message())\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
        #endif
    }
}
