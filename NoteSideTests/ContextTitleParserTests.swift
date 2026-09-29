import Foundation
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

struct LinearTitleParserTests {

    @Test func issueKeyFromWindowTitle() {
        #expect(LinearTitleParser.issueKey(in: "ENG-123 Fix login bug") == "ENG-123")
        #expect(LinearTitleParser.issueKey(in: "Fix login – DES2-7 – Linear") == "DES2-7")
        #expect(LinearTitleParser.issueKey(in: "Inbox") == nil)
        #expect(LinearTitleParser.issueKey(in: "My issues - 2024-05") == nil)
    }

    @Test func desktopLinkFromWebURL() {
        #expect(
            LinearTitleParser.desktopURLString(forWebURL: "https://linear.app/acme/issue/ENG-1")
                == "linear://acme/issue/ENG-1"
        )
        #expect(LinearTitleParser.desktopURLString(forWebURL: "https://example.com/acme") == nil)
        #expect(LinearTitleParser.desktopURLString(forWebURL: "https://linear.app/") == nil)
    }
}

struct TerminalTitleParserTests {
    let home = "/Users/me"

    @Test func tildePathTitles() {
        #expect(TerminalTitleParser.directoryPath(in: "~/src/app", homeDirectory: home) == "/Users/me/src/app")
        #expect(TerminalTitleParser.directoryPath(in: "me@mac: ~/src/app", homeDirectory: home) == "/Users/me/src/app")
        #expect(TerminalTitleParser.directoryPath(in: "~/src/app (-zsh)", homeDirectory: home) == "/Users/me/src/app")
        #expect(TerminalTitleParser.directoryPath(in: "~", homeDirectory: home) == "/Users/me")
    }

    @Test func absolutePathTitles() {
        #expect(TerminalTitleParser.directoryPath(in: "/opt/homebrew — -zsh", homeDirectory: home) == "/opt/homebrew")
    }

    @Test func titlesWithoutAPath() {
        #expect(TerminalTitleParser.directoryPath(in: "app — -zsh — 80×24", homeDirectory: home) == nil)
        #expect(TerminalTitleParser.directoryPath(in: "vim", homeDirectory: home) == nil)
        #expect(TerminalTitleParser.directoryPath(in: "/", homeDirectory: home) == nil)
    }
}

struct SlackClientURLTests {
    private func link(_ string: String) -> String? {
        SlackClientURL.location(from: URL(string: string)!).map(SlackClientURL.deepLink(for:))
    }

    @Test func channelAndDMOpenTheConversation() {
        #expect(link("https://app.slack.com/client/T0AR0MQEYLS/C024BE91L") == "slack://channel?team=T0AR0MQEYLS&id=C024BE91L")
        #expect(link("https://app.slack.com/client/T0AR0MQEYLS/D024BE91L") == "slack://channel?team=T0AR0MQEYLS&id=D024BE91L")
        #expect(link("https://app.slack.com/client/E0ENTERPR/G024BE91L") == "slack://channel?team=E0ENTERPR&id=G024BE91L")
    }

    @Test func threadPaneReopensItsConversation() {
        #expect(
            link("https://app.slack.com/client/T0AR0MQEYLS/C024BE91L/thread/C024BE91L-1712345678.123456")
                == "slack://channel?team=T0AR0MQEYLS&id=C024BE91L"
        )
    }

    @Test func workspaceViewsOpenTheWorkspace() {
        #expect(link("https://app.slack.com/client/T0AR0MQEYLS/unreads") == "slack://open?team=T0AR0MQEYLS")
        #expect(link("https://app.slack.com/client/T0AR0MQEYLS") == "slack://open?team=T0AR0MQEYLS")
    }

    @Test func nonClientURLsAreIgnored() {
        // What the signed-out app reports: no conversation to reopen.
        #expect(link("https://app.slack.com/ssb/first?team=T0AR0MQEYLS") == nil)
        #expect(link("https://acme.slack.com/archives/C024BE91L") == nil)
    }
}

struct SlackTitleHardeningTests {

    /// A title naming only the workspace (a workspace view such as
    /// Activity) left the workspace slot to the AX walk, which filled it
    /// with Slack's zoom-button tooltip.
    @Test func tooltipNeverFillsInForATitle() {
        let result = SlackTitleParser.parse(
            windowTitle: "Activity - dylblake - Slack",
            candidateStrings: ["This button also has an action to zoom the window", "all-dylblake"]
        )
        #expect(result.workspace == nil)
        #expect(result.conversation == "dylblake")
    }

    @Test func workspaceViewPerURLNamesTheWorkspace() {
        let result = SlackTitleParser.parse(
            windowTitle: "Activity - dylblake - Slack",
            candidateStrings: ["This button also has an action to zoom the window"],
            conversationOpen: false
        )
        #expect(result == SlackTitleParser.Result(workspace: "dylblake", conversation: nil))
    }

    @Test func conversationTitleUnchangedWhenURLConfirmsIt() {
        let result = SlackTitleParser.parse(
            windowTitle: "new-channel (Channel) - dylblake - Slack",
            conversationOpen: true
        )
        #expect(result == SlackTitleParser.Result(workspace: "dylblake", conversation: "new-channel (Channel)"))
    }

    /// Live title: "Slackbot" contains "slack", which the keyword
    /// heuristics reject as a conversation name.
    @Test func openConversationFollowsTitleOrder() {
        let result = SlackTitleParser.parse(
            windowTitle: "Slackbot (DM) - dylblake - Slack",
            conversationOpen: true
        )
        #expect(result == SlackTitleParser.Result(workspace: "dylblake", conversation: "Slackbot (DM)"))
    }

    @Test func interfaceTextIsDroppedWithoutATitle() {
        let result = SlackTitleParser.parse(
            windowTitle: nil,
            candidateStrings: ["This button also has an action to zoom the window", "#support", "Acme"]
        )
        #expect(result == SlackTitleParser.Result(workspace: "Acme", conversation: "#support"))
    }
}
