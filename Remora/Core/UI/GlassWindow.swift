import AppKit
import SwiftUI

extension NSWindow {
    /// A titled window whose only visible chrome is the traffic lights. The
    /// window itself is clear; the SwiftUI root draws the Liquid Glass (see
    /// `glassWindowBackground()`), so About / Setup / License read as the
    /// same material as the floating panels while keeping native drag,
    /// close and ⌘W.
    static func glass(contentSize: NSSize, title: String, resizable: Bool = false) -> NSWindow {
        var styleMask: StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable {
            styleMask.insert(.resizable)
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        // Still the window's name for VoiceOver and Mission Control; only
        // the drawn title bar text is hidden.
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        return window
    }

    /// Centres the window on the screen under the pointer, else the key
    /// window's screen, else the main screen, clamped to the visible frame.
    func centerOnPreferredScreen(size: NSSize) {
        guard let screen = Self.preferredScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let centeredX = visibleFrame.midX - (width / 2)
        let centeredY = visibleFrame.midY - (height / 2)
        let originX = min(max(centeredX, visibleFrame.minX), visibleFrame.maxX - width)
        let originY = min(max(centeredY, visibleFrame.minY), visibleFrame.maxY - height)
        setFrame(
            NSRect(x: floor(originX), y: floor(originY), width: floor(width), height: floor(height)),
            display: false
        )
    }

    private static func preferredScreen() -> NSScreen? {
        let pointerLocation = NSEvent.mouseLocation
        if let pointerScreen = NSScreen.screens.first(where: { NSMouseInRect(pointerLocation, $0.frame, false) }) {
            return pointerScreen
        }
        if let keyWindowScreen = NSApp.keyWindow?.screen {
            return keyWindowScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

extension View {
    /// Root of a glass window: the content sits on the same sheet glass as
    /// the panels, filling the clear window edge to edge (title bar too).
    func glassWindowBackground() -> some View {
        background {
            Color.clear
                .glassEffect(RemoraTheme.sheetGlass, in: Rectangle())
                .ignoresSafeArea()
        }
    }
}
