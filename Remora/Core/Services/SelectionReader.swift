import AppKit
import ApplicationServices

/// Reads the text currently selected in another app. Accessibility first:
/// native text views answer `AXSelectedText` on the focused element, WebKit
/// on the `AXWebArea`. Where that has nothing — Chromium and Electron apps
/// never expose a selection, and plenty of native apps use text views or web
/// views that don't either — the app is asked to copy it (⌘C) and the
/// clipboard is put back. Secure fields yield nothing either way.
///
/// Call off the main thread (AX blocks on IPC) and never for our own pid.
nonisolated struct SelectionReader: Sendable {
    static let maximumLength = 2_000

    private static let browserBundleIdentifiers = Set(BrowserURLProvider.supportedBrowsers.map(\.bundleIdentifier))
    private static let chromiumBundleIdentifiers = Set(
        BrowserURLProvider.supportedBrowsers.filter { $0.scriptFamily == .chromium || $0.scriptFamily == .arc }.map(\.bundleIdentifier)
    )
    /// ⌘C in Finder copies the selected files, not text.
    private static let neverCopyFrom: Set<String> = ["com.apple.finder"]

    /// Chromium browsers and Electron apps (Slack, VS Code, Discord, Notion…)
    /// expose no selection through Accessibility, so they go straight to ⌘C
    /// rather than spend time on reads that always miss.
    static func readsThroughCopy(bundleIdentifier: String?, bundleURL: URL?) -> Bool {
        if let bundleIdentifier, chromiumBundleIdentifiers.contains(bundleIdentifier) { return true }
        guard let bundleURL else { return false }
        let electron = bundleURL.appending(path: "Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: electron.path)
    }

    /// `onHostDone` fires once the host app no longer needs to stay key: as
    /// soon as Accessibility has answered, or the host has handled the ⌘C
    /// (which it only honours while its window is key) — well before a copy
    /// of an empty selection times out.
    func selectedText(in app: NSRunningApplication, onHostDone: @Sendable () -> Void = {}) -> String? {
        #if DEBUG
        if let injected = ProcessInfo.processInfo.environment["UITEST_SELECTION_TEXT"], !injected.isEmpty {
            onHostDone()
            return Self.normalized(injected)
        }
        #endif

        guard AXIsProcessTrusted(),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            DebugTrace.log("selection: not trusted or own pid (trusted=\(AXIsProcessTrusted()))")
            onHostDone()
            return nil
        }

        if Self.readsThroughCopy(bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL) {
            return selectionViaCopy(pid: app.processIdentifier, onHostDone: onHostDone)
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        if let focused = element(kAXFocusedUIElementAttribute, of: appElement),
           let text = string(kAXSelectedTextAttribute, of: focused), !text.isEmpty {
            DebugTrace.log("selection: focused-element AX hit (\(text.count) chars)")
            onHostDone()
            return Self.normalized(text)
        }
        DebugTrace.log("selection: focused-element AX miss for \(app.bundleIdentifier ?? "?")")

        // WebKit exposes the selection on the web area.
        if let bundleIdentifier = app.bundleIdentifier, Self.browserBundleIdentifiers.contains(bundleIdentifier),
           let window = element(kAXFocusedWindowAttribute, of: appElement) ?? element(kAXMainWindowAttribute, of: appElement),
           let webArea = AXBrowserURLReader().findWebArea(in: window),
           let text = string(kAXSelectedTextAttribute, of: webArea), !text.isEmpty {
            onHostDone()
            return Self.normalized(text)
        }

        guard !Self.neverCopyFrom.contains(app.bundleIdentifier ?? "") else {
            onHostDone()
            return nil
        }
        return selectionViaCopy(pid: app.processIdentifier, onHostDone: onHostDone)
    }

    /// Posts ⌘C to `pid`, waits for the pasteboard to change (≤ 400 ms),
    /// reads the plain text, and restores what was on the clipboard before.
    /// Nothing selected → the pasteboard doesn't change → nil.
    private func selectionViaCopy(pid: pid_t, onHostDone: @Sendable () -> Void) -> String? {
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

        let changed = Self.waitForCopy(
            changed: { pasteboard.changeCount != changeCountBefore },
            wait: { usleep(5_000) },
            onHostDone: onHostDone
        )
        DebugTrace.log("selection: copy path changed=\(changed)")
        guard changed else { return nil }
        // Files (a file list, a Photos item) aren't a text selection.
        let copiedFiles = pasteboard.types?.contains(.fileURL) ?? false
        let text = copiedFiles ? nil : pasteboard.string(forType: .string)

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

    /// Polls for the copy to land, one `wait` (5 ms) at a time, for up to
    /// `maxPolls` (400 ms). `onHostDone` fires exactly once: when the copy
    /// lands, or after `hostPolls` (15 ms) — an idle browser handles the
    /// keystroke within a few ms, and the drawer should be key by its first
    /// frame (a non-key window draws its glass in the lighter inactive
    /// style). An empty selection never changes the pasteboard; the read
    /// keeps polling for a slow copy regardless.
    static func waitForCopy(
        changed: () -> Bool,
        wait: () -> Void,
        hostPolls: Int = 3,
        maxPolls: Int = 80,
        onHostDone: () -> Void
    ) -> Bool {
        var hostDone = false
        defer { if !hostDone { onHostDone() } }
        for poll in 1...maxPolls {
            wait()
            if changed() {
                hostDone = true
                onHostDone()
                return true
            }
            if poll == hostPolls {
                hostDone = true
                onHostDone()
            }
        }
        return false
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
