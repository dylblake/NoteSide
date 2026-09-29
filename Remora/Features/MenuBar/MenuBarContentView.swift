import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Menu bar popover. Primary actions and recent notes up top, settings
/// and hotkeys always visible beneath them, license and update status at
/// the bottom.
struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    #if !MAS_BUILD
    @StateObject private var updateChecker = UpdateChecker()
    #endif
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginNeedsApproval: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            header

            VStack(alignment: .leading, spacing: Spacing.xs) {
                menuButton("View All Notes", systemImage: "square.grid.2x2", shortcut: appState.hotkeys.allNotesHotKeyDisplayString) {
                    dismiss()
                    appState.openAllNotes()
                }
                menuButton("New Note Here", systemImage: "square.and.pencil", shortcut: appState.hotkeys.hotKeyDisplayString) {
                    dismiss()
                    appState.toggleQuickNote()
                }
            }

            if let errorMessage = appState.editor.editorErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(RemoraTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            recentSection

            Divider()

            settingsSection

            Divider()

            licenseSection

            #if !MAS_BUILD
            updateRow
            #endif

            Divider()

            HStack(spacing: Spacing.xs) {
                menuButton("Permissions & Setup", systemImage: "checklist") {
                    dismiss()
                    appState.showOnboarding()
                }
                menuButton("Quit", systemImage: "power") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(Spacing.md)
        .frame(width: 340)
        .onAppear { refreshLaunchAtLoginState() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remora")
                    .font(.headline)
                Text("Notes for the app, page, or file you're in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                dismiss()
                appState.showInfoWindow()
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .foregroundStyle(RemoraTheme.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("About Remora")
            .accessibilityLabel("About Remora")
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeader("Recent")

            if appState.notesState.recentNotes.isEmpty {
                Text("No notes yet. Press \(appState.hotkeys.hotKeyDisplayString) in any app to write one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(appState.notesState.recentNotes) { note in
                        RecentNoteRow(note: note) {
                            dismiss()
                            appState.open(note)
                        }
                    }
                }
            }
        }
    }

    /// Settings and hotkeys stay visible; the popover is the one place
    /// to check or change a shortcut, so hiding them costs more than the
    /// height saves.
    private var settingsSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                sectionHeader("Settings")

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                Toggle("Generate note titles automatically", isOn: $appState.isAutoTitleEnabled)

                if launchAtLoginNeedsApproval {
                    HStack(spacing: Spacing.xs - 2) {
                        Text("Approve Remora in System Settings to launch at login.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .font(.subheadline)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                sectionHeader("Hotkeys")
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
                    .foregroundStyle(RemoraTheme.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private var licenseSection: some View {
        if appState.isLicensed {
            HStack(spacing: Spacing.xs - 2) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(RemoraTheme.success)
                Text("Licensed")
                    .font(.subheadline)
                    .foregroundStyle(RemoraTheme.secondaryText)
                Spacer()
                #if !MAS_BUILD
                Button("Deactivate") {
                    appState.deactivateLicense()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(RemoraTheme.tertiaryText)
                #endif
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs - 2) {
                    Image(systemName: appState.isTrialExhausted ? "hourglass.bottomhalf.filled" : "hourglass")
                        .foregroundStyle(appState.isTrialExhausted ? RemoraTheme.warning : RemoraTheme.secondaryText)
                    Text(trialStatusText)
                        .font(.subheadline)
                        .foregroundStyle(RemoraTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Spacing.xs) {
                    Button {
                        dismiss()
                        appState.presentLicenseWindow()
                    } label: {
                        #if MAS_BUILD
                        Label("Unlock Unlimited Notes", systemImage: "infinity")
                        #else
                        Label("Activate License", systemImage: "key")
                        #endif
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    #if MAS_BUILD
                    Button("Restore Purchases") {
                        appState.restorePurchases()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    #endif
                }
            }
        }
    }

    // MARK: Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(RemoraTheme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private func menuButton(_ title: String, systemImage: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }

    private func hotkeyRow(
        _ title: String,
        displayText: String,
        onRecorded: @escaping (HotKeyShortcut) -> Void
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(title)
                .font(.subheadline)

            Spacer(minLength: Spacing.xs)

            ShortcutRecorderView(displayText: displayText, onShortcutRecorded: onRecorded)
                .frame(width: 140)
        }
    }

    private var trialStatusText: String {
        if appState.isTrialExhausted {
            return "Trial complete. A license unlocks new notes."
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
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

        case .checking:
            statusRow(systemImage: nil, tint: nil, message: "Checking for updates…", showsSpinner: true)

        case .upToDate:
            statusRow(
                systemImage: "checkmark.circle.fill",
                tint: RemoraTheme.success,
                message: "Up to date (v\(UpdateChecker.currentVersion))",
                showsSpinner: false
            )

        case .updateAvailable(let version, _, let releaseURL):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("Update available: v\(version)", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RemoraTheme.accent)

                Text("You have v\(UpdateChecker.currentVersion).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: Spacing.xs) {
                    Button("Install Update") {
                        updateChecker.installUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Release Notes") {
                        NSWorkspace.shared.open(releaseURL)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: Spacing.xs - 2) {
                HStack(spacing: Spacing.xs) {
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
            statusRow(systemImage: nil, tint: nil, message: "Installing update. The app will restart…", showsSpinner: true)

        case .failed(let message):
            HStack(spacing: Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(RemoraTheme.warning)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Retry") {
                    updateChecker.check()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(systemImage: String?, tint: Color?, message: String, showsSpinner: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint ?? RemoraTheme.secondaryText)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif
}

/// A recent note: title line plus one-line preview, with a hover
/// highlight so it reads as a row rather than loose text.
private struct RecentNoteRow: View {
    let note: ContextNote
    let action: () -> Void
    @State private var isHovered = false

    private var title: String {
        if let title = note.title, !title.isEmpty { return title }
        return note.context.displayName
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(note.body.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs + 1)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.control - 2, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Open note \(title)")
    }
}
