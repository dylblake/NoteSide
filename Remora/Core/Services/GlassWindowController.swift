import AppKit
import SwiftUI

/// Shared plumbing for the secondary windows (About, Welcome, License,
/// Setup): one glass `NSWindow`, centred on the screen the user is looking
/// at, fronted over other apps even though Remora is an accessory app.
/// Subclasses supply the root view and, if AppState needs to know (the
/// setup windows drive permission polling), override
/// `windowVisibilityDidChange`.
@MainActor
class GlassWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private(set) weak var appState: AppState?

    let title: String
    /// `.zero` lets the SwiftUI root size the window (the first-run wizard).
    let defaultContentSize: NSSize
    let isResizable: Bool
    let level: NSWindow.Level

    init(title: String, defaultContentSize: NSSize = .zero, resizable: Bool = false, level: NSWindow.Level = .normal) {
        self.title = title
        self.defaultContentSize = defaultContentSize
        self.isResizable = resizable
        self.level = level
        super.init()
    }

    /// Subclasses call this from `install(appState:)` with their root view.
    func installWindow(appState: AppState, rootView: some View) {
        self.appState = appState
        let window = NSWindow.glass(contentSize: defaultContentSize, title: title, resizable: isResizable)
        window.contentViewController = NSHostingController(rootView: rootView.glassWindowBackground())
        window.level = level
        if defaultContentSize != .zero {
            window.minSize = defaultContentSize
            window.setContentSize(defaultContentSize)
        }
        window.delegate = self
        self.window = window
    }

    func present() {
        guard let window else { return }
        windowVisibilityDidChange(true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        let size = window.isVisible || defaultContentSize == .zero
            ? window.frame.size
            : window.frameRect(forContentRect: NSRect(origin: .zero, size: defaultContentSize)).size
        window.centerOnPreferredScreen(size: size)
        // A plain `activate()` is a cooperative request that macOS refuses
        // while another app is active, which is always the case when the
        // hotkey brings up the license window: it then shows but isn't key,
        // and the first click only activates it.
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window, title] in
            DebugTrace.log("window '\(title)' presented: active=\(NSApp.isActive) key=\(window?.isKeyWindow ?? false)")
        }
        #endif
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Re-front the window when the user returns to Remora (e.g. after a
    /// trip to System Settings). No-op if hidden or minimized.
    func bringToFrontIfVisible() {
        guard let window, window.isVisible, !window.isMiniaturized else { return }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        windowVisibilityDidChange(false)
    }

    func windowVisibilityDidChange(_ isVisible: Bool) {}
}
