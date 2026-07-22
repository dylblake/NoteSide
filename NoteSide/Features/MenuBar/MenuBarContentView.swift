import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    #if !MAS_BUILD
    @StateObject private var updateChecker = UpdateChecker()
    #endif
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginNeedsApproval: Bool = false

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NoteSide")
                        .font(.title3.weight(.semibold))
                    Text("Leave notes for the app, page, or file you are in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    dismiss()
                    appState.showInfoWindow()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NoteSideTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About NoteSide")
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    dismiss()
                    appState.openAllNotes()
                } label: {
                    Label("View All Notes", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    dismiss()
                    appState.showOnboarding()
                } label: {
                    Label("Permissions & Setup", systemImage: "checklist")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            sectionHeader("Settings")

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Launch on startup", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                Toggle("Auto-generate note titles", isOn: $appState.isAutoTitleEnabled)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)

                if launchAtLoginNeedsApproval {
                    HStack(spacing: 6) {
                        Text("Enable NoteSide in System Settings to allow launch on startup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }

            Divider()

            sectionHeader("Hotkeys")

            VStack(alignment: .leading, spacing: 8) {
                hotkeyRow("Quick Note", displayText: appState.hotkeys.hotKeyDisplayString) { shortcut in
                    appState.hotkeys.setHotKeyShortcut(shortcut)
                }
                hotkeyRow("All Notes", displayText: appState.hotkeys.allNotesHotKeyDisplayString) { shortcut in
                    appState.hotkeys.setAllNotesHotKeyShortcut(shortcut)
                }
                hotkeyRow("Dictation (hold)", displayText: appState.hotkeys.dictationHotKeyDisplayString) { shortcut in
                    appState.hotkeys.setDictationHotKeyShortcut(shortcut)
                }

                Text("Click a shortcut, then press the keys you want.")
                    .font(.caption)
                    .foregroundStyle(NoteSideTheme.tertiaryText)
            }

            if let errorMessage = appState.editor.editorErrorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(NoteSideTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            sectionHeader("Recent")

            if appState.notesState.recentNotes.isEmpty {
                Text("No notes yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(appState.notesState.recentNotes) { note in
                        Button {
                            dismiss()
                            appState.open(note)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.context.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(note.body)
                                    .lineLimit(1)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            if appState.isLicensed {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(NoteSideTheme.success)
                    Text("Licensed")
                        .font(.subheadline)
                        .foregroundStyle(NoteSideTheme.secondaryText)
                    Spacer()
                    #if !MAS_BUILD
                    Button("Deactivate") {
                        appState.deactivateLicense()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(NoteSideTheme.tertiaryText)
                    #endif
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: appState.isTrialExhausted ? "hourglass.bottomhalf.filled" : "hourglass")
                            .foregroundStyle(appState.isTrialExhausted ? NoteSideTheme.warning : NoteSideTheme.secondaryText)
                        Text(trialStatusText)
                            .font(.subheadline)
                            .foregroundStyle(NoteSideTheme.secondaryText)
                    }

                    Button {
                        dismiss()
                        appState.presentLicenseWindow()
                    } label: {
                        #if MAS_BUILD
                        Label("Unlock Unlimited Notes", systemImage: "infinity")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        #else
                        Label("Activate License", systemImage: "key")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
                    }
                    #if MAS_BUILD
                    Button("Restore Purchases") {
                        appState.restorePurchases()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    #endif
                }
            }

            #if !MAS_BUILD
            updateRow
            #endif

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit NoteSide", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { refreshLaunchAtLoginState() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(NoteSideTheme.secondaryText)
    }

    private func hotkeyRow(
        _ title: String,
        displayText: String,
        onRecorded: @escaping (HotKeyShortcut) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)

            Spacer(minLength: 8)

            ShortcutRecorderView(displayText: displayText, onShortcutRecorded: onRecorded)
                .frame(width: 150)
        }
    }

    private var trialStatusText: String {
        if appState.isTrialExhausted {
            return "Trial complete — a license unlocks new notes."
        }
        return "Free trial: \(appState.trialNotesUsed) of \(AppState.trialNoteLimit) notes used."
    }

    private func refreshLaunchAtLoginState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled)
        launchAtLoginNeedsApproval = (status == .requiresApproval)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status != .notRegistered {
                    try service.unregister()
                }
            }
        } catch {
            // Fall through to status reconciliation below.
        }

        let status = service.status
        let actualEnabled = (status == .enabled)
        if launchAtLogin != actualEnabled {
            launchAtLogin = actualEnabled
        }
        launchAtLoginNeedsApproval = (enabled && status == .requiresApproval)
    }

    #if !MAS_BUILD
    @ViewBuilder
    private var updateRow: some View {
        switch updateChecker.state {
        case .idle:
            Button {
                updateChecker.check()
            } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .checking:
            statusRow(
                systemImage: nil,
                tint: nil,
                message: "Checking for updates…",
                showsSpinner: true
            )

        case .upToDate:
            statusRow(
                systemImage: "checkmark.circle.fill",
                tint: NoteSideTheme.success,
                message: "You're up to date (v\(UpdateChecker.currentVersion))",
                showsSpinner: false
            )

        case .updateAvailable(let version, _, let releaseURL):
            VStack(alignment: .leading, spacing: 8) {
                Label("Update Available — v\(version)", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NoteSideTheme.accent)

                Text("You have v\(UpdateChecker.currentVersion). Install the latest version now?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        updateChecker.installUpdate()
                    } label: {
                        Text("Install Update")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        NSWorkspace.shared.open(releaseURL)
                    } label: {
                        Text("Release Notes")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading update…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                        .progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .installing:
            statusRow(
                systemImage: nil,
                tint: nil,
                message: "Installing update — the app will restart…",
                showsSpinner: true
            )

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(NoteSideTheme.warning)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Retry") {
                    updateChecker.check()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(systemImage: String?, tint: Color?, message: String, showsSpinner: Bool) -> some View {
        HStack(spacing: 8) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint ?? NoteSideTheme.secondaryText)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif
}
