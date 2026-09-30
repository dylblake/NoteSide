import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class AllNotesPanelController {
    /// Where the list sits while it is on screen.
    enum Placement: Equatable {
        /// Alone, at the right edge of the pointer's display.
        case edge
        /// Beside the note drawer: tucked under its leading edge, in
        /// `frame` (see `PanelLayout.stackedAllNotesFrame`).
        case stacked(frame: NSRect)
    }

    enum DismissStyle {
        /// Back off the right edge of its own window: under the note when
        /// stacked.
        case slide
        /// Off the right edge of the display, for when the note beside it
        /// is leaving too. The window is first widened to the display's
        /// edge (the content keeps its place), so the list isn't cut off
        /// at the line the note's sheet no longer hides.
        case slideOffDisplay
    }

    private var panel: NoteEditorPanel?
    /// The SwiftUI root, sized by hand inside a plain container so the
    /// window can be widened for `slideOffDisplay` without a relayout.
    private var hostingView: NSView?
    private var animationSequence = 0
    private var placement: Placement = .edge
    private let clickOutsideMonitor = ClickOutsideMonitor()

    /// A click outside the panel on its display (see `ClickOutsideMonitor`).
    /// Only while the list is alone; beside the note, the note's monitor
    /// speaks for both.
    var onClickOutside: (() -> Void)?

    var window: NSWindow? { panel }

    /// The panel's frame while it is on screen.
    var visibleFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

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
        // A container holds the SwiftUI root at a size set here, not by
        // the window: `slideOffDisplay` widens the window under it.
        let container = NSView(frame: .zero)
        container.autoresizesSubviews = false
        let hostingView = hostingController.view
        hostingView.autoresizingMask = []
        container.addSubview(hostingView)
        panel.contentView = container
        self.hostingView = hostingView
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // One level under the note drawer, so beside it the list is always
        // the layer beneath: a click or a key change reorders windows
        // within a level, never across levels.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
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

    func present(placement: Placement = .edge) {
        guard let panel else { return }
        let finalFrame: NSRect
        switch placement {
        case .edge:
            guard let screen = targetScreen() else { return }
            finalFrame = paneFrame(for: screen)
        case .stacked(let frame):
            finalFrame = frame
        }
        self.placement = placement
        animationSequence += 1
        let sequence = animationSequence

        // A visible panel in this same frame means a dismiss is still in
        // flight: reverse it from where it is instead of restarting from
        // off-screen. (A different frame is a different place to open.)
        let isReversingDismiss = panel.isVisible && panel.frame == finalFrame
        let reduceMotion = PanelAnimation.prefersReducedMotion
        let layer = panel.contentView?.layer
        panel.setFrame(finalFrame, display: false)
        fitHostingView()

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
            // Beside the note that edge is under the note's sheet, so the
            // list emerges from beneath it. Lay it out and draw it before
            // it's shown, and pin it off-screen so ordering front can't
            // flash it; the slide starts below.
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
        if placement == .edge {
            clickOutsideMonitor.start(watching: panel) { [weak self] in self?.onClickOutside?() }
        } else {
            clickOutsideMonitor.stop()
        }
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
        PanelMotionTrace.mark("listPresent", panel: panel, label: PanelMotionTrace.listLabel)

        let finish = { [weak self] in
            guard let self, self.animationSequence == sequence else { return }
            panel.alphaValue = 1
            if let layer = panel.contentView?.layer {
                PanelAnimation.clearSlide(layer)
            }
            PanelMotionTrace.mark("listPresented", panel: panel, label: PanelMotionTrace.listLabel)
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

    /// Builds and draws the list once, invisibly, so its first real open
    /// (often beside a note that's already on screen) doesn't pay for
    /// SwiftUI's and the glass's first-time work. See the note drawer's
    /// `prewarm`. Never takes key status.
    func prewarm() {
        guard let panel, !panel.isVisible, let screen = targetScreen() else { return }
        panel.setFrame(paneFrame(for: screen), display: false)
        fitHostingView()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        CATransaction.flush()
        let sequence = animationSequence
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            panel.ignoresMouseEvents = false
            guard let self, self.animationSequence == sequence else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    func dismiss(style: DismissStyle = .slide) {
        clickOutsideMonitor.stop()
        guard let panel, panel.isVisible else {
            panel?.orderOut(nil)
            return
        }
        animationSequence += 1
        let sequence = animationSequence

        let finish = { [weak self] in
            guard let self, self.animationSequence == sequence else { return }
            panel.orderOut(nil)
            PanelMotionTrace.mark("listDismissed", panel: panel, label: PanelMotionTrace.listLabel)
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
            PanelMotionTrace.mark("listDismiss", panel: panel, label: PanelMotionTrace.listLabel)
            return
        }

        let startX = panel.contentView?.layer.map(PanelAnimation.currentOffset(of:)) ?? 0
        let width: CGFloat
        let duration: TimeInterval
        switch style {
        case .slide:
            // Slide the content back off the right edge, fully opaque, from
            // wherever it is on screen (mid-present included), over the
            // share of the duration the remaining distance deserves.
            width = panel.frame.width
            duration = PanelAnimation.duration(PanelAnimation.dismissDuration, remaining: width - startX, of: width)
        case .slideOffDisplay:
            // Widen the window to the display's edge (the content stays
            // where it is) and travel the whole way in the note's time:
            // the list has further to go, so it tucks under the note as
            // the two leave together.
            var frame = panel.frame
            let edge = panel.screen?.visibleFrame.integral.maxX ?? frame.maxX
            frame.size.width = max(frame.width, edge - frame.minX)
            panel.setFrame(frame, display: false)
            width = frame.width
            duration = PanelAnimation.dismissDuration
        }
        let travel = PanelAnimation.slide(panel, fromX: startX, toX: width, duration: duration)
        CATransaction.flush()
        PanelMotionTrace.mark("listDismiss", panel: panel, label: PanelMotionTrace.listLabel)
        DispatchQueue.main.asyncAfter(deadline: .now() + travel) { finish() }
    }

    /// The SwiftUI root fills the window's content area. Called whenever
    /// the window is given a frame to open in; not when it is widened to
    /// slide off the display.
    private func fitHostingView() {
        guard let panel, let contentView = panel.contentView, let hostingView else { return }
        hostingView.frame = contentView.bounds
    }

    /// Follows the user to another display with the same slide it opens
    /// with, never a jump into place. Only while the list is alone: beside
    /// the note it goes where the note goes (the note's move retracts it).
    func repositionToActiveScreenIfNeeded() {
        guard let panel, panel.isVisible, placement == .edge else { return }
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
        fitHostingView()
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
