import Foundation

/// A passage captured from the app in front: the selected text, the page
/// it came from, and (for web pages) a link that reopens the page
/// scrolled to that passage.
nonisolated struct Passage: Equatable, Sendable {
    let text: String
    let sourceURL: URL?
    let link: URL?

    init(text: String, sourceURL: URL?) {
        self.text = text
        self.sourceURL = sourceURL
        self.link = sourceURL.flatMap { PassageLink.textFragmentURL(page: $0, selection: text) }
    }

    /// First few words, for chips and previews.
    var preview: String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let head = words.prefix(8).joined(separator: " ")
        return words.count > 8 ? head + "…" : head
    }
}

/// Builds W3C Text Fragment links (`#:~:text=start,end`) that Safari 16.1+
/// and every Chromium browser scroll to and highlight.
nonisolated enum PassageLink {
    /// Selections up to this many words become a single range; longer
    /// ones use a start/end pair so the fragment stays short and robust.
    static let singleRangeWordLimit = 10
    static let rangeWordCount = 5

    static func textFragmentURL(page: URL, selection: String) -> URL? {
        let words = selection.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }

        let base = URLCanonicalizer.navigationURL(for: page)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        let directive: String
        if words.count <= singleRangeWordLimit {
            directive = encode(words.joined(separator: " "))
        } else {
            let start = words.prefix(rangeWordCount).joined(separator: " ")
            let end = words.suffix(rangeWordCount).joined(separator: " ")
            directive = encode(start) + "," + encode(end)
        }

        components.fragment = nil
        components.percentEncodedFragment = ":~:text=" + directive
        return components.url
    }

    static func isTextFragment(_ url: URL) -> Bool {
        url.fragment(percentEncoded: true)?.hasPrefix(":~:") ?? false
    }

    /// Percent-encodes a text directive term. Besides the usual fragment
    /// escaping, `-`, `&` and `,` are syntax inside a directive and must be
    /// escaped in the text itself.
    static func encode(_ term: String) -> String {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "-&,%#?/:@!$'()*+;=")
        return term.addingPercentEncoding(withAllowedCharacters: allowed) ?? term
    }
}
