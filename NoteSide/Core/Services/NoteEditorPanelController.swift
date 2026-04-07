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
        self.panel = panel
    }

    func present() {
        guard let panel, let screen = targetScreen(preferPanelScreen: false) else { return }
        animationSequence += 1
        let sequence = animationSequence
        lastPresentedScreen = screen
        let screenFrame = screen.visibleFrame.integral
        let paneWidth = floor(screenFrame.width / 3)
        let collapsedWidth: CGFloat = 28
        let finalFrame = NSRect(
            x: screenFrame.maxX - paneWidth,
            y: screenFrame.minY,
            width: paneWidth,
            height: screenFrame.height
        )
        let startFrame = NSRect(
            x: screenFrame.maxX - collapsedWidth,
            y: screenFrame.minY,
            width: collapsedWidth,
            height: screenFrame.height
        )

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

    func dismiss() {
        guard let panel, let screen = targetScreen(preferPanelScreen: true), panel.isVisible else {
            panel?.orderOut(nil)
            return
        }
        animationSequence += 1
        let sequence = animationSequence

        let screenFrame = screen.visibleFrame.integral
        let collapsedWidth: CGFloat = 28
        let endFrame = NSRect(
            x: screenFrame.maxX - collapsedWidth,
            y: screenFrame.minY,
            width: collapsedWidth,
            height: screenFrame.height
        )

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
}
