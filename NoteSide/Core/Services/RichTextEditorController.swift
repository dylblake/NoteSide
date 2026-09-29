import AppKit

/// Owns every formatting operation on the note editor's `NSTextView`.
///
/// Design notes:
/// - Paragraph styles (Title / Heading / Subheading / Body / Monospaced)
///   are the same concept Apple Notes uses. A style is identified by the
///   canonical font size and traits of the paragraph, so it survives the
///   RTF round-trip used for persistence (custom attribute keys and
///   `headerLevel` do not).
/// - Text size is a *zoom* (⌘+ / ⌘− / ⌘0), again like Notes: the document
///   is stored at canonical sizes and scaled for display, so headings stay
///   proportional and a note never becomes a soup of arbitrary sizes.
/// - Lists are real paragraphs with a marker (`•⇥` / `1.⇥`) and a hanging
///   indent from the paragraph style, so wrapped lines align under the
///   text like a native list. Numbering is recomputed after every edit.
/// - Tables are `NSTextTable` blocks, which TextKit 1 lays out natively
///   and RTF persists.
@MainActor
final class RichTextEditorController {

    // MARK: - Types

    enum TextStyle: String, CaseIterable, Identifiable {
        case title
        case heading
        case subheading
        case body
        case monospaced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .title: return "Title"
            case .heading: return "Heading"
            case .subheading: return "Subheading"
            case .body: return "Body"
            case .monospaced: return "Monospaced"
            }
        }

        /// Point size at 100% zoom.
        var canonicalSize: CGFloat {
            switch self {
            case .title: return 28
            case .heading: return 22
            case .subheading: return 17
            case .body: return 15
            case .monospaced: return 13
            }
        }

        var weight: NSFont.Weight {
            switch self {
            case .title, .heading: return .bold
            case .subheading: return .semibold
            case .body, .monospaced: return .regular
            }
        }

        var isMonospaced: Bool { self == .monospaced }

        /// Extra space above the paragraph so headings breathe.
        var spacingBefore: CGFloat {
            switch self {
            case .title: return 8
            case .heading: return 10
            case .subheading: return 6
            case .body, .monospaced: return 0
            }
        }

        /// ⇧⌘ + this key, mirroring Apple Notes.
        var shortcutKey: Character {
            switch self {
            case .title: return "t"
            case .heading: return "h"
            case .subheading: return "j"
            case .body: return "b"
            case .monospaced: return "m"
            }
        }

        /// Classifies a font stored at canonical (unzoomed) size.
        static func style(forCanonicalSize size: CGFloat, monospaced: Bool) -> TextStyle {
            if monospaced { return .monospaced }
            if size >= 26 { return .title }
            if size >= 20 { return .heading }
            if size >= 16.5 { return .subheading }
            return .body
        }
    }

    enum ListKind: Equatable {
        case bulleted
        case numbered
    }

    struct FormattingState: Equatable {
        var textStyle: TextStyle = .body
        var isBold = false
        var isItalic = false
        var isUnderlined = false
        var isStrikethrough = false
        var listKind: ListKind?
        var isInTable = false
        var zoom: CGFloat = 1
    }

    enum Command {
        case toggleBold, toggleItalic, toggleUnderline, toggleStrikethrough
        case style(TextStyle)
        case toggleList(ListKind)
        case insertTable
        case table(TableEdit)
        case zoomIn, zoomOut, resetZoom
    }

    enum TableEdit: CaseIterable, Identifiable {
        case addRowBelow, addRowAbove, addColumnAfter, addColumnBefore
        case deleteRow, deleteColumn, deleteTable

        var id: Self { self }

        var title: String {
            switch self {
            case .addRowBelow: return "Add Row Below"
            case .addRowAbove: return "Add Row Above"
            case .addColumnAfter: return "Add Column After"
            case .addColumnBefore: return "Add Column Before"
            case .deleteRow: return "Delete Row"
            case .deleteColumn: return "Delete Column"
            case .deleteTable: return "Delete Table"
            }
        }

        var isDestructive: Bool {
            switch self {
            case .deleteRow, .deleteColumn, .deleteTable: return true
            default: return false
            }
        }
    }

    // MARK: - Constants

    static let zoomSteps: [CGFloat] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
    private static let zoomDefaultsKey = "editorTextZoom"

    private static let listIndentUnit: CGFloat = 24
    private static let listMarkerWidth: CGFloat = 26
    private static let maxListLevel = 3
    private static let bulletGlyphs = ["•", "◦", "▪", "•"]

    private static let lineSpacing: CGFloat = 3
    private static let paragraphSpacing: CGFloat = 8

    /// `•⇥`, `1.⇥`, `a.⇥`, `iv.⇥` at the start of a paragraph.
    private static let markerPattern = try! NSRegularExpression(
        pattern: #"^(?:[•◦▪]|\d{1,3}\.|[a-z]\.|(?:i{1,3}|iv|v|vi{0,3}|ix|x)\.)\t"#,
        options: [.caseInsensitive]
    )
    /// Legacy notes: optional indent, marker, single space.
    private static let legacyMarkerPattern = try! NSRegularExpression(
        pattern: #"^([ \t]*)(•|\d{1,3}\.|[a-z]\.|(?:i{1,3}|iv|v|vi{0,3}|ix|x)\.) "#,
        options: [.caseInsensitive]
    )

    // MARK: - State

    weak var textView: NSTextView?
    var onSelectionAttributesChange: ((FormattingState) -> Void)?

    private(set) var zoom: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: RichTextEditorController.zoomDefaultsKey)
        return stored > 0 ? CGFloat(stored) : 1
    }()

    private var isRenumbering = false

    // MARK: - Attachment

    func attach(_ textView: NSTextView) {
        self.textView = textView
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func insertDictatedText(_ text: String) {
        guard let textView, !text.isEmpty else { return }
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    // MARK: - Default attributes

    var defaultParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = Self.lineSpacing
        style.paragraphSpacing = Self.paragraphSpacing
        return style
    }

    var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font(for: .body, italic: false),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: defaultParagraphStyle
        ]
    }

    // MARK: - Document in / out

    /// Prepares stored text for display: migrates legacy list markers,
    /// rebuilds every font as the system font at the current zoom, forces
    /// label colour, and re-tints table borders.
    func normalizedAttributedText(_ attributedText: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        migrateLegacyLists(in: mutable)

        let fullRange = NSRange(location: 0, length: mutable.length)
        guard mutable.length > 0 else { return mutable }

        mutable.beginEditing()
        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let stored = (value as? NSFont) ?? NSFont.systemFont(ofSize: TextStyle.body.canonicalSize)
            let traits = stored.fontDescriptor.symbolicTraits
            let canonical = Self.roundToHalf(stored.pointSize)
            let style = TextStyle.style(forCanonicalSize: canonical, monospaced: traits.contains(.monoSpace))
            let weight: NSFont.Weight
            if traits.contains(.bold) {
                weight = style == .subheading ? .semibold : .bold
            } else {
                weight = .regular
            }
            let font = makeFont(size: canonical * zoom, weight: weight, italic: traits.contains(.italic), monospaced: style.isMonospaced)
            mutable.addAttribute(.font, value: font, range: range)
        }
        mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        mutable.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
            guard let style = value as? NSParagraphStyle else {
                mutable.addAttribute(.paragraphStyle, value: defaultParagraphStyle, range: range)
                return
            }
            for case let block as NSTextTableBlock in style.textBlocks {
                Self.applyCellAppearance(to: block)
            }
        }
        mutable.endEditing()
        return mutable
    }

    /// The document at canonical (100%) size, ready to persist.
    func currentAttributedText() -> NSAttributedString? {
        guard let textView else { return nil }
        let copy = NSMutableAttributedString(attributedString: textView.attributedString())
        guard zoom != 1, copy.length > 0 else { return copy }
        let fullRange = NSRange(location: 0, length: copy.length)
        copy.beginEditing()
        copy.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let canonical = Self.roundToHalf(font.pointSize / zoom)
            copy.addAttribute(.font, value: Self.resized(font, to: canonical), range: range)
        }
        copy.endEditing()
        return copy
    }

    // MARK: - Formatting state

    func currentFormattingState() -> FormattingState {
        guard let textView else { return FormattingState(zoom: zoom) }
        let selection = selectedRange(in: textView)
        let font = fontAtSelection(in: textView) ?? self.font(for: .body, italic: false)
        let traits = font.fontDescriptor.symbolicTraits
        let canonical = Self.roundToHalf(font.pointSize / zoom)
        let attributes = attributesAtSelection(in: textView)

        var state = FormattingState(zoom: zoom)
        state.textStyle = TextStyle.style(forCanonicalSize: canonical, monospaced: traits.contains(.monoSpace))
        state.isBold = traits.contains(.bold)
        state.isItalic = traits.contains(.italic)
        state.isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
        state.isStrikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0

        let paragraphRange = (textView.string as NSString).paragraphRange(for: NSRange(location: selection.location, length: 0))
        state.listKind = listMarker(inParagraph: paragraphRange, storage: textView.attributedString())?.kind
        state.isInTable = tableBlock(at: selection.location) != nil
        return state
    }

    func currentTextStyle() -> TextStyle {
        currentFormattingState().textStyle
    }

    func notifySelectionAttributesChange() {
        onSelectionAttributesChange?(currentFormattingState())
    }

    // MARK: - Commands

    @discardableResult
    func perform(_ command: Command) -> Bool {
        switch command {
        case .toggleBold: toggleBold()
        case .toggleItalic: toggleItalic()
        case .toggleUnderline: toggleUnderline()
        case .toggleStrikethrough: toggleStrikethrough()
        case .style(let style): apply(style: style)
        case .toggleList(let kind): toggleList(kind)
        case .insertTable: insertTable()
        case .table(let edit): performTableEdit(edit)
        case .zoomIn: zoomIn()
        case .zoomOut: zoomOut()
        case .resetZoom: setZoom(1)
        }
        return true
    }

    // MARK: Character traits

    func toggleBold() {
        transformFonts { font in
            let traits = font.fontDescriptor.symbolicTraits
            let canonical = Self.roundToHalf(font.pointSize / self.zoom)
            let style = TextStyle.style(forCanonicalSize: canonical, monospaced: traits.contains(.monoSpace))
            let nextWeight: NSFont.Weight = traits.contains(.bold) ? .regular : (style == .subheading ? .semibold : .bold)
            return self.makeFont(size: font.pointSize, weight: nextWeight, italic: traits.contains(.italic), monospaced: traits.contains(.monoSpace))
        }
    }

    func toggleItalic() {
        transformFonts { font in
            let traits = font.fontDescriptor.symbolicTraits
            return self.makeFont(size: font.pointSize, weight: Self.weight(of: font), italic: !traits.contains(.italic), monospaced: traits.contains(.monoSpace))
        }
    }

    func toggleUnderline() {
        toggleIntegerAttribute(.underlineStyle, on: NSUnderlineStyle.single.rawValue)
    }

    func toggleStrikethrough() {
        toggleIntegerAttribute(.strikethroughStyle, on: NSUnderlineStyle.single.rawValue)
    }

    // MARK: Paragraph styles

    /// Applies a paragraph style to every paragraph touched by the
    /// selection. Bold/italic that the user added on top of the style are
    /// reset, matching Notes: choosing "Heading" gives you a heading.
    func apply(style: TextStyle) {
        guard let textView else { return }
        let selection = selectedRange(in: textView)
        let storage = textView.attributedString()
        let ranges = paragraphRanges(in: storage.string as NSString, intersecting: selection)

        let rewritten = ranges.map { range -> NSAttributedString in
            let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
            let full = NSRange(location: 0, length: paragraph.length)
            if paragraph.length > 0 {
                paragraph.enumerateAttribute(.font, in: full, options: []) { value, subrange, _ in
                    let italic = (value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
                    paragraph.addAttribute(.font, value: self.font(for: style, italic: italic), range: subrange)
                }
                paragraph.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, subrange, _ in
                    let mutableStyle = ((value as? NSParagraphStyle) ?? self.defaultParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                    mutableStyle.paragraphSpacingBefore = style.spacingBefore
                    paragraph.addAttribute(.paragraphStyle, value: mutableStyle, range: subrange)
                }
            }
            return paragraph
        }

        if let first = ranges.first, let last = ranges.last {
            let union = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            let replacement = NSMutableAttributedString()
            rewritten.forEach { replacement.append($0) }
            rewriteBlock(union, with: replacement, in: textView, originalSelection: selection)
        }

        var typing = textView.typingAttributes
        let italic = (typing[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
        typing[.font] = font(for: style, italic: italic)
        if let current = typing[.paragraphStyle] as? NSParagraphStyle {
            let mutableStyle = current.mutableCopy() as! NSMutableParagraphStyle
            mutableStyle.paragraphSpacingBefore = style.spacingBefore
            typing[.paragraphStyle] = mutableStyle
        }
        textView.typingAttributes = typing
        notifySelectionAttributesChange()
    }

    // MARK: Zoom

    var canZoomIn: Bool { zoom < Self.zoomSteps.last! }
    var canZoomOut: Bool { zoom > Self.zoomSteps.first! }

    func zoomIn() {
        guard let next = Self.zoomSteps.first(where: { $0 > zoom + 0.001 }) else { return }
        setZoom(next)
    }

    func zoomOut() {
        guard let next = Self.zoomSteps.last(where: { $0 < zoom - 0.001 }) else { return }
        setZoom(next)
    }

    func setZoom(_ newZoom: CGFloat) {
        let clamped = min(max(newZoom, Self.zoomSteps.first!), Self.zoomSteps.last!)
        guard clamped != zoom else { return }
        let factor = clamped / zoom
        zoom = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.zoomDefaultsKey)

        guard let textView else {
            notifySelectionAttributesChange()
            return
        }

        // Display-only change: rescale in place without touching the undo
        // stack or marking the document dirty (canonical sizes are unchanged).
        if let storage = textView.textStorage, storage.length > 0 {
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
                guard let font = value as? NSFont else { return }
                storage.addAttribute(.font, value: Self.resized(font, to: font.pointSize * factor), range: range)
            }
            storage.endEditing()
        }
        if let font = textView.typingAttributes[.font] as? NSFont {
            textView.typingAttributes[.font] = Self.resized(font, to: font.pointSize * factor)
        }
        notifySelectionAttributesChange()
    }

    // MARK: Lists

    func insertBulletedList() { toggleList(.bulleted) }
    func insertNumberedList() { toggleList(.numbered) }

    /// Turns the selected paragraphs into a list of `kind`, or back into
    /// plain paragraphs when they already are that kind.
    func toggleList(_ kind: ListKind) {
        guard let textView else { return }
        let selection = selectedRange(in: textView)
        let storage = textView.attributedString()
        let nsString = storage.string as NSString
        let ranges = paragraphRanges(in: nsString, intersecting: selection)
        guard let first = ranges.first, let last = ranges.last else { return }

        let markers = ranges.map { listMarker(inParagraph: $0, storage: storage) }
        let allAlreadyKind = markers.allSatisfy { $0?.kind == kind }

        let rewritten: [NSAttributedString] = zip(ranges, markers).map { range, marker in
            let paragraph = storage.attributedSubstring(from: range)
            if allAlreadyKind {
                return strippedOfMarker(paragraph, marker: marker)
            }
            let level = marker?.level ?? 0
            let content = marker.map { strippedOfMarker(paragraph, marker: $0) } ?? paragraph
            return withMarker(kind: kind, level: level, ordinal: 1, content: content)
        }

        let union = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let replacement = NSMutableAttributedString()
        rewritten.forEach { replacement.append($0) }
        rewriteBlock(union, with: replacement, in: textView, originalSelection: selection)
        renumberLists(around: textView.selectedRange())
        notifySelectionAttributesChange()
    }

    /// Return key. Continues a list, ends it on an empty item, and drops
    /// back to Body after a heading. Returns `false` to let the text view
    /// insert a plain newline.
    func handleReturn() -> Bool {
        guard let textView else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }

        let storage = textView.attributedString()
        let nsString = storage.string as NSString
        let paragraphRange = nsString.paragraphRange(for: selection)

        if let marker = listMarker(inParagraph: paragraphRange, storage: storage) {
            let contentStart = paragraphRange.location + marker.markerLength
            let contentEnd = paragraphEnd(paragraphRange, in: nsString)
            let content = nsString.substring(with: NSRange(location: contentStart, length: max(contentEnd - contentStart, 0)))

            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty item: end the list instead of adding another marker.
                let plain = strippedOfMarker(storage.attributedSubstring(from: paragraphRange), marker: marker)
                replace(paragraphRange, with: plain, in: textView, restoring: NSRange(location: paragraphRange.location, length: 0))
                renumberLists(around: NSRange(location: max(paragraphRange.location - 1, 0), length: 0))
                notifySelectionAttributesChange()
                return true
            }

            if selection.location < contentStart {
                // Caret inside the marker: treat as start of the item.
                textView.setSelectedRange(NSRange(location: contentStart, length: 0))
            }

            let continuation = withMarker(kind: marker.kind, level: marker.level, ordinal: marker.ordinal + 1, content: NSAttributedString(string: ""))
            let insertion = NSMutableAttributedString(string: "\n", attributes: attributesForContinuation(in: textView, paragraphRange: paragraphRange))
            insertion.append(continuation)
            let caret = textView.selectedRange().location
            replace(NSRange(location: caret, length: 0), with: insertion, in: textView, restoring: NSRange(location: caret + insertion.length, length: 0))
            renumberLists(around: textView.selectedRange())
            notifySelectionAttributesChange()
            return true
        }

        // Heading → Body on the next line, when the caret sits at the end.
        let style = currentTextStyle()
        let atEnd = selection.location >= paragraphEnd(paragraphRange, in: nsString)
        if style != .body, style != .monospaced, atEnd, tableBlock(at: selection.location) == nil {
            var attributes = textView.typingAttributes
            attributes[.font] = font(for: .body, italic: false)
            let paragraphStyle = ((attributes[.paragraphStyle] as? NSParagraphStyle) ?? defaultParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            paragraphStyle.paragraphSpacingBefore = 0
            attributes[.paragraphStyle] = paragraphStyle
            attributes[.foregroundColor] = NSColor.labelColor
            let newline = NSAttributedString(string: "\n", attributes: attributes)
            replace(selection, with: newline, in: textView, restoring: NSRange(location: selection.location + 1, length: 0))
            textView.typingAttributes = attributes
            notifySelectionAttributesChange()
            return true
        }

        return false
    }

    /// Delete key with the caret right after a list marker removes the
    /// marker (like Notes) instead of eating the tab character.
    func handleDeleteBackward() -> Bool {
        guard let textView else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let storage = textView.attributedString()
        let paragraphRange = (storage.string as NSString).paragraphRange(for: selection)
        guard let marker = listMarker(inParagraph: paragraphRange, storage: storage),
              selection.location == paragraphRange.location + marker.markerLength else {
            return false
        }

        if marker.level > 0 {
            return adjustListLevel(delta: -1)
        }

        let plain = strippedOfMarker(storage.attributedSubstring(from: paragraphRange), marker: marker)
        replace(paragraphRange, with: plain, in: textView, restoring: NSRange(location: paragraphRange.location, length: 0))
        renumberLists(around: NSRange(location: max(paragraphRange.location - 1, 0), length: 0))
        notifySelectionAttributesChange()
        return true
    }

    /// Tab: indent a list item, or move to the next table cell.
    func indentSelection() -> Bool {
        if moveToAdjacentTableCell(forward: true) { return true }
        return adjustListLevel(delta: 1)
    }

    /// Shift-Tab: outdent a list item, or move to the previous table cell.
    func outdentSelection() -> Bool {
        if moveToAdjacentTableCell(forward: false) { return true }
        return adjustListLevel(delta: -1)
    }

    /// Typing `- `, `* `, or `1. ` at the start of a paragraph starts a list.
    @discardableResult
    func handleAutoListTrigger(for affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let textView, replacementString == " ", affectedCharRange.length == 0 else { return false }
        let storage = textView.attributedString()
        let nsString = storage.string as NSString
        guard affectedCharRange.location <= nsString.length else { return false }

        let paragraphRange = nsString.paragraphRange(for: NSRange(location: affectedCharRange.location, length: 0))
        guard listMarker(inParagraph: paragraphRange, storage: storage) == nil, tableBlock(at: affectedCharRange.location) == nil else { return false }
        let beforeCaret = nsString.substring(with: NSRange(location: paragraphRange.location, length: affectedCharRange.location - paragraphRange.location))

        let kind: ListKind
        switch beforeCaret {
        case "-", "*", "•": kind = .bulleted
        case "1.", "1": kind = .numbered
        default: return false
        }

        let restOfParagraph = storage.attributedSubstring(from: NSRange(location: affectedCharRange.location, length: NSMaxRange(paragraphRange) - affectedCharRange.location))
        let item = withMarker(kind: kind, level: 0, ordinal: 1, content: restOfParagraph)
        let markerLength = listMarker(inParagraph: NSRange(location: 0, length: item.length), storage: item)?.markerLength ?? 0
        replace(paragraphRange, with: item, in: textView, restoring: NSRange(location: paragraphRange.location + markerLength, length: 0))
        renumberLists(around: textView.selectedRange())
        notifySelectionAttributesChange()
        return true
    }

    /// Re-derives numbering for the list block around `range`. Safe to call
    /// after any edit; does nothing when the markers are already correct.
    func renumberLists(around range: NSRange) {
        guard let textView, !isRenumbering else { return }
        if let undo = textView.undoManager, undo.isUndoing || undo.isRedoing { return }
        isRenumbering = true
        defer { isRenumbering = false }

        let storage = textView.attributedString()
        let nsString = storage.string as NSString
        guard let block = listBlockRange(around: range, storage: storage) else { return }
        let ranges = paragraphRanges(in: nsString, intersecting: block)

        var counters = Array(repeating: 0, count: Self.maxListLevel + 1)
        var kinds = Array(repeating: ListKind?.none, count: Self.maxListLevel + 1)
        var previousLevel = -1
        var edits: [(NSRange, NSAttributedString)] = []

        for paragraphRange in ranges {
            guard let marker = listMarker(inParagraph: paragraphRange, storage: storage) else { continue }
            if marker.level < previousLevel {
                for deeper in (marker.level + 1)...Self.maxListLevel {
                    counters[deeper] = 0
                    kinds[deeper] = nil
                }
            }
            previousLevel = marker.level
            // A bulleted item breaks a numbered sequence at its level, and
            // a numbered list starting after bullets counts from 1.
            if kinds[marker.level] != marker.kind {
                counters[marker.level] = 0
                kinds[marker.level] = marker.kind
            }
            counters[marker.level] += 1
            let expected = Self.markerText(kind: marker.kind, level: marker.level, ordinal: counters[marker.level])
            if marker.text != expected {
                let markerRange = NSRange(location: paragraphRange.location, length: marker.text.utf16.count)
                let attributes = storage.attributes(at: paragraphRange.location, effectiveRange: nil)
                edits.append((markerRange, NSAttributedString(string: expected, attributes: attributes)))
            }
        }

        guard !edits.isEmpty, let textStorage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        var selectionLocation = selection.location
        var selectionLength = selection.length
        let affected = NSRange(location: block.location, length: block.length)
        guard textView.shouldChangeText(in: affected, replacementString: nil) else { return }
        textStorage.beginEditing()
        for (markerRange, replacement) in edits.reversed() {
            textStorage.replaceCharacters(in: markerRange, with: replacement)
            let delta = replacement.length - markerRange.length
            if markerRange.location < selectionLocation {
                selectionLocation += delta
            } else if markerRange.location < selectionLocation + selectionLength {
                selectionLength += delta
            }
        }
        textStorage.endEditing()
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: max(selectionLocation, 0), length: max(selectionLength, 0)))
    }

    // MARK: Tables

    func insertTable(rows: Int = 2, columns: Int = 2) {
        guard let textView, rows > 0, columns > 0 else { return }
        let storage = textView.attributedString()
        let nsString = storage.string as NSString
        let selection = textView.selectedRange()
        guard tableBlock(at: selection.location) == nil else { return }

        let paragraphRange = nsString.paragraphRange(for: NSRange(location: selection.location, length: 0))
        let contentLength = paragraphEnd(paragraphRange, in: nsString) - paragraphRange.location
        let insertion = NSMutableAttributedString()
        var insertAt: Int
        var leadingNewlineLength = 0

        if contentLength == 0 {
            insertAt = paragraphRange.location
        } else {
            insertAt = NSMaxRange(paragraphRange)
            if !Self.hasTrailingNewline(paragraphRange, in: nsString) {
                insertion.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
                leadingNewlineLength = 1
            }
        }

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        for row in 0..<rows {
            insertion.append(tableRow(table: table, row: row, columns: columns))
        }

        // Always leave a plain paragraph after the table so the caret can
        // get out of it and typing at the end doesn't extend the last cell.
        let needsExitParagraph = insertAt >= nsString.length
            || nsString.paragraphRange(for: NSRange(location: insertAt, length: 0)).length == 0
            || tableBlock(at: insertAt) != nil
        if needsExitParagraph {
            insertion.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
        }

        let firstCellLocation = insertAt + leadingNewlineLength
        replace(NSRange(location: insertAt, length: 0), with: insertion, in: textView, restoring: NSRange(location: firstCellLocation, length: 0))
        notifySelectionAttributesChange()
    }

    /// Position of the caret's cell, for menus that need to know.
    var currentTableCell: (row: Int, column: Int, rows: Int, columns: Int)? {
        guard let textView, let model = tableModel(at: textView.selectedRange().location),
              let cell = model.cell(containing: textView.selectedRange().location) else { return nil }
        return (cell.row, cell.column, model.rows.count, model.columns)
    }

    /// Structural table edits. The table is rebuilt from its cell contents
    /// so every block gets a fresh, correct row/column index (blocks are
    /// immutable once created); character formatting inside cells is kept.
    func performTableEdit(_ edit: TableEdit) {
        guard let textView else { return }
        let caret = textView.selectedRange().location
        guard var model = tableModel(at: caret), let cell = model.cell(containing: caret) else { return }

        var targetRow = cell.row
        var targetColumn = cell.column

        switch edit {
        case .addRowBelow:
            model.rows.insert(emptyRow(columns: model.columns), at: cell.row + 1)
            targetRow = cell.row + 1
        case .addRowAbove:
            model.rows.insert(emptyRow(columns: model.columns), at: cell.row)
        case .addColumnAfter:
            for index in model.rows.indices { model.rows[index].insert(emptyCell(), at: cell.column + 1) }
            model.columns += 1
            targetColumn = cell.column + 1
        case .addColumnBefore:
            for index in model.rows.indices { model.rows[index].insert(emptyCell(), at: cell.column) }
            model.columns += 1
        case .deleteRow:
            guard model.rows.count > 1 else { deleteTable(model, in: textView); return }
            model.rows.remove(at: cell.row)
            targetRow = min(cell.row, model.rows.count - 1)
        case .deleteColumn:
            guard model.columns > 1 else { deleteTable(model, in: textView); return }
            for index in model.rows.indices { model.rows[index].remove(at: cell.column) }
            model.columns -= 1
            targetColumn = min(cell.column, model.columns - 1)
        case .deleteTable:
            deleteTable(model, in: textView)
            return
        }

        let rebuilt = regenerateTable(rows: model.rows, columns: model.columns)
        var caretOffset = 0
        for (rowIndex, row) in model.rows.enumerated() {
            for (columnIndex, content) in row.enumerated() {
                if rowIndex == targetRow, columnIndex == targetColumn { break }
                caretOffset += max(content.length, 1)
            }
            if rowIndex == targetRow { break }
        }
        replace(model.range, with: rebuilt, in: textView, restoring: NSRange(location: model.range.location + caretOffset, length: 0))
        notifySelectionAttributesChange()
    }

    private func deleteTable(_ model: TableModel, in textView: NSTextView) {
        replace(model.range, with: NSAttributedString(string: ""), in: textView, restoring: NSRange(location: model.range.location, length: 0))
        textView.typingAttributes = defaultTypingAttributes
        notifySelectionAttributesChange()
    }

    /// Tab / Shift-Tab inside a table. Tab on the last cell appends a row.
    private func moveToAdjacentTableCell(forward: Bool) -> Bool {
        guard let textView else { return false }
        let selection = textView.selectedRange()
        guard let current = tableBlock(at: selection.location) else { return false }
        let storage = textView.attributedString()
        let nsString = storage.string as NSString
        let table = current.table
        let columns = table.numberOfColumns

        var targetRow = current.startingRow
        var targetColumn = current.startingColumn + (forward ? 1 : -1)
        if targetColumn >= columns { targetColumn = 0; targetRow += 1 }
        if targetColumn < 0 { targetColumn = columns - 1; targetRow -= 1 }
        guard targetRow >= 0 else { return true }

        if let range = cellRange(table: table, row: targetRow, column: targetColumn, storage: storage) {
            textView.setSelectedRange(NSRange(location: range.location, length: paragraphEnd(range, in: nsString) - range.location))
            textView.scrollRangeToVisible(textView.selectedRange())
            return true
        }

        guard forward else { return true }
        // Past the last cell: add a row after the table's final paragraph.
        guard let lastRange = lastCellRange(of: table, storage: storage) else { return true }
        let newRow = tableRow(table: table, row: targetRow, columns: columns)
        let insertAt = NSMaxRange(lastRange)
        replace(NSRange(location: insertAt, length: 0), with: newRow, in: textView, restoring: NSRange(location: insertAt, length: 0))
        notifySelectionAttributesChange()
        return true
    }

    /// AppKit derives typing attributes from the character before the
    /// caret. At the very end of the document that character can be a
    /// table cell's newline or a list item's, which would silently extend
    /// the table/list into the next paragraph typed. Reset to plain body
    /// attributes when the caret sits in an empty trailing paragraph.
    func sanitizeTypingAttributesAfterSelectionChange(in textView: NSTextView) {
        let selection = textView.selectedRange()
        guard selection.length == 0, let storage = textView.textStorage,
              selection.location == storage.length, storage.length > 0 else { return }
        let last = storage.string.utf16.last
        guard last == 0x0A else { return }
        guard let style = textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle,
              !style.textBlocks.isEmpty || style.headIndent > 0 else { return }
        var attributes = textView.typingAttributes
        let plain = style.mutableCopy() as! NSMutableParagraphStyle
        plain.textBlocks = []
        plain.firstLineHeadIndent = 0
        plain.headIndent = 0
        plain.tabStops = []
        plain.paragraphSpacing = Self.paragraphSpacing
        plain.paragraphSpacingBefore = 0
        attributes[.paragraphStyle] = plain
        textView.typingAttributes = attributes
    }

    // MARK: - Private: replacement plumbing

    /// Replaces a run of whole paragraphs and keeps the selection sensible:
    /// a range selection grows/shrinks to cover the rewritten paragraphs,
    /// a caret keeps its distance from the end of the block (so it stays
    /// after a marker that was just added or removed).
    private func rewriteBlock(_ union: NSRange, with replacement: NSAttributedString, in textView: NSTextView, originalSelection: NSRange) {
        let restored: NSRange
        if originalSelection.length > 0 {
            var length = replacement.length
            let selectedText = (textView.string as NSString).substring(with: originalSelection)
            if replacement.string.hasSuffix("\n"), !selectedText.hasSuffix("\n") {
                length -= 1
            }
            restored = NSRange(location: union.location, length: max(length, 0))
        } else {
            let distanceFromEnd = NSMaxRange(union) - originalSelection.location
            let location = max(union.location + replacement.length - distanceFromEnd, union.location)
            restored = NSRange(location: location, length: 0)
        }
        replace(union, with: replacement, in: textView, restoring: restored)
    }

    /// Single undoable replacement that preserves attributes, then places
    /// the selection.
    private func replace(_ range: NSRange, with replacement: NSAttributedString, in textView: NSTextView, restoring selection: NSRange) {
        guard let storage = textView.textStorage else { return }
        guard textView.shouldChangeText(in: range, replacementString: replacement.string) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        storage.endEditing()
        textView.didChangeText()

        let maxLocation = storage.length
        let location = min(max(selection.location, 0), maxLocation)
        let length = min(max(selection.length, 0), maxLocation - location)
        textView.setSelectedRange(NSRange(location: location, length: length))
    }

    private func transformFonts(_ transform: @escaping (NSFont) -> NSFont) {
        guard let textView else { return }
        let range = selectedRange(in: textView)

        if range.length == 0 {
            let current = (textView.typingAttributes[.font] as? NSFont) ?? font(for: .body, italic: false)
            textView.typingAttributes[.font] = transform(current)
        } else if let storage = textView.textStorage, textView.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let current = (value as? NSFont) ?? self.font(for: .body, italic: false)
                storage.addAttribute(.font, value: transform(current), range: subrange)
            }
            storage.endEditing()
            textView.didChangeText()
            if let font = textView.typingAttributes[.font] as? NSFont {
                textView.typingAttributes[.font] = transform(font)
            }
        }
        notifySelectionAttributesChange()
    }

    private func toggleIntegerAttribute(_ key: NSAttributedString.Key, on value: Int) {
        guard let textView else { return }
        let range = selectedRange(in: textView)

        if range.length == 0 {
            let current = textView.typingAttributes[key] as? Int ?? 0
            textView.typingAttributes[key] = current == 0 ? value : 0
        } else if let storage = textView.textStorage, textView.shouldChangeText(in: range, replacementString: nil) {
            // If any of the selection lacks the attribute, apply it to all;
            // otherwise remove it from all — the standard toggle behaviour.
            var allOn = true
            storage.enumerateAttribute(key, in: range, options: []) { existing, _, _ in
                if (existing as? Int ?? 0) == 0 { allOn = false }
            }
            storage.beginEditing()
            storage.addAttribute(key, value: allOn ? 0 : value, range: range)
            storage.endEditing()
            textView.didChangeText()
            textView.typingAttributes[key] = allOn ? 0 : value
        }
        notifySelectionAttributesChange()
    }

    // MARK: - Private: fonts

    func font(for style: TextStyle, italic: Bool) -> NSFont {
        makeFont(size: style.canonicalSize * zoom, weight: style.weight, italic: italic, monospaced: style.isMonospaced)
    }

    private func makeFont(size: CGFloat, weight: NSFont.Weight, italic: Bool, monospaced: Bool) -> NSFont {
        var font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private static func weight(of font: NSFont) -> NSFont.Weight {
        if let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
           let raw = traits[.weight] as? CGFloat {
            if raw >= NSFont.Weight.bold.rawValue - 0.01 { return .bold }
            if raw >= NSFont.Weight.semibold.rawValue - 0.01 { return .semibold }
            if raw >= NSFont.Weight.medium.rawValue - 0.01 { return .medium }
            return .regular
        }
        return font.fontDescriptor.symbolicTraits.contains(.bold) ? .bold : .regular
    }

    private static func resized(_ font: NSFont, to size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? NSFontManager.shared.convert(font, toSize: size)
    }

    private static func roundToHalf(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }

    private func bodyAttributes() -> [NSAttributedString.Key: Any] {
        defaultTypingAttributes
    }

    // MARK: - Private: selection helpers

    private func selectedRange(in textView: NSTextView) -> NSRange {
        let selected = textView.selectedRange()
        if selected.location == NSNotFound {
            return NSRange(location: 0, length: (textView.string as NSString).length)
        }
        return selected
    }

    private func fontAtSelection(in textView: NSTextView) -> NSFont? {
        attributesAtSelection(in: textView)[.font] as? NSFont
    }

    private func attributesAtSelection(in textView: NSTextView) -> [NSAttributedString.Key: Any] {
        let range = selectedRange(in: textView)
        guard let storage = textView.textStorage, storage.length > 0 else { return textView.typingAttributes }
        if range.length == 0 {
            return textView.typingAttributes
        }
        let location = min(range.location, storage.length - 1)
        return storage.attributes(at: location, effectiveRange: nil)
    }

    private func paragraphRanges(in nsString: NSString, intersecting range: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        let clampedLocation = min(max(range.location, 0), nsString.length)
        var location = nsString.paragraphRange(for: NSRange(location: clampedLocation, length: 0)).location
        let end = min(NSMaxRange(range), nsString.length)
        while true {
            let paragraph = nsString.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(paragraph)
            location = NSMaxRange(paragraph)
            if paragraph.length == 0 || location >= end { break }
        }
        return ranges
    }

    /// End of the paragraph's content, excluding its newline.
    private func paragraphEnd(_ paragraphRange: NSRange, in nsString: NSString) -> Int {
        Self.hasTrailingNewline(paragraphRange, in: nsString) ? NSMaxRange(paragraphRange) - 1 : NSMaxRange(paragraphRange)
    }

    private static func hasTrailingNewline(_ paragraphRange: NSRange, in nsString: NSString) -> Bool {
        guard paragraphRange.length > 0 else { return false }
        let last = nsString.character(at: NSMaxRange(paragraphRange) - 1)
        return last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029
    }

    // MARK: - Private: list model

    private struct ListMarker {
        let kind: ListKind
        let level: Int
        let ordinal: Int
        let text: String
        var markerLength: Int { text.utf16.count }
    }

    private func listMarker(inParagraph range: NSRange, storage: NSAttributedString) -> ListMarker? {
        guard range.length > 0, range.location < storage.length else { return nil }
        let text = (storage.string as NSString).substring(with: range)
        guard let match = Self.markerPattern.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) else {
            return nil
        }
        let markerText = (text as NSString).substring(with: match.range)
        let token = String(markerText.dropLast())  // drop the tab
        let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        let level = min(max(Int(((style?.firstLineHeadIndent ?? 0) / Self.listIndentUnit).rounded()), 0), Self.maxListLevel)

        if Self.bulletGlyphs.contains(token) {
            return ListMarker(kind: .bulleted, level: level, ordinal: 1, text: markerText)
        }
        let ordinal = Self.ordinal(fromNumberToken: String(token.dropLast()), level: level)
        return ListMarker(kind: .numbered, level: level, ordinal: ordinal, text: markerText)
    }

    private func strippedOfMarker(_ paragraph: NSAttributedString, marker: ListMarker?) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: paragraph)
        if let marker {
            mutable.deleteCharacters(in: NSRange(location: 0, length: min(marker.markerLength, mutable.length)))
        }
        let full = NSRange(location: 0, length: mutable.length)
        if mutable.length > 0 {
            mutable.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, subrange, _ in
                let style = ((value as? NSParagraphStyle) ?? self.defaultParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                style.firstLineHeadIndent = 0
                style.headIndent = 0
                style.tabStops = []
                mutable.addAttribute(.paragraphStyle, value: style, range: subrange)
            }
        }
        return mutable
    }

    /// Prefixes `content` (a marker-free paragraph, newline included if it
    /// had one) with a list marker and applies the hanging indent.
    private func withMarker(kind: ListKind, level: Int, ordinal: Int, content: NSAttributedString) -> NSAttributedString {
        let clampedLevel = min(max(level, 0), Self.maxListLevel)
        let markerText = Self.markerText(kind: kind, level: clampedLevel, ordinal: ordinal)

        var attributes: [NSAttributedString.Key: Any]
        if content.length > 0 {
            attributes = content.attributes(at: 0, effectiveRange: nil)
        } else {
            attributes = textView?.typingAttributes ?? defaultTypingAttributes
        }
        // Markers are always regular-weight body text so a bold first word
        // doesn't bold the bullet.
        let baseFont = (attributes[.font] as? NSFont) ?? font(for: .body, italic: false)
        attributes[.font] = makeFont(size: baseFont.pointSize, weight: .regular, italic: false, monospaced: false)
        attributes[.underlineStyle] = nil
        attributes[.strikethroughStyle] = nil

        let paragraphStyle = ((attributes[.paragraphStyle] as? NSParagraphStyle) ?? defaultParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        Self.applyListIndent(level: clampedLevel, to: paragraphStyle)
        attributes[.paragraphStyle] = paragraphStyle
        attributes[.foregroundColor] = NSColor.labelColor

        let result = NSMutableAttributedString(string: markerText, attributes: attributes)
        result.append(content)
        let full = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, subrange, _ in
            let style = ((value as? NSParagraphStyle) ?? self.defaultParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            Self.applyListIndent(level: clampedLevel, to: style)
            result.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        return result
    }

    private static func applyListIndent(level: Int, to style: NSMutableParagraphStyle) {
        let indent = CGFloat(level) * listIndentUnit
        style.firstLineHeadIndent = indent
        style.headIndent = indent + listMarkerWidth
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + listMarkerWidth)]
        style.defaultTabInterval = listIndentUnit
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = 2
    }

    private static func markerText(kind: ListKind, level: Int, ordinal: Int) -> String {
        switch kind {
        case .bulleted:
            return bulletGlyphs[min(level, bulletGlyphs.count - 1)] + "\t"
        case .numbered:
            return numberToken(ordinal: ordinal, level: level) + ".\t"
        }
    }

    /// 1. / a. / i. / 1. by depth.
    private static func numberToken(ordinal: Int, level: Int) -> String {
        switch level % 3 {
        case 1:
            let scalar = UnicodeScalar(UInt32(97 + max(min(ordinal, 26), 1) - 1))!
            return String(Character(scalar))
        case 2:
            return romanNumeral(for: ordinal)
        default:
            return String(ordinal)
        }
    }

    private static func ordinal(fromNumberToken token: String, level: Int) -> Int {
        if let value = Int(token) { return value }
        let lower = token.lowercased()
        if level % 3 == 2 || ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"].contains(lower) {
            if let index = romanNumerals.firstIndex(of: lower) { return index + 1 }
        }
        if let scalar = lower.unicodeScalars.first, lower.count == 1 {
            return Int(scalar.value) - 96
        }
        return 1
    }

    private static let romanNumerals = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii", "xiii", "xiv", "xv", "xvi", "xvii", "xviii", "xix", "xx"]

    private static func romanNumeral(for value: Int) -> String {
        guard value >= 1 else { return "i" }
        if value <= romanNumerals.count { return romanNumerals[value - 1] }
        return String(value)
    }

    private func attributesForContinuation(in textView: NSTextView, paragraphRange: NSRange) -> [NSAttributedString.Key: Any] {
        var attributes = textView.typingAttributes
        attributes[.foregroundColor] = NSColor.labelColor
        if let style = textView.attributedString().attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) {
            attributes[.paragraphStyle] = style
        }
        return attributes
    }

    private func adjustListLevel(delta: Int) -> Bool {
        guard let textView else { return false }
        let selection = selectedRange(in: textView)
        let storage = textView.attributedString()
        let nsString = storage.string as NSString
        let ranges = paragraphRanges(in: nsString, intersecting: selection)
        let markers = ranges.map { listMarker(inParagraph: $0, storage: storage) }
        guard markers.contains(where: { $0 != nil }) else { return false }

        var changed = false
        let rewritten: [NSAttributedString] = zip(ranges, markers).map { range, marker in
            let paragraph = storage.attributedSubstring(from: range)
            guard let marker else { return paragraph }
            let target = min(max(marker.level + delta, 0), Self.maxListLevel)
            guard target != marker.level else { return paragraph }
            changed = true
            return withMarker(kind: marker.kind, level: target, ordinal: 1, content: strippedOfMarker(paragraph, marker: marker))
        }
        guard changed, let first = ranges.first, let last = ranges.last else { return true }

        let union = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let replacement = NSMutableAttributedString()
        rewritten.forEach { replacement.append($0) }
        rewriteBlock(union, with: replacement, in: textView, originalSelection: selection)
        renumberLists(around: textView.selectedRange())
        notifySelectionAttributesChange()
        return true
    }

    /// Contiguous run of list paragraphs around `range`, or nil when the
    /// range doesn't touch a list.
    private func listBlockRange(around range: NSRange, storage: NSAttributedString) -> NSRange? {
        let nsString = storage.string as NSString
        guard nsString.length > 0 else { return nil }
        let anchor = nsString.paragraphRange(for: NSRange(location: min(range.location, nsString.length), length: 0))

        var start = anchor.location
        var end = NSMaxRange(anchor)
        var sawList = listMarker(inParagraph: anchor, storage: storage) != nil

        // Expand upward.
        var probe = start
        while probe > 0 {
            let previous = nsString.paragraphRange(for: NSRange(location: probe - 1, length: 0))
            guard listMarker(inParagraph: previous, storage: storage) != nil else { break }
            sawList = true
            start = previous.location
            probe = previous.location
        }
        // Expand downward.
        probe = end
        while probe < nsString.length {
            let next = nsString.paragraphRange(for: NSRange(location: probe, length: 0))
            guard next.length > 0, listMarker(inParagraph: next, storage: storage) != nil else { break }
            sawList = true
            end = NSMaxRange(next)
            probe = end
        }
        guard sawList else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Converts `• item` / `1. item` text with space-indents (the format
    /// used before the paragraph-style list engine) into real markers.
    private func migrateLegacyLists(in mutable: NSMutableAttributedString) {
        let nsString = mutable.string as NSString
        guard nsString.length > 0 else { return }
        var location = 0
        var edits: [(NSRange, NSAttributedString)] = []

        while location < nsString.length {
            let paragraphRange = nsString.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paragraphRange) }
            guard paragraphRange.length > 0 else { break }
            let text = nsString.substring(with: paragraphRange)
            guard let match = Self.legacyMarkerPattern.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) else {
                continue
            }
            let indentText = (text as NSString).substring(with: match.range(at: 1))
            let token = (text as NSString).substring(with: match.range(at: 2))
            let level = min(indentText.replacingOccurrences(of: "\t", with: "    ").count / 4, Self.maxListLevel)
            let kind: ListKind = token == "•" ? .bulleted : .numbered
            let ordinal = kind == .numbered ? Self.ordinal(fromNumberToken: String(token.dropLast()), level: level) : 1

            let content = mutable.attributedSubstring(from: NSRange(location: paragraphRange.location + match.range.length, length: paragraphRange.length - match.range.length))
            let rebuilt = withMarker(kind: kind, level: level, ordinal: ordinal, content: content)
            edits.append((paragraphRange, rebuilt))
        }

        for (range, replacement) in edits.reversed() {
            mutable.replaceCharacters(in: range, with: replacement)
        }
    }

    // MARK: - Private: table model

    private func tableBlock(at location: Int) -> NSTextTableBlock? {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return nil }
        let safe = min(max(location, 0), storage.length - 1)
        let style = storage.attribute(.paragraphStyle, at: safe, effectiveRange: nil) as? NSParagraphStyle
        return style?.textBlocks.compactMap { $0 as? NSTextTableBlock }.first
    }

    private func cellRange(table: NSTextTable, row: Int, column: Int, storage: NSAttributedString) -> NSRange? {
        let nsString = storage.string as NSString
        var location = 0
        while location < nsString.length {
            let paragraph = nsString.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            if let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle,
               let block = style.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first,
               block.table === table, block.startingRow == row, block.startingColumn == column {
                return paragraph
            }
            location = NSMaxRange(paragraph)
        }
        return nil
    }

    private func lastCellRange(of table: NSTextTable, storage: NSAttributedString) -> NSRange? {
        let nsString = storage.string as NSString
        var location = 0
        var last: NSRange?
        while location < nsString.length {
            let paragraph = nsString.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            if let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle,
               let block = style.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first,
               block.table === table {
                last = paragraph
            }
            location = NSMaxRange(paragraph)
        }
        return last
    }

    private func tableRow(table: NSTextTable, row: Int, columns: Int) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for column in 0..<columns {
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            block.setContentWidth(100 / CGFloat(columns), type: .percentageValueType)
            Self.applyCellAppearance(to: block)

            let style = defaultParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = 0
            style.lineSpacing = 2
            style.textBlocks = [block]

            var attributes = bodyAttributes()
            attributes[.paragraphStyle] = style
            result.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        return result
    }

    /// A table as a grid of cell contents (each cell's paragraphs, newlines
    /// included) plus the document range it occupies.
    private struct TableModel {
        let table: NSTextTable
        let range: NSRange
        var rows: [[NSAttributedString]]
        var columns: Int
        /// Document location where each cell starts, by (row, column).
        let cellStarts: [[Int]]

        func cell(containing location: Int) -> (row: Int, column: Int)? {
            var found: (Int, Int)?
            for (rowIndex, row) in cellStarts.enumerated() {
                for (columnIndex, start) in row.enumerated() where start <= location {
                    found = (rowIndex, columnIndex)
                }
            }
            return found
        }
    }

    private func tableModel(at location: Int) -> TableModel? {
        guard let textView, let anchor = tableBlock(at: location) else { return nil }
        let storage = textView.attributedString()
        let nsString = storage.string as NSString
        let table = anchor.table
        let columns = max(table.numberOfColumns, 1)

        var cells: [Int: [Int: NSMutableAttributedString]] = [:]
        var starts: [Int: [Int: Int]] = [:]
        var rangeStart: Int?
        var rangeEnd = 0
        var probe = 0
        while probe < nsString.length {
            let paragraph = nsString.paragraphRange(for: NSRange(location: probe, length: 0))
            guard paragraph.length > 0 else { break }
            defer { probe = NSMaxRange(paragraph) }
            guard let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle,
                  let block = style.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first,
                  block.table === table else {
                if rangeStart != nil { break }
                continue
            }
            if rangeStart == nil { rangeStart = paragraph.location }
            rangeEnd = NSMaxRange(paragraph)
            let content = storage.attributedSubstring(from: paragraph)
            if let existing = cells[block.startingRow]?[block.startingColumn] {
                existing.append(content)
            } else {
                cells[block.startingRow, default: [:]][block.startingColumn] = NSMutableAttributedString(attributedString: content)
                starts[block.startingRow, default: [:]][block.startingColumn] = paragraph.location
            }
        }
        guard let rangeStart else { return nil }

        let rowCount = (cells.keys.max() ?? 0) + 1
        var rows: [[NSAttributedString]] = []
        var cellStarts: [[Int]] = []
        for row in 0..<rowCount {
            var rowCells: [NSAttributedString] = []
            var rowStarts: [Int] = []
            for column in 0..<columns {
                rowCells.append(cells[row]?[column] ?? emptyCell())
                rowStarts.append(starts[row]?[column] ?? rangeEnd)
            }
            rows.append(rowCells)
            cellStarts.append(rowStarts)
        }
        return TableModel(table: table, range: NSRange(location: rangeStart, length: rangeEnd - rangeStart), rows: rows, columns: columns, cellStarts: cellStarts)
    }

    private func emptyCell() -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: bodyAttributes())
    }

    private func emptyRow(columns: Int) -> [NSAttributedString] {
        (0..<columns).map { _ in emptyCell() }
    }

    private func regenerateTable(rows: [[NSAttributedString]], columns: Int) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.layoutAlgorithm = .automaticLayoutAlgorithm

        let result = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: columnIndex, columnSpan: 1)
                block.setContentWidth(100 / CGFloat(columns), type: .percentageValueType)
                Self.applyCellAppearance(to: block)

                let source = columnIndex < row.count ? row[columnIndex] : emptyCell()
                let cell = NSMutableAttributedString(attributedString: source.length > 0 ? source : emptyCell())
                if !cell.string.hasSuffix("\n") {
                    cell.append(NSAttributedString(string: "\n", attributes: cell.attributes(at: cell.length - 1, effectiveRange: nil)))
                }
                let full = NSRange(location: 0, length: cell.length)
                cell.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, subrange, _ in
                    let style = ((value as? NSParagraphStyle) ?? self.defaultParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                    style.textBlocks = [block]
                    style.paragraphSpacing = 0
                    style.lineSpacing = 2
                    cell.addAttribute(.paragraphStyle, value: style, range: subrange)
                }
                result.append(cell)
            }
        }
        return result
    }

    private static func applyCellAppearance(to block: NSTextTableBlock) {
        // Tertiary label is a touch stronger than separatorColor, which all
        // but disappears on the dark glass sheet.
        block.setBorderColor(NSColor.tertiaryLabelColor)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        block.setWidth(0, type: .absoluteValueType, for: .margin)
        block.backgroundColor = nil
        block.table.collapsesBorders = true
        block.table.hidesEmptyCells = false
    }
}
