import Foundation

/// Pure string parsing for Slack window titles and AX candidate strings.
/// Extracted from ContextResolver so the heuristics are unit-testable
/// against fixtures — these break silently whenever Slack ships a
/// redesign, and a test suite is the only way to notice.
///
/// Hardening over the original heuristics:
/// - The en dash (" – ") is a recognized separator.
/// - A positional fallback handles non-English locales: with the (never
///   localized) product token stripped, the leading token is treated as
///   the conversation and the trailing one as the workspace, even when
///   the English keyword filters can't classify them.
nonisolated enum SlackTitleParser {
    struct Result: Equatable {
        let workspace: String?
        let conversation: String?
    }

    static let titleSeparators = [" — ", " – ", " - ", " | ", " • ", " · ", ":"]

    static func parse(windowTitle: String?, candidateStrings: [String] = []) -> Result {
        let titleTokens = windowTitle.map(tokens(from:)) ?? []

        var conversation = titleTokens.first(where: isLikelyConversation)
        var workspace = titleTokens.last(where: { isLikelyWorkspace($0) && $0 != conversation })

        if conversation == nil {
            conversation = candidateStrings.first(where: isLikelyConversation)
        }
        if workspace == nil {
            workspace = candidateStrings.first { candidate in
                isLikelyWorkspace(candidate) && candidate != conversation
            }
        }

        // Positional fallback for locales where the keyword heuristics
        // can't classify anything: Slack titles lead with the
        // conversation and end with the workspace.
        if conversation == nil, workspace == nil, !titleTokens.isEmpty {
            conversation = titleTokens.first
            if titleTokens.count > 1 {
                workspace = titleTokens.last
            }
        }

        return Result(workspace: workspace, conversation: conversation)
    }

    static func tokens(from title: String) -> [String] {
        var tokens = [title]
        for separator in titleSeparators {
            tokens = tokens.flatMap { $0.components(separatedBy: separator) }
        }
        return deduplicate(
            tokens.map(normalize).filter { !ignoredTokens.contains($0.lowercased()) }
        )
    }

    static func identifier(workspace: String?, conversation: String?) -> String {
        let normalizedWorkspace = identifierComponent(from: workspace)
        let normalizedConversation = identifierComponent(from: conversation)

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

    static func displayName(workspace: String?, conversation: String?) -> String {
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

    static func identifierComponent(from string: String?) -> String? {
        guard let string = string?.lowercased(), !string.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_#@."))
        let scalars = string.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func isLikelyConversation(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        guard
            !string.isEmpty,
            string.count <= 80,
            !ignoredTokens.contains(lowercased)
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

    static func isLikelyWorkspace(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        guard
            !string.isEmpty,
            string.count <= 80,
            !ignoredTokens.contains(lowercased)
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

    static func normalize(_ string: String) -> String {
        string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    static func deduplicate(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { string in
            guard !string.isEmpty else { return false }
            return seen.insert(string).inserted
        }
    }

    static let ignoredTokens: Set<String> = [
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

/// Pure string parsing for Figma window titles and AX candidate strings.
/// Same rationale and hardening as SlackTitleParser; Figma titles use an
/// en dash ("File – Figma"), which the original separator list missed.
nonisolated enum FigmaTitleParser {
    struct Result: Equatable {
        let fileName: String?
        let pageName: String?
    }

    static func parse(windowTitle: String?, candidateStrings: [String] = []) -> Result {
        let titleTokens = windowTitle.map(tokens(from:)) ?? []

        var fileName = titleTokens.first
        if fileName == nil {
            fileName = candidateStrings.first(where: isLikelyDocumentName)
        }

        // Only trust the window title for the page name. AX-walked
        // candidate strings include hovered tooltips ("Close tab") and
        // section labels ("Application toolbar"), which leak into the
        // path and make the context unstable. If the title doesn't carry
        // a distinct page token, surface no page rather than guess.
        var pageName: String?
        if titleTokens.count > 1 {
            pageName = titleTokens.first(where: { $0 != fileName })
        }
        if pageName == fileName {
            pageName = nil
        }

        return Result(fileName: fileName, pageName: pageName)
    }

    static func tokens(from title: String) -> [String] {
        var tokens = [title]
        for separator in SlackTitleParser.titleSeparators {
            tokens = tokens.flatMap { $0.components(separatedBy: separator) }
        }
        return SlackTitleParser.deduplicate(
            tokens
                .map(SlackTitleParser.normalize)
                .filter { !$0.isEmpty && !ignoredTokens.contains($0.lowercased()) }
        )
    }

    /// Filters AX candidate strings down to plausible document names —
    /// drops UI chrome tokens and accessibility hints.
    static func filterCandidates(_ strings: [String]) -> [String] {
        SlackTitleParser.deduplicate(
            strings.filter { candidate in
                let lowercased = candidate.lowercased()
                return !ignoredTokens.contains(lowercased)
                    && !looksLikeAccessibilityHint(candidate)
            }
        )
    }

    static func identifier(fileName: String?, pageName: String?) -> String {
        let normalizedFile = SlackTitleParser.identifierComponent(from: fileName)
        let normalizedPage = SlackTitleParser.identifierComponent(from: pageName)

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

    static func displayName(fileName: String?, pageName: String?) -> String {
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

    static func urlString(from string: String) -> String? {
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

    static func isLikelyDocumentName(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        return !string.isEmpty
            && string.count <= 120
            && !ignoredTokens.contains(lowercased)
            && !looksLikeAccessibilityHint(string)
            && !lowercased.hasPrefix("page ")
            && !lowercased.contains("figma")
    }

    static func looksLikeAccessibilityHint(_ string: String) -> Bool {
        let lowercased = string.lowercased()
        return lowercased.contains("button")
            || lowercased.contains("action")
            || lowercased.contains("zoom")
            || lowercased.contains("window")
            || lowercased.contains("click")
            || lowercased.contains("press")
            || lowercased.contains("toggle")
            || lowercased.contains("tooltip")
            || lowercased.contains("toolbar")
            || lowercased.contains("sidebar")
            || string.contains(".")
    }

    static let ignoredTokens: Set<String> = [
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

    private static func firstURL(in string: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return detector.firstMatch(in: string, options: [], range: range)?.url
    }

    private static func firstMatch(in string: String, pattern: String) -> String? {
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
}
