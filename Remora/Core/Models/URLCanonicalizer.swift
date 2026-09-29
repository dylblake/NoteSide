import Foundation

/// Turns a browser URL into a stable identity for "this page".
///
/// The same document is reached through URLs that differ in session
/// tokens (`t=` on Figma), analytics tags (`utm_*`, `fbclid`), renamed
/// slugs (Figma, Notion, Google Docs) and share suffixes (YouTube `si`).
/// Without canonicalisation each variant became a separate note and a
/// saved note went missing on the next visit.
///
/// Generic rules apply everywhere; a small table of host rules narrows
/// well-known apps down to the path segments and query keys that actually
/// identify the document. Hash-routed apps (Gmail) keep their fragment.
nonisolated enum URLCanonicalizer {

    struct HostRule: Sendable {
        /// Matches `host == suffix` or `host.hasSuffix("." + suffix)`.
        let hostSuffix: String
        /// Keep only this many leading path components (nil = all).
        let keepPathComponents: Int?
        /// Keep only these query keys (nil = generic rule; empty = none).
        let keptQueryKeys: Set<String>?
        /// Whether the fragment is part of the document identity.
        let keepFragment: Bool
        /// Optional path rewrite for hosts whose identity hides inside a
        /// slug (Notion appends a 32-hex id to the page name).
        let pathTransform: (@Sendable ([String]) -> [String])?

        init(
            hostSuffix: String,
            keepPathComponents: Int? = nil,
            keptQueryKeys: Set<String>? = nil,
            keepFragment: Bool = false,
            pathTransform: (@Sendable ([String]) -> [String])? = nil
        ) {
            self.hostSuffix = hostSuffix
            self.keepPathComponents = keepPathComponents
            self.keptQueryKeys = keptQueryKeys
            self.keepFragment = keepFragment
            self.pathTransform = pathTransform
        }
    }

    /// Query keys that never identify a document, on any host.
    static let trackingQueryKeys: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "twclid", "ttclid",
        "mc_cid", "mc_eid", "ref_src", "ref_url", "igshid", "si",
        "_hsenc", "_hsmi", "vero_id", "yclid", "wickedid", "oly_anon_id", "oly_enc_id"
    ]

    static let trackingQueryKeyPrefixes: [String] = ["utm_", "pk_", "mtm_"]

    /// First matching rule wins; keep specific hosts above general ones.
    static let hostRules: [HostRule] = [
        HostRule(hostSuffix: "figma.com", keepPathComponents: 2, keptQueryKeys: ["node-id"]),
        HostRule(hostSuffix: "docs.google.com", keptQueryKeys: [], pathTransform: googleDocumentPath),
        HostRule(hostSuffix: "drive.google.com", keptQueryKeys: [], pathTransform: googleDocumentPath),
        HostRule(hostSuffix: "mail.google.com", keptQueryKeys: [], keepFragment: true),
        HostRule(hostSuffix: "notion.so", keptQueryKeys: [], pathTransform: notionPath),
        HostRule(hostSuffix: "notion.site", keptQueryKeys: [], pathTransform: notionPath),
        HostRule(hostSuffix: "youtube.com", keptQueryKeys: ["v"]),
        HostRule(hostSuffix: "github.com", keptQueryKeys: [], pathTransform: githubPath),
        HostRule(hostSuffix: "linear.app", keptQueryKeys: [], pathTransform: linearPath),
        HostRule(hostSuffix: "atlassian.net", keptQueryKeys: []),
        HostRule(hostSuffix: "app.slack.com", keptQueryKeys: [])
    ]

    /// The identity string stored in `NoteContext.identifier` for web pages.
    static func canonicalIdentifier(for url: URL) -> String {
        canonicalURL(for: url).absoluteString
    }

    /// The URL to reopen: canonical path and query, plus the original
    /// fragment when it isn't a tracking/session artefact (in-page anchors
    /// are still worth landing on).
    static func navigationURL(for url: URL) -> URL {
        canonicalURL(for: url, includeFragment: true)
    }

    static func canonicalURL(for url: URL, includeFragment: Bool = false) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = components.host?.lowercased(), !rawHost.isEmpty else {
            return url
        }

        rewriteAliases(&components, host: rawHost)
        let aliasedHost = components.host?.lowercased() ?? rawHost
        let host = aliasedHost.hasPrefix("www.") ? String(aliasedHost.dropFirst(4)) : aliasedHost
        let rule = hostRules.first { host == $0.hostSuffix || host.hasSuffix("." + $0.hostSuffix) }

        components.scheme = scheme
        components.host = host
        if let port = components.port, (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            components.port = nil
        }

        // Path
        var pathComponents = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if let keep = rule?.keepPathComponents {
            pathComponents = Array(pathComponents.prefix(keep))
        }
        if let transform = rule?.pathTransform {
            pathComponents = transform(pathComponents)
        }
        components.percentEncodedPath = pathComponents.isEmpty ? "/" : "/" + pathComponents.joined(separator: "/")

        // Query
        let items = components.queryItems ?? []
        let kept = items.filter { item in
            let key = item.name.lowercased()
            if let allowed = rule?.keptQueryKeys {
                return allowed.contains(key)
            }
            return !isTrackingKey(key)
        }
        .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        components.queryItems = kept.isEmpty ? nil : kept

        // Fragment
        let fragmentIsIdentity = rule?.keepFragment ?? false
        if !(fragmentIsIdentity || (includeFragment && !(components.fragment ?? "").isEmpty)) {
            components.fragment = nil
        }
        if let fragment = components.fragment, fragment.hasPrefix(":~:") {
            // A text-fragment directive is a passage pointer, not identity.
            components.fragment = nil
        }

        return components.url ?? url
    }

    static func isTrackingKey(_ key: String) -> Bool {
        if trackingQueryKeys.contains(key) { return true }
        return trackingQueryKeyPrefixes.contains { key.hasPrefix($0) }
    }

    /// Hosts and paths that are different spellings of one document:
    /// `youtu.be/ID`, `youtube.com/shorts/ID` and `/live/ID` are all
    /// `youtube.com/watch?v=ID`, and `m.youtube.com` is the same site.
    private static func rewriteAliases(_ components: inout URLComponents, host: String) {
        let path = components.percentEncodedPath.split(separator: "/").map(String.init)
        let isYouTube = host == "youtube.com" || host.hasSuffix(".youtube.com")
        let videoID: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            videoID = path.first
        } else if isYouTube, path.count >= 2, ["shorts", "live"].contains(path[0]) {
            videoID = path[1]
        } else {
            videoID = nil
        }

        if let videoID, !videoID.isEmpty {
            components.host = "youtube.com"
            components.percentEncodedPath = "/watch"
            let rest = (components.queryItems ?? []).filter { $0.name != "v" }
            components.queryItems = [URLQueryItem(name: "v", value: videoID)] + rest
        } else if host == "m.youtube.com" {
            components.host = "youtube.com"
        }
    }

    /// `docs.google.com/document/u/1/d/ID/edit` → `/document/d/ID`: the
    /// signed-in account slot (`u/N`) is not part of the document, and
    /// keeping it collapsed every doc of a second account into one note.
    /// Published docs (`/d/e/ID/pub`) carry their id one segment later.
    private static let googleDocumentPath: @Sendable ([String]) -> [String] = { components in
        var stripped: [String] = []
        var index = 0
        while index < components.count {
            if components[index] == "u", index + 1 < components.count, Int(components[index + 1]) != nil {
                index += 2
                continue
            }
            stripped.append(components[index])
            index += 1
        }
        let keep = stripped.count > 2 && stripped[1] == "d" && stripped[2] == "e" ? 4 : 3
        return Array(stripped.prefix(keep))
    }

    /// Owner and repo are case-insensitive on GitHub, and a pull request
    /// or issue is one thing across its tabs (`/pull/42/files`,
    /// `/pull/42/commits`).
    private static let githubPath: @Sendable ([String]) -> [String] = { components in
        var result = components
        for index in result.indices.prefix(2) {
            result[index] = result[index].lowercased()
        }
        if result.count > 4, ["pull", "issues", "discussions"].contains(result[2]) {
            result = Array(result.prefix(4))
        }
        return result
    }

    /// Linear issue URLs end in a title slug that changes on rename:
    /// `/acme/issue/ENG-123/fix-login` → `/acme/issue/ENG-123`. Project
    /// URLs end in `<slug>-<12 hex id>` plus a tab; only the id is stable.
    private static let linearPath: @Sendable ([String]) -> [String] = { components in
        guard components.count >= 3 else { return components }
        switch components[1] {
        case "issue":
            return Array(components.prefix(3))
        case "project":
            let slug = components[2]
            let id = slug.split(separator: "-").last.map(String.init) ?? slug
            let stableID = id.count == 12 && id.allSatisfy(\.isHexDigit) ? id : slug
            return [components[0], components[1], stableID]
        default:
            return components
        }
    }

    /// Notion page URLs end in `<Slug>-<32 hex>`; only the id is stable.
    private static let notionPath: @Sendable ([String]) -> [String] = { components in
        guard let last = components.last else { return components }
        let candidate = last.split(separator: "-").last.map(String.init) ?? last
        if candidate.count == 32, candidate.allSatisfy(\.isHexDigit) {
            return Array(components.dropLast()) + [candidate]
        }
        return components
    }
}
