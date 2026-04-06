import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    let displayText: String
    let onShortcutRecorded: (HotKeyShortcut) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onShortcutRecorded = onShortcutRecorded
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.displayText = displayText
        nsView.onShortcutRecorded = onShortcutRecorded
        nsView.refresh()
    }
}

final class RecorderNSView: NSView {
    var displayText = ""
    var onShortcutRecorded: ((HotKeyShortcut) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let idleText = "Click here to record hotkey"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        applyAppearance()
        updateLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        let widestText = [idleText, displayText].max(by: { $0.count < $1.count }) ?? idleText
        let textWidth = (widestText as NSString).size(withAttributes: [.font: label.font as Any]).width
        return NSSize(width: ceil(textWidth) + 24, height: 34)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        label.stringValue = "Type shortcut"
    }

    override func resignFirstResponder() -> Bool {
        applyAppearance()
        updateLabel()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }

        guard let shortcut = HotKeyShortcut.from(event: event) else {
            NSSound.beep()
            return
        }

        onShortcutRecorded?(shortcut)
        window?.makeFirstResponder(nil)
    }

    private func updateLabel() {
        let hasDisplayText = !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        label.stringValue = hasDisplayText ? displayText : idleText
        label.textColor = hasDisplayText ? .labelColor : .secondaryLabelColor
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    func refresh() {
        invalidateIntrinsicContentSize()
        applyAppearance()
        updateLabel()
    }
}
