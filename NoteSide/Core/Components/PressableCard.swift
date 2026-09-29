import SwiftUI

/// Hover and press feedback for a clickable card that contains its own
/// buttons (so it can't be a `Button` itself). Opens on mouse-up like a
/// button; the press is acknowledged on mouse-down with a subtle scale.
struct PressableCard: ViewModifier {
    let cornerRadius: CGFloat
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isPressed ? 0.08 : isHovered ? 0.04 : 0))
                    .allowsHitTesting(false)
            )
            .scaleEffect(isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16), value: isPressed)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture(perform: action)
            // Tracks mouse-down only; never completes, so the tap above
            // still decides whether the click opens the note.
            .onLongPressGesture(
                minimumDuration: .infinity,
                maximumDistance: 8,
                perform: {},
                onPressingChanged: { isPressed = $0 }
            )
    }
}

extension View {
    /// See `PressableCard`.
    func pressableCard(cornerRadius: CGFloat, action: @escaping () -> Void) -> some View {
        modifier(PressableCard(cornerRadius: cornerRadius, action: action))
    }
}
