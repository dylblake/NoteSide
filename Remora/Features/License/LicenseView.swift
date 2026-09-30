import SwiftUI

#if !MAS_BUILD

struct LicenseView: View {
    @Environment(AppState.self) private var appState
    @State private var licenseKey = ""
    @State private var errorMessage: String?
    @State private var isActivated = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header

                if isActivated {
                    successCard
                } else {
                    licenseCard
                }
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isActivated = false
        }
    }

    @ViewBuilder
    private var header: some View {
        if isActivated {
            PageHeader(title: "You're all set.")
        } else if appState.isTrialExhausted {
            PageHeader(
                title: "Your \(AppState.trialNoteLimit)-note free trial is complete.",
                subtitle: "Your existing notes stay fully available. A license unlocks unlimited new notes — the key is in your purchase confirmation email."
            )
        } else {
            PageHeader(
                title: "Enter your license key.",
                subtitle: "You're on the free trial (\(appState.trialNotesUsed) of \(AppState.trialNoteLimit) notes used) — activate anytime. The key is in your purchase confirmation email."
            )
        }
    }

    private var successCard: some View {
        LicenseSuccessCard(
            title: "License Activated",
            message: "Thank you for purchasing Remora. Use \(appState.hotkeys.hotKeyDisplayString) to start taking notes."
        ) {
            appState.dismissLicenseWindow()
        }
    }

    private var licenseCard: some View {
        TitledCard(title: "License Key", systemImage: "key") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                TextField("Paste your license key…", text: $licenseKey)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(.system(.body, design: .monospaced))
                    .truncationMode(.middle)
                    .onSubmit(activate)
                    .accessibilityIdentifier("licenseKeyField")
                    .onChange(of: licenseKey) { _, newValue in
                        let stripped = newValue
                            .components(separatedBy: .whitespacesAndNewlines)
                            .joined()
                        if stripped != newValue {
                            licenseKey = stripped
                        }
                    }

                if let errorMessage {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(errorMessage)
                    }
                    .font(.subheadline)
                    .foregroundStyle(RemoraTheme.danger)
                }

                HStack {
                    Button("Activate", action: activate)
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(licenseKey.isEmpty)
                }
            }
        }
    }

    private func activate() {
        errorMessage = nil

        do {
            try LicenseValidator.validate(licenseKey)
            LicenseValidator.storeLicenseKey(licenseKey)
            appState.isLicensed = true
            withAnimation(.easeInOut(duration: 0.3)) {
                isActivated = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
