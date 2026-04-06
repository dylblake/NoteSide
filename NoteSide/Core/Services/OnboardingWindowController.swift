import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let defaultFrame = NSRect(x: 0, y: 0, width: 760, height: 620)
    private var window: NSWindow?
    private weak var appState: AppState?

    func install(appState: AppState) {
        self.appState = appState

        let rootView = OnboardingView()
            .environmentObject(appState)

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Permissions & Setup"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: defaultFrame.width, height: defaultFrame.height)
        window.setContentSize(defaultFrame.size)
        window.delegate = self
        self.window = window
    }

    func present() {
        guard let window else { return }

        if window.frame.width < defaultFrame.width || window.frame.height < defaultFrame.height {
            window.setFrame(defaultFrame, display: false)
        }

        appState?.setOnboardingWindowVisible(true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if let screen = targetScreen() {
            let targetSize = window.isVisible
                ? window.frame.size
                : window.frameRect(forContentRect: NSRect(origin: .zero, size: defaultFrame.size)).size
            let frame = centeredFrame(for: targetSize, on: screen)
            window.setFrame(frame, display: false)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        appState?.setOnboardingWindowVisible(false)
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
