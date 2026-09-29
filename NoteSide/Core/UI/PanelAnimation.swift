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

/// Pane geometry for the edge panels. Widths are a fraction of the screen
/// but clamped so the drawer is usable on a narrow or portrait display and
/// doesn't sprawl across an ultra-wide one.
enum PanelLayout {
    static let editorMinWidth: CGFloat = 440
    static let editorMaxWidth: CGFloat = 640
    static let allNotesMinWidth: CGFloat = 540
    static let allNotesMaxWidth: CGFloat = 960

    static func editorPaneWidth(forScreenWidth screenWidth: CGFloat) -> CGFloat {
        if let override = debugPaneWidthOverride { return min(override, screenWidth) }
        return clamp(floor(screenWidth / 3), min: editorMinWidth, max: editorMaxWidth, screenWidth: screenWidth)
    }

    static func allNotesPaneWidth(forScreenWidth screenWidth: CGFloat) -> CGFloat {
        if let override = debugPaneWidthOverride { return min(override, screenWidth) }
        return clamp(floor(screenWidth * 0.45), min: allNotesMinWidth, max: allNotesMaxWidth, screenWidth: screenWidth)
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat, screenWidth: CGFloat) -> CGFloat {
        // Never cover more than 85% of the screen, whatever the minimum says.
        let hardCap = floor(screenWidth * 0.85)
        return Swift.min(Swift.max(value, Swift.min(lower, hardCap)), Swift.min(upper, hardCap))
    }

    /// `NOTESIDE_PANE_WIDTH=480` forces a pane width so layouts can be
    /// checked at any size on one display. Debug builds only.
    private static var debugPaneWidthOverride: CGFloat? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["NOTESIDE_PANE_WIDTH"], let value = Double(raw), value > 0 {
            return CGFloat(value)
        }
        #endif
        return nil
    }
}
