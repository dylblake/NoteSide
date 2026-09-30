import SwiftUI

/// A card with a `Label` heading, on the translucent fill used inside the
/// glass windows.
struct TitledCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(RemoraTheme.primaryText)
                .accessibilityAddTraits(.isHeader)

            content()
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: CornerRadius.sheet, fill: RemoraTheme.glassCardFill)
    }
}
