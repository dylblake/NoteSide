import SwiftUI

/// Hero of a secondary window (About, Setup, License): the wordmark, the
/// page heading at the same weight as the All Notes title, and an
/// optional one-line subtitle.
struct PageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Wordmark(height: 22)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(RemoraTheme.primaryText)
                    .accessibilityAddTraits(.isHeader)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(RemoraTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
