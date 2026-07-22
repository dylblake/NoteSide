import Testing
@testable import NoteSide

// Fixture tests for the Slack/Figma title heuristics. These strings are
// what the apps actually put in their window titles; when Slack or Figma
// ships a redesign that changes the format, these tests are the place to
// record the new fixtures.

struct SlackTitleParserTests {

    @Test func channelAndWorkspaceFromWindowTitle() {
        let result = SlackTitleParser.parse(windowTitle: "#eng-core - Acme Corp - Slack")
        #expect(result.conversation == "#eng-core")
        #expect(result.workspace == "Acme Corp")
    }

    @Test func directMessageFromWindowTitle() {
        let result = SlackTitleParser.parse(windowTitle: "Jane Doe - Acme Corp - Slack")
        #expect(result.conversation == "Jane Doe")
        #expect(result.workspace == "Acme Corp")
    }

    @Test func dmPrefixIsConversation() {
        let result = SlackTitleParser.parse(windowTitle: "DM with Jane - Acme - Slack")
        #expect(result.conversation == "DM with Jane")
        #expect(result.workspace == "Acme")
    }

    @Test func enDashSeparatorIsRecognized() {
        let result = SlackTitleParser.parse(windowTitle: "#design – Acme Corp – Slack")
        #expect(result.conversation == "#design")
        #expect(result.workspace == "Acme Corp")
    }

    @Test func productTokenNeverLeaksIntoResult() {
        let result = SlackTitleParser.parse(windowTitle: "#general - Slack")
        #expect(result.conversation == "#general")
        #expect(result.workspace == nil)
    }

    @Test func candidateStringsFillInWhenTitleIsUseless() {
        let result = SlackTitleParser.parse(
            windowTitle: nil,
            candidateStrings: ["#design", "Acme Corp"]
        )
        #expect(result.conversation == "#design")
        #expect(result.workspace == "Acme Corp")
    }

    @Test func chromeTokensAreIgnored() {
        let result = SlackTitleParser.parse(
            windowTitle: nil,
            candidateStrings: ["Threads", "Drafts", "#support", "Search"]
        )
        #expect(result.conversation == "#support")
    }

    @Test func emptyInputYieldsNothing() {
        let result = SlackTitleParser.parse(windowTitle: nil, candidateStrings: [])
        #expect(result.conversation == nil)
        #expect(result.workspace == nil)
    }

    @Test func identifierIsNormalized() {
        let identifier = SlackTitleParser.identifier(workspace: "Acme Corp", conversation: "#eng-core")
        #expect(identifier == "slack:acme-corp:#eng-core")
    }

    @Test func identifierFallsBackToBundleID() {
        #expect(SlackTitleParser.identifier(workspace: nil, conversation: nil) == "com.tinyspeck.slackmacgap")
    }

    @Test func displayNameComposition() {
        #expect(SlackTitleParser.displayName(workspace: "Acme", conversation: "#eng") == "Slack / Acme / #eng")
        #expect(SlackTitleParser.displayName(workspace: nil, conversation: "#eng") == "Slack / #eng")
        #expect(SlackTitleParser.displayName(workspace: "Acme", conversation: nil) == "Slack / Acme")
        #expect(SlackTitleParser.displayName(workspace: nil, conversation: nil) == "Slack")
    }

    /// Non-English locale: the keyword heuristics can't classify these
    /// tokens, so the positional fallback must place them.
    @Test func positionalFallbackForLocalizedTitles() {
        let result = SlackTitleParser.parse(windowTitle: "#allgemein - Beispiel GmbH - Slack")
        #expect(result.conversation == "#allgemein")
        #expect(result.workspace == "Beispiel GmbH")
    }

    @Test func normalizationCollapsesWhitespace() {
        #expect(SlackTitleParser.normalize("  a \n  b  ") == "a b")
    }
}

struct FigmaTitleParserTests {

    @Test func fileAndPageFromEnDashTitle() {
        // Figma separates title segments with an en dash — the original
        // separator list missed it entirely, so files never resolved.
        let result = FigmaTitleParser.parse(windowTitle: "Homepage Redesign – Cover – Figma")
        #expect(result.fileName == "Homepage Redesign")
        #expect(result.pageName == "Cover")
    }

    @Test func fileOnlyTitle() {
        let result = FigmaTitleParser.parse(windowTitle: "Design System – Figma")
        #expect(result.fileName == "Design System")
        #expect(result.pageName == nil)
    }

    @Test func candidateFallbackSkipsUIChrome() {
        let result = FigmaTitleParser.parse(
            windowTitle: nil,
            candidateStrings: FigmaTitleParser.filterCandidates([
                "Close tab button", "Application toolbar", "Marketing Site"
            ])
        )
        #expect(result.fileName == "Marketing Site")
    }

    @Test func identifierComposition() {
        #expect(FigmaTitleParser.identifier(fileName: "My File", pageName: "Page 2") == "figma:my-file:page-2")
        #expect(FigmaTitleParser.identifier(fileName: nil, pageName: nil) == "com.figma.Desktop")
    }

    @Test func figmaURLDetection() {
        let url = FigmaTitleParser.urlString(from: "see https://www.figma.com/design/AbC123/My-File?node-id=1")
        #expect(url == "https://www.figma.com/design/AbC123/My-File?node-id=1")
        #expect(FigmaTitleParser.urlString(from: "https://example.com/x") == nil)
    }

    @Test func accessibilityHintsAreRejected() {
        #expect(FigmaTitleParser.looksLikeAccessibilityHint("Zoom to fit"))
        #expect(FigmaTitleParser.looksLikeAccessibilityHint("Click to expand"))
        #expect(!FigmaTitleParser.looksLikeAccessibilityHint("Marketing Site"))
    }
}
