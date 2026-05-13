//
//  HotKeyState.swift
//  NoteSide
//

import ApplicationServices
import Foundation
import Observation

@MainActor
@Observable
final class HotKeyState {
    var hotKeyShortcut: HotKeyShortcut
    var allNotesHotKeyShortcut: HotKeyShortcut
    var dictationHotKeyShortcut: HotKeyShortcut

    var hotKeyDisplayString: String { hotKeyShortcut.displayString }
    var allNotesHotKeyDisplayString: String { allNotesHotKeyShortcut.displayString }
    var dictationHotKeyDisplayString: String { dictationHotKeyShortcut.displayString }
    var availableHotKeyKeys: [HotKeyShortcut.KeyOption] { HotKeyShortcut.availableKeys }

    @ObservationIgnored private let hotKeyMonitor: GlobalHotKeyMonitor
    @ObservationIgnored private var onAccessibilityNeeded: () -> Void
    @ObservationIgnored private var onError: (String?) -> Void

    // Stored so re-registrations (e.g. shortcut key change) reuse the same action.
    @ObservationIgnored private var quickNoteAction: @MainActor () -> Void
    @ObservationIgnored private var allNotesAction: @MainActor () -> Void
    @ObservationIgnored private var dictationAction: @MainActor () -> Void

    private static let hotKeyDefaultsKey = "globalHotKeyShortcut"
    private static let allNotesHotKeyDefaultsKey = "allNotesHotKeyShortcut"
    private static let dictationHotKeyDefaultsKey = "dictationHotKeyShortcut"

    init(hotKeyMonitor: GlobalHotKeyMonitor) {
        self.hotKeyMonitor = hotKeyMonitor
        self.quickNoteAction = { }
        self.allNotesAction = { }
        self.dictationAction = { }
        self.onAccessibilityNeeded = { }
        self.onError = { _ in }

        hotKeyShortcut = Self.loadHotKeyShortcut()
        allNotesHotKeyShortcut = Self.loadAllNotesHotKeyShortcut()
        dictationHotKeyShortcut = Self.loadDictationHotKeyShortcut()
    }

    /// Must be called once after init to wire action closures and register hotkeys.
    func configure(
        quickNoteAction: @escaping @MainActor () -> Void,
        allNotesAction: @escaping @MainActor () -> Void,
        dictationAction: @escaping @MainActor () -> Void,
        onAccessibilityNeeded: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (String?) -> Void
    ) {
        self.quickNoteAction = quickNoteAction
        self.allNotesAction = allNotesAction
        self.dictationAction = dictationAction
        self.onAccessibilityNeeded = onAccessibilityNeeded
        self.onError = onError

        registerHotKey(id: 1, shortcut: hotKeyShortcut, action: quickNoteAction)
        registerHotKey(id: 2, shortcut: allNotesHotKeyShortcut, action: allNotesAction)
        registerHotKey(id: 3, shortcut: dictationHotKeyShortcut, action: dictationAction)
    }

    func updateHotKeyKeyCode(_ keyCode: UInt32) {
        hotKeyShortcut = hotKeyShortcut.updating(keyCode: keyCode)
        persistAndRegister(shortcut: hotKeyShortcut, defaultsKey: Self.hotKeyDefaultsKey, id: 1, action: quickNoteAction)
    }

    func setHotKeyShortcut(_ shortcut: HotKeyShortcut) {
        hotKeyShortcut = shortcut
        persistAndRegister(shortcut: hotKeyShortcut, defaultsKey: Self.hotKeyDefaultsKey, id: 1, action: quickNoteAction)
    }

    func setHotKeyModifier(_ modifier: UInt32, enabled: Bool) {
        hotKeyShortcut = hotKeyShortcut.updating(set: modifier, enabled: enabled)
        persistAndRegister(shortcut: hotKeyShortcut, defaultsKey: Self.hotKeyDefaultsKey, id: 1, action: quickNoteAction)
    }

    func setAllNotesHotKeyShortcut(_ shortcut: HotKeyShortcut) {
        allNotesHotKeyShortcut = shortcut
        persistAndRegister(shortcut: allNotesHotKeyShortcut, defaultsKey: Self.allNotesHotKeyDefaultsKey, id: 2, action: allNotesAction)
    }

    func setDictationHotKeyShortcut(_ shortcut: HotKeyShortcut) {
        dictationHotKeyShortcut = shortcut
        persistAndRegister(shortcut: dictationHotKeyShortcut, defaultsKey: Self.dictationHotKeyDefaultsKey, id: 3, action: dictationAction)
    }

    private func persistAndRegister(shortcut: HotKeyShortcut, defaultsKey: String, id: UInt32, action: @escaping @MainActor () -> Void) {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        registerHotKey(id: id, shortcut: shortcut, action: action)
    }

    private func registerHotKey(id: UInt32, shortcut: HotKeyShortcut, action: @escaping @MainActor () -> Void) {
        let accessibilityNeeded = onAccessibilityNeeded
        do {
            try hotKeyMonitor.register(id: id, shortcut: shortcut) {
                Task { @MainActor in
                    if !AXIsProcessTrusted() {
                        accessibilityNeeded()
                        return
                    }
                    action()
                }
            }
            onError(nil)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private static func loadHotKeyShortcut() -> HotKeyShortcut {
        guard
            let data = UserDefaults.standard.data(forKey: hotKeyDefaultsKey),
            let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
        else {
            return .default
        }
        return shortcut
    }

    private static func loadAllNotesHotKeyShortcut() -> HotKeyShortcut {
        guard
            let data = UserDefaults.standard.data(forKey: allNotesHotKeyDefaultsKey),
            let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
        else {
            return .allNotesDefault
        }
        return shortcut
    }

    private static func loadDictationHotKeyShortcut() -> HotKeyShortcut {
        guard
            let data = UserDefaults.standard.data(forKey: dictationHotKeyDefaultsKey),
            let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data)
        else {
            return .dictationDefault
        }
        return shortcut
    }
}
