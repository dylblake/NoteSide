import AppKit
import SwiftUI

@MainActor
final class InfoWindowController: NSObject, NSWindowDelegate {
    private let defaultContentSize = NSSize(width: 560, height: 520)
    private var window: NSWindow?
    private weak var appState: AppState?

    func install(appState: AppState) {
        self.appState = appState

        let rootView = InfoView()
            .environmentObject(appState)

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "About NoteSide"
        window.isReleasedWhenClosed = false
        window.minSize = defaultContentSize
        window.setContentSize(defaultContentSize)
        window.delegate = self
        self.window = window
    }

    func present() {
        guard let window else { return }
        appState?.setInfoWindowVisible(true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if let screen = targetScreen() {
            let targetSize = window.isVisible
                ? window.frame.size
                : window.frameRect(forContentRect: NSRect(origin: .zero, size: defaultContentSize)).size
            let frame = centeredFrame(for: targetSize, on: screen)
            window.setFrame(frame, display: false)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        appState?.setInfoWindowVisible(false)
    }

    private func targetScreen() -> NSScreen? {
        let pointerLocation = NSEvent.mouseLocation

        if let pointerScreen = NSScreen.screens.first(where: { NSMouseInRect(pointerLocation, $0.frame, false) }) {
            return pointerScreen
        }

        if let keyWindowScreen = NSApp.keyWindow?.screen {
            return keyWindowScreen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private func centeredFrame(for size: NSSize, on screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let centeredX = visibleFrame.midX - (width / 2)
        let centeredY = visibleFrame.midY - (height / 2)
        let originX = min(max(centeredX, visibleFrame.minX), visibleFrame.maxX - width)
        let originY = min(max(centeredY, visibleFrame.minY), visibleFrame.maxY - height)

        return NSRect(
            x: floor(originX),
            y: floor(originY),
            width: floor(width),
            height: floor(height)
        )
    }
}
