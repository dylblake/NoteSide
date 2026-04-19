import AppKit
import ApplicationServices
import Foundation

nonisolated struct ContextResolver: Sendable {
    private let browserURLProvider = BrowserURLProvider()
    private let supportedBrowserBundleIdentifiers = Set(
        BrowserURLProvider.supportedBrowsers.map(\.bundleIdentifier)
    )
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
        "com.visualstudio.code.oss"
    ]

    func resolveCurrentContext(allowBrowserAutomation: Bool = true) -> NoteContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
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

        if bundleIdentifier == "com.apple.finder", let finderURL = currentFinderContextURL() {
            // Route Finder selections through fileContext(...) so they pick
            // up a stable inode-based fileSystemIdentifier. Without it, a
            // rename in Finder changes the NoteContext.id and the rename
            // detection in refreshEditorContextIfNeeded treats it as a brand
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

        if allowBrowserAutomation,
           let url = browserURLProvider.activeURL(bundleIdentifier: bundleIdentifier) {
            let host = normalizedHost(for: url)
            return NoteContext(
                kind: .url,
                identifier: pageIdentifier(for: url),
                displayName: host ?? displayName(for: url),
                secondaryLabel: url.absoluteString,
                navigationTarget: url.absoluteString
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

        if supportedBrowserBundleIdentifiers.contains(bundleIdentifier) {
            return NoteContext(
                kind: .application,
                identifier: bundleIdentifier,
                displayName: "\(appName) (Browser URL Unavailable)",
                secondaryLabel: "Allow Automation access to attach notes per site.",
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

        guard let script = NSAppleScript(source: scriptSource) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)

        if error != nil {
            return nil
        }

        let path = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

        let conversation = slackConversationName(
            windowTitle: windowTitle,
            candidateStrings: strings
        )
        let workspace = slackWorkspaceName(
            windowTitle: windowTitle,
            candidateStrings: strings,
            conversation: conversation
        )

        guard conversation != nil || workspace != nil else { return nil }

        let identifier = slackIdentifier(workspace: workspace, conversation: conversation)
        let displayName = slackDisplayName(workspace: workspace, conversation: conversation)
        let secondaryLabel = [workspace, conversation]
            .compactMap { $0 }
            .joined(separator: " • ")

        return NoteContext(
            kind: .application,
            identifier: identifier,
            displayName: displayName,
            secondaryLabel: secondaryLabel.isEmpty ? nil : secondaryLabel,
            navigationTarget: nil
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

        let fileName = figmaFileName(windowTitle: windowTitle, candidateStrings: strings)
        let pageName = figmaPageName(windowTitle: windowTitle, candidateStrings: strings, fileName: fileName)

        guard fileName != nil || pageName != nil else { return nil }

        let identifier = figmaIdentifier(fileName: fileName, pageName: pageName)
        let displayName = figmaDisplayName(fileName: fileName, pageName: pageName)
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

    private func pageIdentifier(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = normalizedHost(for: url)
        components.fragment = nil

        let path = components.percentEncodedPath
        components.percentEncodedPath = path.isEmpty ? "/" : path

        return components.string ?? url.absoluteString
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

        return executeFilePathScript(scriptSource)
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

        guard let url = executeFilePathScript(scriptSource) else { return nil }
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

        guard let focusedWindow = axElementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: appElement
        ) else {
            return nil
        }

        return preferredDocumentURL(startingAt: focusedWindow)
    }

    private func preferredWorkspaceRootURL(for app: NSRunningApplication) -> URL? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        enableElectronAccessibility(on: appElement)
        var candidateURLs: [URL] = []

        if let focusedElement = copyAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: appElement
        ) as! AXUIElement? {
            candidateURLs.append(contentsOf: descendantDocumentURLs(startingAt: focusedElement))
            candidateURLs.append(contentsOf: ancestorDocumentURLs(startingAt: focusedElement))
        }

        if let focusedWindow = copyAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: appElement
        ) as! AXUIElement? {
            candidateURLs.append(contentsOf: descendantDocumentURLs(startingAt: focusedWindow))
            candidateURLs.append(contentsOf: ancestorDocumentURLs(startingAt: focusedWindow))
        }

        if let directRoot = candidateURLs.first(where: { isWorkspaceRootCandidate($0) }) {
            return normalizedWorkspaceRoot(from: directRoot)
        }

        return nil
    }

    private func preferredDocumentURL(startingAt element: AXUIElement) -> URL? {
        let documentURLs = descendantDocumentURLs(startingAt: element) + ancestorDocumentURLs(startingAt: element)

        if let fileURL = documentURLs.first(where: \.isFileURL),
           !isDirectory(fileURL) {
            return fileURL
        }

        return documentURLs.first
    }

    private func ancestorDocumentURLs(startingAt element: AXUIElement) -> [URL] {
        var currentElement: AXUIElement? = element
        var urls: [URL] = []

        for _ in 0..<12 {
            guard let unwrappedElement = currentElement else { break }

            if let documentURL = documentURL(from: unwrappedElement) {
                urls.append(documentURL)
            }

            currentElement = copyAttribute(
                kAXParentAttribute as CFString,
                from: unwrappedElement
            ) as! AXUIElement?
        }

        return urls
    }

    private func descendantDocumentURLs(startingAt element: AXUIElement) -> [URL] {
        var queue: [AXUIElement] = [element]
        var urls: [URL] = []
        var visited = Set<CFHashCode>()

        while !queue.isEmpty && visited.count < 256 {
            let current = queue.removeFirst()
            let currentHash = CFHash(current)
            guard visited.insert(currentHash).inserted else { continue }

            if let documentURL = documentURL(from: current) {
                urls.append(documentURL)
            }

            if let children = copyAttribute(kAXChildrenAttribute as CFString, from: current) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }

        return urls
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
        let fileManager = FileManager.default
        let rootMarkers = [
            ".git",
            ".hg",
            ".svn",
            "package.json",
            "pnpm-workspace.yaml",
            "yarn.lock",
            "Package.swift"
        ]

        while currentURL.path != "/" {
            if let contents = try? fileManager.contentsOfDirectory(atPath: currentURL.path(percentEncoded: false)) {
                if contents.contains(where: { rootMarkers.contains($0) || $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".code-workspace") }) {
                    return currentURL
                }
            }
            currentURL.deleteLastPathComponent()
        }

        return fileURL.deletingLastPathComponent()
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

    private func isWorkspaceRootCandidate(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if isDirectory(url) {
            return true
        }

        let ext = url.pathExtension.lowercased()
        return ["xcworkspace", "xcodeproj", "code-workspace"].contains(ext)
    }

    private func normalizedWorkspaceRoot(from url: URL) -> URL {
        let ext = url.pathExtension.lowercased()
        if ["xcworkspace", "xcodeproj", "code-workspace"].contains(ext) {
            return url
        }
        return isDirectory(url) ? url : url.deletingLastPathComponent()
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

        return deduplicatedStrings(results.map(slackNormalizedString))
    }

    private func figmaCandidateStrings(
        focusedElement: AXUIElement?,
        focusedWindow: AXUIElement?
    ) -> [String] {
        deduplicatedStrings(
            slackCandidateStrings(
                focusedElement: focusedElement,
                focusedWindow: focusedWindow,
                includeHelp: false
            )
            .filter {
                let lowercased = $0.lowercased()
                return !figmaIgnoredTokens.contains(lowercased)
                    && !looksLikeAccessibilityHint($0)
            }
        )
    }

    private func figmaNavigationTarget(
        focusedElement: AXUIElement?,
        focusedWindow: AXUIElement?,
        candidateStrings: [String]
    ) -> String? {
        if let target = candidateStrings.compactMap(figmaURLString(from:)).first {
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

    private func slackConversationName(windowTitle: String?, candidateStrings: [String]) -> String? {
        if let windowTitle,
           let parsedConversation = slackConversationFromWindowTitle(windowTitle) {
            return parsedConversation
        }

        return candidateStrings.first(where: isLikelySlackConversation)
    }

    private func slackWorkspaceName(
        windowTitle: String?,
        candidateStrings: [String],
        conversation: String?
    ) -> String? {
        if let windowTitle,
           let parsedWorkspace = slackWorkspaceFromWindowTitle(windowTitle) {
            return parsedWorkspace
        }

        return candidateStrings.first { candidate in
            isLikelySlackWorkspace(candidate) && candidate != conversation
        }
    }

    private func slackConversationFromWindowTitle(_ title: String) -> String? {
        let tokens = slackTitleTokens(from: title)
        return tokens.first(where: isLikelySlackConversation)
    }

    private func slackWorkspaceFromWindowTitle(_ title: String) -> String? {
        let tokens = slackTitleTokens(from: title)
        return tokens.last(where: isLikelySlackWorkspace)
    }

    private func slackTitleTokens(from title: String) -> [String] {
        let separators = [" — ", " - ", " | ", " • ", " · ", ":"]
        var tokens = [title]

        for separator in separators {
            tokens = tokens.flatMap { $0.components(separatedBy: separator) }
        }

        return deduplicatedStrings(tokens.map(slackNormalizedString).filter { !slackIgnoredTokens.contains($0.lowercased()) })
    }

    private func slackIdentifier(workspace: String?, conversation: String?) -> String {
        let normalizedWorkspace = slackIdentifierComponent(from: workspace)
        let normalizedConversation = slackIdentifierComponent(from: conversation)

        if let normalizedWorkspace, let normalizedConversation {
            return "slack:\(normalizedWorkspace):\(normalizedConversation)"
        }
        if let normalizedConversation {
            return "slack:\(normalizedConversation)"
        }
        if let normalizedWorkspace {
            return "slack:\(normalizedWorkspace)"
        }
        return "com.tinyspeck.slackmacgap"
    }

    private func slackDisplayName(workspace: String?, conversation: String?) -> String {
        switch (workspace, conversation) {
        case let (.some(workspace), .some(conversation)):
            return "Slack / \(workspace) / \(conversation)"
        case let (.none, .some(conversation)):
            return "Slack / \(conversation)"
        case let (.some(workspace), .none):
            return "Slack / \(workspace)"
        case (.none, .none):
            return "Slack"
        }
    }

    private func slackIdentifierComponent(from string: String?) -> String? {
        guard let string = string?.lowercased(), !string.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_#@."))
        let scalars = string.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func isLikelySlackConversation(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        guard
            !string.isEmpty,
            string.count <= 80,
            !slackIgnoredTokens.contains(lowercased)
        else {
            return false
        }

        if string.hasPrefix("#") || string.hasPrefix("@") {
            return true
        }

        if lowercased.hasPrefix("dm with ") || lowercased.hasPrefix("messages with ") {
            return true
        }

        return !lowercased.contains("slack")
            && !lowercased.contains("workspace")
            && !lowercased.contains("huddle")
            && !lowercased.contains("activity")
            && !lowercased.contains("later")
            && !lowercased.contains("canvas")
    }

    private func figmaURLString(from string: String) -> String? {
        if let url = firstURL(in: string),
           (url.host?.contains("figma.com") == true || url.scheme == "figma") {
            return url.absoluteString
        }

        if let match = firstMatch(
            in: string,
            pattern: #"https://www\.figma\.com/(file|design|proto|board)/[A-Za-z0-9]+[^ ]*"#
        ) {
            return match
        }

        return nil
    }

    private func isLikelySlackWorkspace(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        guard
            !string.isEmpty,
            string.count <= 80,
            !slackIgnoredTokens.contains(lowercased)
        else {
            return false
        }

        return !string.hasPrefix("#")
            && !string.hasPrefix("@")
            && !lowercased.hasPrefix("dm with ")
            && !lowercased.hasPrefix("messages with ")
            && !lowercased.contains("thread")
            && !lowercased.contains("unreads")
            && !lowercased.contains("activity")
    }

    private func slackNormalizedString(_ string: String) -> String {
        string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func figmaFileName(windowTitle: String?, candidateStrings: [String]) -> String? {
        if let windowTitle,
           let titleToken = figmaTitleTokens(from: windowTitle).first {
            return titleToken
        }

        return candidateStrings.first(where: isLikelyFigmaDocumentName)
    }

    private func figmaPageName(windowTitle: String?, candidateStrings: [String], fileName: String?) -> String? {
        // Only trust the window title for the page name. AX-walked candidate
        // strings include hovered tooltips ("Close tab") and section labels
        // ("Application toolbar"), which leak into the path and make the
        // context unstable. If the title doesn't carry a distinct page token,
        // surface no page rather than guess.
        guard let windowTitle else { return nil }
        let titleTokens = figmaTitleTokens(from: windowTitle)
        guard titleTokens.count > 1 else { return nil }
        return titleTokens.first(where: { $0 != fileName })
    }

    private func figmaTitleTokens(from title: String) -> [String] {
        let separators = [" — ", " - ", " | ", " • ", " · ", ":"]
        var tokens = [title]

        for separator in separators {
            tokens = tokens.flatMap { $0.components(separatedBy: separator) }
        }

        return deduplicatedStrings(
            tokens
                .map(slackNormalizedString)
                .filter { !$0.isEmpty && !figmaIgnoredTokens.contains($0.lowercased()) }
        )
    }

    private func figmaIdentifier(fileName: String?, pageName: String?) -> String {
        let normalizedFile = slackIdentifierComponent(from: fileName)
        let normalizedPage = slackIdentifierComponent(from: pageName)

        if let normalizedFile, let normalizedPage {
            return "figma:\(normalizedFile):\(normalizedPage)"
        }
        if let normalizedFile {
            return "figma:\(normalizedFile)"
        }
        if let normalizedPage {
            return "figma:\(normalizedPage)"
        }
        return "com.figma.Desktop"
    }

    private func figmaDisplayName(fileName: String?, pageName: String?) -> String {
        switch (fileName, pageName) {
        case let (.some(fileName), .some(pageName)):
            return "Figma / \(fileName) / \(pageName)"
        case let (.some(fileName), .none):
            return "Figma / \(fileName)"
        case let (.none, .some(pageName)):
            return "Figma / \(pageName)"
        case (.none, .none):
            return "Figma"
        }
    }

    private func isLikelyFigmaDocumentName(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        return !string.isEmpty
            && string.count <= 120
            && !figmaIgnoredTokens.contains(lowercased)
            && !looksLikeAccessibilityHint(string)
            && !lowercased.hasPrefix("page ")
            && !lowercased.contains("figma")
    }

    private func isLikelyFigmaPageName(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        return !string.isEmpty
            && string.count <= 60
            && !figmaIgnoredTokens.contains(lowercased)
            && !looksLikeAccessibilityHint(string)
            && wordCount(in: string) <= 4
            && !lowercased.contains("figma")
    }

    private func looksLikeAccessibilityHint(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        return lowercased.contains("button")
            || lowercased.contains("action")
            || lowercased.contains("zoom")
            || lowercased.contains("window")
            || lowercased.contains("click")
            || lowercased.contains("press")
            || lowercased.contains("toggle")
            || lowercased.contains("tooltip")
            || string.contains(".")
    }

    private func wordCount(in string: String) -> Int {
        string.split(whereSeparator: \.isWhitespace).count
    }

    private func deduplicatedStrings(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { string in
            guard !string.isEmpty else { return false }
            return seen.insert(string).inserted
        }
    }

    private func webDocumentString(startingAt element: AXUIElement) -> String? {
        let documentStrings = descendantDocumentStrings(startingAt: element) + ancestorDocumentStrings(startingAt: element)
        return documentStrings.first { documentString in
            documentString.hasPrefix("https://") || documentString.hasPrefix("http://")
        }
    }

    private func firstURL(in string: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return detector.firstMatch(in: string, options: [], range: range)?.url
    }

    private func firstMatch(in string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              let matchRange = Range(match.range, in: string) else {
            return nil
        }

        return String(string[matchRange])
    }

    private func ancestorDocumentStrings(startingAt element: AXUIElement) -> [String] {
        var currentElement: AXUIElement? = element
        var strings: [String] = []

        for _ in 0..<12 {
            guard let unwrappedElement = currentElement else { break }

            if let documentString = documentString(from: unwrappedElement) {
                strings.append(documentString)
            }

            currentElement = copyAttribute(
                kAXParentAttribute as CFString,
                from: unwrappedElement
            ) as! AXUIElement?
        }

        return strings
    }

    private func descendantDocumentStrings(startingAt element: AXUIElement) -> [String] {
        var queue: [AXUIElement] = [element]
        var strings: [String] = []
        var visited = Set<CFHashCode>()

        while !queue.isEmpty && visited.count < 256 {
            let current = queue.removeFirst()
            let currentHash = CFHash(current)
            guard visited.insert(currentHash).inserted else { continue }

            if let documentString = documentString(from: current) {
                strings.append(documentString)
            }

            if let children = copyAttribute(kAXChildrenAttribute as CFString, from: current) as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }

        return strings
    }

    private var slackIgnoredTokens: Set<String> {
        [
            "slack",
            "home",
            "later",
            "activity",
            "threads",
            "dms",
            "more",
            "search",
            "drafts",
            "canvases",
            "huddles",
            "messages",
            "send message",
            "new message",
            "untitled",
            "window"
        ]
    }

    private var figmaIgnoredTokens: Set<String> {
        [
            "figma",
            "drafts",
            "workspace",
            "recents",
            "search",
            "community",
            "design",
            "prototype",
            "dev mode",
            "present",
            "share",
            "comments",
            "assets",
            "layers",
            "untitled",
            "window"
        ]
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    private func axElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        // AXUIElement is a CoreFoundation type — the cast always succeeds when non-nil.
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

    private func executeFilePathScript(_ scriptSource: String) -> URL? {
        guard let script = NSAppleScript(source: scriptSource) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)

        if error != nil {
            return nil
        }

        let path = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
