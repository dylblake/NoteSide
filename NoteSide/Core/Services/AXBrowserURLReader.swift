import AppKit
import ApplicationServices

/// Reads the active page URL from a browser through the Accessibility
/// API: find the frontmost window's AXWebArea (a role, so this is
/// locale-independent) and read its AXURL attribute.
///
/// Both engine families expose this — WebKit (Safari) and Chromium
/// (Chrome, Edge, Brave, Arc, Vivaldi) — measured at 7–50ms per read.
/// Unlike the AppleScript path it needs no Apple Events: one system-wide
/// Accessibility grant replaces ten per-browser Automation prompts, and
/// it's the only browser-context mechanism available to a sandboxed
/// App Store build.
nonisolated struct AXBrowserURLReader: Sendable {

    /// Returns the frontmost page's URL, or nil when it can't be read
    /// (no Accessibility permission, no window, AX tree not yet
    /// populated, or an internal page like chrome://newtab). Callers
    /// fall back to Apple Events or app-level context.
    func activeURL(for app: NSRunningApplication) -> URL? {
        guard AXIsProcessTrusted() else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Wake Chromium's AX tree; harmless for WebKit.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        guard let window = element(kAXFocusedWindowAttribute as String, of: appElement)
            ?? element(kAXMainWindowAttribute as String, of: appElement) else {
            return nil
        }

        guard let webArea = findWebArea(in: window) else { return nil }

        guard let value = copyValue("AXURL", from: webArea) else { return nil }
        let url: URL?
        if let direct = value as? URL {
            url = direct
        } else if let string = value as? String {
            url = URL(string: string)
        } else {
            url = nil
        }

        // Only real web pages: internal pages (chrome://newtab,
        // favorites://) fall through to the caller's fallback handling.
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    /// Breadth-first search for the outermost AXWebArea. Iframes nest
    /// *inside* the main web area, so first-found is the page itself.
    /// Toolbar and menu subtrees can't contain it and are pruned.
    private func findWebArea(in root: AXUIElement, maxNodes: Int = 1500) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var visited = 0

        while !queue.isEmpty && visited < maxNodes {
            let current = queue.removeFirst()
            visited += 1

            let role = copyValue(kAXRoleAttribute as String, from: current) as? String
            if role == "AXWebArea" { return current }
            if role == "AXToolbar" || role == "AXMenuBar" { continue }

            if let children = copyValue(kAXChildrenAttribute as String, from: current) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }

    private func element(_ attribute: String, of parent: AXUIElement) -> AXUIElement? {
        guard let value = copyValue(attribute, from: parent) else { return nil }
        return (value as! AXUIElement)
    }

    private func copyValue(_ attribute: String, from element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
