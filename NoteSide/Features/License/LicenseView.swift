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
        .background(background)
        .onAppear {
            isActivated = false
        }
    }

    private var background: some View {
        NoteSideTheme.windowBackground
            .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("NoteSide")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(NoteSideTheme.primaryText)
                .accessibilityAddTraits(.isHeader)

            if isActivated {
                Text("You're all set.")
                    .font(.title3)
                    .foregroundStyle(NoteSideTheme.secondaryText)
            } else if appState.isTrialExhausted {
                Text("Your \(AppState.trialNoteLimit)-note free trial is complete.")
                    .font(.title3)
                    .foregroundStyle(NoteSideTheme.secondaryText)

                Text("Your existing notes stay fully available. A license unlocks unlimited new notes — the key is in your purchase confirmation email.")
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.tertiaryText)
            } else {
                Text("Enter your license key to unlock unlimited notes.")
                    .font(.title3)
                    .foregroundStyle(NoteSideTheme.secondaryText)

                Text("You're on the free trial (\(appState.trialNotesUsed) of \(AppState.trialNoteLimit) notes used) — activate anytime. The key is in your purchase confirmation email.")
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.tertiaryText)
            }
        }
    }

    private var successCard: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(NoteSideTheme.success)

            Text("License Activated")
                .font(.title2.weight(.semibold))
                .foregroundStyle(NoteSideTheme.primaryText)

            Text("Thank you for purchasing NoteSide. Use \(appState.hotkeys.hotKeyDisplayString) to start taking notes.")
                .font(.subheadline)
                .foregroundStyle(NoteSideTheme.secondaryText)
                .multilineTextAlignment(.center)

            Button("Get Started") {
                appState.dismissLicenseWindow()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, Spacing.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.xl)
        .cardSurface(cornerRadius: CornerRadius.sheet)
    }

    private var licenseCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label("License Key", systemImage: "key")
                .font(.headline)
                .foregroundStyle(NoteSideTheme.primaryText)

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
                    .foregroundStyle(NoteSideTheme.danger)
                }

                HStack {
                    Button("Activate", action: activate)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(licenseKey.isEmpty)
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: CornerRadius.sheet)
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
