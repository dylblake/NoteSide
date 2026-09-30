import AppKit
import SwiftUI

@MainActor
final class LicenseWindowController: GlassWindowController {
    init() {
        #if MAS_BUILD
        let title = "Unlock Remora"
        #else
        let title = "Activate Remora"
        #endif
        super.init(title: title, defaultContentSize: NSSize(width: 520, height: 380), level: .floating)
    }

    func install(appState: AppState) {
        #if MAS_BUILD
        installWindow(appState: appState, rootView: PurchaseView().environment(appState))
        #else
        installWindow(appState: appState, rootView: LicenseView().environment(appState))
        #endif
    }
}
