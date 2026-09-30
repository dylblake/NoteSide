import AppKit

/// Watches for clicks in other apps while an edge panel is open. A click
/// on the panel's own display, outside the panel, means the user is done
/// with it; a click on another display means "follow me", which the
/// panel controllers already handle by repositioning. Mouse monitors need
/// no permission (only key monitors do).
@MainActor
final class ClickOutsideMonitor {
    private var monitor: Any?

    /// `alsoInside` names further frames that count as the panel, so one
    /// monitor can speak for a stack (the note and the list beside it).
    func start(
        watching panel: NSPanel,
        alsoInside: @escaping @MainActor () -> [NSRect] = { [] },
        onClickOutside: @escaping @MainActor () -> Void
    ) {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak panel] _ in
            Task { @MainActor in
                guard let panel, panel.isVisible, let panelScreen = panel.screen else { return }
                let point = NSEvent.mouseLocation
                guard let clickScreen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
                      clickScreen.frame == panelScreen.frame else {
                    return
                }
                guard !panel.frame.contains(point) else { return }
                guard !alsoInside().contains(where: { $0.contains(point) }) else { return }
                onClickOutside()
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
