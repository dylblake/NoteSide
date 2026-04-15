import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class AllNotesPanelController {
    private var panel: NoteEditorPanel?
    private var animationSequence = 0

    private static let presentDuration: TimeInterval = 0.46
    private static let dismissDuration: TimeInterval = 0.38

    private static let smoothEaseOut = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
    private static let smoothEaseIn = CAMediaTimingFunction(controlPoints: 0.7, 0.0, 0.84, 0.0)

    func install(appState: AppState) {
        let rootView = FloatingAllNotesView()
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

        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.masksToBounds = true
        }

        self.panel = panel
    }

    func present() {
        guard let panel, let screen = targetScreen() else { return }
        animationSequence += 1
        let sequence = animationSequence
        let finalFrame = paneFrame(for: screen)

        let offScreenFrame = NSRect(
            x: screen.visibleFrame.maxX,
            y: finalFrame.minY,
            width: finalFrame.width,
            height: finalFrame.height
        )

        panel.setFrame(offScreenFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.presentDuration
            context.timingFunction = Self.smoothEaseOut
            context.allowsImplicitAnimation = true
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

    func dismiss() {
        guard let panel, let screen = targetScreen(), panel.isVisible else {
            panel?.orderOut(nil)
            return
        }
        animationSequence += 1
        let sequence = animationSequence

        let endFrame = collapsedFrame(for: screen)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.dismissDuration
            context.timingFunction = Self.smoothEaseIn
            context.allowsImplicitAnimation = true
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

    func repositionToActiveScreenIfNeeded() {
        guard let panel, panel.isVisible else { return }
        let pointerLocation = NSEvent.mouseLocation
        guard let target = NSScreen.screens.first(where: { NSMouseInRect(pointerLocation, $0.frame, false) }) else { return }
        guard let currentScreen = panel.screen, currentScreen.frame != target.frame else { return }
        panel.setFrame(paneFrame(for: target), display: true, animate: false)
    }

    private func paneFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.visibleFrame.integral
        let paneWidth = floor(screenFrame.width * 0.45)
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

    private func targetScreen() -> NSScreen? {
        if let panelScreen = panel?.screen, panel?.isVisible == true {
            return panelScreen
        }

        let pointerLocation = NSEvent.mouseLocation
        if let pointerScreen = NSScreen.screens.first(where: { NSMouseInRect(pointerLocation, $0.frame, false) }) {
            return pointerScreen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }
}
