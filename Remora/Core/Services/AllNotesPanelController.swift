import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class AllNotesPanelController {
    private var panel: NoteEditorPanel?
    private var animationSequence = 0
    private let clickOutsideMonitor = ClickOutsideMonitor()

    /// A click outside the panel on its display (see `ClickOutsideMonitor`).
    var onClickOutside: (() -> Void)?

    func install(appState: AppState) {
        let rootView = FloatingAllNotesView()
            .environment(appState)

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

        // A visible panel on this screen means a dismiss is still in flight:
        // reverse it from where it is instead of restarting from off-screen.
        let isReversingDismiss = panel.isVisible && panel.screen?.frame == screen.frame
        let reduceMotion = PanelAnimation.prefersReducedMotion
        let layer = panel.contentView?.layer
        panel.setFrame(finalFrame, display: false)

        var duration: TimeInterval
        var startX: CGFloat = 0
        if reduceMotion {
            // Fade in place, continuing a fade-out that's still running.
            if let layer { PanelAnimation.clearSlide(layer) }
            let startAlpha = isReversingDismiss ? panel.alphaValue : 0
            duration = PanelAnimation.reducedMotionFadeDuration * Double(1 - startAlpha)
            panel.alphaValue = startAlpha
        } else {
            // The window sits at its final frame; only its content slides in
            // from the right edge, fully opaque (see PanelAnimation.slide).
            // Lay it out and draw it before it's shown, and pin it off-screen
            // so ordering front can't flash it; the slide starts below.
            let width = finalFrame.width
            startX = isReversingDismiss
                ? min(layer.map(PanelAnimation.currentOffset(of:)) ?? width, width)
                : width
            if !isReversingDismiss {
                panel.contentView?.layoutSubtreeIfNeeded()
                panel.displayIfNeeded()
            }
            panel.alphaValue = 1
            PanelAnimation.hold(panel, atX: startX)
            duration = 0
        }

        panel.orderFrontRegardless()
        panel.makeKey()
        clickOutsideMonitor.start(watching: panel) { [weak self] in self?.onClickOutside?() }
        if !reduceMotion {
            // Commit the window, held off-screen, before the slide's clock
            // starts: putting it up (on another display especially) can take
            // tens of ms, which would otherwise come out of the slide.
            CATransaction.flush()
            duration = PanelAnimation.slide(
                panel,
                fromX: startX,
                toX: 0,
                duration: PanelAnimation.duration(PanelAnimation.presentDuration, remaining: startX, of: finalFrame.width)
            )
        }
        // Hand the animation to the render server now, so it starts on the
        // keypress rather than after the rest of this main-thread turn.
        CATransaction.flush()

        let finish = { [weak self] in
            guard let self, self.animationSequence == sequence else { return }
            panel.alphaValue = 1
            if let layer = panel.contentView?.layer {
                PanelAnimation.clearSlide(layer)
            }
        }
        if reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                panel.animator().alphaValue = 1
            }, completionHandler: { Task { @MainActor in finish() } })
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { finish() }
        }
    }

    func dismiss() {
        clickOutsideMonitor.stop()
        guard let panel, targetScreen() != nil, panel.isVisible else {
            panel?.orderOut(nil)
            return
        }
        animationSequence += 1
        let sequence = animationSequence

        let finish = { [weak self] in
            guard let self, self.animationSequence == sequence else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            if let layer = panel.contentView?.layer {
                PanelAnimation.clearSlide(layer)
            }
        }

        if PanelAnimation.prefersReducedMotion {
            // Fade out in place instead of sliding.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = PanelAnimation.reducedMotionFadeDuration
                panel.animator().alphaValue = 0
            }, completionHandler: { Task { @MainActor in finish() } })
            return
        }

        // Slide the content back off the right edge, fully opaque, from
        // wherever it is on screen (mid-present included), over the share
        // of the duration the remaining distance deserves.
        let width = panel.frame.width
        let startX = panel.contentView?.layer.map(PanelAnimation.currentOffset(of:)) ?? 0
        let duration = PanelAnimation.slide(
            panel,
            fromX: startX,
            toX: width,
            duration: PanelAnimation.duration(PanelAnimation.dismissDuration, remaining: width - startX, of: width)
        )
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { finish() }
    }

    /// Follows the user to another display with the same slide it opens
    /// with, never a jump into place.
    func repositionToActiveScreenIfNeeded() {
        guard let panel, panel.isVisible else { return }
        let pointerLocation = NSEvent.mouseLocation
        guard let target = NSScreen.screens.first(where: { NSMouseInRect(pointerLocation, $0.frame, false) }) else { return }
        guard let currentScreen = panel.screen, currentScreen.frame != target.frame else { return }
        // Arrive invisibly and settle before sliding in; see
        // `NoteEditorPanelController.repositionToActiveScreenIfNeeded`.
        animationSequence += 1
        let sequence = animationSequence
        panel.orderOut(nil)
        let finalFrame = paneFrame(for: target)
        panel.setFrame(finalFrame, display: false)
        PanelAnimation.hold(panel, atX: finalFrame.width)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelAnimation.displaySwitchSettle) { [weak self] in
            guard let self, self.animationSequence == sequence else { return }
            if !PanelAnimation.prefersReducedMotion {
                panel.alphaValue = 1
            }
            self.present()
        }
    }

    private func paneFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.visibleFrame.integral
        let paneWidth = PanelLayout.allNotesPaneWidth(forScreenWidth: screenFrame.width)
        return NSRect(
            x: screenFrame.maxX - paneWidth,
            y: screenFrame.minY,
            width: paneWidth,
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
