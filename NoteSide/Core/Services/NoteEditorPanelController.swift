import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class NoteEditorPanelController {
    private var panel: NoteEditorPanel?
    private var animationSequence = 0
    private var lastPresentedScreen: NSScreen?

    func install(appState: AppState) {
        let rootView = FloatingNoteEditorView()
            .environmentObject(appState)

        let hostingController = NSHostingController(rootView: rootView)
        let panel = NoteEditorPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        // Clip the hosting layer so SwiftUI content transitions can never
        // bleed past the panel frame onto an adjacent display when the panel
        // is anchored to a screen edge.
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.masksToBounds = true
        }

        self.panel = panel
    }

    func present() {
        guard let panel, let screen = targetScreen(preferPanelScreen: false) else { return }
        animationSequence += 1
        let sequence = animationSequence
        lastPresentedScreen = screen
        let finalFrame = paneFrame(for: screen)
        let startFrame = collapsedFrame(for: screen)

        panel.animator().alphaValue = panel.alphaValue
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0.96
        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.animationSequence == sequence else { return }
                panel.setFrame(finalFrame, display: false)
                panel.alphaValue = 1
            }
        })
    }

    /// If the panel is visible and the cursor is now on a different screen
    /// than the panel currently sits on, slide the panel to that screen's
    /// right edge. Cheap and idempotent — safe to call from both the
    /// didActivateApplication notification and the polling timer.
    func repositionToActiveScreenIfNeeded() {
        guard let panel, panel.isVisible else { return }
        guard let target = targetScreen(preferPanelScreen: false) else { return }
        guard let currentScreen = panel.screen else {
            // Panel has no screen yet — just snap to the target.
            panel.setFrame(paneFrame(for: target), display: true)
            lastPresentedScreen = target
            return
        }
        // NSScreen instances aren't necessarily reference-stable across calls;
        // compare frames instead.
        guard currentScreen.frame != target.frame else { return }

        animationSequence += 1
        let sequence = animationSequence
        lastPresentedScreen = target
        let newFrame = paneFrame(for: target)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0)
            panel.animator().setFrame(newFrame, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.animationSequence == sequence else { return }
                panel.setFrame(newFrame, display: false)
            }
        })
    }

    private func paneFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.visibleFrame.integral
        let paneWidth = floor(screenFrame.width / 3)
        return NSRect(
            x: screenFrame.maxX - paneWidth,
            y: screenFrame.minY,
            width: paneWidth,
            height: screenFrame.height
        )
    }

    private func collapsedFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.visibleFrame.integral
        let collapsedWidth: CGFloat = 28
        return NSRect(
            x: screenFrame.maxX - collapsedWidth,
            y: screenFrame.minY,
            width: collapsedWidth,
            height: screenFrame.height
        )
    }

    func dismiss() {
        guard let panel, let screen = targetScreen(preferPanelScreen: true), panel.isVisible else {
            panel?.orderOut(nil)
            return
        }
        animationSequence += 1
        let sequence = animationSequence

        let endFrame = collapsedFrame(for: screen)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.animationSequence == sequence else { return }
                panel.orderOut(nil)
                panel.setFrame(endFrame, display: false)
                panel.alphaValue = 1
            }
        })
    }

    private func targetScreen(preferPanelScreen: Bool) -> NSScreen? {
        if preferPanelScreen, let panelScreen = panel?.screen {
            return panelScreen
        }

        // Prefer the screen the frontmost app's focused window actually lives
        // on. When the user opens a note from All Notes, the cursor stays
        // over the (now-dismissed) All Notes window while the navigated app
        // activates on whatever screen its window is on; using the cursor
        // would put the panel on the wrong display.
        if let appWindowScreen = frontmostAppFocusedWindowScreen() {
            return appWindowScreen
        }

        let pointerLocation = NSEvent.mouseLocation
        if let pointerScreen = NSScreen.screens.first(where: { NSMouseInRect(pointerLocation, $0.frame, false) }) {
            return pointerScreen
        }

        if let lastPresentedScreen {
            return lastPresentedScreen
        }

        if let mainScreen = NSScreen.main {
            return mainScreen
        }

        if let keyWindowScreen = NSApp.keyWindow?.screen {
            return keyWindowScreen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Asks the Accessibility API for the frontmost app's focused window
    /// rect, then maps the window's center to whichever NSScreen contains
    /// that point. Returns nil if AX can't reach the target (no permission,
    /// non-AX app, no focused window, missing position/size attributes).
    private func frontmostAppFocusedWindowScreen() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Wake up Electron/Chromium AX trees so position queries succeed for
        // Slack, VSCode, Figma, etc.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        var focusedWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef) == .success,
              let focusedWindowRef
        else {
            return nil
        }
        let focusedWindow = focusedWindowRef as! AXUIElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        // AX coordinates: top-left origin of the primary screen, Y down.
        // Cocoa coordinates: bottom-left origin of the primary screen, Y up.
        // Convert the window's center point and find the screen that contains it.
        let centerAX = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let centerCocoa = CGPoint(x: centerAX.x, y: primaryHeight - centerAX.y)

        return NSScreen.screens.first { NSMouseInRect(centerCocoa, $0.frame, false) }
    }
}
