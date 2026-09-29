import AppKit
import SwiftUI

private enum PermissionRowStatus {
    case granted
    /// Explicitly denied or required-and-absent.
    case missing
    /// Not requested yet — nothing is wrong.
    case pending

    var symbolName: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        case .pending: return "circle.dashed"
        }
    }

    var color: Color {
        switch self {
        case .granted: return NoteSideTheme.success
        case .missing: return NoteSideTheme.danger
        case .pending: return NoteSideTheme.secondaryText
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .granted: return "granted"
        case .missing: return "not granted"
        case .pending: return "not requested"
        }
    }
}

/// Permissions & Setup. A short "how it works" card, then one permission
/// row per capability. Each row shows its state at a glance; the per-app
/// detail (individual browsers, Finder / Xcode, microphone + speech) is
/// tucked behind a disclosure that opens itself only when something needs
/// attention.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var showsBrowserDetails = false
    @State private var showsAppDetails = false
    @State private var showsDictationDetails = false
    @State private var didSeedDisclosures = false

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
        .background(NoteSideTheme.windowBackground.ignoresSafeArea())
        .onAppear(perform: seedDisclosures)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("NoteSide")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(NoteSideTheme.primaryText)
                .accessibilityAddTraits(.isHeader)

            Text("Notes that stay attached to the app, page, or file you're in.")
                .font(.title3)
                .foregroundStyle(NoteSideTheme.secondaryText)
        }
    }

    // MARK: How it works

    private var howItWorksCard: some View {
        card(title: "How it works", systemImage: "keyboard") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                step(1, "Switch to any app, browser tab, or file.")
                step(2, "Press \(appState.hotkeys.hotKeyDisplayString) to open a note for that context, and again to save.")
                step(3, "Press \(appState.hotkeys.allNotesHotKeyDisplayString) to browse every note. Add #tags to find them across contexts.")
                step(4, "Hold \(appState.hotkeys.dictationHotKeyDisplayString) to dictate; release to insert the text.")

                HStack(spacing: Spacing.xs) {
                    Spacer(minLength: 0)
                    Button("Open All Notes") { appState.toggleAllNotesPanel() }
                        .buttonStyle(.bordered)
                    Button("Try a Note") { appState.toggleQuickNote() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, Spacing.xxs)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text("\(number)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(NoteSideTheme.accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(NoteSideTheme.accent.opacity(0.12)))
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .foregroundStyle(NoteSideTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        card(title: "Permissions", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Hotkeys work out of the box. Everything below is optional and unlocks one capability each.")
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.secondaryText)
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
        permissionRow(
            title: "Accessibility",
            detail: accessibilityRowDetail,
            status: appState.isAccessibilityTrusted ? .granted : .missing
        ) {
            if !appState.isAccessibilityTrusted {
                Button("Request Access") { appState.openAccessibilitySettings() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var accessibilityRowDetail: String {
        #if MAS_BUILD
        appState.isAccessibilityTrusted
            ? "Reads the current browser page and detects Slack, Figma, and editor context."
            : "Needed for browser pages, Slack / Figma / editor context, and dictation. After clicking, enable NoteSide in System Settings; use ＋ if it isn't listed."
        #else
        appState.isAccessibilityTrusted
            ? "Detects Slack, Figma, and editor context, and powers dictation's hold-to-release."
            : "Needed for Slack / Figma / editor context and dictation. After clicking, enable NoteSide in System Settings; use ＋ if it isn't listed."
        #endif
    }

    #if !MAS_BUILD
    private var browserRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            permissionRow(
                title: "Browser Automation",
                detail: browserSummaryDetail,
                status: browserAutomationSummaryStatus
            ) {
                if browserAutomationSummaryStatus == .missing {
                    Button("Open Settings") { appState.browserPermissions.openAutomationSettings() }
                        .buttonStyle(.bordered)
                }
            }

            if !installedBrowsers.isEmpty {
                DisclosureGroup(isExpanded: $showsBrowserDetails) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(installedBrowsers, id: \.bundleIdentifier) { browser in
                            browserDetailRow(title: browser.title, bundleIdentifier: browser.bundleIdentifier)
                        }
                    }
                    .padding(.top, Spacing.xs)
                } label: {
                    Text("\(installedBrowsers.count) installed \(installedBrowsers.count == 1 ? "browser" : "browsers")")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.leading, Spacing.xl + Spacing.xxs)
                .accessibilityIdentifier("browserDetailsDisclosure")
            }
        }
    }

    private var browserSummaryDetail: String {
        switch browserAutomationSummaryStatus {
        case .granted: return "Attaches notes to the exact page you're on. All installed browsers are connected."
        case .missing: return "A browser has Automation turned off. macOS asks once; re-enable it in System Settings → Privacy & Security → Automation."
        case .pending: return "Attaches notes to the exact page you're on. macOS asks the first time NoteSide reads a browser's active tab."
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

        return detailRow(title: title, detail: automationStatusText(for: status), status: rowStatus(for: status)) {
            if appState.browserPermissions.isRequestPending(for: bundleIdentifier) {
                pendingLabel("Connecting…")
            } else if status == .undetermined {
                Button("Connect") { appState.browserPermissions.requestAutomationAccess(for: bundleIdentifier) }
                    .buttonStyle(.bordered)
            } else if status != .granted {
                // macOS won't re-prompt after a denial — the only path back
                // is the Automation pane in System Settings.
                Button("Open Settings") { appState.browserPermissions.openAutomationSettings() }
                    .buttonStyle(.bordered)
            }
        }
    }
    #endif

    private var appAutomationRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            permissionRow(
                title: "Finder & Xcode",
                detail: appAutomationSummaryDetail,
                status: appAutomationSummaryStatus
            ) {
                if appAutomationSummaryStatus == .missing {
                    Button("Open Settings") { appState.browserPermissions.openAutomationSettings() }
                        .buttonStyle(.bordered)
                }
            }

            if !installedAppAutomationTargets.isEmpty {
                DisclosureGroup(isExpanded: $showsAppDetails) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(installedAppAutomationTargets, id: \.bundleIdentifier) { target in
                            appAutomationDetailRow(for: target)
                        }
                    }
                    .padding(.top, Spacing.xs)
                } label: {
                    Text("Per-app access")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.leading, Spacing.xl + Spacing.xxs)
                .accessibilityIdentifier("appDetailsDisclosure")
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

        return detailRow(title: target.title, detail: target.purpose, status: rowStatus(for: status)) {
            if appState.browserPermissions.isRequestPending(for: target.bundleIdentifier) {
                pendingLabel("Requesting…")
            } else if status == .undetermined {
                Button("Request Access") { appState.browserPermissions.requestAppAutomationAccess(for: target) }
                    .buttonStyle(.bordered)
            } else if status == .notGranted {
                Button("Open Settings") { appState.browserPermissions.openAutomationSettings() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var dictationRow: some View {
        let micGranted = appState.isMicrophoneAuthorized
        let speechGranted = appState.isSpeechRecognitionAuthorized
        let status: PermissionRowStatus = (micGranted && speechGranted) ? .granted : .missing

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            permissionRow(
                title: "Voice Dictation",
                detail: status == .granted
                    ? "Hold \(appState.hotkeys.dictationHotKeyDisplayString) in a note to dictate. Speech is recognised on device."
                    : "Hold \(appState.hotkeys.dictationHotKeyDisplayString) in a note to dictate. Needs the microphone and on-device speech recognition.",
                status: status
            ) {
                if status != .granted {
                    Button("Enable") { appState.requestDictationPermissionsIfNeeded() }
                        .buttonStyle(.bordered)
                }
            }

            DisclosureGroup(isExpanded: $showsDictationDetails) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    detailRow(title: "Microphone", detail: micGranted ? "Enabled." : "Required to capture audio.", status: micGranted ? .granted : .missing) {
                        if !micGranted {
                            Button("Request Access") { appState.requestMicrophoneAccess() }
                                .buttonStyle(.bordered)
                        }
                    }
                    detailRow(title: "Speech Recognition", detail: speechGranted ? "Enabled." : "Required to turn speech into text.", status: speechGranted ? .granted : .missing) {
                        if !speechGranted {
                            Button("Request Access") { appState.requestSpeechRecognitionAccess() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.top, Spacing.xs)
            } label: {
                Text("Microphone and speech")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.leading, Spacing.xl + Spacing.xxs)
            .accessibilityIdentifier("dictationDetailsDisclosure")
        }
    }

    // MARK: Footer

    private var completionFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            Text("Reopen this window anytime from the menu bar icon → Permissions & Setup.")
                .font(.footnote)
                .foregroundStyle(NoteSideTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.md)

            Button(appState.hasCompletedOnboarding ? "Done" : "Get Started") {
                appState.completeOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Building blocks

    private func card<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(NoteSideTheme.primaryText)
                .accessibilityAddTraits(.isHeader)

            content()
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: CornerRadius.sheet)
    }

    /// Top-level permission: status glyph, title, one-line detail, action.
    private func permissionRow<Action: View>(
        title: String,
        detail: String,
        status: PermissionRowStatus,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: status.symbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(status.color)
                .frame(width: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NoteSideTheme.primaryText)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.sm)

            action()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetRowSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status.accessibilityDescription)")
    }

    /// Nested per-app row inside a disclosure.
    private func detailRow<Action: View>(
        title: String,
        detail: String,
        status: PermissionRowStatus,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: status.symbolName)
                .font(.body)
                .foregroundStyle(status.color)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NoteSideTheme.primaryText)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(NoteSideTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.sm)

            action()
                .controlSize(.small)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status.accessibilityDescription)")
    }

    private func pendingLabel(_ text: String) -> some View {
        HStack(spacing: Spacing.xs - 2) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.footnote)
                .foregroundStyle(NoteSideTheme.secondaryText)
        }
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
            return "Automation is off. Enable NoteSide under System Settings → Privacy & Security → Automation."
        case .undetermined:
            return "Not connected yet. macOS will ask when you connect."
        case .notInstalled:
            return "Not installed on this Mac."
        }
    }

    /// Open the disclosures that need attention the first time the window
    /// appears; leave everything else folded.
    private func seedDisclosures() {
        guard !didSeedDisclosures else { return }
        didSeedDisclosures = true
        #if !MAS_BUILD
        showsBrowserDetails = browserAutomationSummaryStatus != .granted && !installedBrowsers.isEmpty
        #endif
        showsAppDetails = appAutomationSummaryStatus == .missing
        showsDictationDetails = !(appState.isMicrophoneAuthorized && appState.isSpeechRecognitionAuthorized)
            && (appState.isMicrophoneAuthorized || appState.isSpeechRecognitionAuthorized)
    }
}
