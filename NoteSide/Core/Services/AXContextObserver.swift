import AppKit
import ApplicationServices

/// The AXObserver C callback can't capture context, so it reaches the
/// observer instance through the refcon pointer. The run loop source is
/// scheduled on the main run loop, so this always arrives on the main
/// thread.
private let axContextObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let target = Unmanaged<AXContextObserver>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        target.handleAXEvent(named: name)
    }
}

/// Watches the frontmost app's accessibility notifications so intra-app
/// context changes (Slack channel switches, editor file changes, browser
/// tab changes via window title) refresh the editor immediately instead
/// of waiting for the next poll tick.
@MainActor
final class AXContextObserver {
    /// Fired (debounced) when an observed AX event suggests the context
    /// may have changed. The owner decides whether to re-resolve.
    var onContextMayHaveChanged: (() -> Void)?

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var appElement: AXUIElement?
    private var titleObservedWindow: AXUIElement?
    private var pendingNotification: Task<Void, Never>?

    /// Notifications registered on the application element. Focus changes
    /// cover most in-app navigation; window changes let us re-anchor the
    /// title observation.
    private static let appNotifications: [CFString] = [
        kAXFocusedUIElementChangedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXMainWindowChangedNotification as CFString
    ]

    var isObserving: Bool { observer != nil }

    func isObservingApp(withProcessIdentifier pid: pid_t) -> Bool {
        observer != nil && observedPID == pid
    }

    /// Starts observing the given app, tearing down any previous
    /// observation. Returns true when at least one notification was
    /// registered — false means events will not arrive and the caller
    /// should rely on polling.
    @discardableResult
    func observe(app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        if isObservingApp(withProcessIdentifier: pid) { return true }
        stop()

        guard AXIsProcessTrusted() else { return false }

        var newObserver: AXObserver?
        guard AXObserverCreate(pid, axContextObserverCallback, &newObserver) == .success,
              let newObserver else {
            return false
        }

        let element = AXUIElementCreateApplication(pid)
        // Wake Electron/Chromium AX trees (Slack, Figma, VS Code) so
        // registration succeeds and events actually fire.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var registeredAny = false
        for notification in Self.appNotifications {
            if AXObserverAddNotification(newObserver, element, notification, refcon) == .success {
                registeredAny = true
            }
        }

        guard registeredAny else { return false }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(newObserver),
            .defaultMode
        )

        observer = newObserver
        observedPID = pid
        appElement = element
        refreshTitleObservation()
        return true
    }

    func stop() {
        pendingNotification?.cancel()
        pendingNotification = nil

        if let observer {
            if let appElement {
                for notification in Self.appNotifications {
                    AXObserverRemoveNotification(observer, appElement, notification)
                }
            }
            if let titleObservedWindow {
                AXObserverRemoveNotification(
                    observer,
                    titleObservedWindow,
                    kAXTitleChangedNotification as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }

        observer = nil
        observedPID = 0
        appElement = nil
        titleObservedWindow = nil
    }

    fileprivate func handleAXEvent(named name: String) {
        // Title changes must be registered per-window, so when focus moves
        // to a different window, re-anchor the title observation there.
        if name == (kAXFocusedWindowChangedNotification as String)
            || name == (kAXMainWindowChangedNotification as String) {
            refreshTitleObservation()
        }

        // AX events arrive in bursts (a Slack channel switch fires several
        // focus/title events back to back); coalesce before notifying.
        pendingNotification?.cancel()
        pendingNotification = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.onContextMayHaveChanged?()
        }
    }

    /// Registers kAXTitleChangedNotification on the currently focused
    /// window (browser tab switches and editor file switches surface as
    /// window title changes).
    private func refreshTitleObservation() {
        guard let observer, let appElement else { return }

        var focusedWindowRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        )
        guard status == .success, let focusedWindowRef else { return }
        let focusedWindow = focusedWindowRef as! AXUIElement

        if let titleObservedWindow, CFEqual(titleObservedWindow, focusedWindow) { return }

        if let titleObservedWindow {
            AXObserverRemoveNotification(
                observer,
                titleObservedWindow,
                kAXTitleChangedNotification as CFString
            )
        }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        if AXObserverAddNotification(
            observer,
            focusedWindow,
            kAXTitleChangedNotification as CFString,
            refcon
        ) == .success {
            titleObservedWindow = focusedWindow
        } else {
            titleObservedWindow = nil
        }
    }
}
