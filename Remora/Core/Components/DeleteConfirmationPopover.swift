import SwiftUI

/// Inline delete confirmation. The popover already supplies the system
/// material and shadow, so the content is just text and native buttons.
struct DeleteConfirmationPopover: View {
    var title = "Delete this note?"
    var message = "This can't be undone."
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Spacing.xs) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(RemoraTheme.danger)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirmDeleteButton")
            }
        }
        .controlSize(.regular)
        .padding(Spacing.md)
        .frame(width: 240)
    }
}
