import AppKit
import Foundation

@MainActor
final class DictationHotKeyMonitor {
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var requiredModifiers: NSEvent.ModifierFlags = []

    func startMonitoringRelease(modifiers: NSEvent.ModifierFlags) {
        stopMonitoring()
        requiredModifiers = modifiers.intersection(.deviceIndependentFlagsMask)

        let handler: (NSEvent) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    func stopMonitoring() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        requiredModifiers = []
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let stillHeld = currentModifiers.contains(requiredModifiers)
        if !stillHeld {
            stopMonitoring()
            onRelease?()
        }
    }
}
