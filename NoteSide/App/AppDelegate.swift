import AppKit

/// AppKit delegate for the pieces SwiftUI's `App` can't express for a
/// menu-bar app: the Services provider, and (later) URL and Spotlight
/// continuation handling.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let servicesProvider = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
    }
}
