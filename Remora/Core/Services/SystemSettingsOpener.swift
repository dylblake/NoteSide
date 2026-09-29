import AppKit

/// The Privacy panes Remora deep-links into. Raw values are the anchor
/// suffixes macOS accepts on the System Settings URL schemes.
enum SystemSettingsPrivacyPane: String {
    case accessibility = "Privacy_Accessibility"
    case automation = "Privacy_Automation"
    case microphone = "Privacy_Microphone"
    case speechRecognition = "Privacy_SpeechRecognition"
}

/// Single place that opens a System Settings Privacy pane, so every
/// permission surface (Accessibility, Automation, Microphone, Speech)
/// behaves identically. Tries the modern Ventura+ scheme first, the
/// legacy scheme next, then the bare Privacy & Security root — so the
/// worst case is "the root pane opens," never a silent no-op.
///
/// Works from the App Store sandbox: opening an `x-apple.systempreferences:`
/// URL via NSWorkspace needs no entitlement.
@MainActor
enum SystemSettingsOpener {
    @discardableResult
    static func openPrivacyPane(_ pane: SystemSettingsPrivacyPane) -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane.rawValue)",
            "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }
}
