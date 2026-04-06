import Foundation

struct BrowserDescriptor: Hashable {
    enum ScriptFamily {
        case safari
        case chromium
        case arc
    }

    let title: String
    let bundleIdentifier: String
    let scriptFamily: ScriptFamily
}

enum BrowserAutomationProbeResult {
    case notBrowser
    case success(browserName: String, url: URL)
    case noTab(browserName: String)
    case automationDenied(browserName: String)
    case unavailable(browserName: String)

    var message: String {
        switch self {
        case .notBrowser:
            return "Put a supported browser in front to test browser context."
        case .success(let browserName, let url):
            return "\(browserName) access working: \(url.absoluteString)"
        case .noTab(let browserName):
            return "\(browserName) is open, but there is no active tab URL."
        case .automationDenied(let browserName):
            return "Automation access is blocked for \(browserName). macOS should prompt the first time Side Note tries to read the active tab."
        case .unavailable(let browserName):
            return "Could not read the active tab from \(browserName)."
        }
    }
}

struct BrowserAutomationAttemptResult {
    let result: BrowserAutomationProbeResult
    let debugDetails: String
}

struct BrowserURLProvider {
    static let supportedBrowsers: [BrowserDescriptor] = [
        BrowserDescriptor(title: "Safari", bundleIdentifier: "com.apple.Safari", scriptFamily: .safari),
        BrowserDescriptor(title: "Safari Technology Preview", bundleIdentifier: "com.apple.SafariTechnologyPreview", scriptFamily: .safari),
        BrowserDescriptor(title: "Google Chrome", bundleIdentifier: "com.google.Chrome", scriptFamily: .chromium),
        BrowserDescriptor(title: "Google Chrome Beta", bundleIdentifier: "com.google.Chrome.beta", scriptFamily: .chromium),
        BrowserDescriptor(title: "Google Chrome Canary", bundleIdentifier: "com.google.Chrome.canary", scriptFamily: .chromium),
        BrowserDescriptor(title: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac", scriptFamily: .chromium),
        BrowserDescriptor(title: "Microsoft Edge Beta", bundleIdentifier: "com.microsoft.edgemac.Beta", scriptFamily: .chromium),
        BrowserDescriptor(title: "Brave", bundleIdentifier: "com.brave.Browser", scriptFamily: .chromium),
        BrowserDescriptor(title: "Arc", bundleIdentifier: "company.thebrowser.Browser", scriptFamily: .arc),
        BrowserDescriptor(title: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi", scriptFamily: .chromium)
    ]

    private let browserMap = Dictionary(
        uniqueKeysWithValues: supportedBrowsers.map { ($0.bundleIdentifier, $0) }
    )

    func supports(bundleIdentifier: String) -> Bool {
        browserMap[bundleIdentifier] != nil
    }

    func activeURL(bundleIdentifier: String) -> URL? {
        if case .success(_, let url) = accessAttempt(
            bundleIdentifier: bundleIdentifier,
            activatesBrowser: false
        ).result {
            return url
        }

        return nil
    }

    func accessAttempt(bundleIdentifier: String, activatesBrowser: Bool = true) -> BrowserAutomationAttemptResult {
        guard let browser = browserMap[bundleIdentifier] else {
            return BrowserAutomationAttemptResult(
                result: .notBrowser,
                debugDetails: "No supported browser script for bundle identifier \(bundleIdentifier)."
            )
        }

        let browserName = browser.title
        let scriptSource = scriptSource(for: browser, activatesBrowser: activatesBrowser)
        guard let script = NSAppleScript(source: scriptSource) else {
            return BrowserAutomationAttemptResult(
                result: .unavailable(browserName: browserName),
                debugDetails: "NSAppleScript could not compile the request script for \(browserName)."
            )
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)

        if let error {
            let errorNumber = error[NSAppleScript.errorNumber] as? Int
            let debugDetails = debugDescription(for: error, browserName: browserName)
            if errorNumber == -1743 {
                return BrowserAutomationAttemptResult(
                    result: .automationDenied(browserName: browserName),
                    debugDetails: debugDetails
                )
            }
            return BrowserAutomationAttemptResult(
                result: .unavailable(browserName: browserName),
                debugDetails: debugDetails
            )
        }

        let value = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            return BrowserAutomationAttemptResult(
                result: .noTab(browserName: browserName),
                debugDetails: "\(browserName) responded successfully but returned an empty active tab URL."
            )
        }
        guard let url = URL(string: value) else {
            return BrowserAutomationAttemptResult(
                result: .unavailable(browserName: browserName),
                debugDetails: "\(browserName) returned a non-URL string: \(value)"
            )
        }
        return BrowserAutomationAttemptResult(
            result: .success(browserName: browserName, url: url),
            debugDetails: "\(browserName) returned active URL \(url.absoluteString)"
        )
    }

    func probeFrontmostBrowserAttempt(frontmostBundleIdentifier: String?) -> BrowserAutomationAttemptResult {
        guard
            let frontmostBundleIdentifier,
            supports(bundleIdentifier: frontmostBundleIdentifier)
        else {
            return BrowserAutomationAttemptResult(
                result: .notBrowser,
                debugDetails: "Frontmost app is not one of the supported browsers."
            )
        }
        return accessAttempt(bundleIdentifier: frontmostBundleIdentifier)
    }

    func descriptor(for bundleIdentifier: String) -> BrowserDescriptor? {
        browserMap[bundleIdentifier]
    }

    private func scriptSource(for browser: BrowserDescriptor, activatesBrowser: Bool) -> String {
        let activationPrefix = activatesBrowser ? "activate\n        delay 0.2\n        " : ""

        switch browser.scriptFamily {
        case .safari:
            return """
            tell application id "\(browser.bundleIdentifier)"
                \(activationPrefix)if not (exists front document) then return ""
                return URL of front document
            end tell
            """
        case .chromium:
            return """
            tell application id "\(browser.bundleIdentifier)"
                \(activationPrefix)if (count of windows) is 0 then return ""
                return URL of active tab of front window
            end tell
            """
        case .arc:
            return """
            tell application id "\(browser.bundleIdentifier)"
                \(activationPrefix)if (count of windows) is 0 then return ""
                if (count of tabs of window 1) is 0 then return ""
                return URL of tab 1 of window 1
            end tell
            """
        }
    }

    private func debugDescription(for error: NSDictionary, browserName: String) -> String {
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        let brief = error[NSAppleScript.errorBriefMessage] as? String ?? "No brief message"
        let range = error[NSAppleScript.errorRange] ?? "No range"
        return "\(browserName) Apple Events error \(number): \(message). Brief: \(brief). Range: \(range)"
    }
}
