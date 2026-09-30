import AppKit
import SwiftUI

/// The Setup window. A short "how it works" card, then one permission
/// row per capability. Each row shows its state at a glance, with the
/// per-app detail (individual browsers, Finder / Xcode, microphone +
/// speech) listed straight beneath it: nothing to expand.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header
                howItWorksCard
                permissionsCard
                completionFooter
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        PageHeader(
            title: "Setup",
            subtitle: "Notes that stay attached to the app, page, or file you're in."
        )
    }

    // MARK: How it works

    private var howItWorksCard: some View {
        TitledCard(title:"How it works", systemImage: "keyboard") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                step(1, "Switch to any app, browser tab, or file.")
                step(2, "Press \(appState.hotkeys.hotKeyDisplayString) to open a note for that context, and again to save.")
                step(3, "Press \(appState.hotkeys.allNotesHotKeyDisplayString) to browse every note. Add #tags to find them across contexts.")
                step(4, "Hold \(appState.hotkeys.dictationHotKeyDisplayString) to dictate; release to insert the text.")

                HStack(spacing: Spacing.xs) {
                    Spacer(minLength: 0)
                    Button("Open All Notes") { appState.toggleAllNotesPanel() }
                        .buttonStyle(.glass)
                    Button("Try a Note") { appState.toggleQuickNote() }
                        .buttonStyle(.glass)
                }
                .padding(.top, Spacing.xxs)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text("\(number)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(RemoraTheme.accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(RemoraTheme.accent.opacity(0.12)))
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .foregroundStyle(RemoraTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        TitledCard(title:"Permissions", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Hotkeys work out of the box. Accessibility is the one to turn on first; the rest unlock one capability each and can wait until you need them.")
                    .font(.subheadline)
                    .foregroundStyle(RemoraTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                accessibilityRow

                #if !MAS_BUILD
                browserRow
                #endif

                appAutomationRow
                dictationRow
            }
        }
    }

    private var accessibilityRow: some View {
        PermissionRow(
            title: "Accessibility",
            detail: accessibilityRowDetail,
            status: appState.isAccessibilityTrusted ? .granted : .missing
        ) {
            if !appState.isAccessibilityTrusted {
                Button("Request Access") { appState.openAccessibilitySettings() }
                    .buttonStyle(.glass)
            }
        }
    }

    /// The same in both builds: Accessibility is how browser pages are
    /// read, with a browser's Automation only as a fallback.
    private var accessibilityRowDetail: String {
        appState.isAccessibilityTrusted
            ? "Reads the current browser page and detects Slack, Figma, and editor context."
            : "Needed for browser pages, Slack / Figma / editor context, and dictation. After clicking, enable Remora in System Settings; use ＋ if it isn't listed."
    }

    #if !MAS_BUILD
    private var browserRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            PermissionRow(
                title: "Browser Automation",
                detail: browserSummaryDetail,
                status: browserAutomationSummaryStatus
            ) {
                if browserAutomationSummaryStatus == .missing {
                    Button("Open Settings") { appState.browserPermissions.openAutomationSettings() }
                        .buttonStyle(.glass)
                }
            }

            if !installedBrowsers.isEmpty {
                detailRows {
                    ForEach(installedBrowsers, id: \.bundleIdentifier) { browser in
                        browserDetailRow(title: browser.title, bundleIdentifier: browser.bundleIdentifier)
                    }
                }
                .accessibilityIdentifier("browserDetails")
            }
        }
    }

    private var browserSummaryDetail: String {
        switch browserAutomationSummaryStatus {
        case .granted: return "Reopening a note finds its page among a browser's background tabs. All installed browsers are connected."
        case .missing: return "A browser has Automation turned off. macOS asks once; re-enable it in System Settings → Privacy & Security → Automation."
        case .pending: return "Optional. Accessibility already reads the page you're on; connecting a browser also lets a reopened note find its page among background tabs."
        }
    }

    /// Aggregate over the per-browser rows: red only when a browser is
    /// actually denied; a browser that merely hasn't been asked about yet
    /// is "pending", not an error.
    private var browserAutomationSummaryStatus: PermissionRowStatus {
        let states = installedBrowsers.map { browser in
            appState.browserPermissions.browserPermissionStates[browser.bundleIdentifier] ?? .undetermined
        }
        if states.contains(.notGranted) { return .missing }
        if !states.isEmpty && states.allSatisfy({ $0 == .granted }) { return .granted }
        return .pending
    }

    private var installedBrowsers: [BrowserDescriptor] {
        AppState.supportedBrowsers.filter { browser in
            if let state = appState.browserPermissions.browserPermissionStates[browser.bundleIdentifier] {
                return state != .notInstalled
            }
            return false
        }
    }

    private func browserDetailRow(title: String, bundleIdentifier: String) -> some View {
        let status = appState.browserPermissions.browserPermissionStates[bundleIdentifier] ?? .notInstalled

        return PermissionDetailRow(title: title, detail: automationStatusText(for: status), status: rowStatus(for: status)) {
            if appState.browserPermissions.isRequestPending(for: bundleIdentifier) {
                PendingLabel(text: "Connecting…")
            } else if status == .undetermined {
                Button("Connect") { appState.browserPermissions.requestAutomationAccess(for: bundleIdentifier) }
                    .buttonStyle(.glass)
            } else if status != .granted {
                // macOS won't re-prompt after a denial — the only path back
                // is the Automation pane in System Settings.
                Button("Open Settings") { appState.browserPermissions.openAutomationSettings() }
                    .buttonStyle(.glass)
            }
        }
    }
    #endif

    private var appAutomationRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            PermissionRow(
                title: "Finder & Xcode",
                detail: appAutomationSummaryDetail,
                status: appAutomationSummaryStatus
            ) {
                if appAutomationSummaryStatus == .missing {
                    Button("Open Settings") { appState.browserPermissions.openAutomationSettings() }
                        .buttonStyle(.glass)
                }
            }

            if !installedAppAutomationTargets.isEmpty {
                detailRows {
                    ForEach(installedAppAutomationTargets, id: \.bundleIdentifier) { target in
                        appAutomationDetailRow(for: target)
                    }
                }
                .accessibilityIdentifier("appDetails")
            }
        }
    }

    private var appAutomationSummaryDetail: String {
        switch appAutomationSummaryStatus {
        case .granted: return "Notes attach to the folder or file you're in rather than the app itself."
        case .missing: return "Access is turned off for one of these apps, so notes attach to the app instead of the file."
        case .pending: return "Attach notes to the folder or file you're in. Uses the same one-time Automation permission as browsers."
        }
    }

    private var appAutomationSummaryStatus: PermissionRowStatus {
        let states = installedAppAutomationTargets.map { target in
            appState.browserPermissions.appAutomationStates[target.bundleIdentifier] ?? .undetermined
        }
        if states.contains(.notGranted) { return .missing }
        if !states.isEmpty && states.allSatisfy({ $0 == .granted }) { return .granted }
        return .pending
    }

    private var installedAppAutomationTargets: [AppAutomationTarget] {
        BrowserPermissionsState.appAutomationTargets.filter { target in
            guard let state = appState.browserPermissions.appAutomationStates[target.bundleIdentifier] else {
                return false
            }
            return state != .notInstalled
        }
    }

    private func appAutomationDetailRow(for target: AppAutomationTarget) -> some View {
        let status = appState.browserPermissions.appAutomationStates[target.bundleIdentifier] ?? .notInstalled

        return PermissionDetailRow(title: target.title, detail: target.purpose, status: rowStatus(for: status)) {
            if appState.browserPermissions.isRequestPending(for: target.bundleIdentifier) {
                PendingLabel(text: "Requesting…")
            } else if status == .undetermined {
                Button("Request Access") { appState.browserPermissions.requestAppAutomationAccess(for: target) }
                    .buttonStyle(.glass)
            } else if status == .notGranted {
                Button("Open Settings") { appState.browserPermissions.openAutomationSettings() }
                    .buttonStyle(.glass)
            }
        }
    }

    private var dictationRow: some View {
        let micGranted = appState.isMicrophoneAuthorized
        let speechGranted = appState.isSpeechRecognitionAuthorized
        let status: PermissionRowStatus = (micGranted && speechGranted) ? .granted : .missing

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            PermissionRow(
                title: "Voice Dictation",
                detail: status == .granted
                    ? "Hold \(appState.hotkeys.dictationHotKeyDisplayString) in a note to dictate. Speech is recognised on device."
                    : "Hold \(appState.hotkeys.dictationHotKeyDisplayString) in a note to dictate. Needs the microphone and on-device speech recognition.",
                status: status
            ) {
                if status != .granted {
                    Button("Enable") { appState.requestDictationPermissionsIfNeeded() }
                        .buttonStyle(.glass)
                }
            }

            detailRows {
                PermissionDetailRow(title: "Microphone", detail: micGranted ? "Enabled." : "Required to capture audio.", status: micGranted ? .granted : .missing) {
                    if !micGranted {
                        Button("Request Access") { appState.requestMicrophoneAccess() }
                            .buttonStyle(.glass)
                    }
                }
                PermissionDetailRow(title: "Speech Recognition", detail: speechGranted ? "Enabled." : "Required to turn speech into text.", status: speechGranted ? .granted : .missing) {
                    if !speechGranted {
                        Button("Request Access") { appState.requestSpeechRecognitionAccess() }
                            .buttonStyle(.glass)
                    }
                }
            }
            .accessibilityIdentifier("dictationDetails")
        }
    }

    // MARK: Footer

    private var completionFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Text("Reopen this window anytime from the menu bar icon → Setup.")
                .font(.footnote)
                .foregroundStyle(RemoraTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.md)

            Button(appState.hasCompletedOnboarding ? "Done" : "Get Started") {
                appState.completeOnboarding()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Building blocks

    /// The per-app rows under a permission's summary row, indented to sit
    /// under its text. Always shown.
    private func detailRows<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            rows()
        }
        .padding(.leading, Spacing.xl + Spacing.xxs)
        .padding(.trailing, Spacing.md)
        .accessibilityElement(children: .contain)
    }

    private func rowStatus(for state: BrowserPermissionState) -> PermissionRowStatus {
        switch state {
        case .granted: return .granted
        case .notGranted: return .missing
        case .undetermined, .notInstalled: return .pending
        }
    }

    private func automationStatusText(for status: BrowserPermissionState) -> String {
        switch status {
        case .granted:
            return "Connected."
        case .notGranted:
            return "Automation is off. Enable Remora under System Settings → Privacy & Security → Automation."
        case .undetermined:
            return "Not connected yet. macOS will ask when you connect."
        case .notInstalled:
            return "Not installed on this Mac."
        }
    }
}
