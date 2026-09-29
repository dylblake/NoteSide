import AppKit
import ApplicationServices
import Foundation

nonisolated struct ContextResolver: Sendable {
    private let browserURLProvider = BrowserURLProvider()
    private let supportedBrowserBundleIdentifiers = Set(
        BrowserURLProvider.supportedBrowsers.map(\.bundleIdentifier)
    )
    private static let scriptExecutor = AppleScriptExecutor.shared
    private let axBrowserURLReader = AXBrowserURLReader()
    private let slackBundleIdentifiers: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.tinyspeck.slackmacgap2"
    ]
    private let figmaBundleIdentifiers: Set<String> = [
        "com.figma.Desktop"
    ]
    private let xcodeBundleIdentifier = "com.apple.dt.Xcode"
    private let codeBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf"
    ]
    private let linearBundleIdentifier = "com.linear"
    private let itermBundleIdentifier = "com.googlecode.iterm2"
    private let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty"
    ]

    /// `sourceApp` is the app the note is for; nil means the frontmost
    /// app (context tracking follows whatever is in front).
    func resolveCurrentContext(for sourceApp: NSRunningApplication? = nil, allowBrowserAutomation: Bool = true) -> NoteContext {
        guard let app = sourceApp ?? NSWorkspace.shared.frontmostApplication else {
            return NoteContext(
                kind: .application,
                identifier: "unknown",
                displayName: "Unknown App",
                secondaryLabel: nil,
                navigationTarget: nil
            )
        }

        let bundleIdentifier = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? "Unknown App"

        // Never walk our own accessibility tree. This runs on a background
        // queue, and AppKit serves in-process AX queries synchronously on
        // that thread while the main thread may be answering an AX client
        // (VoiceOver, XCUITest) — the two deadlock on HIServices' lock.
        // Happens whenever a Remora window is frontmost with the drawer
        // open, e.g. pressing the hotkey from the first-run wizard.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return NoteContext(
                kind: .application,
                identifier: bundleIdentifier,
                displayName: appName,
                secondaryLabel: nil,
                navigationTarget: nil
            )
        }

        if bundleIdentifier == "com.apple.finder", let finderURL = currentFinderContextURL() {
            // Route Finder selections through fileContext(...) so they pick
            // up a stable inode-based fileSystemIdentifier. Without it, a
            // rename in Finder changes the NoteContext.id and the rename
            // detection in applyRefreshedContext treats it as a brand
            // new file instead of updating the existing note.
            let finderRootPath = isDirectory(finderURL)
                ? finderURL.path(percentEncoded: false)
                : finderURL.deletingLastPathComponent().path(percentEncoded: false)
            return fileContext(
                for: finderURL,
                sourceBundleIdentifier: bundleIdentifier,
                sourceRootPath: finderRootPath
            )
        }

        if supportedBrowserBundleIdentifiers.contains(bundleIdentifier) {
            return browserContext(
                for: app,
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                allowBrowserAutomation: allowBrowserAutomation
            )
        }

        if slackBundleIdentifiers.contains(bundleIdentifier),
           let slackContext = slackContext(for: app) {
            return slackContext
        }

        if figmaBundleIdentifiers.contains(bundleIdentifier),
           let figmaContext = figmaContext(for: app) {
            return figmaContext
        }

        if bundleIdentifier == linearBundleIdentifier,
           let linearContext = linearContext(for: app) {
            return linearContext
        }

        if terminalBundleIdentifiers.contains(bundleIdentifier) {
            return terminalContext(for: app, bundleIdentifier: bundleIdentifier, appName: appName)
        }

        if let editorDocumentURL = editorDocumentURL(for: app, bundleIdentifier: bundleIdentifier) {
            let rootURL = editorRootURL(for: app, bundleIdentifier: bundleIdentifier, fileURL: editorDocumentURL)
            return fileContext(
                for: editorDocumentURL,
                sourceBundleIdentifier: bundleIdentifier,
                sourceRootPath: rootURL?.path(percentEncoded: false)
            )
        }

        if let documentURL = focusedDocumentURL(for: app) {
            let rootURL = inferredProjectRoot(for: documentURL)
            return fileContext(
                for: documentURL,
                sourceBundleIdentifier: bundleIdentifier,
                sourceRootPath: rootURL?.path(percentEncoded: false)
            )
        }

        // Code editor with no resolvable document (unsaved buffer, welcome
        // tab, or no file focused): be explicit that the note attaches to
        // the app, not a file — otherwise the note silently fails to
        // follow the file the user thinks they're annotating.
        if bundleIdentifier == xcodeBundleIdentifier || codeBundleIdentifiers.contains(bundleIdentifier) {
            return NoteContext(
                kind: .application,
                identifier: bundleIdentifier,
                displayName: appName,
                secondaryLabel: "No saved file in focus — this note attaches to \(appName) itself.",
                navigationTarget: nil
            )
        }

        return NoteContext(
            kind: .application,
            identifier: bundleIdentifier,
            displayName: appName,
            secondaryLabel: bundleIdentifier,
            navigationTarget: nil
        )
    }

    /// Resolves the context for a supported browser. Prefers the
    /// Accessibility path (no Apple Events, no per-browser Automation
    /// prompt), falling back to AppleScript, and distinguishes "no
    /// active tab" (permission is fine, there's just nothing to attach
    /// to) from "Automation not granted" so users with access aren't
    /// told to grant it again.
    private func browserContext(
        for app: NSRunningApplication,
        bundleIdentifier: String,
        appName: String,
        allowBrowserAutomation: Bool
    ) -> NoteContext {
        if let url = axBrowserURLReader.activeURL(for: app) {
            return pageContext(for: url, sourceBundleIdentifier: bundleIdentifier)
        }

        if allowBrowserAutomation {
            let attempt = browserURLProvider.accessAttempt(
                bundleIdentifier: bundleIdentifier,
                activatesBrowser: false
            )

            switch attempt.result {
            case .success(_, let url):
                return pageContext(for: url, sourceBundleIdentifier: bundleIdentifier)
            case .noTab:
                return NoteContext(
                    kind: .application,
                    identifier: bundleIdentifier,
                    displayName: appName,
                    secondaryLabel: "No active tab — this note attaches to \(appName) itself.",
                    navigationTarget: nil
                )
            case .automationDenied, .unavailable, .notBrowser:
                break
            }
        }

        #if MAS_BUILD
        let grantHint = "Turn on Accessibility for Remora to attach notes per site."
        #else
        let grantHint = "Allow Automation access to attach notes per site."
        #endif
        return NoteContext(
            kind: .application,
            identifier: bundleIdentifier,
            displayName: "\(appName) (Browser URL Unavailable)",
            secondaryLabel: grantHint,
            navigationTarget: nil
        )
    }

    /// A local file open in a browser (a PDF dragged into Chrome) is a
    /// file, not a web page: it follows renames like any other file and
    /// shows its name rather than a `file://` URL.
    private func pageContext(for url: URL, sourceBundleIdentifier: String) -> NoteContext {
        if url.isFileURL {
            return fileContext(for: url, sourceBundleIdentifier: sourceBundleIdentifier)
        }
        return webPageContext(for: url, sourceBundleIdentifier: sourceBundleIdentifier)
    }

    /// Linear's desktop app is the web app in a shell, so its web area
    /// carries the same `linear.app` URL a browser would: notes taken in
    /// either place land on one issue. The note reopens through the
    /// `linear://` scheme, which the desktop app handles. Without the
    /// URL (AX tree not ready), the issue key in the window title
    /// (`ENG-123 Fix login`) still separates issues.
    private func linearContext(for app: NSRunningApplication) -> NoteContext? {
        if let url = axBrowserURLReader.activeURL(for: app),
           let host = url.host()?.lowercased(),
           host == "linear.app" || host.hasSuffix(".linear.app") {
            let context = webPageContext(for: url)
            let desktopTarget = context.navigationTarget.flatMap(LinearTitleParser.desktopURLString(forWebURL:))
            return NoteContext(
                kind: .url,
                identifier: context.identifier,
                displayName: context.displayName,
                secondaryLabel: context.secondaryLabel,
                navigationTarget: desktopTarget ?? context.navigationTarget
            )
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        enableElectronAccessibility(on: appElement)
        let windowTitle = axElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement)
            .flatMap { stringAttribute(kAXTitleAttribute as CFString, from: $0) }
        guard let windowTitle, let issueKey = LinearTitleParser.issueKey(in: windowTitle) else { return nil }

        return NoteContext(
            kind: .application,
            identifier: "linear:\(issueKey.lowercased())",
            displayName: "Linear / \(issueKey)",
            secondaryLabel: windowTitle,
            navigationTarget: nil
        )
    }

    /// Terminal notes attach to the project the shell is in — the
    /// enclosing repository when there is one, so `cd src` doesn't start
    /// a new note — and reopen as a new terminal window there. The
    /// working directory comes from the window's proxy document
    /// (Terminal.app, Ghostty), iTerm2's scripting `path` variable, or a
    /// path in the window title (most shells' default prompt title).
    private func terminalContext(
        for app: NSRunningApplication,
        bundleIdentifier: String,
        appName: String
    ) -> NoteContext {
        let documentDirectory = focusedDocumentURL(for: app)
            .flatMap { $0.isFileURL ? $0 : nil }
            .map { isDirectory($0) ? $0 : $0.deletingLastPathComponent() }
        let directory = documentDirectory
            ?? (bundleIdentifier == itermBundleIdentifier ? itermSessionDirectoryURL() : nil)
            ?? terminalTitleDirectoryURL(for: app)

        guard let directory, isDirectory(directory) else {
            return NoteContext(
                kind: .application,
                identifier: bundleIdentifier,
                displayName: appName,
                secondaryLabel: "No working directory detected — this note attaches to \(appName) itself.",
                navigationTarget: nil
            )
        }

        let resolved = directory.resolvingSymlinksInPath()
        return fileContext(
            for: terminalProjectRoot(for: resolved) ?? resolved,
            sourceBundleIdentifier: bundleIdentifier
        )
    }

    private func itermSessionDirectoryURL() -> URL? {
        let scriptSource = """
        tell application id "com.googlecode.iterm2"
            if (count of windows) is 0 then return ""
            tell current session of current window
                return variable named "path"
            end tell
        end tell
        """
        return executeFilePathScript(scriptSource, cacheKey: "iterm_session_path")
    }

    private func terminalTitleDirectoryURL(for app: NSRunningApplication) -> URL? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windowTitle = axElementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement)
            .flatMap { stringAttribute(kAXTitleAttribute as CFString, from: $0) }
        guard let windowTitle,
              let path = TerminalTitleParser.directoryPath(
                in: windowTitle,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
              ) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// Nearest enclosing directory with a project marker, stopping at the
    /// home folder: a dotfiles repo in `~` must not swallow every project
    /// beneath it. Nil when the directory isn't inside a project.
    private func terminalProjectRoot(for directory: URL) -> URL? {
        // `.path` (unlike path(percentEncoded:)) never ends in a slash.
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        var current = directory.standardizedFileURL
        while current.path != "/" {
            if containsProjectMarker(at: current) { return current }
            if current.path == home { return nil }
            current.deleteLastPathComponent()
        }
        return nil
    }

    /// `sourceBundleIdentifier` records the browser the page was captured
    /// in so the note reopens there rather than in the default browser.
    private func webPageContext(for url: URL, sourceBundleIdentifier: String? = nil) -> NoteContext {
        let host = normalizedHost(for: url)
        let navigationURL = URLCanonicalizer.navigationURL(for: url).absoluteString
        return NoteContext(
            kind: .url,
            identifier: pageIdentifier(for: url),
            displayName: host ?? displayName(for: url),
            secondaryLabel: navigationURL,
            navigationTarget: navigationURL,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
    }

    private func fileContext(
        for url: URL,
        sourceBundleIdentifier: String? = nil,
        sourceRootPath: String? = nil
    ) -> NoteContext {
        let resolvedPath = url.path(percentEncoded: false)
        return NoteContext(
            kind: .file,
            identifier: resolvedPath,
            displayName: fileDisplayName(for: url),
            secondaryLabel: fileSecondaryLabel(for: url),
            navigationTarget: nil,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceRootPath: sourceRootPath,
            fileSystemIdentifier: stableFileSystemIdentifier(for: url),
            fileBookmarkData: fileBookmarkData(for: url)
        )
    }

    private func currentFinderContextURL() -> URL? {
        // Address Finder by bundle id rather than name so the sandbox's
        // temporary-exception.apple-events list (which is keyed on bundle id)
        // matches the script target.
        let scriptSource = """
        tell application id "com.apple.finder"
            if selection is not {} then
                set selectedItem to item 1 of (get selection)
                return POSIX path of (selectedItem as alias)
            end if

            if (count of Finder windows) > 0 then
                return POSIX path of ((target of front Finder window) as alias)
            end if

            return POSIX path of (desktop as alias)
        end tell
        """

        let (resultDescriptor, error) = Self.scriptExecutor.executeSync(key: "finder", source: scriptSource)

        if error != nil {
            return nil
        }

        let path = resultDescriptor?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func slackContext(for app: NSRunningApplication) -> NoteContext? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        enableElectronAccessibility(on: appElement)
        let focusedWindow = axElementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: appElement
        )
        let focusedElement = axElementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: appElement
        )

        let windowTitle = focusedWindow.flatMap { stringAttribute(kAXTitleAttribute as CFString, from: $0) }
        let strings = slackCandidateStrings(
            focusedElement: focusedElement,
            focusedWindow: focusedWindow
        )

        let location = axBrowserURLReader.activeURL(for: app).flatMap(SlackClientURL.location(from:))
        let parsed = SlackTitleParser.parse(
            windowTitle: windowTitle,
            candidateStrings: strings,
            conversationOpen: location.map { $0.conversationID != nil }
        )
        let workspace = parsed.workspace
        let conversation = parsed.conversation

        guard conversation != nil || workspace != nil else { return nil }

        let identifier = SlackTitleParser.identifier(workspace: workspace, conversation: conversation)
        let displayName = SlackTitleParser.displayName(workspace: workspace, conversation: conversation)
        let secondaryLabel = [workspace, conversation]
            .compactMap { $0 }
            .joined(separator: " • ")
        // Identity stays name-based so existing notes keep matching; the
        // client URL only supplies the ids that let All Notes reopen the
        // conversation. Saving the note in Slack stores the link.
        let navigationTarget = location.map(SlackClientURL.deepLink(for:))

        return NoteContext(
            kind: .application,
            identifier: identifier,
            displayName: displayName,
            secondaryLabel: secondaryLabel.isEmpty ? nil : secondaryLabel,
            navigationTarget: navigationTarget
        )
    }

    private func fileDisplayName(for url: URL) -> String {
        let name = url.lastPathComponent
        if !name.isEmpty {
            return name
        }

        let path = url.path(percentEncoded: false)
        return path.isEmpty ? "/" : path
    }

    private func fileSecondaryLabel(for url: URL) -> String? {
        let path = url.path(percentEncoded: false)
        return path.isEmpty ? nil : path
    }

    private func figmaContext(for app: NSRunningApplication) -> NoteContext? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        enableElectronAccessibility(on: appElement)
        let focusedWindow = axElementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: appElement
        )
        let focusedElement = axElementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: appElement
        )

        let windowTitle = focusedWindow.flatMap { stringAttribute(kAXTitleAttribute as CFString, from: $0) }
        let strings = figmaCandidateStrings(
            focusedElement: focusedElement,
            focusedWindow: focusedWindow
        )
        let navigationTarget = figmaNavigationTarget(
            focusedElement: focusedElement,
            focusedWindow: focusedWindow,
            candidateStrings: strings
        )

        let parsed = FigmaTitleParser.parse(windowTitle: windowTitle, candidateStrings: strings)
        let fileName = parsed.fileName
        let pageName = parsed.pageName

        guard fileName != nil || pageName != nil else { return nil }

        let identifier = FigmaTitleParser.identifier(fileName: fileName, pageName: pageName)
        let displayName = FigmaTitleParser.displayName(fileName: fileName, pageName: pageName)
        let secondaryLabel = [fileName, pageName]
            .compactMap { $0 }
            .joined(separator: " • ")

        return NoteContext(
            kind: .application,
            identifier: identifier,
            displayName: displayName,
            secondaryLabel: secondaryLabel.isEmpty ? nil : secondaryLabel,
            navigationTarget: navigationTarget
        )
    }

    private func displayName(for url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        let path = url.path(percentEncoded: false)
        guard path != "/" && !path.isEmpty else { return host }
        return host + path
    }

    private func normalizedHost(for url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Stable identity for a web page: session/tracking parameters and
    /// renamed slugs must not split one page into several notes.
    private func pageIdentifier(for url: URL) -> String {
        URLCanonicalizer.canonicalIdentifier(for: url)
    }

    private func editorDocumentURL(for app: NSRunningApplication, bundleIdentifier: String) -> URL? {
        if bundleIdentifier == xcodeBundleIdentifier {
            return xcodeActiveSourceDocumentURL() ?? focusedDocumentURL(for: app)
        }

        if codeBundleIdentifiers.contains(bundleIdentifier) {
            return focusedDocumentURL(for: app)
        }

        return nil
    }

    private func editorRootURL(for app: NSRunningApplication, bundleIdentifier: String, fileURL: URL) -> URL? {
        if bundleIdentifier == xcodeBundleIdentifier {
            return xcodeWorkspaceDocumentURL() ?? inferredProjectRoot(for: fileURL)
        }

        if codeBundleIdentifiers.contains(bundleIdentifier) {
            // For VS Code, use inferredProjectRoot directly as it reliably detects
            // workspace roots by looking for .git, .vscode, package.json, etc.
            // The generic preferredWorkspaceRootURL can match incorrect directories
            // from the accessibility UI tree.
            return inferredProjectRoot(for: fileURL)
        }

        return inferredProjectRoot(for: fileURL)
    }

    private func xcodeActiveSourceDocumentURL() -> URL? {
        let scriptSource = """
        tell application id "com.apple.dt.Xcode"
            if not (exists front window) then return ""

            set windowTitle to name of front window
            set AppleScript's text item delimiters to " — "
            set titleParts to text items of windowTitle
            set AppleScript's text item delimiters to ""
            set activeDocumentName to item -1 of titleParts

            try
                set matchingSourcePaths to path of every source document whose name is activeDocumentName
                if (count of matchingSourcePaths) > 0 then return item 1 of matchingSourcePaths
            on error
            end try

            try
                set matchingDocumentPaths to path of every document whose name is activeDocumentName
                if (count of matchingDocumentPaths) > 0 then return item 1 of matchingDocumentPaths
            on error
            end try

            try
                return path of document of front window
            on error
                return ""
            end try
        end tell
        """

        return executeFilePathScript(scriptSource, cacheKey: "xcode_active_doc")
    }

    private func xcodeWorkspaceDocumentURL() -> URL? {
        let scriptSource = """
        tell application id "com.apple.dt.Xcode"
            if not (exists front window) then return ""
            try
                return path of document of front window
            on error
                return ""
            end try
        end tell
        """

        guard let url = executeFilePathScript(scriptSource, cacheKey: "xcode_workspace") else { return nil }
        if isDirectory(url) {
            return url
        }
        if ["xcodeproj", "xcworkspace"].contains(url.pathExtension.lowercased()) {
            return url
        }
        return url.deletingLastPathComponent()
    }

    private func focusedDocumentURL(for app: NSRunningApplication) -> URL? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        enableElectronAccessibility(on: appElement)

        if let focusedElement = copyAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: appElement
        ) as! AXUIElement?,
           let documentURL = preferredDocumentURL(startingAt: focusedElement) {
            return documentURL
        }

        var focusedWindowValue: CFTypeRef?
        let focusedWindowStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        guard
            focusedWindowStatus == .success,
            let focusedWindow = focusedWindowValue
        else {
            return nil
        }

        return preferredDocumentURL(startingAt: focusedWindow as! AXUIElement)
    }

    private func preferredDocumentURL(startingAt element: AXUIElement) -> URL? {
        let documentURLs = descendantDocumentURLs(startingAt: element) + ancestorDocumentURLs(startingAt: element)

        if let fileURL = documentURLs.first(where: \.isFileURL),
           !isDirectory(fileURL) {
            return fileURL
        }

        return documentURLs.first
    }

    private func ancestorValues<T>(startingAt element: AXUIElement, maxDepth: Int = 12, extract: (AXUIElement) -> T?) -> [T] {
        var current: AXUIElement? = element
        var results: [T] = []
        for _ in 0..<maxDepth {
            guard let el = current else { break }
            if let value = extract(el) { results.append(value) }
            current = copyAttribute(kAXParentAttribute as CFString, from: el) as! AXUIElement?
        }
        return results
    }

    private func descendantValues<T>(startingAt element: AXUIElement, maxNodes: Int = 256, extract: (AXUIElement) -> T?) -> [T] {
        var queue: [AXUIElement] = [element]
        var results: [T] = []
        var visited = Set<CFHashCode>()
        while !queue.isEmpty && visited.count < maxNodes {
            let current = queue.removeFirst()
            guard visited.insert(CFHash(current)).inserted else { continue }
            if let value = extract(current) { results.append(value) }
            if let children = copyAttribute(kAXChildrenAttribute as CFString, from: current) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return results
    }

    private func ancestorDocumentURLs(startingAt element: AXUIElement) -> [URL] {
        ancestorValues(startingAt: element, extract: documentURL(from:))
    }

    private func descendantDocumentURLs(startingAt element: AXUIElement) -> [URL] {
        descendantValues(startingAt: element, extract: documentURL(from:))
    }

    private func documentURL(from element: AXUIElement) -> URL? {
        guard
            let documentString = copyAttribute(
                kAXDocumentAttribute as CFString,
                from: element
            ) as? String,
            !documentString.isEmpty
        else {
            return nil
        }

        if let fileURL = URL(string: documentString), fileURL.isFileURL {
            return fileURL
        }

        return URL(fileURLWithPath: documentString)
    }

    private func documentString(from element: AXUIElement) -> String? {
        guard
            let documentString = copyAttribute(
                kAXDocumentAttribute as CFString,
                from: element
            ) as? String,
            !documentString.isEmpty
        else {
            return nil
        }

        return documentString
    }

    private func inferredProjectRoot(for fileURL: URL) -> URL? {
        guard fileURL.isFileURL else { return nil }

        var currentURL = isDirectory(fileURL) ? fileURL : fileURL.deletingLastPathComponent()

        while currentURL.path != "/" {
            if containsProjectMarker(at: currentURL) {
                return currentURL
            }
            currentURL.deleteLastPathComponent()
        }

        return fileURL.deletingLastPathComponent()
    }

    private static let projectRootMarkers: Set<String> = [
        ".git",
        ".hg",
        ".svn",
        "package.json",
        "pnpm-workspace.yaml",
        "yarn.lock",
        "Package.swift"
    ]

    private func containsProjectMarker(at directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else {
            return false
        }
        return contents.contains {
            Self.projectRootMarkers.contains($0)
                || $0.hasSuffix(".xcodeproj")
                || $0.hasSuffix(".xcworkspace")
                || $0.hasSuffix(".code-workspace")
        }
    }

    private func stableFileSystemIdentifier(for url: URL) -> String? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
            let fileResourceIdentifier = values.fileResourceIdentifier
        else {
            return nil
        }

        return String(describing: fileResourceIdentifier)
    }

    private func fileBookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func slackCandidateStrings(
        focusedElement: AXUIElement?,
        focusedWindow: AXUIElement?,
        includeHelp: Bool = true
    ) -> [String] {
        var queue: [AXUIElement] = []
        if let focusedElement {
            queue.append(focusedElement)
        }
        if let focusedWindow {
            queue.append(focusedWindow)
        }

        var results: [String] = []
        var visited = Set<CFHashCode>()

        while !queue.isEmpty && visited.count < 180 {
            let current = queue.removeFirst()
            let currentHash = CFHash(current)
            guard visited.insert(currentHash).inserted else { continue }

            if let title = stringAttribute(kAXTitleAttribute as CFString, from: current) {
                results.append(title)
            }
            if let value = stringAttribute(kAXValueAttribute as CFString, from: current) {
                results.append(value)
            }
            if let description = stringAttribute(kAXDescriptionAttribute as CFString, from: current) {
                results.append(description)
            }
            if includeHelp,
               let help = stringAttribute(kAXHelpAttribute as CFString, from: current) {
                results.append(help)
            }

            if let children = copyAttribute(kAXChildrenAttribute as CFString, from: current) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(24))
            }
            if let selectedChildren = copyAttribute(kAXSelectedChildrenAttribute as CFString, from: current) as? [AXUIElement] {
                queue.append(contentsOf: selectedChildren)
            }
        }

        return SlackTitleParser.deduplicate(results.map(SlackTitleParser.normalize))
    }

    private func figmaCandidateStrings(
        focusedElement: AXUIElement?,
        focusedWindow: AXUIElement?
    ) -> [String] {
        FigmaTitleParser.filterCandidates(
            slackCandidateStrings(
                focusedElement: focusedElement,
                focusedWindow: focusedWindow,
                includeHelp: false
            )
        )
    }

    private func figmaNavigationTarget(
        focusedElement: AXUIElement?,
        focusedWindow: AXUIElement?,
        candidateStrings: [String]
    ) -> String? {
        if let target = candidateStrings.compactMap(FigmaTitleParser.urlString(from:)).first {
            return target
        }

        let elements = [focusedElement, focusedWindow].compactMap { $0 }

        for element in elements {
            if let target = webDocumentString(startingAt: element) {
                return target
            }
        }

        return nil
    }

    private func webDocumentString(startingAt element: AXUIElement) -> String? {
        let documentStrings = descendantDocumentStrings(startingAt: element) + ancestorDocumentStrings(startingAt: element)
        return documentStrings.first { documentString in
            documentString.hasPrefix("https://") || documentString.hasPrefix("http://")
        }
    }

    private func ancestorDocumentStrings(startingAt element: AXUIElement) -> [String] {
        ancestorValues(startingAt: element, extract: documentString(from:))
    }

    private func descendantDocumentStrings(startingAt element: AXUIElement) -> [String] {
        descendantValues(startingAt: element, extract: documentString(from:))
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    private func axElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        copyAttribute(attribute, from: element).map { $0 as! AXUIElement }
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success else { return nil }
        return value
    }

    /// Wakes up the AX backend in Chromium/Electron-based apps (Slack, Figma,
    /// VSCode, etc.). Without this they keep their accessibility tree disabled
    /// and every AXUIElementCopyAttributeValue call returns kAXErrorCannotComplete
    /// (-25204). Setting either AXManualAccessibility (modern Chromium) or
    /// AXEnhancedUserInterface (older Electron / AppKit-style) on the
    /// application element forces them to materialize the tree.
    private func enableElectronAccessibility(on appElement: AXUIElement) {
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private func executeFilePathScript(_ scriptSource: String, cacheKey: String) -> URL? {
        let (resultDescriptor, error) = Self.scriptExecutor.executeSync(key: cacheKey, source: scriptSource)

        if error != nil {
            return nil
        }

        let path = resultDescriptor?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
