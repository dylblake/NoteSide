import AppKit
import SwiftUI

struct ClickableIconView: NSViewRepresentable {
    let iconName: String
    let iconColor: NSColor
    let hoverColor: NSColor
    let size: CGFloat
    let action: () -> Void

    init(
        iconName: String,
        iconColor: NSColor,
        hoverColor: NSColor = .labelColor,
        size: CGFloat,
        action: @escaping () -> Void
    ) {
        self.iconName = iconName
        self.iconColor = iconColor
        self.hoverColor = hoverColor
        self.size = size
        self.action = action
    }

    func makeNSView(context: Context) -> ClickableIconNSView {
        let view = ClickableIconNSView()
        view.iconName = iconName
        view.iconColor = iconColor
        view.hoverColor = hoverColor
        view.iconSize = size
        view.onClick = action
        return view
    }

    func updateNSView(_ nsView: ClickableIconNSView, context: Context) {
        nsView.iconName = iconName
        nsView.iconColor = iconColor
        nsView.hoverColor = hoverColor
        nsView.iconSize = size
        nsView.onClick = action
        nsView.needsDisplay = true
    }
}

final class ClickableIconNSView: NSView {
    var iconName: String = "questionmark"
    var iconColor: NSColor = .labelColor
    var hoverColor: NSColor = .labelColor
    var iconSize: CGFloat = 16
    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        // Trigger action immediately on mouse down for better responsiveness
        onClick?()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw the SF Symbol icon
        guard let baseImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) else {
            return
        }

        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
        guard let configuredImage = baseImage.withSymbolConfiguration(config) else {
            return
        }

        // Create a tinted version of the image
        let tintedImage = NSImage(size: configuredImage.size)
        tintedImage.lockFocus()

        let activeColor = isHovered ? hoverColor : iconColor
        activeColor.set()
        let imageRect = NSRect(origin: .zero, size: configuredImage.size)
        configuredImage.draw(in: imageRect)
        imageRect.fill(using: .sourceAtop)

        tintedImage.unlockFocus()

        // Draw the tinted image centered in the view
        let drawRect = NSRect(
            x: (bounds.width - tintedImage.size.width) / 2,
            y: (bounds.height - tintedImage.size.height) / 2,
            width: tintedImage.size.width,
            height: tintedImage.size.height
        )

        tintedImage.draw(in: drawRect)
    }

    override var acceptsFirstResponder: Bool {
        return true
    }
}
