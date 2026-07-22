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
        case .pending: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .granted: return NoteSideTheme.success
        case .missing: return NoteSideTheme.danger
        case .pending: return NoteSideTheme.secondaryText
        }
    }
}

struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                hotkeyCard
                permissionsCard
                completionFooter
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }

    private var background: some View {
        ZStack {
            Rectangle()
                .fill(NoteSideTheme.windowBackground)

            Rectangle()
                .fill(.regularMaterial)

            LinearGradient(
                colors: [
                    NoteSideTheme.accent.opacity(0.06),
                    Color.clear,
                    NoteSideTheme.warning.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NoteSide")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(NoteSideTheme.primaryText)

            Text("Context-aware notes that stay attached to the app, site, or file you are actually in.")
                .font(.title3)
                .foregroundStyle(NoteSideTheme.secondaryText)

            Text("Use `\(appState.hotkeys.hotKeyDisplayString)` to open the right-side note pane from anywhere.")
                .font(.subheadline)
                .foregroundStyle(NoteSideTheme.tertiaryText)
        }
    }

    private var hotkeyCard: some View {
        onboardingCard(title: "How it works", systemImage: "keyboard") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Switch to any app, browser tab, or file.")
                        Text("2. Press `\(appState.hotkeys.hotKeyDisplayString)` to open a note for that context.")
                        Text("3. Type your note and press the hotkey again to save.")
                        Text("4. Press `\(appState.hotkeys.allNotesHotKeyDisplayString)` to view all your notes in a panel.")
                        Text("5. Hold `\(appState.hotkeys.dictationHotKeyDisplayString)` to dictate — release to insert text.")
                        Text("6. Add #tags to organize notes across contexts.")
                        Text("7. Notes are automatically titled using on-device AI.")
                    }

                    Spacer(minLength: 16)

                    VStack(spacing: 10) {
                        primaryButton("Open a Context Note") {
                            appState.toggleQuickNote()
                        }

                        primaryButton("Open All Notes") {
                            appState.toggleAllNotesPanel()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .font(.body)
            .foregroundStyle(NoteSideTheme.primaryText)
        }
    }

    private var permissionsCard: some View {
        onboardingCard(title: "Permissions", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: 16) {
                Text("The global hotkeys work out of the box. Accessibility unlocks in-app context detection (Slack, Figma, code editors) and dictation. Microphone and Speech Recognition enable voice-to-text dictation (optional).")
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.secondaryText)

                permissionStatusRow(
                    title: "Accessibility",
                    detail: appState.isAccessibilityTrusted
                        ? "Enabled. NoteSide can detect in-app context (Slack channels, Figma files, editor documents) and dictation release."
                        : "Not enabled. Needed for Slack/Figma/editor context detection and dictation. Click Request Access, then enable NoteSide in macOS Accessibility settings.",
                    status: appState.isAccessibilityTrusted ? .granted : .missing,
                    buttonTitle: appState.isAccessibilityTrusted ? nil : "Request Access",
                    action: appState.isAccessibilityTrusted ? nil : { [appState] in appState.openAccessibilitySettings() }
                )

                permissionStatusRow(
                    title: "Browser Automation",
                    detail: "Request access per browser below. macOS will ask the first time NoteSide tries to read that browser's active tab.",
                    status: browserAutomationSummaryStatus,
                    buttonTitle: browserAutomationSummaryStatus == .missing ? "Open Settings" : nil,
                    action: browserAutomationSummaryStatus == .missing ? { [appState] in appState.browserPermissions.openAutomationSettings() } : nil
                )

                Text(appState.browserPermissions.browserAutomationMessage)
                    .font(.footnote)
                    .foregroundStyle(NoteSideTheme.secondaryText)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Supported Browser Requests")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NoteSideTheme.primaryText)

                    ForEach(installedBrowsers, id: \.bundleIdentifier) { browser in
                        browserRequestRow(title: browser.title, bundleIdentifier: browser.bundleIdentifier)
                    }
                }

                appAutomationSection

                dictationPermissionsSection
            }
        }
    }

    private var appAutomationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 4)

            Text("App Automation")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NoteSideTheme.primaryText)

            Text("Finder and Xcode use the same per-app Automation permission as browsers. Without it, notes over these apps attach to the app itself instead of the folder or file you're in.")
                .font(.footnote)
                .foregroundStyle(NoteSideTheme.secondaryText)

            ForEach(installedAppAutomationTargets, id: \.bundleIdentifier) { target in
                appAutomationRow(for: target)
            }
        }
    }

    private var installedAppAutomationTargets: [AppAutomationTarget] {
        BrowserPermissionsState.appAutomationTargets.filter { target in
            guard let state = appState.browserPermissions.appAutomationStates[target.bundleIdentifier] else {
                return false
            }
            return state != .notInstalled
        }
    }

    private func appAutomationRow(for target: AppAutomationTarget) -> some View {
        let status = appState.browserPermissions.appAutomationStates[target.bundleIdentifier] ?? .notInstalled

        return HStack(alignment: .top, spacing: 12) {
            browserStatusIcon(for: status)

            VStack(alignment: .leading, spacing: 4) {
                Text(target.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NoteSideTheme.primaryText)

                Text(target.purpose)
                    .font(.footnote)
                    .foregroundStyle(NoteSideTheme.secondaryText)

                Text(browserStatusText(for: status))
                    .font(.footnote)
                    .foregroundStyle(NoteSideTheme.tertiaryText)
            }

            Spacer(minLength: 12)

            if status == .undetermined {
                secondaryButton("Request Access") {
                    appState.browserPermissions.requestAppAutomationAccess(for: target)
                }
            } else if status == .notGranted {
                secondaryButton("Open Settings") {
                    appState.browserPermissions.openAutomationSettings()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(NoteSideTheme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(NoteSideTheme.border.opacity(0.75), lineWidth: 1)
                )
        )
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

    private var dictationPermissionsSection: some View {
        let micDetail: String = appState.isMicrophoneAuthorized
            ? "Enabled. NoteSide can capture audio for dictation."
            : "Not enabled. Required for voice-to-text dictation in notes."
        let micButton: String? = appState.isMicrophoneAuthorized ? nil : "Request Access"
        let micAction: (() -> Void)? = appState.isMicrophoneAuthorized ? nil : { [appState] in appState.requestMicrophoneAccess() }

        let speechDetail: String = appState.isSpeechRecognitionAuthorized
            ? "Enabled. On-device speech recognition is available."
            : "Not enabled. Required for converting speech to text."
        let speechButton: String? = appState.isSpeechRecognitionAuthorized ? nil : "Request Access"
        let speechAction: (() -> Void)? = appState.isSpeechRecognitionAuthorized ? nil : { [appState] in appState.requestSpeechRecognitionAccess() }

        return VStack(alignment: .leading, spacing: 16) {
            Divider()
                .padding(.vertical, 4)

            Text("Voice-to-Text Dictation")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NoteSideTheme.primaryText)

            permissionStatusRow(
                title: "Microphone",
                detail: micDetail,
                status: appState.isMicrophoneAuthorized ? .granted : .missing,
                buttonTitle: micButton,
                action: micAction
            )

            permissionStatusRow(
                title: "Speech Recognition",
                detail: speechDetail,
                status: appState.isSpeechRecognitionAuthorized ? .granted : .missing,
                buttonTitle: speechButton,
                action: speechAction
            )
        }
    }

    private var completionFooter: some View {
        HStack {
            Text("You can reopen this window anytime from the menu bar icon → Permissions & Setup.")
                .font(.footnote)
                .foregroundStyle(NoteSideTheme.tertiaryText)

            Spacer(minLength: 16)

            primaryButton(appState.hasCompletedOnboarding ? "Done" : "Get Started") {
                appState.completeOnboarding()
            }
        }
    }

    private func onboardingCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(NoteSideTheme.primaryText)

            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(NoteSideTheme.contentBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(NoteSideTheme.border.opacity(0.8), lineWidth: 1)
                )
        )
    }

    private func permissionStatusRow(
        title: String,
        detail: String,
        status: PermissionRowStatus,
        buttonTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: status.symbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(status.color)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NoteSideTheme.primaryText)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.secondaryText)
            }

            Spacer(minLength: 12)

            if let buttonTitle, let action {
                secondaryButton(buttonTitle, action: action)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NoteSideTheme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(NoteSideTheme.border.opacity(0.75), lineWidth: 1)
                )
        )
    }

    private var installedBrowsers: [BrowserDescriptor] {
        AppState.supportedBrowsers.filter { browser in
            // Only show browsers that have been attempted (have a state) and are not marked as notInstalled
            if let state = appState.browserPermissions.browserPermissionStates[browser.bundleIdentifier] {
                return state != .notInstalled
            }
            return false
        }
    }

    private func browserRequestRow(title: String, bundleIdentifier: String) -> some View {
        let status = appState.browserPermissions.browserPermissionStates[bundleIdentifier] ?? .notInstalled

        return HStack(alignment: .top, spacing: 12) {
            browserStatusIcon(for: status)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NoteSideTheme.primaryText)

                Text(browserStatusText(for: status))
                    .font(.footnote)
                    .foregroundStyle(NoteSideTheme.secondaryText)
            }

            Spacer(minLength: 12)

            if status == .undetermined {
                secondaryButton("Request Access") {
                    appState.browserPermissions.requestAutomationAccess(for: bundleIdentifier)
                }
            } else if status == .notGranted {
                // macOS won't re-prompt after a denial — the only path
                // back is the Automation pane in System Settings.
                secondaryButton("Open Settings") {
                    appState.browserPermissions.openAutomationSettings()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(NoteSideTheme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(NoteSideTheme.border.opacity(0.75), lineWidth: 1)
                )
        )
    }

    private func browserStatusIcon(for status: BrowserPermissionState) -> some View {
        Image(systemName: browserStatusSymbol(for: status))
            .font(.title3.weight(.semibold))
            .foregroundStyle(browserStatusColor(for: status))
            .padding(.top, 2)
    }

    private func browserStatusSymbol(for status: BrowserPermissionState) -> String {
        switch status {
        case .granted:
            return "checkmark.circle.fill"
        case .notGranted:
            return "xmark.circle.fill"
        case .undetermined:
            return "questionmark.circle"
        case .notInstalled:
            return "circle"
        }
    }

    private func browserStatusColor(for status: BrowserPermissionState) -> Color {
        switch status {
        case .granted:
            return NoteSideTheme.success
        case .notGranted:
            return NoteSideTheme.danger
        case .undetermined:
            return NoteSideTheme.secondaryText
        case .notInstalled:
            return NoteSideTheme.quaternaryText
        }
    }

    private func browserStatusText(for status: BrowserPermissionState) -> String {
        switch status {
        case .granted:
            return "Installed and automation access is enabled."
        case .notGranted:
            return "Automation is turned off. macOS asks only once — enable NoteSide in System Settings → Privacy & Security → Automation."
        case .undetermined:
            return "Installed. Automation access hasn't been requested yet — macOS will ask when you request it."
        case .notInstalled:
            return "Not installed on this Mac."
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(NoteSideTheme.accent)
                )
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(NoteSideTheme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(NoteSideTheme.contentBackground)
                )
        }
        .buttonStyle(.plain)
    }
}
