import AppKit
import CoreServices

/// Asks macOS whether Remora may send Apple Events to another app,
/// without sending one. The URL-reading scripts answer a different
/// question ("what page is open"), so they can't tell a granted browser
/// showing its start page from one that was never asked; this is the
/// permission itself.
///
/// The call blocks while TCC answers, so it never runs on the main thread
/// or on the AppleScript queue (a script waiting on a consent prompt
/// would hold it up).
nonisolated enum AutomationPermission {
    enum Status: Sendable, Equatable {
        case granted
        case denied
        /// macOS has never asked; sending an event would show the prompt.
        case notDetermined
        /// The target isn't running, so there is nothing to ask about yet.
        case unknown
    }

    private static let queue = DispatchQueue(label: "com.remora.automation-permission", qos: .userInitiated)

    /// Never prompts and never launches the target.
    static func status(forBundleIdentifier bundleIdentifier: String) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        let code = withExtendedLifetime(target) {
            AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        }
        switch code {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        default:
            // procNotFound (-600) when the app isn't running, including
            // the moment just after it launches.
            return .unknown
        }
    }

    static func statuses(forBundleIdentifiers bundleIdentifiers: [String]) async -> [String: Status] {
        await withCheckedContinuation { continuation in
            queue.async {
                var result: [String: Status] = [:]
                for bundleIdentifier in bundleIdentifiers {
                    result[bundleIdentifier] = status(forBundleIdentifier: bundleIdentifier)
                }
                continuation.resume(returning: result)
            }
        }
    }
}
