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

        // TextKit 1: `NSTextTable` (tables) is only laid out by
        // NSLayoutManager, and temporary attributes need it too.
        let textView = EditorTextView(usingTextLayoutManager: false)
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.defaultParagraphStyle = controller.defaultParagraphStyle
        textView.typingAttributes = controller.defaultTypingAttributes
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        textView.setAccessibilityIdentifier("noteEditorTextView")
        textView.setAccessibilityLabel("Note body")
        textView.textStorage?.setAttributedString(controller.normalizedAttributedText(attributedText))
        textView.delegate = context.coordinator
        textView.onCommand = { [controller] command in controller.perform(command) }
        textView.tableMenuProvider = { [controller] in
            guard controller.currentTableCell != nil else { return nil }
            let menu = NSMenu(title: "Table")
            for edit in RichTextEditorController.TableEdit.allCases {
                if edit == .deleteRow { menu.addItem(.separator()) }
                let item = NSMenuItem(title: edit.title, action: nil, keyEquivalent: "")
                item.representedObject = edit
                menu.addItem(item)
            }
            return menu
        }
        textView.onTableEdit = { [controller] edit in controller.performTableEdit(edit) }

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
            textView.typingAttributes = controller.defaultTypingAttributes
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
            // Keep numbered lists correct after any edit (deleting or
            // pasting items), then publish the canonical document.
            parent.controller.renumberLists(around: textView.selectedRange())
            Self.colorTags(in: textView)
            if let canonical = parent.controller.currentAttributedText() {
                parent.attributedText = canonical
            }
        }

        private static let tagPattern = try! NSRegularExpression(pattern: #"#\w+"#)

        static func colorTags(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            let text = storage.string

            // Temporary attributes are display-only: no layout invalidation
            // and nothing leaks into the persisted document.
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
            let matches = tagPattern.matches(in: text, range: fullRange)
            for match in matches {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.controlAccentColor, forCharacterRange: match.range)
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if parent.controller.handleAutoListTrigger(for: affectedCharRange, replacementString: replacementString) {
                return false
            }
            return true
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            parent.controller.onOpenLink?(url)
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                parent.controller.sanitizeTypingAttributesAfterSelectionChange(in: textView)
            }
            parent.controller.notifySelectionAttributesChange()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return parent.controller.handleReturn()
            case #selector(NSResponder.insertTab(_:)):
                return parent.controller.indentSelection()
            case #selector(NSResponder.insertBacktab(_:)):
                return parent.controller.outdentSelection()
            case #selector(NSResponder.deleteBackward(_:)):
                return parent.controller.handleDeleteBackward()
            default:
                return false
            }
        }
    }
}

/// Routes the editor's keyboard shortcuts (mirroring Apple Notes and
/// TextEdit) to the controller before AppKit's defaults see them.
private final class EditorTextView: NSTextView {
    var onCommand: ((RichTextEditorController.Command) -> Bool)?
    var tableMenuProvider: (() -> NSMenu?)?
    var onTableEdit: ((RichTextEditorController.TableEdit) -> Void)?

    /// Right-click inside a table adds a "Table" submenu with the same
    /// row/column edits as the toolbar, like Notes and Pages.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let tableMenu = tableMenuProvider?() else { return menu }
        for item in tableMenu.items where !item.isSeparatorItem {
            item.target = self
            item.action = #selector(performTableMenuItem(_:))
        }
        let container = menu ?? NSMenu()
        let tableItem = NSMenuItem(title: "Table", action: nil, keyEquivalent: "")
        tableItem.submenu = tableMenu
        container.insertItem(.separator(), at: 0)
        container.insertItem(tableItem, at: 0)
        return container
    }

    @objc private func performTableMenuItem(_ sender: NSMenuItem) {
        guard let edit = sender.representedObject as? RichTextEditorController.TableEdit else { return }
        onTableEdit?(edit)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        let command: RichTextEditorController.Command?
        switch (characters, modifiers) {
        case ("b", [.command]): command = .toggleBold
        case ("i", [.command]): command = .toggleItalic
        case ("u", [.command]): command = .toggleUnderline
        case ("x", [.command, .shift]): command = .toggleStrikethrough
        case ("t", [.command, .shift]): command = .style(.title)
        case ("h", [.command, .shift]): command = .style(.heading)
        case ("j", [.command, .shift]): command = .style(.subheading)
        case ("b", [.command, .shift]): command = .style(.body)
        case ("m", [.command, .shift]): command = .style(.monospaced)
        case ("7", [.command, .shift]): command = .toggleList(.bulleted)
        case ("9", [.command, .shift]): command = .toggleList(.numbered)
        case ("t", [.command, .option]): command = .insertTable
        case ("q", [.command, .shift]): command = .quoteSelection
        case ("=", [.command]), ("+", [.command]), ("=", [.command, .shift]): command = .zoomIn
        case ("-", [.command]): command = .zoomOut
        case ("0", [.command]): command = .resetZoom
        case ("z", [.command]):
            undoManager?.undo()
            return true
        case ("z", [.command, .shift]):
            undoManager?.redo()
            return true
        default: command = nil
        }

        if let command, let onCommand, onCommand(command) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
