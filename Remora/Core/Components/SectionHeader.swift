import SwiftUI

/// Small uppercase eyebrow above a group of rows (the popover's "Recent",
/// the first-run wizard's "Welcome to Remora").
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(RemoraTheme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}
