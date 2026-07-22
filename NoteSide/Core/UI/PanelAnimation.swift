import AppKit
import QuartzCore

/// Shared animation vocabulary for the edge panels (note editor and All
/// Notes), so the two controllers can't drift apart.
///
/// Fast enough that the drawer reads as instant — this is the app's
/// signature interaction — while the soft ease-out keeps the settle from
/// feeling abrupt. Present is slightly longer than dismiss because the
/// eye reads "appear" as the more meaningful event.
@MainActor
enum PanelAnimation {
    static let presentDuration: TimeInterval = 0.28
    static let dismissDuration: TimeInterval = 0.22
    static let reducedMotionFadeDuration: TimeInterval = 0.15

    /// Width of the edge sliver a panel collapses to / expands from.
    static let collapsedWidth: CGFloat = 28

    /// Gentle decel ("ease out quint") for present and expansion.
    static let smoothEaseOut = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
    /// Mirrored accel for dismiss, so the panel speeds up as it leaves.
    static let smoothEaseIn = CAMediaTimingFunction(controlPoints: 0.7, 0.0, 0.84, 0.0)

    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
