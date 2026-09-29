import SwiftUI

struct InfoView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    header
                    privacyCard
                }
                .padding(Spacing.xl)
            }

            footer
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }

    private var background: some View {
        RemoraTheme.windowBackground
            .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Remora")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(RemoraTheme.primaryText)
                .accessibilityAddTraits(.isHeader)

            Text("Context-aware notes for the app, page, or file you are in.")
                .font(.subheadline)
                .foregroundStyle(RemoraTheme.tertiaryText)
        }
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
        infoCard(title: "Privacy", systemImage: "hand.raised") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                bullet("Notes are stored locally on this Mac.")
                bullet("Accessibility is only used for the hotkey and context detection.")
                bullet("Browser Automation is only used to read the active tab URL for supported browsers.")
                bullet("This build does not require an account to use the app.")
            }
        }
    }

    private func infoCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(RemoraTheme.primaryText)

            content()
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: CornerRadius.sheet)
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
