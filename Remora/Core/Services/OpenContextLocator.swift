import AppKit
import ApplicationServices
import Foundation

/// Finds a note's context already open somewhere — a browser tab, a
/// document or folder window — and brings it forward, so reopening a note
/// doesn't spawn a second tab or window for a page that's already there.
///
/// Two mechanisms, tried in order:
/// 1. Accessibility: walk each candidate app's windows and read the visible
///    page URL (`AXURL` of the web area) or document (`AXDocument`). Needs
///    only the Accessibility grant the app already has, and works in the
///    sandboxed build. Sees one tab per window — the visible one.
/// 2. Apple Events: enumerate every tab of a browser and select the match.
///    Only for browsers the caller says are already scriptable, so a click
///    never triggers a consent prompt; the App Store build passes none.
///
/// All AX and Apple Event round-trips run off the main thread.
nonisolated struct OpenContextLocator: Sendable {

    struct Request: Sendable {
        let context: NoteContext
        /// Resolved location for `.file` contexts. The caller keeps any
        /// security scope open for the duration of the call.
        let fileURL: URL?
        /// Browsers Remora may send Apple Events to without a TCC prompt.
        let scriptableBrowserBundleIDs: Set<String>
        /// Whether Finder may be scripted without a TCC prompt.
        let finderScriptable: Bool
    }

    struct TabLocation: Equatable, Sendable {
        let window: Int
        let tab: Int
        let url: String
    }

    /// What a window scan found. `container` is a window showing the
    /// context's parent (an Xcode workspace for a source file): worth
    /// raising, but the caller still has to open the file into it.
    enum WindowMatch: Sendable {
        case exact
        case container
        case none
    }

    static let finderBundleIdentifier = "com.apple.finder"

    /// True when the context was found and brought forward, so the caller
    /// must not open it again.
    func revealIfOpen(_ request: Request) async -> Bool {
        switch request.context.kind {
        case .application:
            // Deep links (slack://, linear://) already land in the running
            // app's existing window; plain app contexts just activate.
            return false
        case .url:
            return await revealURL(request)
        case .file:
            return await revealFile(request)
        }
    }

    // MARK: - Web pages

    private func revealURL(_ request: Request) async -> Bool {
        let identifier = request.context.identifier
        let browsers = Self.runningBrowsers(preferring: request.context.sourceBundleIdentifier)
        DebugTrace.log("locator url \(identifier) browsers=\(browsers.compactMap(\.bundleIdentifier)) scriptable=\(request.scriptableBrowserBundleIDs.sorted())")
        guard !browsers.isEmpty else { return false }

        // Pass 1: the visible tab of every window, through Accessibility.
        let reader = AXBrowserURLReader()
        for app in browsers {
            let match = await raiseWindow(of: app) { window in
                guard let webArea = reader.findWebArea(in: window, maxNodes: 400),
                      let url = Self.axURL(of: webArea) else { return .none }
                return URLCanonicalizer.canonicalIdentifier(for: url) == identifier ? .exact : .none
            }
            DebugTrace.log("locator ax \(app.bundleIdentifier ?? "?") -> \(match)")
            if match == .exact { return true }
        }

        // Pass 2: every tab, through Apple Events, where already permitted.
        let provider = BrowserURLProvider()
        for app in browsers {
            guard let bundleID = app.bundleIdentifier,
                  request.scriptableBrowserBundleIDs.contains(bundleID),
                  let descriptor = provider.descriptor(for: bundleID) else { continue }

            let (listing, listError) = await AppleScriptExecutor.shared.execute(
                key: "openContextLocator.tabs:\(bundleID)",
                source: Self.enumerateTabsScript(bundleID: bundleID)
            )
            guard listError == nil, let text = listing?.stringValue else {
                DebugTrace.log("locator tabs \(bundleID) error=\(listError.map { "\($0)" } ?? "nil")")
                continue
            }
            let tabs = Self.parseTabList(text)
            guard let hit = Self.matchingTab(in: tabs, identifier: identifier) else {
                DebugTrace.log("locator tabs \(bundleID) no match among \(tabs.count)")
                continue
            }
            DebugTrace.log("locator tabs \(bundleID) hit window \(hit.window) tab \(hit.tab)")

            let (_, selectError) = await AppleScriptExecutor.shared.execute(
                key: "openContextLocator.select:\(bundleID):\(hit.window):\(hit.tab)",
                source: Self.selectTabScript(
                    family: descriptor.scriptFamily,
                    bundleID: bundleID,
                    window: hit.window,
                    tab: hit.tab
                )
            )
            if selectError == nil {
                await Self.activate(app)
                return true
            }
            DebugTrace.log("locator select \(bundleID) error=\(selectError.map { "\($0)" } ?? "nil")")
        }
        return false
    }

    /// Running supported browsers, the one the note was captured in first.
    private static func runningBrowsers(preferring preferred: String?) -> [NSRunningApplication] {
        let running = BrowserURLProvider.supportedBrowsers.flatMap { browser in
            NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier)
        }
        guard let preferred else { return running }
        return running.filter { $0.bundleIdentifier == preferred }
            + running.filter { $0.bundleIdentifier != preferred }
    }

    // MARK: - Files and folders

    private func revealFile(_ request: Request) async -> Bool {
        guard let fileURL = request.fileURL,
              let bundleID = request.context.sourceBundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }

        let isFinder = bundleID == Self.finderBundleIdentifier
        let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        // Finder shows folders; a note on a file lives in its parent window.
        let target = isFinder && !isDirectory ? fileURL.deletingLastPathComponent() : fileURL
        let rootURL = request.context.sourceRootPath
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

        let match = await raiseWindow(of: app) { window in
            guard let document = Self.axString(kAXDocumentAttribute as String, of: window) else { return .none }
            if Self.documentMatches(document, fileURL: target) { return .exact }
            if let rootURL, Self.documentMatches(document, fileURL: rootURL) { return .container }
            return .none
        }
        DebugTrace.log("locator file \(target.path(percentEncoded: false)) in \(bundleID) ax -> \(match) finderScriptable=\(request.finderScriptable)")
        switch match {
        case .exact:
            return true
        case .container:
            // Raised the workspace; the caller opens the file into it.
            return false
        case .none:
            break
        }

        if isFinder, request.finderScriptable {
            let (result, error) = await AppleScriptExecutor.shared.execute(
                key: "openContextLocator.finder:\(target.path(percentEncoded: false))",
                source: Self.finderRevealScript(folderPath: target.path(percentEncoded: false))
            )
            DebugTrace.log("locator finder result=\(result?.stringValue ?? "nil") error=\(error.map { "\($0)" } ?? "nil")")
            return error == nil && result?.stringValue == "1"
        }
        return false
    }

    // MARK: - Accessibility

    /// Scans `app`'s windows on a background queue, raises the first exact
    /// match (or, failing that, the first container match), and activates
    /// the app. Elements never leave the queue; only the verdict does.
    private func raiseWindow(
        of app: NSRunningApplication,
        matching: @escaping @Sendable (AXUIElement) -> WindowMatch
    ) async -> WindowMatch {
        let pid = app.processIdentifier
        // Walking our own AX tree from a background queue deadlocks against
        // the main thread answering the query (see ContextResolver).
        guard AXIsProcessTrusted(), pid != ProcessInfo.processInfo.processIdentifier else { return .none }

        let match: WindowMatch = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let appElement = AXUIElementCreateApplication(pid)
                // Wake Chromium's lazily built AX tree; harmless elsewhere.
                AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement] else {
                    continuation.resume(returning: .none)
                    return
                }

                var container: AXUIElement?
                for window in windows {
                    switch matching(window) {
                    case .exact:
                        Self.raise(window)
                        continuation.resume(returning: .exact)
                        return
                    case .container:
                        if container == nil { container = window }
                    case .none:
                        continue
                    }
                }
                if let container {
                    Self.raise(container)
                    continuation.resume(returning: .container)
                } else {
                    continuation.resume(returning: .none)
                }
            }
        }

        if match != .none {
            await Self.activate(app)
        }
        return match
    }

    private static func raise(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Raising a window only reorders it within its app; the app itself
    /// still has to come forward. `activate()` can be refused when Remora
    /// isn't the active app (its panel is non-activating), so fall back to
    /// the workspace, which activates a running app without new windows.
    @MainActor
    private static func activate(_ app: NSRunningApplication) {
        if app.activate() { return }
        guard let appURL = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    static func axURL(of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    static func axString(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let string = value as? String, !string.isEmpty { return string }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    // MARK: - Pure helpers (unit-tested)

    /// One `window<TAB>tab<TAB>url` row per line, as the enumeration
    /// script emits. Malformed rows are skipped.
    static func parseTabList(_ text: String) -> [TabLocation] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let window = Int(parts[0]), let tab = Int(parts[1]) else { return nil }
            return TabLocation(
                window: window,
                tab: tab,
                url: String(parts[2]).trimmingCharacters(in: .whitespaces)
            )
        }
    }

    /// First tab whose URL is the same page as `identifier` once both are
    /// canonicalised (tracking parameters, `www.`, slugs).
    static func matchingTab(in tabs: [TabLocation], identifier: String) -> TabLocation? {
        tabs.first { tab in
            guard let url = URL(string: tab.url) else { return false }
            return URLCanonicalizer.canonicalIdentifier(for: url) == identifier
        }
    }

    /// `AXDocument` is a `file://` URL string in most apps and a bare path
    /// in a few; either way, compare resolved paths.
    static func documentMatches(_ documentString: String, fileURL: URL) -> Bool {
        let documentURL: URL
        if let url = URL(string: documentString), url.isFileURL {
            documentURL = url
        } else {
            documentURL = URL(fileURLWithPath: documentString)
        }
        return comparablePath(documentURL) == comparablePath(fileURL)
    }

    private static func comparablePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// Quotes a string for embedding in AppleScript source.
    static func appleScriptLiteral(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - AppleScript sources

    /// Safari, Chromium and Arc all expose `URL of tabs of window w`. Inside
    /// a browser `tell` block `tab` names the tab class, so the separator
    /// is spelled `character id 9` rather than the `tab` constant.
    static func enumerateTabsScript(bundleID: String) -> String {
        """
        set sep to character id 9
        set out to ""
        tell application id \(appleScriptLiteral(bundleID))
            set windowCount to count of windows
            repeat with w from 1 to windowCount
                try
                    set tabURLs to URL of tabs of window w
                    repeat with t from 1 to count of tabURLs
                        set u to item t of tabURLs
                        if u is missing value then set u to ""
                        set out to out & (w as text) & sep & (t as text) & sep & (u as text) & linefeed
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
    }

    /// Makes tab `tab` of window `window` current and brings that window
    /// to the front of its app. Each engine spells "current tab" its own way.
    static func selectTabScript(family: BrowserDescriptor.ScriptFamily, bundleID: String, window: Int, tab: Int) -> String {
        let app = appleScriptLiteral(bundleID)
        switch family {
        case .chromium:
            return """
            tell application id \(app)
                set active tab index of window \(window) to \(tab)
                set index of window \(window) to 1
                activate
            end tell
            """
        case .safari:
            return """
            tell application id \(app)
                set current tab of window \(window) to tab \(tab) of window \(window)
                set index of window \(window) to 1
                activate
            end tell
            """
        case .arc:
            return """
            tell application id \(app)
                tell window \(window)
                    tell tab \(tab) to select
                end tell
                try
                    set index of window \(window) to 1
                end try
                activate
            end tell
            """
        }
    }

    /// Brings forward the Finder window already showing `folderPath`.
    /// Returns "1" when one was found, "0" otherwise. Compares POSIX path
    /// strings (Finder gives folders a trailing slash), the same way
    /// `ContextResolver.currentFinderContextURL` reads a window's target.
    /// Windows are addressed by index: `target of item N of every Finder
    /// window` can't be coerced to an alias through the list reference.
    static func finderRevealScript(folderPath: String) -> String {
        var normalized = folderPath
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        normalized += "/"
        return """
        tell application id "com.apple.finder"
            set targetPath to \(appleScriptLiteral(normalized))
            repeat with i from 1 to (count of Finder windows)
                try
                    if (POSIX path of ((target of Finder window i) as alias)) is targetPath then
                        set index of Finder window i to 1
                        activate
                        return "1"
                    end if
                end try
            end repeat
            return "0"
        end tell
        """
    }
}
