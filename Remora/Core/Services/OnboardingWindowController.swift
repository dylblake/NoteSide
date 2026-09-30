import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: GlassWindowController {
    init() {
        super.init(title: "Setup", defaultContentSize: NSSize(width: 760, height: 620), resizable: true)
    }

    func install(appState: AppState) {
        installWindow(appState: appState, rootView: OnboardingView().environment(appState))
    }

    override func present() {
        // The window is resizable; never come back smaller than the default.
        if let window,
           window.frame.width < defaultContentSize.width || window.frame.height < defaultContentSize.height {
            window.setFrame(NSRect(origin: .zero, size: defaultContentSize), display: false)
        }
        super.present()
    }

    override func windowVisibilityDidChange(_ isVisible: Bool) {
        appState?.setOnboardingWindowVisible(isVisible)
    }
}
