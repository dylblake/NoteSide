import AppKit
import SwiftUI

/// Guided first-run wizard. The full permissions dashboard
/// (OnboardingView, "Setup") remains the returning-user
/// surface; this is the guided path to the first note.
///
/// Direct build (3 steps): hotkey → connect browser (per-browser
/// Automation) → optional extras.
///
/// MAS build (2 steps): hotkey → permissions. Browsers there are read
/// through Accessibility, the same grant that unlocks Slack/Figma/editor
/// context and dictation — so a dedicated browser step would just ask for
/// the same permission twice. The single permissions step leads with
/// Accessibility and names browser pages among what it unlocks.
struct FirstRunView: View {
    @Environment(AppState.self) private var appState
    @State private var step = 0
    @State private var didOpenDrawer = false

    #if MAS_BUILD
    private static let stepCount = 2
    #else
    private static let stepCount = 3
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    switch step {
                    case 0: hotkeyStep
                    #if MAS_BUILD
                    default: extrasStep
                    #else
                    case 1: browserStep
                    default: extrasStep
                    #endif
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            navigationBar
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.md)
        }
        // +28 over the old content height: with `.fullSizeContentView` the
        // frame includes the (transparent) title bar strip.
        .frame(width: 620, height: 588)
        .onChange(of: appState.editor.isEditorPresented) { _, isPresented in
            if isPresented {
                didOpenDrawer = true
            }
        }
    }

    // MARK: - Step 1: the hotkey

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            stepHeader(
                title: "Try it right now",
                subtitle: "Remora lives behind one shortcut. Press it and the note drawer slides in from the right, attached to whatever you're in — at this moment, that's this window."
            )

            HStack {
                Spacer()
                Text(appState.hotkeys.hotKeyDisplayString)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .padding(.horizontal, Spacing.lg + Spacing.xxs)
                    .padding(.vertical, Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                            .fill(RemoraTheme.glassCardFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                                    .stroke(didOpenDrawer ? RemoraTheme.success : RemoraTheme.border, lineWidth: didOpenDrawer ? 2 : 1)
                            )
                    )
                    .animation(.easeOut(duration: 0.2), value: didOpenDrawer)
                    .accessibilityLabel("Quick note shortcut \(appState.hotkeys.hotKeyDisplayString)")
                Spacer()
            }

            if didOpenDrawer {
                Label {
                    Text("That's the drawer. Press the shortcut again — or Escape — to close it; nothing is saved unless you type.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(RemoraTheme.success)
                }
                .font(.subheadline)
            } else {
                Text("Go ahead — press it now. This screen will notice.")
                    .font(.subheadline)
                    .foregroundStyle(RemoraTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
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
                        Text("Heads up: \(appState.hotkeys.hotKeyDisplayString) is also “New Private Window” in Safari and Chrome. While Remora runs, it wins. Change it here if you use that shortcut.")
                            .font(.caption)
                            .foregroundStyle(RemoraTheme.secondaryText)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(RemoraTheme.warning)
                    }
                }
            }
        }
    }

    // MARK: - Step 2: the browser (direct build only — MAS reads browsers
    // through Accessibility, handled in the permissions step)
    #if !MAS_BUILD

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
        VStack(alignment: .leading, spacing: Spacing.md) {
            stepHeader(
                title: "Connect your browser",
                subtitle: "This is where Remora shines: notes attach to the exact page you're on and reappear when you come back. macOS asks for permission once per browser."
            )

            if let browser = featuredBrowser {
                featuredBrowserCard(browser)
            } else {
                Text("No supported browser found. Remora works with Safari, Chrome, Edge, Brave, Arc, and Vivaldi — install one and grant access later from Setup.")
                    .font(.subheadline)
                    .foregroundStyle(RemoraTheme.secondaryText)
            }

            if !otherInstalledBrowsers.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(otherInstalledBrowsers, id: \.bundleIdentifier) { browser in
                            compactBrowserRow(browser)
                        }
                    }
                    .padding(.top, Spacing.xs)
                } label: {
                    Text("More browsers")
                        .font(.subheadline.weight(.medium))
                }
            }

            Text("You can skip this — notes still attach to the browser app itself, just not to individual pages.")
                .font(.caption)
                .foregroundStyle(RemoraTheme.tertiaryText)
        }
    }

    private func featuredBrowserCard(_ browser: BrowserDescriptor) -> some View {
        let state = appState.browserPermissions.browserPermissionStates[browser.bundleIdentifier] ?? .undetermined

        return HStack(alignment: .center, spacing: Spacing.md) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "globe")
                .font(.system(size: 28))
                .foregroundStyle(state == .granted ? RemoraTheme.success : RemoraTheme.accent)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(browser.title)
                    .font(.headline)
                Text(featuredBrowserDetail(for: state))
                    .font(.subheadline)
                    .foregroundStyle(RemoraTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            browserActionButtons(for: browser.bundleIdentifier, state: state, prominentConnect: true)
        }
        .padding(Spacing.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(
            cornerRadius: CornerRadius.card,
            fill: RemoraTheme.glassCardFill,
            strokeColor: state == .granted ? RemoraTheme.success.opacity(0.5) : nil
        )
    }

    /// Connect / Open Settings / "Connecting…" cluster shared by the featured
    /// card and the compact rows. A granted browser shows nothing; a pending
    /// request shows a disabled "Connecting…" so the click is never invisible;
    /// every other state always offers Open Settings as a working escape hatch,
    /// plus Connect while the browser has never been asked (.undetermined).
    @ViewBuilder
    private func browserActionButtons(
        for bundleIdentifier: String,
        state: BrowserPermissionState,
        prominentConnect: Bool
    ) -> some View {
        if state == .granted {
            EmptyView()
        } else if appState.browserPermissions.isRequestPending(for: bundleIdentifier) {
            PendingLabel(text: "Connecting…")
        } else {
            HStack(spacing: Spacing.xs) {
                if state == .undetermined {
                    wizardButton("Connect", prominent: prominentConnect) {
                        appState.browserPermissions.requestAutomationAccess(for: bundleIdentifier)
                    }
                }
                wizardButton("Open Settings", prominent: false) {
                    appState.browserPermissions.openAutomationSettings()
                }
            }
        }
    }

    private func featuredBrowserDetail(for state: BrowserPermissionState) -> String {
        switch state {
        case .granted:
            return "Connected. Open any page and press \(appState.hotkeys.hotKeyDisplayString)."
        case .notGranted:
            return "Automation is turned off. macOS asks only once — enable Remora in System Settings → Privacy & Security → Automation."
        default:
            return "Your default browser. Connecting opens it and shows the macOS permission prompt."
        }
    }

    private func compactBrowserRow(_ browser: BrowserDescriptor) -> some View {
        let state = appState.browserPermissions.browserPermissionStates[browser.bundleIdentifier] ?? .undetermined

        return HStack(spacing: Spacing.sm) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(state == .granted ? RemoraTheme.success : RemoraTheme.secondaryText)

            Text(browser.title)
                .font(.subheadline)

            Spacer()

            browserActionButtons(for: browser.bundleIdentifier, state: state, prominentConnect: false)
        }
    }

    #endif

    // MARK: - Final step: permissions (MAS) / optional extras (direct)

    private var extrasStep: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            #if MAS_BUILD
            stepHeader(
                title: "Enable Accessibility",
                subtitle: "One permission unlocks it all — reading the current browser page, plus context inside Slack, Figma, and code editors. Dictation and Finder/Xcode below are optional."
            )
            #else
            stepHeader(
                title: "Optional extras",
                subtitle: "Everything here can wait — grant these when you need them, from the menu bar icon → Setup."
            )
            #endif

            extraRow(
                icon: "figure.wave",
                granted: appState.isAccessibilityTrusted,
                title: "Accessibility",
                detail: accessibilityRowDetail,
                buttonTitle: appState.isAccessibilityTrusted ? nil : "Enable",
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
                buttonTitle: "Open Setup",
                action: { appState.showOnboarding() }
            )

            if !appState.isLicensed {
                Divider()

                Label {
                    Text(trialFooterText)
                        .font(.subheadline)
                        .foregroundStyle(RemoraTheme.secondaryText)
                } icon: {
                    Image(systemName: "hourglass")
                        .foregroundStyle(RemoraTheme.accent)
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

    /// Accessibility row copy. On MAS it leads with browser pages (that
    /// grant is how browsers are read there) and notes the "＋ add Remora"
    /// fallback in case the row isn't auto-listed in System Settings.
    private var accessibilityRowDetail: String {
        if appState.isAccessibilityTrusted {
            #if MAS_BUILD
            return "Enabled. Remora reads the current browser page and detects Slack, Figma, and editor context."
            #else
            return "Enabled. Remora detects context inside Slack, Figma, and code editors, and powers dictation's hold-to-release."
            #endif
        }
        #if MAS_BUILD
        return "Reads the current browser page and detects Slack, Figma, and editor context. Click Enable, then turn Remora on in System Settings — if it isn't listed, use the ＋ button to add it. This updates on its own."
        #else
        return "Detects context inside Slack, Figma, and code editors, and powers dictation's hold-to-release. Click Enable, then turn Remora on in System Settings — if it isn't listed, use the ＋ button to add it. This updates on its own."
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
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: showsStatusIcon && granted ? "checkmark.circle.fill" : icon)
                .font(.title3)
                .foregroundStyle(showsStatusIcon && granted ? RemoraTheme.success : RemoraTheme.secondaryText)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(RemoraTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let buttonTitle, let action {
                wizardButton(buttonTitle, prominent: false, action: action)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetRowSurface(fill: RemoraTheme.glassInsetRowFill)
    }

    // MARK: - Shared pieces

    private func stepHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionHeader(title: "Welcome to Remora")

            Text(title)
                .font(.title.weight(.bold))
                .foregroundStyle(RemoraTheme.primaryText)
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(RemoraTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var navigationBar: some View {
        HStack(spacing: Spacing.md) {
            if step > 0 {
                Button("Back") {
                    step -= 1
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            HStack(spacing: Spacing.xs) {
                ForEach(0..<Self.stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == step ? RemoraTheme.accent : RemoraTheme.border)
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

    @ViewBuilder
    private func wizardButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(title, action: action)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        } else {
            Button(title, action: action)
                .buttonStyle(.glass)
                .controlSize(.regular)
        }
    }
}
