import AppKit
import Carbon
import Foundation

struct HotKeyShortcut: Codable, Equatable, Hashable {
    struct KeyOption: Hashable {
        let label: String
        let keyCode: UInt32
    }

    let keyCode: UInt32
    let modifiers: UInt32

    static let commandModifier = UInt32(cmdKey)
    static let shiftModifier = UInt32(shiftKey)
    static let optionModifier = UInt32(optionKey)
    static let controlModifier = UInt32(controlKey)

    static let `default` = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_N),
        modifiers: commandModifier | shiftModifier
    )

    static let availableKeys: [KeyOption] = [
        ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D),
        ("E", kVK_ANSI_E), ("F", kVK_ANSI_F), ("G", kVK_ANSI_G), ("H", kVK_ANSI_H),
        ("I", kVK_ANSI_I), ("J", kVK_ANSI_J), ("K", kVK_ANSI_K), ("L", kVK_ANSI_L),
        ("M", kVK_ANSI_M), ("N", kVK_ANSI_N), ("O", kVK_ANSI_O), ("P", kVK_ANSI_P),
        ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R), ("S", kVK_ANSI_S), ("T", kVK_ANSI_T),
        ("U", kVK_ANSI_U), ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X),
        ("Y", kVK_ANSI_Y), ("Z", kVK_ANSI_Z),
        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
        ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
        ("8", kVK_ANSI_8), ("9", kVK_ANSI_9)
    ].map { KeyOption(label: $0.0, keyCode: UInt32($0.1)) }

    var displayString: String {
        let modifierLabels: [String] = [
            contains(Self.commandModifier) ? "Cmd" : nil,
            contains(Self.shiftModifier) ? "Shift" : nil,
            contains(Self.optionModifier) ? "Option" : nil,
            contains(Self.controlModifier) ? "Control" : nil
        ].compactMap { $0 }

        let keyLabel = Self.label(for: keyCode)
        return (modifierLabels + [keyLabel]).joined(separator: "+")
    }

    func contains(_ modifier: UInt32) -> Bool {
        modifiers & modifier == modifier
    }

    func updating(keyCode: UInt32? = nil, set modifier: UInt32? = nil, enabled: Bool? = nil) -> HotKeyShortcut {
        var updatedModifiers = modifiers

        if let modifier, let enabled {
            if enabled {
                updatedModifiers |= modifier
            } else {
                updatedModifiers &= ~modifier
            }
        }

        return HotKeyShortcut(
            keyCode: keyCode ?? self.keyCode,
            modifiers: updatedModifiers
        )
    }

    static func label(for keyCode: UInt32) -> String {
        availableKeys.first(where: { $0.keyCode == keyCode })?.label ?? "?"
    }

    static func from(event: NSEvent) -> HotKeyShortcut? {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = carbonModifiers(from: modifierFlags)
        let keyCode = UInt32(event.keyCode)
        guard label(for: keyCode) != "?" else { return nil }
        return HotKeyShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= commandModifier }
        if flags.contains(.shift) { modifiers |= shiftModifier }
        if flags.contains(.option) { modifiers |= optionModifier }
        if flags.contains(.control) { modifiers |= controlModifier }
        return modifiers
    }
}

enum GlobalHotKeyError: LocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            return "Global hotkey registration failed (\(status))."
        }
    }
}

final class GlobalHotKeyMonitor {
    var onKeyDown: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x534E4F54), id: 1)

    func start(shortcut: HotKeyShortcut) throws {
        if eventHandlerRef == nil {
            var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let callback: EventHandlerUPP = { _, event, userData in
                guard
                    let userData,
                    let event
                else { return noErr }

                let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                if status == noErr, hotKeyID.signature == monitor.hotKeyID.signature, hotKeyID.id == monitor.hotKeyID.id {
                    monitor.onKeyDown?()
                }

                return noErr
            }

            InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                1,
                &eventSpec,
                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                &eventHandlerRef
            )
        }

        if hotKeyRef != nil {
            UnregisterEventHotKey(hotKeyRef)
            hotKeyRef = nil
        }

        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            throw GlobalHotKeyError.registrationFailed(status)
        }
    }
}
