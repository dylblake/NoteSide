import SwiftUI

struct LicenseView: View {
    @EnvironmentObject private var appState: AppState
    @State private var licenseKey = ""
    @State private var errorMessage: String?
    @State private var isActivated = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if isActivated {
                    successCard
                } else {
                    licenseCard
                }
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
                    NoteSideTheme.warning.opacity(0.04),
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

            if isActivated {
                Text("You're all set.")
                    .font(.title3)
                    .foregroundStyle(NoteSideTheme.secondaryText)
            } else {
                Text("Enter your license key to get started.")
                    .font(.title3)
                    .foregroundStyle(NoteSideTheme.secondaryText)

                Text("You received this key in your purchase confirmation email.")
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.tertiaryText)
            }
        }
    }

    private var successCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(NoteSideTheme.success)

            Text("License Activated")
                .font(.title2.weight(.semibold))
                .foregroundStyle(NoteSideTheme.primaryText)

            Text("Thank you for purchasing NoteSide. Use \(appState.hotKeyDisplayString) to start taking notes.")
                .font(.subheadline)
                .foregroundStyle(NoteSideTheme.secondaryText)
                .multilineTextAlignment(.center)

            Button {
                appState.dismissLicenseWindow()
            } label: {
                Text("Get Started")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(NoteSideTheme.accent)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(NoteSideTheme.contentBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(NoteSideTheme.border.opacity(0.8), lineWidth: 1)
                )
        )
    }

    private var licenseCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("License Key", systemImage: "key")
                .font(.headline)
                .foregroundStyle(NoteSideTheme.primaryText)

            VStack(alignment: .leading, spacing: 16) {
                TextField("Paste your license key…", text: $licenseKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(NoteSideTheme.primaryText)
                    .padding(12)
                    .truncationMode(.middle)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(NoteSideTheme.secondaryBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(NoteSideTheme.border, lineWidth: 1)
                            )
                    )
                    .onChange(of: licenseKey) { _, newValue in
                        let stripped = newValue
                            .components(separatedBy: .whitespacesAndNewlines)
                            .joined()
                        if stripped != newValue {
                            licenseKey = stripped
                        }
                    }

                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(errorMessage)
                    }
                    .font(.subheadline)
                    .foregroundStyle(NoteSideTheme.danger)
                }

                HStack {
                    Button(action: activate) {
                        Text("Activate")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(NoteSideTheme.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(licenseKey.isEmpty)
                    .opacity(licenseKey.isEmpty ? 0.5 : 1)
                }
            }
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
