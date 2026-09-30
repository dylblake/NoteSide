import AppKit
import ApplicationServices
import CoreGraphics

/// Which window is under the pointer, and where the app in front has its
/// window, from one snapshot of the window server's on-screen list. The
/// list needs no permission and carries bounds, owner and layer; it
/// covers only the current Space, so nothing in another Space is ever
/// brought forward. Coordinates are the window server's: global, origin
/// at the top-left of the primary display, y down.
nonisolated enum PointerWindowLocator {
    struct Window: Equatable {
        let ownerPID: pid_t
        let layer: Int
        let bounds: CGRect
        let alpha: Double
    }

    struct Decision: Equatable {
        /// The app in front's first ordinary window, if it has one on screen.
        let frontmostWindow: Window?
        /// The topmost ordinary window under the pointer that belongs to
        /// another app.
        let windowUnderPointer: Window?
    }

    /// Anything smaller is a tooltip, a badge or a helper, not somewhere
    /// the user is working.
    private static let smallestUsefulSize = CGSize(width: 120, height: 60)

    static func onScreenWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsValue = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsValue) else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            return Window(ownerPID: pid, layer: layer, bounds: bounds, alpha: alpha)
        }
    }

    /// `windows` in the window server's order, front to back.
    static func decide(windows: [Window], pointer: CGPoint, frontmostPID: pid_t?, ownPID: pid_t) -> Decision {
        let ordinary = windows.filter { window in
            window.layer == 0
                && window.alpha > 0.01
                && window.ownerPID != ownPID
                && window.bounds.width >= smallestUsefulSize.width
                && window.bounds.height >= smallestUsefulSize.height
        }
        let frontmostWindow = frontmostPID.flatMap { pid in ordinary.first { $0.ownerPID == pid } }
        let underPointer = ordinary.first { $0.bounds.contains(pointer) }
        return Decision(frontmostWindow: frontmostWindow, windowUnderPointer: underPointer)
    }

    /// The pointer, in the same coordinates as the window list.
    static func pointerLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    /// The display holding a point given in window-server coordinates.
    @MainActor
    static func screen(containing point: CGPoint) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = NSPoint(x: point.x, y: primaryHeight - point.y)
        return NSScreen.screens.first { NSMouseInRect(cocoaPoint, $0.frame, false) }
    }

    /// Brings `window` to the front of its app and makes it the app's main
    /// window, through Accessibility. Blocks on the app for at most a
    /// quarter of a second per call, so it never runs on the main thread.
    /// Returns false when the window couldn't be matched or the app
    /// didn't answer.
    static func raise(_ window: Window) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.25)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let axWindows = windowsValue as? [AXUIElement] else { return false }

        for axWindow in axWindows {
            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
                  AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
                  let positionValue, let sizeValue else { continue }
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { continue }
            let frame = CGRect(origin: position, size: size)
            guard abs(frame.minX - window.bounds.minX) <= 2, abs(frame.minY - window.bounds.minY) <= 2,
                  abs(frame.width - window.bounds.width) <= 2, abs(frame.height - window.bounds.height) <= 2 else { continue }

            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            return AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) == .success
        }
        return false
    }

    /// Makes `app` the active app. `activate()` can be refused while
    /// Remora isn't active (its panels don't activate it); Accessibility's
    /// frontmost attribute is the fallback, and unlike opening the app
    /// through the workspace it brings no other windows forward.
    @MainActor
    static func activate(_ app: NSRunningApplication) {
        if app.activate() { return }
        guard AXIsProcessTrusted() else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}
