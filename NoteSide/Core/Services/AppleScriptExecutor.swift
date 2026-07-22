import Foundation

/// Runs all of the app's AppleScript on one dedicated serial queue.
///
/// NSAppleScript instances aren't safe to use concurrently, and previously
/// each subsystem held its own script cache behind an NSLock — so a slow
/// script started by the background context poll could block a hotkey-
/// triggered resolution (or the main thread) on that lock until the Apple
/// Event round-trip finished. A single serial executor gives every script
/// the same isolation guarantees without cross-subsystem lock contention,
/// and keeps Apple Event round-trips off the main thread, where a busy
/// target app could otherwise stall the UI for the event-timeout duration.
final class AppleScriptExecutor: @unchecked Sendable {
    static let shared = AppleScriptExecutor()

    private static let queueKey = DispatchSpecificKey<Void>()

    private let queue: DispatchQueue
    /// Compiled-script cache. Confined to `queue`.
    private var scripts: [String: NSAppleScript] = [:]

    init() {
        queue = DispatchQueue(label: "com.noteside.applescript", qos: .userInitiated)
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    func execute(key: String, source: String) async -> (descriptor: NSAppleEventDescriptor?, error: NSDictionary?) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: run(key: key, source: source))
            }
        }
    }

    /// Blocks the calling thread while the script runs on the executor
    /// queue. Callable from the executor queue itself (runs inline), so
    /// higher-level operations composed of several scripts can execute as
    /// one unit without deadlocking. Avoid on the main thread in
    /// user-interaction paths.
    func executeSync(key: String, source: String) -> (descriptor: NSAppleEventDescriptor?, error: NSDictionary?) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return run(key: key, source: source)
        }
        return queue.sync {
            run(key: key, source: source)
        }
    }

    /// Must only run on `queue`.
    private func run(key: String, source: String) -> (descriptor: NSAppleEventDescriptor?, error: NSDictionary?) {
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
