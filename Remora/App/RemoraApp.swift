//
//  side_noteApp.swift
//  Remora
//
//  Created by Dylan Evans on 4/2/26.
//

import AppKit
import SwiftUI

@main
struct RemoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        let state = AppState()
        _appState = State(initialValue: state)
        AppEnvironment.shared.appState = state
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(appState)
        } label: {
            MenuBarIconView()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIconView: View {
    var body: some View {
        if let image = templateMenuBarImage() {
            Image(nsImage: image)
                .renderingMode(.template)
                .accessibilityLabel("Remora")
        } else {
            Image(systemName: "note.text")
                .accessibilityLabel("Remora")
        }
    }

    private func templateMenuBarImage() -> NSImage? {
        guard let image = NSImage(named: "MenuBarIcon") else { return nil }
        let templateImage = image.copy() as? NSImage ?? image
        templateImage.isTemplate = true
        return templateImage
    }
}
