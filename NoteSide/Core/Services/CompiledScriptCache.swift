import Foundation

final class CompiledScriptCache: @unchecked Sendable {
    private var scripts: [String: NSAppleScript] = [:]
    private let lock = NSLock()

    func execute(key: String, source: String) -> (descriptor: NSAppleEventDescriptor?, error: NSDictionary?) {
        lock.lock()
        defer { lock.unlock() }

        let script: NSAppleScript
        if let cached = scripts[key] {
            script = cached
        } else {
            guard let newScript = NSAppleScript(source: source) else {
                return (nil, nil)
            }
            scripts[key] = newScript
            script = newScript
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return (result, error)
    }
}
