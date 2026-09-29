import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class NoteEditorPanelController {
    private var panel: NoteEditorPanel?
    private var animationSequence = 0
    private var lastPresentedScreen: NSScreen?
    private let clickOutsideMonitor = ClickOutsideMonitor()

    /// Called when the user clicks outside the drawer on the same display
    /// (a click on another display means "follow me", handled by
    /// `repositionToActiveScreenIfNeeded`).
    var onClickOutside: (() -> Void)?

    func install(appState: AppState) {
        let rootView = FloatingNoteEditorView()
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

        // Clip the hosting layer so SwiftUI content transitions can never
        // bleed past the panel frame onto an adjacent display when the panel
        // is anchored to a screen edge.
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.masksToBounds = true
        }

        self.panel = panel
    }

    /// `makeKey: false` is the rare slow path: a Chromium selection read is
    /// still in flight and needs the host window to stay key; the caller
    /// calls `makeKeyIfVisible()` when it lands.
    func present(makeKey: Bool = true) {
        guard let panel, let screen = targetScreen(preferPanelScreen: false) else { return }
        animationSequence += 1
        let sequence = animationSequence
        lastPresentedScreen = screen
        let finalFrame = paneFrame(for: screen)

        // A visible panel on this screen means a dismiss is still in flight:
        // reverse it from where it is instead of restarting from off-screen.
        let isReversingDismiss = panel.isVisible && panel.alphaValue > 0 && panel.screen?.frame == screen.frame
        panel.ignoresMouseEvents = false
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
        if makeKey {
            panel.makeKey()
        }
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
        PanelMotionTrace.mark("present", panel: panel)

        let finish = { [weak self] in
            guard let self, self.animationSequence == sequence else { return }
            panel.alphaValue = 1
            if let layer = panel.contentView?.layer {
                PanelAnimation.clearSlide(layer)
            }
            PanelMotionTrace.mark("presented", panel: panel)
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

    /// Lays the drawer out and puts it on screen for a moment, fully
    /// transparent and click-through, so SwiftUI, the glass and the window
    /// server have all done their first-time work before the first open.
    /// Never takes key status.
    func prewarm() {
        guard let panel, !panel.isVisible, let screen = targetScreen(preferPanelScreen: false) else { return }
        panel.setFrame(paneFrame(for: screen), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        CATransaction.flush()
        let sequence = animationSequence
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.animationSequence == sequence else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
        }
    }

    func makeKeyIfVisible() {
        guard let panel, panel.isVisible else { return }
        panel.makeKey()
    }

    /// Hands key status back to the host app so it will honour a posted
    /// ⌘C; the drawer stays on screen (it never activates NoteSide).
    func yieldKey(to app: NSRunningApplication?) {
        guard let app, panel?.isKeyWindow == true else { return }
        app.activate()
    }

    /// Follows the user to another display: the drawer leaves the old one
    /// and slides in on the new one exactly as it opens — the same slide and
    /// timing, never a jump into place. (Snapshot "ghost" windows can't
    /// carry Liquid Glass, which is drawn from what's behind the window.)
    func repositionToActiveScreenIfNeeded() {
        guard let panel, panel.isVisible,
              let target = targetScreen(preferPanelScreen: false),
              let current = panel.screen,
              // NSScreen instances aren't reference-stable; compare frames.
              current.frame != target.frame else { return }
        PanelMotionTrace.mark("move", panel: panel)
        let wasKey = panel.isKeyWindow
        animationSequence += 1
        let sequence = animationSequence

        // A window that has just changed displays shows its settled content,
        // not its layer animations, for its first ~200 ms there (measured;
        // nothing signals the end), so a slide started straight away is
        // over before it's seen — the drawer jumps into place. Put it on the
        // new display invisibly, held off-screen, let it settle, then slide.
        panel.orderOut(nil)
        let finalFrame = paneFrame(for: target)
        panel.setFrame(finalFrame, display: false)
        PanelAnimation.hold(panel, atX: finalFrame.width)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelAnimation.displaySwitchSettle) { [weak self] in
            guard let self, self.animationSequence == sequence else { return }
            // Held at full offset on this display, so `present` slides it in
            // from there (under Reduce Motion it fades in from transparent).
            if !PanelAnimation.prefersReducedMotion {
                panel.alphaValue = 1
            }
            self.present(makeKey: wasKey)
        }
    }

    #if DEBUG
    /// UI-test hook: makes the other display the target, as if the user had
    /// switched to an app there, and follows.
    func moveToOtherScreenForTesting() {
        guard let current = panel?.screen,
              let other = NSScreen.screens.first(where: { $0.frame != current.frame }) else { return }
        screenOverrideForTesting = other
        repositionToActiveScreenIfNeeded()
    }

    private var screenOverrideForTesting: NSScreen?
    #endif

    private func paneFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.visibleFrame.integral
        let paneWidth = PanelLayout.editorPaneWidth(forScreenWidth: screenFrame.width)
        return NSRect(
            x: screenFrame.maxX - paneWidth,
            y: screenFrame.minY,
            width: paneWidth,
            height: screenFrame.height
        )
    }

    func dismiss() {
        clickOutsideMonitor.stop()
        guard let panel, targetScreen(preferPanelScreen: true) != nil, panel.isVisible else {
            panel?.orderOut(nil)
            return
        }
        animationSequence += 1
        let sequence = animationSequence

        let finish = { [weak self] in
            guard let self, self.animationSequence == sequence else { return }
            panel.orderOut(nil)
            PanelMotionTrace.mark("dismissed", panel: panel)
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
            PanelMotionTrace.mark("dismiss", panel: panel)
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
        // Commit now: callers save synchronously right after this, and the
        // slide should run in the render server while they do.
        CATransaction.flush()
        PanelMotionTrace.mark("dismiss", panel: panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { finish() }
    }

    private func targetScreen(preferPanelScreen: Bool) -> NSScreen? {
        #if DEBUG
        if let screenOverrideForTesting { return screenOverrideForTesting }
        #endif
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
    /// non-AX app, no focused window, missing position/size attributes) or
    /// if the frontmost app is one whose AX-reported window is unreliable
    /// for screen detection (Finder, see below).
    private func frontmostAppFocusedWindowScreen() -> NSScreen? {
        // Cross-process AX queries below block on IPC when the app isn't
        // trusted — indefinitely under the App Sandbox — and this runs on
        // the main thread during panel repositioning. Bail before any AX
        // call if we're untrusted; the caller falls back to cursor location.
        guard AXIsProcessTrusted() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        // Finder owns the desktop, which is exposed via AX as a window that
        // spans every display. Its center lands somewhere in the middle of
        // the workspace and doesn't reflect which screen the user is
        // actually looking at, so a click on Finder/the desktop on screen 2
        // would otherwise route the panel to screen 1. Skip AX entirely for
        // Finder and let the caller fall back to cursor location, which
        // correctly reflects the click.
        if app.bundleIdentifier == "com.apple.finder" {
            return nil
        }

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
