import SwiftUI

#if !MAS_BUILD

struct LicenseView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var licenseKey = ""
    @State private var errorMessage: String?
    @State private var isActivated = false
    @State private var isOpeningCheckout = false

    /// Opens the website's Paddle checkout; the key arrives by email.
    private static let purchaseURL = URL(string: "https://dylblake.dev/remora/buy")!

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
                subtitle: "Your existing notes stay fully available. A license unlocks unlimited new notes — buy one below, or paste the key from your purchase confirmation email."
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
                    .onSubmit(submit)
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

                HStack(spacing: Spacing.md) {
                    licenseButton("Activate", isPrimary: !buyIsPrimary, action: activate)
                        .disabled(licenseKey.isEmpty)

                    licenseButton("Buy a License", isPrimary: buyIsPrimary, action: buy)
                        .accessibilityIdentifier("buyLicenseButton")
                }
            }
        }
    }

    /// At the paywall with nothing typed, buying is the next step, so it
    /// takes the prominent default slot; a typed key hands it to Activate.
    private var buyIsPrimary: Bool {
        appState.isTrialExhausted && licenseKey.isEmpty
    }

    @ViewBuilder
    private func licenseButton(_ title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        if isPrimary {
            Button(title, action: action)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        } else {
            Button(title, action: action)
                .buttonStyle(.glass)
                .controlSize(.large)
        }
    }

    /// Return in the key field: activate what was typed, or buy when the
    /// field is empty at the paywall.
    private func submit() {
        if !licenseKey.isEmpty {
            activate()
        } else if buyIsPrimary {
            buy()
        }
    }

    /// The window floats above the browser, so it steps aside for the
    /// checkout; Activate License in the menu bar brings it back. Return
    /// can reach here through both the field and the default button, so
    /// a second call within the same moment is dropped.
    private func buy() {
        guard !isOpeningCheckout else { return }
        isOpeningCheckout = true
        openURL(Self.purchaseURL)
        appState.dismissLicenseWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            isOpeningCheckout = false
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
