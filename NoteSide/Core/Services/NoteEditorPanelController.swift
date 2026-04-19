import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class NoteEditorPanelController {
    private var panel: NoteEditorPanel?
    private var animationSequence = 0
    private var lastPresentedScreen: NSScreen?
    private var activeGhostWindows: [NSWindow] = []

    // Animation tuning. Longer durations + softer curves than the defaults
    // to make the slide-in feel deliberate and the slide-out less jumpy.
    // Present is slightly longer than dismiss because the eye reads "appear"
    // as the more meaningful event; dismiss can be slightly faster without
    // feeling rushed.
    private static let presentDuration: TimeInterval = 0.6
    private static let dismissDuration: TimeInterval = 0.45

    // Cubic-bezier curves chosen for smoothness:
    //  - smoothEaseOut: gentle decel — used for present (and the expand
    //    phase of reposition). Shape ≈ "ease out quint", starts moving fast
    //    and settles in.
    //  - smoothEaseIn:  mirror — used for dismiss (and the collapse phase
    //    of reposition) so it accelerates as the panel leaves the screen.
    private static let smoothEaseOut = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
    private static let smoothEaseIn = CAMediaTimingFunction(controlPoints: 0.7, 0.0, 0.84, 0.0)

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

    func present() {
        guard let panel, let screen = targetScreen(preferPanelScreen: false) else { return }
        finalizeInFlightTransition()
        animationSequence += 1
        let sequence = animationSequence
        lastPresentedScreen = screen
        let finalFrame = paneFrame(for: screen)

        // Start the panel as a collapsed sliver at the right edge of the
        // active screen, then expand leftward. This keeps the entire
        // animation within the active display — no bleed onto an
        // adjacent monitor.
        panel.setFrame(collapsedFrame(for: screen), display: false)
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

    /// Captures the panel's current visual state into an NSImage. Used by
    /// AppState to grab the *old* context snapshot before triggering a
    /// context refresh that re-renders the panel for the new screen.
    func captureCurrentSnapshot() -> NSImage? {
        guard let panel, panel.isVisible else { return nil }
        return makeSnapshot(of: panel)
    }

    /// If the panel is visible and the cursor is now on a different screen
    /// than the panel currently sits on, perform a parallel cross-screen
    /// transition. The real panel is hidden, pre-positioned on the new
    /// screen at its final expanded frame, then SwiftUI re-renders the
    /// editor at the new screen's pane width with the new context. Two
    /// ghost windows handle the visual animation — one collapsing on the
    /// old screen, one expanding on the new screen — both inside a single
    /// NSAnimationContext block. When the animation completes, the real
    /// panel just becomes visible: it's already at the correct size and
    /// position, so there's no teleport and no end-of-animation size pop.
    ///
    /// `oldContextSnapshot` is captured by AppState *before* it refreshes
    /// the editor context, so the collapsing ghost on the old screen shows
    /// the old screen's context. The expanding ghost on the new screen
    /// uses a fresh snapshot taken inside this method, after SwiftUI has
    /// re-rendered the panel at the new screen's pane width.
    func repositionToActiveScreenIfNeeded(oldContextSnapshot: NSImage? = nil) {
        guard let panel, panel.isVisible else { return }
        guard let target = targetScreen(preferPanelScreen: false) else { return }

        // If a previous cross-screen transition is still in flight (rapid
        // clicks between displays), finalize it before starting a new one.
        finalizeInFlightTransition()

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

        // Capture all frames up front, BEFORE any mutation moves the panel
        // off the old screen. After the cross-screen setFrame below,
        // panel.screen and panel.frame both refer to the new screen, and
        // the old-screen frames would be unreachable.
        let oldExpandedFrame = panel.frame
        let collapsedOnOld = collapsedFrame(for: currentScreen)
        let collapsedOnNew = collapsedFrame(for: target)
        let expandedOnNew = paneFrame(for: target)

        // The old-screen ghost uses the snapshot AppState captured before
        // the context refresh, so it shows the old context. If the caller
        // didn't supply one (e.g. someone calls reposition directly without
        // pre-capturing), fall back to a snapshot of the current panel —
        // still on the old screen with the new context, which is fine for
        // this fallback path.
        let oldImage = oldContextSnapshot ?? makeSnapshot(of: panel)

        // PRE-POSITION the real panel at its final destination on the new
        // screen, while invisible. This is the key simplification: by
        // moving the real panel to expandedOnNew first, the SwiftUI
        // hosting view re-lays out at the new screen's pane width, and
        // the snapshot we take after the next runloop tick will be at the
        // correct size. We also avoid any teleport at the end of the
        // animation — the real panel just becomes visible where the
        // ghostNew leaves off, pixel-for-pixel matched.
        //
        // We use setFrame(_:display:animate:) (the non-animated form), not
        // panel.animator().setFrame, so the cross-screen frame change goes
        // straight to the window server without touching the animator's
        // cached state. The animator's cross-screen weakness is sidestepped
        // because we never call animator() on the real panel during the
        // transition.
        panel.alphaValue = 0
        panel.setFrame(expandedOnNew, display: true, animate: false)

        // Defer one runloop tick so SwiftUI has time to re-render the
        // editor at the new pane width with the new context (which AppState
        // already set before calling us). Without this hop, the snapshot
        // below would still capture the old layout / old size.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.animationSequence == sequence else { return }
            guard let panel = self.panel, panel.isVisible else { return }

            // Now the real panel is at the new screen at the new pane
            // width with the new context fully rendered. Snapshot it.
            let newImage = self.makeSnapshot(of: panel)

            guard let oldImage, let newImage else {
                // Snapshot failed entirely. The real panel is already at
                // its final position — just unhide it and we're done.
                panel.alphaValue = 1
                panel.orderFrontRegardless()
                return
            }

            // Old-screen ghost: at the panel's previous expanded frame,
            // showing the old context, fully visible. To the user this
            // looks like the real panel still sitting on the old screen.
            let ghostOld = self.makeGhostWindow(image: oldImage, frame: oldExpandedFrame)
            ghostOld.alphaValue = 1

            // New-screen ghost: at the collapsed sliver on the right edge
            // of the new screen, transparent, ready to expand in. Its
            // image is rendered at the new screen's pane width, so its
            // final frame and content match the real panel exactly.
            let ghostNew = self.makeGhostWindow(image: newImage, frame: collapsedOnNew)
            ghostNew.alphaValue = 0

            ghostOld.orderFrontRegardless()
            ghostNew.orderFrontRegardless()
            self.activeGhostWindows = [ghostOld, ghostNew]

            // Animate both ghosts in a single NSAnimationContext block so
            // they share one clock and visually move in lockstep.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.presentDuration
                context.timingFunction = Self.smoothEaseOut
                context.allowsImplicitAnimation = true

                ghostOld.animator().setFrame(collapsedOnOld, display: true)
                ghostOld.animator().alphaValue = 0

                ghostNew.animator().setFrame(expandedOnNew, display: true)
                ghostNew.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    // Always tear down both of THIS transition's ghosts.
                    // If a newer reposition has already taken over, the
                    // cleanup of its ghosts is its own responsibility, but
                    // ours stay ours.
                    ghostOld.orderOut(nil)
                    ghostNew.orderOut(nil)

                    guard let self else { return }
                    self.activeGhostWindows.removeAll { $0 === ghostOld || $0 === ghostNew }

                    // If a newer transition started, don't unhide the real
                    // panel — it now belongs to that transition.
                    guard self.animationSequence == sequence else { return }
                    guard let panel = self.panel else { return }

                    // The real panel has been at expandedOnNew on the new
                    // screen since the start of the transition. Just
                    // unhide it. No teleport, no resize, no pop — the
                    // pixels under the ghost are identical to the pixels
                    // about to appear from the real panel.
                    panel.alphaValue = 1
                    panel.orderFrontRegardless()
                }
            })
        }
    }

    /// Cleans up an in-progress cross-screen transition so the next one
    /// can start from a stable visual state. Tears down any ghost windows
    /// from the previous reposition, restores the real panel to its
    /// expected expanded frame on whichever screen it currently lives on,
    /// and bumps `animationSequence` so chained completion handlers from
    /// the old transition bail out.
    private func finalizeInFlightTransition() {
        guard !activeGhostWindows.isEmpty else { return }

        for ghost in activeGhostWindows {
            ghost.orderOut(nil)
        }
        activeGhostWindows.removeAll()

        if let panel, panel.isVisible, let panelScreen = panel.screen {
            panel.setFrame(paneFrame(for: panelScreen), display: true, animate: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        animationSequence += 1
    }

    /// Captures the panel's current visible content into an NSImage. Renders
    /// the contentView's layer into a bitmap so we don't need Screen Recording
    /// permission (this is rendering our own view, not reading the framebuffer).
    private func makeSnapshot(of window: NSWindow) -> NSImage? {
        guard let contentView = window.contentView else { return nil }
        let bounds = contentView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // Layer-backed contentView (we set wantsLayer = true in install) —
        // render its layer hierarchy into a CGContext.
        if let layer = contentView.layer {
            let scale = window.backingScaleFactor
            let pixelWidth = Int(bounds.width * scale)
            let pixelHeight = Int(bounds.height * scale)
            guard pixelWidth > 0, pixelHeight > 0 else { return nil }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

            guard let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }

            // Flip the coordinate system so layer.render(in:) draws
            // right-side-up. CGContext's default origin is bottom-left
            // (Quartz), but CALayer.render expects top-left (CoreAnimation),
            // so without this the resulting bitmap is upside-down and the
            // ghost windows show a vertically-mirrored panel mid-animation.
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: scale, y: -scale)

            layer.render(in: context)

            guard let cgImage = context.makeImage() else { return nil }
            return NSImage(cgImage: cgImage, size: bounds.size)
        }

        // Fallback for non-layer-backed views: standard cacheDisplay.
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        contentView.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Builds a borderless transparent window that displays a static snapshot
    /// of the panel. Used as a "ghost" during cross-screen transitions so
    /// each screen has something to animate while the real panel stays
    /// hidden. The image is right-aligned and unscaled so that when the
    /// window's width animates, the snapshot is *revealed* / *clipped* from
    /// the right edge instead of being stretched horizontally.
    private func makeGhostWindow(image: NSImage, frame: NSRect) -> NSWindow {
        let ghost = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.hasShadow = false
        ghost.level = .statusBar
        ghost.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ghost.ignoresMouseEvents = true
        ghost.isReleasedWhenClosed = false

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.image = image
        // No scaling — keep the snapshot at its natural size and let the
        // imageView's bounds (and layer mask) clip to whatever width the
        // window currently is. Anchored to the right edge so as the window
        // grows, the snapshot is revealed leftward from the screen edge.
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignRight
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        ghost.contentView = imageView

        return ghost
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
        finalizeInFlightTransition()
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
    /// non-AX app, no focused window, missing position/size attributes) or
    /// if the frontmost app is one whose AX-reported window is unreliable
    /// for screen detection (Finder, see below).
    private func frontmostAppFocusedWindowScreen() -> NSScreen? {
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
