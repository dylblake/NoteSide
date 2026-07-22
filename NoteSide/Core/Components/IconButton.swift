import SwiftUI

/// Icon-only button with a hover highlight. Uses standard Button
/// semantics — fires on mouse-up and carries a VoiceOver role and label —
/// unlike the raw NSView it replaced, which was invisible to
/// accessibility and acted on mouse-down.
struct IconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var tint: Color = NoteSideTheme.primaryText
    var size: CGFloat = 16
    var hitSize: CGFloat = 50
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: hitSize, height: hitSize)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}
