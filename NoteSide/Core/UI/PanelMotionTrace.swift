import AppKit
import QuartzCore

/// DEBUG-only, frame-by-frame record of the edge panels' motion, written
/// as JSON lines to the file named by `NOTESIDE_MOTION_TRACE`. The UI tests
/// read it back and assert the animation's shape (`PanelMotionUITests`),
/// so a change that makes the drawer lag, stall or jump fails a test
/// instead of shipping. Every call is a no-op outside DEBUG or when the
/// variable is unset.
///
/// Samples come from a display link on the panel, so there is one per
/// screen refresh while the main thread is free; a gap between samples
/// is a main-thread stall. The offset is read from the presentation
/// layer — what is on screen — not the model value.
@MainActor
enum PanelMotionTrace {
    /// Records a named event and samples `panel` (or the last panel
    /// traced) every frame until it has been still for a moment.
    static func mark(_ event: String, panel: NSWindow? = nil) {
        #if DEBUG
        guard let recorder = Recorder.shared else { return }
        recorder.record(event: event, panel: panel)
        recorder.sample(panel)
        #endif
    }
}

#if DEBUG
@MainActor
private final class Recorder: NSObject {
    static let shared: Recorder? = {
        guard let path = ProcessInfo.processInfo.environment["NOTESIDE_MOTION_TRACE"], !path.isEmpty else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return Recorder(path: path)
    }()

    /// Keep sampling this long after the last event, to catch the settle.
    private static let tail: CFTimeInterval = 0.6

    private let path: String
    private var lines: [String] = []
    private var panel: NSWindow?
    private var link: CADisplayLink?
    private var sampleUntil: CFTimeInterval = 0

    private init(path: String) {
        self.path = path
    }

    func record(event: String, panel: NSWindow?) {
        var fields: [String: Any] = ["t": CACurrentMediaTime(), "event": event]
        if let panel { fields.merge(state(of: panel)) { $1 } }
        append(fields)
        // Events are rare; write them through so a test can wait on them.
        flush()
    }

    func sample(_ panel: NSWindow?) {
        guard let panel = panel ?? self.panel else { return }
        self.panel = panel
        sampleUntil = CACurrentMediaTime() + Self.tail
        guard link == nil, let view = panel.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let panel else { return }
        var fields = state(of: panel)
        // Read time, not the link's frame time: the presentation layer is
        // evaluated at the current time, so value and time stay paired even
        // when a callback runs late.
        fields["t"] = CACurrentMediaTime()
        fields["event"] = "frame"
        append(fields)
        if CACurrentMediaTime() > sampleUntil {
            link.invalidate()
            self.link = nil
            flush()
        }
    }

    private func state(of panel: NSWindow) -> [String: Any] {
        let offset = panel.contentView?.layer.map(PanelAnimation.currentOffset(of:)) ?? 0
        var fields: [String: Any] = [
            "offset": Double(offset),
            "alpha": Double(panel.alphaValue),
            "width": Double(panel.frame.width),
            "visible": panel.isVisible,
            "key": panel.isKeyWindow,
            // No screen (ordered out): -1, never NaN, which JSON can't hold.
            "screenX": panel.screen.map { Double($0.frame.minX) } ?? -1
        ]
        if let contentView = panel.contentView, let field = titleField(in: contentView) {
            fields["title"] = field.stringValue
            fields["titleAlpha"] = Double(onScreenOpacity(of: field, within: contentView))
        }
        return fields
    }

    /// The drawer's title: the editable text field with the largest font.
    private func titleField(in view: NSView) -> NSTextField? {
        var best: NSTextField?
        func visit(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable,
               (field.font?.pointSize ?? 0) > (best?.font?.pointSize ?? 0) {
                best = field
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    /// The field's opacity as composited: the product of every layer's
    /// presentation opacity from the field up to the content view, so it
    /// sees a SwiftUI `.opacity` wherever it lands in the hierarchy.
    private func onScreenOpacity(of field: NSView, within root: NSView) -> Float {
        var opacity: Float = field.isHiddenOrHasHiddenAncestor ? 0 : 1
        var layer = field.layer
        while let current = layer, current !== root.layer?.superlayer {
            opacity *= (current.presentation() ?? current).opacity
            layer = current.superlayer
        }
        return opacity
    }

    private func append(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        lines.append(line)
    }

    private func flush() {
        guard !lines.isEmpty, let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try? handle.close()
        lines.removeAll()
    }
}
#endif
