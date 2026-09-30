import AppKit
import SwiftUI

@MainActor
final class InfoWindowController: GlassWindowController {
    init() {
        super.init(title: "About Remora", defaultContentSize: NSSize(width: 560, height: 520))
    }

    func install(appState: AppState) {
        installWindow(appState: appState, rootView: InfoView().environment(appState))
    }
}
