import SwiftUI

struct InfoView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    PageHeader(
                        title: "About Remora",
                        subtitle: "Context-aware notes for the app, page, or file you are in."
                    )
                    privacyCard
                }
                .padding(Spacing.xl)
            }

            footer
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            Text("Version \(appState.appVersionDisplay)")
                .font(.footnote)
                .foregroundStyle(RemoraTheme.tertiaryText)

            HStack(spacing: Spacing.sm) {
                footerLink("Privacy Settings", destination: "https://www.dylblake.dev/remora/privacy-settings")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var privacyCard: some View {
        TitledCard(title: "Privacy", systemImage: "hand.raised") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                bullet("Notes are stored locally on this Mac.")
                bullet("Accessibility is only used for the hotkey and context detection.")
                bullet("Browser Automation is only used to read the active tab URL for supported browsers.")
                bullet("This build does not require an account to use the app.")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Circle()
                .fill(RemoraTheme.secondaryText)
                .frame(width: 5, height: 5)
                .padding(.top, Spacing.xs)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(RemoraTheme.secondaryText)
        }
    }

    private func footerLink(_ title: String, destination: String) -> some View {
        Link(title, destination: URL(string: destination)!)
            .font(.footnote)
            .foregroundStyle(RemoraTheme.accent)
    }

}
