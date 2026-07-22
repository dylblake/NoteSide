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
        window.title = "Welcome to NoteSide"
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
    }

    func present() {
        guard let window else { return }
        appState?.setOnboardingWindowVisible(true)
        if let screen = targetScreen() {
            let frame = centeredFrame(for: window.frame.size, on: screen)
            window.setFrame(frame, display: false)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        appState?.setOnboardingWindowVisible(false)
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
