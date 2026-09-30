import SwiftUI

/// Shown once a license key is accepted or the App Store unlock lands.
struct LicenseSuccessCard: View {
    let title: String
    let message: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(RemoraTheme.success)

            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(RemoraTheme.primaryText)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(RemoraTheme.secondaryText)
                .multilineTextAlignment(.center)

            Button("Get Started", action: action)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, Spacing.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.xl)
        .cardSurface(cornerRadius: CornerRadius.sheet, fill: RemoraTheme.glassCardFill)
    }
}
