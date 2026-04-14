import AppKit
import SwiftUI

@MainActor
final class LicenseWindowController: NSObject, NSWindowDelegate {
    private let defaultFrame = NSRect(x: 0, y: 0, width: 520, height: 380)
    private var window: NSWindow?
    private weak var appState: AppState?

    func install(appState: AppState) {
        self.appState = appState

        let rootView = LicenseView()
            .environmentObject(appState)

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Activate NoteSide"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: defaultFrame.width, height: defaultFrame.height)
        window.setContentSize(defaultFrame.size)
        window.level = .floating
        window.delegate = self
        self.window = window
    }

    func present() {
        guard let window else { return }

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

    func windowWillClose(_: Notification) {}

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
        let originX = floor(visibleFrame.midX - width / 2)
        let originY = floor(visibleFrame.midY - height / 2)
        return NSRect(x: originX, y: originY, width: width, height: height)
    }
}
