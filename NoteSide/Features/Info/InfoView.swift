import SwiftUI

struct InfoView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    actionsCard
                    privacyCard
                }
                .padding(28)
            }

            footer
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
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
                    NoteSideTheme.accent.opacity(0.05),
                    Color.clear,
                    NoteSideTheme.warning.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Side Note")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(NoteSideTheme.primaryText)

            Text("Context-aware notes for the app, page, or file you are in.")
                .font(.subheadline)
                .foregroundStyle(NoteSideTheme.tertiaryText)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Text("Version \(appState.appVersionDisplay)")
                .font(.footnote)
                .foregroundStyle(NoteSideTheme.tertiaryText)
        }
    }

    private var actionsCard: some View {
        infoCard(title: "Actions", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    primaryButton("Check for Updates") {
                        appState.checkForUpdates()
                    }

                    secondaryButton("Permissions & Setup") {
                        appState.showOnboarding()
                    }
                }

                if let status = appState.infoStatusMessage, !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(NoteSideTheme.secondaryText)
                }
            }
        }
    }

    private var privacyCard: some View {
        infoCard(title: "Privacy", systemImage: "hand.raised") {
            VStack(alignment: .leading, spacing: 8) {
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
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(NoteSideTheme.primaryText)

            content()
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

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(NoteSideTheme.secondaryText)
                .frame(width: 5, height: 5)
                .padding(.top, 7)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(NoteSideTheme.secondaryText)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(NoteSideTheme.accent)
                )
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(NoteSideTheme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(NoteSideTheme.contentBackground)
                )
        }
        .buttonStyle(.plain)
    }
}
