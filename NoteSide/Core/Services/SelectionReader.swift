import AppKit
import ApplicationServices

/// Reads the text currently selected in another app through the
/// Accessibility API. Native text views answer `AXSelectedText` on the
/// focused element; browsers answer it on the `AXWebArea`. Secure fields
/// return nothing, which is the behaviour we want.
///
/// Call off the main thread (AX blocks on IPC) and never for our own pid.
nonisolated struct SelectionReader: Sendable {
    static let maximumLength = 2_000

    private static let browserBundleIdentifiers = Set(BrowserURLProvider.supportedBrowsers.map(\.bundleIdentifier))

    func selectedText(in app: NSRunningApplication) -> String? {
        #if DEBUG
        if let injected = ProcessInfo.processInfo.environment["UITEST_SELECTION_TEXT"], !injected.isEmpty {
            return Self.normalized(injected)
        }
        #endif

        guard AXIsProcessTrusted(),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        if let focused = element(kAXFocusedUIElementAttribute, of: appElement),
           let text = string(kAXSelectedTextAttribute, of: focused), !text.isEmpty {
            return Self.normalized(text)
        }

        guard let bundleIdentifier = app.bundleIdentifier, Self.browserBundleIdentifiers.contains(bundleIdentifier) else {
            return nil
        }

        // WebKit exposes the selection on the web area.
        if let window = element(kAXFocusedWindowAttribute, of: appElement) ?? element(kAXMainWindowAttribute, of: appElement),
           let webArea = AXBrowserURLReader().findWebArea(in: window),
           let text = string(kAXSelectedTextAttribute, of: webArea), !text.isEmpty {
            return Self.normalized(text)
        }

        // Chromium reports no selected text through Accessibility at all,
        // so ask the browser to copy and read the pasteboard, then put the
        // previous clipboard back.
        return selectionViaCopy(pid: app.processIdentifier)
    }

    /// Posts ⌘C to `pid`, waits for the pasteboard to change (≤ 400 ms),
    /// reads the plain text, and restores what was on the clipboard before.
    /// Nothing selected → the pasteboard doesn't change → nil.
    private func selectionViaCopy(pid: pid_t) -> String? {
        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount
        let snapshot = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var payload: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { payload[type] = data }
            }
            return payload
        } ?? []

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 8
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)

        var changed = false
        for _ in 0..<20 {
            usleep(20_000)
            if pasteboard.changeCount != changeCountBefore { changed = true; break }
        }
        guard changed else { return nil }
        let text = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        if !snapshot.isEmpty {
            let items = snapshot.map { payload -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in payload { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
        return text.flatMap(Self.normalized)
    }

    /// Collapses whitespace runs and caps the length so a stray "select
    /// all" doesn't paste a whole page into the note.
    static func normalized(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > maximumLength {
            return String(collapsed.prefix(maximumLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return collapsed
    }

    private func element(_ attribute: String, of parent: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
