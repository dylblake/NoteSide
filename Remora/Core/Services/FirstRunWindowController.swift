import AppKit
import SwiftUI

@MainActor
final class FirstRunWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var appState: AppState?

    func install(appState: AppState) {
        self.appState = appState

        let rootView = FirstRunView()
            .environment(appState)

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Welcome to Remora"
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
    }

    func present() {
        guard let window else { return }
        appState?.setFirstRunWindowVisible(true)
        if let screen = targetScreen() {
            let frame = centeredFrame(for: window.frame.size, on: screen)
            window.setFrame(frame, display: false)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
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
        appState?.setFirstRunWindowVisible(false)
    }

    private func targetScreen() -> NSScreen? {
        if let pointerScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
            return pointerScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func centeredFrame(for size: NSSize, on screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        return NSRect(
            x: floor(visibleFrame.midX - width / 2),
            y: floor(visibleFrame.midY - height / 2),
            width: width,
            height: height
        )
    }
}
