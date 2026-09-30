import SwiftUI

enum PermissionRowStatus {
    case granted
    /// Explicitly denied or required-and-absent.
    case missing
    /// Not requested yet — nothing is wrong.
    case pending

    var symbolName: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        case .pending: return "circle.dashed"
        }
    }

    var color: Color {
        switch self {
        case .granted: return RemoraTheme.success
        case .missing: return RemoraTheme.danger
        case .pending: return RemoraTheme.secondaryText
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .granted: return "granted"
        case .missing: return "not granted"
        case .pending: return "not requested"
        }
    }
}

/// Top-level permission: status glyph, title, one-line detail, action.
struct PermissionRow<Action: View>: View {
    let title: String
    let detail: String
    let status: PermissionRowStatus
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: status.symbolName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(status.color)
                .frame(width: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RemoraTheme.primaryText)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(RemoraTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.sm)

            action()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetRowSurface(fill: RemoraTheme.glassInsetRowFill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status.accessibilityDescription)")
    }
}

/// Per-app row listed under a `PermissionRow`.
struct PermissionDetailRow<Action: View>: View {
    let title: String
    let detail: String
    let status: PermissionRowStatus
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: status.symbolName)
                .font(.body)
                .foregroundStyle(status.color)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(RemoraTheme.primaryText)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(RemoraTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.sm)

            action()
                .controlSize(.small)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status.accessibilityDescription)")
    }
}

/// "Connecting…" / "Requesting…" in place of a button while a permission
/// prompt is out, so the click is never invisible.
struct PendingLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: Spacing.xs - 2) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.footnote)
                .foregroundStyle(RemoraTheme.secondaryText)
        }
    }
}
