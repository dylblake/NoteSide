//
//  side_noteApp.swift
//  NoteSide
//
//  Created by Dylan Evans on 4/2/26.
//

import AppKit
import SwiftUI

@main
struct SideNoteApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appState)
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
                .accessibilityLabel("NoteSide")
        } else {
            Image(systemName: "note.text")
                .accessibilityLabel("NoteSide")
        }
    }

    private func templateMenuBarImage() -> NSImage? {
        guard let image = NSImage(named: "MenuBarIcon") else { return nil }
        let templateImage = image.copy() as? NSImage ?? image
        templateImage.isTemplate = true
        return templateImage
    }
}
