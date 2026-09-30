import AppKit
import QuartzCore

/// Shared animation vocabulary for the edge panels (note editor and All
/// Notes), so the two controllers can't drift apart.
///
/// The panels slide, fully opaque, on a gentle ease-out: they leave the
/// edge the moment they're asked to move and slow evenly to a stop. A
/// panel travels its whole width, so a strong ease-out (quint, the iOS
/// sheet curve) is wrong here: it covers 90% of the distance in the first
/// ~35% of the time and creeps through the rest, which reads as a pop and
/// a drift rather than a slide. Dismiss is shorter than present because
/// the eye reads "appear" as the more meaningful event.
/// `PanelAnimationCurveTests` and `PanelMotionUITests` hold these to
/// measured limits, so a change that makes the drawer lag, lurch or stall
/// fails a test.
@MainActor
enum PanelAnimation {
    static let presentDuration: TimeInterval = 0.3
    static let dismissDuration: TimeInterval = 0.22
    static let reducedMotionFadeDuration: TimeInterval = 0.15
    /// How long a panel that has moved to another display waits there,
    /// invisible, before it slides in (see
    /// `NoteEditorPanelController.repositionToActiveScreenIfNeeded`).
    static let displaySwitchSettle: TimeInterval = 0.25

    /// Ease-out quad for every panel move, in and out: peaks at ~1.9× the
    /// average speed, at the start, and decelerates evenly.
    static let slideCurve = CAMediaTimingFunction(controlPoints: 0.5, 1, 0.89, 1)

    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Floor for a retargeted slide, so a reversal that's nearly done
    /// still reads as motion rather than a snap.
    static let minimumRetargetDuration: TimeInterval = 0.1

    /// Duration for a slide that only covers part of the full distance,
    /// so a reversed panel keeps the same pace instead of crawling.
    static func duration(_ full: TimeInterval, remaining: CGFloat, of total: CGFloat) -> TimeInterval {
        guard total > 0 else { return full }
        let fraction = Double(min(max(remaining / total, 0), 1))
        return max(full * fraction, minimumRetargetDuration)
    }

    /// Present/dismiss move the panel's hosting layer, never the window:
    /// the window sits at its final frame, so SwiftUI lays the content out
    /// once instead of on every frame, and the window clips the layer so
    /// nothing bleeds onto an adjacent display.
    private static let slideKey = "panelSlide"

    /// Pins `panel`'s content at `x` until a slide replaces it, so a window
    /// can be ordered front without flashing its settled content first.
    static func hold(_ panel: NSWindow, atX x: CGFloat) {
        guard let layer = panel.contentView?.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = x
        animation.toValue = x
        animation.duration = 3600
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: slideKey)
    }

    /// Slides `panel`'s content layer and returns how long until it has
    /// finished, for completion timing. Call it after the window is front
    /// and key, right before the transaction is flushed.
    @discardableResult
    static func slide(_ panel: NSWindow, fromX: CGFloat, toX: CGFloat, duration: TimeInterval) -> TimeInterval {
        guard let layer = panel.contentView?.layer else { return 0 }
        // The start time is explicit, taken just before the commit: an
        // animation left to pick up its start time at commit restarts from
        // zero whenever the layer tree is re-committed (a window turning
        // key can do it), and one timed any earlier — say, before the 50ms
        // or so it takes to order a window front — would already be well
        // into the curve by its first frame. That frame still reaches the
        // screen a refresh or two after the commit, so the clock starts one
        // refresh late, holding the start value until then; otherwise the
        // first visible frame lands on the curve's fastest part, a lurch.
        let startDelay = panel.screen?.minimumRefreshInterval ?? (1.0 / 60)
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = fromX
        animation.toValue = toX
        animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + startDelay
        animation.duration = duration
        animation.timingFunction = slideCurve
        // Hold the start value until the clock starts, and the end value
        // afterwards: a dismissed panel must stay off-screen until it's
        // ordered out. `clearSlide` removes it once it's settled.
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: slideKey)
        return startDelay + duration
    }

    static func clearSlide(_ layer: CALayer) {
        layer.removeAnimation(forKey: slideKey)
    }

    /// Where the layer is on screen right now (0 = settled). Reading the
    /// presentation layer lets a new slide start from the live position
    /// instead of jumping.
    static func currentOffset(of layer: CALayer) -> CGFloat {
        let value = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber
        return CGFloat(value?.doubleValue ?? 0)
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

    // MARK: The stack (All Notes beside the note drawer)

    /// Both panels inset their glass sheet from the window's edges by
    /// these amounts (see `FloatingNoteEditorView`, `FloatingAllNotesView`).
    static let sheetLeadingPadding: CGFloat = 32
    static let sheetTrailingPadding: CGFloat = 20
    /// Both panels' footers share a height, so their sheets end on the
    /// same line when they sit side by side.
    static let footerHeight: CGFloat = 42

    /// How far the list's sheet runs under the note's sheet. More than the
    /// sheets' corner radius, so the list's rounded corners are hidden and
    /// the note's corners show list behind them, not the desktop.
    static let stackLap: CGFloat = 28

    /// While stacked, the list keeps its content clear of everything the
    /// note covers: the note window's transparent leading padding (which
    /// takes the mouse) and the lap. Only glass sits under the note.
    static let stackedContentInset = sheetLeadingPadding + stackLap

    /// How far the list's window extends under the note's window.
    static let stackTuck = sheetTrailingPadding + stackedContentInset

    private static let stackScreenMargin: CGFloat = 16
    /// Narrowest list window still worth browsing beside a note.
    private static let stackedMinWidth: CGFloat = 480

    /// The All Notes frame when it sits beside the note drawer: tucked
    /// under the drawer's leading edge and extending left, as wide as the
    /// standalone list's content plus what the note covers. Nil when the
    /// display is too narrow for the pair; the caller then swaps the
    /// panels instead of stacking them.
    static func stackedAllNotesFrame(editorFrame: NSRect, visibleFrame: NSRect) -> NSRect? {
        let maxX = editorFrame.minX + stackTuck
        let available = maxX - (visibleFrame.minX + stackScreenMargin)
        let wanted = allNotesPaneWidth(forScreenWidth: visibleFrame.width) + stackedContentInset
        let width = floor(Swift.min(wanted, available))
        guard width >= stackedMinWidth else { return nil }
        return NSRect(x: maxX - width, y: editorFrame.minY, width: width, height: editorFrame.height)
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat, screenWidth: CGFloat) -> CGFloat {
        // Never cover more than 85% of the screen, whatever the minimum says.
        let hardCap = floor(screenWidth * 0.85)
        return Swift.min(Swift.max(value, Swift.min(lower, hardCap)), Swift.min(upper, hardCap))
    }

    /// `REMORA_PANE_WIDTH=480` forces a pane width so layouts can be
    /// checked at any size on one display. Debug builds only.
    private static var debugPaneWidthOverride: CGFloat? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["REMORA_PANE_WIDTH"], let value = Double(raw), value > 0 {
            return CGFloat(value)
        }
        #endif
        return nil
    }
}
