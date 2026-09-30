import AppKit
import SwiftUI

@MainActor
final class FirstRunWindowController: GlassWindowController {
    init() {
        // Sized by FirstRunView's fixed frame.
        super.init(title: "Welcome to Remora")
    }

    func install(appState: AppState) {
        installWindow(appState: appState, rootView: FirstRunView().environment(appState))
    }

    override func windowVisibilityDidChange(_ isVisible: Bool) {
        appState?.setFirstRunWindowVisible(isVisible)
    }
}
