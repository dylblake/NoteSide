import AppKit

/// Target of the "Note This in Remora" Services menu item (declared in
/// Info.plist under NSServices). Any app that can hand over selected text
/// reaches the editor through here, no Accessibility permission needed.
final class ServicesProvider: NSObject {
    @objc func noteThis(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let raw = pasteboard.string(forType: .string),
              let text = SelectionReader.normalized(raw) else {
            error.pointee = "No text was selected."
            return
        }
        Task { @MainActor in
            AppEnvironment.shared.appState?.captureQuickNote(passageText: text)
        }
    }
}

/// Lets AppKit-side entry points (Services, URL events, Spotlight) reach
/// the SwiftUI-owned `AppState`.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()
    weak var appState: AppState?
    private init() {}
}
