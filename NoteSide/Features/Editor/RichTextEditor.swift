import AppKit
import SwiftUI

struct RichTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString

    let controller: RichTextEditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = EditorTextView()
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.defaultParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = 8
            return style
        }()
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: textView.defaultParagraphStyle ?? NSParagraphStyle.default
        ]
        textView.textStorage?.setAttributedString(controller.normalizedAttributedText(attributedText))
        textView.delegate = context.coordinator
        textView.onToggleBold = { controller.toggleBold() }
        textView.onToggleItalic = { controller.toggleItalic() }
        textView.onToggleUnderline = { controller.toggleUnderline() }

        scrollView.documentView = textView
        controller.attach(textView)
        Coordinator.colorTags(in: textView)
        DispatchQueue.main.async {
            controller.notifySelectionAttributesChange()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        controller.attach(textView)

        if textView.string != attributedText.string {
            let savedOrigin = scrollView.contentView.bounds.origin
            let normalized = controller.normalizedAttributedText(attributedText)
            textView.textStorage?.setAttributedString(normalized)
            Coordinator.colorTags(in: textView)
            scrollView.contentView.setBoundsOrigin(savedOrigin)
            DispatchQueue.main.async {
                controller.notifySelectionAttributesChange()
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: RichTextEditor

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            Self.colorTags(in: textView)
            parent.attributedText = NSAttributedString(attributedString: textView.attributedString())
        }

        private static let tagPattern = try! NSRegularExpression(pattern: #"#\w+"#)

        static func colorTags(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            let text = storage.string

            // Use temporary attributes (display-only) to avoid layout invalidation
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
            let matches = tagPattern.matches(in: text, range: fullRange)
            for match in matches {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.controlAccentColor, forCharacterRange: match.range)
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if parent.controller.handleAutoListTrigger(for: affectedCharRange, replacementString: replacementString) {
                parent.attributedText = NSAttributedString(attributedString: textView.attributedString())
                return false
            }

            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.controller.notifySelectionAttributesChange()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return parent.controller.handleReturn()
            }

            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return parent.controller.indentSelection()
            }

            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                return parent.controller.outdentSelection()
            }

            return false
        }
    }
}

private final class EditorTextView: NSTextView {
    var onToggleBold: (() -> Void)?
    var onToggleItalic: (() -> Void)?
    var onToggleUnderline: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch characters {
        case "b":
            onToggleBold?()
            return true
        case "i":
            onToggleItalic?()
            return true
        case "u":
            onToggleUnderline?()
            return true
        case "z" where modifiers == [.command]:
            undoManager?.undo()
            return true
        case "z" where modifiers == [.command, .shift]:
            undoManager?.redo()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
