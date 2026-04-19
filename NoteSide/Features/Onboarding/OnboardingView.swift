import AppKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                hotkeyCard
                permissionsCard
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

            Text("Use `\(appState.hotKeyDisplayString)` to open the right-side note pane from anywhere.")
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
                        Text("2. Press `\(appState.hotKeyDisplayString)` to open a note for that context.")
                        Text("3. Type your note and press the hotkey again to save.")
                        Text("4. Press `\(appState.allNotesHotKeyDisplayString)` to view all your notes in a panel.")
                        Text("5. Hold `\(appState.dictationHotKeyDisplayString)` to dictate — release to insert text.")
                        Text("6. Add #tags to organize notes across contexts.")
                        Text("7. Notes are automatically titled using on-device AI.")
                    }

                    Spacer(minLength: 16)

                    VStack(spacing: 10) {
                        primaryButton("Open a Context Note") {
                            Task {
                                await appState.toggleQuickNote()
                            }
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
                Text("Accessibility is required for the global hotkey and context capture. Microphone and Speech Recognition enable voice-to-text dictation (optional).")
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.secondaryText)

                permissionStatusRow(
                    title: "Accessibility",
                    detail: appState.isAccessibilityTrusted
                        ? "Enabled. NoteSide can listen for the global shortcut."
                        : "Not enabled. Click Request Access, then enable NoteSide in macOS Accessibility settings.",
                    isGranted: appState.isAccessibilityTrusted,
                    buttonTitle: "Request Access",
                    action: appState.openAccessibilitySettings
                )

                permissionStatusRow(
                    title: "Browser Automation",
                    detail: "Request access per browser below. macOS will ask the first time NoteSide tries to read that browser's active tab.",
                    isGranted: !installedBrowsers.isEmpty && installedBrowsers.allSatisfy { browser in
                        appState.browserPermissionStates[browser.bundleIdentifier] == .granted
                    },
                    buttonTitle: "Open Settings",
                    action: appState.openAutomationSettings
                )

                Text(appState.browserAutomationMessage)
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

                dictationPermissionsSection
            }
        }
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
                isGranted: appState.isMicrophoneAuthorized,
                buttonTitle: micButton,
                action: micAction
            )

            permissionStatusRow(
                title: "Speech Recognition",
                detail: speechDetail,
                isGranted: appState.isSpeechRecognitionAuthorized,
                buttonTitle: speechButton,
                action: speechAction
            )
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
        isGranted: Bool,
        buttonTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(
                    isGranted
                        ? NoteSideTheme.success
                        : NoteSideTheme.danger
                )
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
            if let state = appState.browserPermissionStates[browser.bundleIdentifier] {
                return state != .notInstalled
            }
            return false
        }
    }

    private func browserRequestRow(title: String, bundleIdentifier: String) -> some View {
        let status = appState.browserPermissionStates[bundleIdentifier] ?? .notInstalled

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

            if status == .notGranted {
                secondaryButton("Request Access") {
                    appState.requestAutomationAccess(for: bundleIdentifier)
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

    private func browserStatusIcon(for status: AppState.BrowserPermissionState) -> some View {
        Image(systemName: browserStatusSymbol(for: status))
            .font(.title3.weight(.semibold))
            .foregroundStyle(browserStatusColor(for: status))
            .padding(.top, 2)
    }

    private func browserStatusSymbol(for status: AppState.BrowserPermissionState) -> String {
        switch status {
        case .granted:
            return "checkmark.circle.fill"
        case .notGranted:
            return "xmark.circle.fill"
        case .notInstalled:
            return "circle"
        }
    }

    private func browserStatusColor(for status: AppState.BrowserPermissionState) -> Color {
        switch status {
        case .granted:
            return NoteSideTheme.success
        case .notGranted:
            return NoteSideTheme.danger
        case .notInstalled:
            return NoteSideTheme.quaternaryText
        }
    }

    private func browserStatusText(for status: AppState.BrowserPermissionState) -> String {
        switch status {
        case .granted:
            return "Installed and automation access is enabled."
        case .notGranted:
            return "Installed, but automation access is not enabled yet."
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
