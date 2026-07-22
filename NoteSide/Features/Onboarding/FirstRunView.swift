import AppKit
import SwiftUI

/// Three-step first-run wizard. The full permissions dashboard
/// (OnboardingView, "Permissions & Setup") remains the returning-user
/// surface; this is the guided path to the first note:
///   1. Press the hotkey and feel the drawer (plus shortcut conflicts)
///   2. Connect the default browser (the core value for most users)
///   3. Optional extras and the trial expectation
struct FirstRunView: View {
    @Environment(AppState.self) private var appState
    @State private var step = 0
    @State private var didOpenDrawer = false

    private static let stepCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case 0: hotkeyStep
                    case 1: browserStep
                    default: extrasStep
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            navigationBar
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
        .frame(width: 620, height: 560)
        .background(background)
        .onChange(of: appState.editor.isEditorPresented) { _, isPresented in
            if isPresented {
                didOpenDrawer = true
            }
        }
    }

    private var background: some View {
        ZStack {
            Rectangle().fill(NoteSideTheme.windowBackground)
            Rectangle().fill(.regularMaterial)
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

    // MARK: - Step 1: the hotkey

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(
                title: "Try it right now",
                subtitle: "NoteSide lives behind one shortcut. Press it and the note drawer slides in from the right, attached to whatever you're in — at this moment, that's this window."
            )

            HStack {
                Spacer()
                Text(appState.hotkeys.hotKeyDisplayString)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(NoteSideTheme.contentBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(didOpenDrawer ? NoteSideTheme.success : NoteSideTheme.border, lineWidth: didOpenDrawer ? 2 : 1)
                            )
                    )
                Spacer()
            }

            if didOpenDrawer {
                Label {
                    Text("That's the drawer. Press the shortcut again — or Escape — to close it; nothing is saved unless you type.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NoteSideTheme.success)
                }
                .font(.subheadline)
            } else {
                Text("Go ahead — press it now. This screen will notice.")
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Prefer a different shortcut?")
                        .font(.subheadline)
                    Spacer()
                    ShortcutRecorderView(displayText: appState.hotkeys.hotKeyDisplayString) { shortcut in
                        appState.hotkeys.setHotKeyShortcut(shortcut)
                    }
                    .frame(width: 150)
                }

                if appState.hotkeys.hotKeyShortcut == .default {
                    Label {
                        Text("Heads up: \(appState.hotkeys.hotKeyDisplayString) is also “New Private Window” in Safari and Chrome. While NoteSide runs, it wins. Change it here if you use that shortcut.")
                            .font(.caption)
                            .foregroundStyle(NoteSideTheme.secondaryText)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(NoteSideTheme.warning)
                    }
                }
            }
        }
    }

    // MARK: - Step 2: the browser

    private var featuredBrowser: BrowserDescriptor? {
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://www.example.com")!),
           let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
           let match = BrowserPermissionsState.supportedBrowsers.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return match
        }
        // Default browser unsupported (or undetectable): fall back to the
        // first supported browser that's actually installed.
        return BrowserPermissionsState.supportedBrowsers.first { browser in
            let state = appState.browserPermissions.browserPermissionStates[browser.bundleIdentifier]
            return state != nil && state != .notInstalled
        }
    }

    private var otherInstalledBrowsers: [BrowserDescriptor] {
        BrowserPermissionsState.supportedBrowsers.filter { browser in
            guard browser.bundleIdentifier != featuredBrowser?.bundleIdentifier else { return false }
            let state = appState.browserPermissions.browserPermissionStates[browser.bundleIdentifier]
            return state != nil && state != .notInstalled
        }
    }

    private var browserStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepHeader(
                title: "Connect your browser",
                subtitle: "This is where NoteSide shines: notes attach to the exact page you're on and reappear when you come back. macOS asks for permission once per browser."
            )

            if let browser = featuredBrowser {
                featuredBrowserCard(browser)
            } else {
                Text("No supported browser found. NoteSide works with Safari, Chrome, Edge, Brave, Arc, and Vivaldi — install one and grant access later from Permissions & Setup.")
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.secondaryText)
            }

            if !otherInstalledBrowsers.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(otherInstalledBrowsers, id: \.bundleIdentifier) { browser in
                            compactBrowserRow(browser)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("More browsers")
                        .font(.subheadline.weight(.medium))
                }
            }

            Text("You can skip this — notes still attach to the browser app itself, just not to individual pages.")
                .font(.caption)
                .foregroundStyle(NoteSideTheme.tertiaryText)
        }
    }

    private func featuredBrowserCard(_ browser: BrowserDescriptor) -> some View {
        let state = appState.browserPermissions.browserPermissionStates[browser.bundleIdentifier] ?? .undetermined

        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "globe")
                .font(.system(size: 28))
                .foregroundStyle(state == .granted ? NoteSideTheme.success : NoteSideTheme.accent)

            VStack(alignment: .leading, spacing: 3) {
                Text(browser.title)
                    .font(.headline)
                Text(featuredBrowserDetail(for: state))
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if state == .notGranted {
                wizardButton("Open Settings", prominent: false) {
                    appState.browserPermissions.openAutomationSettings()
                }
            } else if state != .granted {
                wizardButton("Connect", prominent: true) {
                    appState.browserPermissions.requestAutomationAccess(for: browser.bundleIdentifier)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(NoteSideTheme.contentBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(state == .granted ? NoteSideTheme.success.opacity(0.5) : NoteSideTheme.border.opacity(0.8), lineWidth: 1)
                )
        )
    }

    private func featuredBrowserDetail(for state: BrowserPermissionState) -> String {
        switch state {
        case .granted:
            return "Connected. Open any page and press \(appState.hotkeys.hotKeyDisplayString)."
        case .notGranted:
            return "Automation is turned off. macOS asks only once — enable NoteSide in System Settings → Privacy & Security → Automation."
        default:
            return "Your default browser. Connecting opens it and shows the macOS permission prompt."
        }
    }

    private func compactBrowserRow(_ browser: BrowserDescriptor) -> some View {
        let state = appState.browserPermissions.browserPermissionStates[browser.bundleIdentifier] ?? .undetermined

        return HStack(spacing: 10) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(state == .granted ? NoteSideTheme.success : NoteSideTheme.secondaryText)

            Text(browser.title)
                .font(.subheadline)

            Spacer()

            if state == .notGranted {
                wizardButton("Open Settings", prominent: false) {
                    appState.browserPermissions.openAutomationSettings()
                }
            } else if state != .granted {
                wizardButton("Connect", prominent: false) {
                    appState.browserPermissions.requestAutomationAccess(for: browser.bundleIdentifier)
                }
            }
        }
    }

    // MARK: - Step 3: extras

    private var extrasStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                title: "Optional extras",
                subtitle: "Everything here can wait — grant these when you need them, from the menu bar icon → Permissions & Setup."
            )

            extraRow(
                icon: "figure.wave",
                granted: appState.isAccessibilityTrusted,
                title: "Accessibility",
                detail: "Detects context inside Slack, Figma, and code editors, and powers dictation's hold-to-release. After enabling it in System Settings, come back — this updates on its own.",
                buttonTitle: appState.isAccessibilityTrusted ? nil : "Request Access",
                action: appState.isAccessibilityTrusted ? nil : { appState.openAccessibilitySettings() }
            )

            extraRow(
                icon: "waveform",
                granted: appState.isMicrophoneAuthorized && appState.isSpeechRecognitionAuthorized,
                title: "Voice dictation",
                detail: "Hold \(appState.hotkeys.dictationHotKeyDisplayString) in a note to dictate, release to insert. Uses the microphone and on-device speech recognition.",
                buttonTitle: (appState.isMicrophoneAuthorized && appState.isSpeechRecognitionAuthorized) ? nil : "Enable",
                action: (appState.isMicrophoneAuthorized && appState.isSpeechRecognitionAuthorized) ? nil : { appState.requestDictationPermissionsIfNeeded() }
            )

            extraRow(
                icon: "folder",
                granted: false,
                showsStatusIcon: false,
                title: "Finder & Xcode",
                detail: "Attach notes to folders and source files. Uses the same one-time Automation permission as browsers.",
                buttonTitle: "Permissions & Setup",
                action: { appState.showOnboarding() }
            )

            if !appState.isLicensed {
                Divider()

                Label {
                    Text(trialFooterText)
                        .font(.subheadline)
                        .foregroundStyle(NoteSideTheme.secondaryText)
                } icon: {
                    Image(systemName: "hourglass")
                        .foregroundStyle(NoteSideTheme.accent)
                }
            }
        }
    }

    private var trialFooterText: String {
        #if MAS_BUILD
        "You're on the free trial — your first \(AppState.trialNoteLimit) notes are on us. Unlocking unlimited notes is a one-time purchase, and everything you write stays yours either way."
        #else
        "You're on the free trial — your first \(AppState.trialNoteLimit) notes are on us. Everything you write stays yours either way; a license just unlocks unlimited new notes."
        #endif
    }

    private func extraRow(
        icon: String,
        granted: Bool,
        showsStatusIcon: Bool = true,
        title: String,
        detail: String,
        buttonTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: showsStatusIcon && granted ? "checkmark.circle.fill" : icon)
                .font(.title3)
                .foregroundStyle(showsStatusIcon && granted ? NoteSideTheme.success : NoteSideTheme.secondaryText)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(NoteSideTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let buttonTitle, let action {
                wizardButton(buttonTitle, prominent: false, action: action)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(NoteSideTheme.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(NoteSideTheme.border.opacity(0.7), lineWidth: 1)
                )
        )
    }

    // MARK: - Shared pieces

    private func stepHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to NoteSide")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.7)
                .foregroundStyle(NoteSideTheme.secondaryText)

            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(NoteSideTheme.primaryText)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(NoteSideTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 16) {
            if step > 0 {
                Button("Back") {
                    step -= 1
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<Self.stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == step ? NoteSideTheme.accent : NoteSideTheme.border)
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityLabel("Step \(step + 1) of \(Self.stepCount)")

            Spacer()

            wizardButton(step == Self.stepCount - 1 ? "Start Taking Notes" : "Continue", prominent: true) {
                if step == Self.stepCount - 1 {
                    appState.completeOnboarding()
                } else {
                    step += 1
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func wizardButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: prominent ? .semibold : .medium, design: .rounded))
                .foregroundStyle(prominent ? Color.white : NoteSideTheme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(prominent ? AnyShapeStyle(NoteSideTheme.accent) : AnyShapeStyle(NoteSideTheme.contentBackground))
                )
        }
        .buttonStyle(.plain)
    }
}
