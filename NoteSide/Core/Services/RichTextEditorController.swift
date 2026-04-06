import AppKit

@MainActor
final class RichTextEditorController {
    private enum NumberedListKind {
        case decimal(Int)
        case alphabetic(Character)
        case roman(String)
    }

    struct FormattingState {
        let textStyle: TextStyle
        let isBold: Bool
        let isItalic: Bool
        let isUnderlined: Bool
    }

    enum TextStyle: String {
        case heading
        case subheading
        case body

        var title: String {
            switch self {
            case .heading:
                return "Heading"
            case .subheading:
                return "Subheading"
            case .body:
                return "Body"
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .heading:
                return 24
            case .subheading:
                return 18
            case .body:
                return 15
            }
        }

        var weight: NSFont.Weight {
            switch self {
            case .heading:
                return .bold
            case .subheading:
                return .semibold
            case .body:
                return .regular
            }
        }
    }

    weak var textView: NSTextView?
    var onSelectionAttributesChange: ((FormattingState) -> Void)?

    func attach(_ textView: NSTextView) {
        self.textView = textView
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func currentAttributedText() -> NSAttributedString? {
        guard let textView else { return nil }
        return NSAttributedString(attributedString: textView.attributedString())
    }

    func toggleBold() {
        toggleTrait(.boldFontMask)
    }

    func toggleItalic() {
        toggleTrait(.italicFontMask)
    }

    func toggleUnderline() {
        guard let textView else { return }
        let range = selectedRange(in: textView)
        guard range.location != NSNotFound else { return }

        if range.length == 0 {
            let current = textView.typingAttributes[.underlineStyle] as? Int ?? 0
            let next = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes[.underlineStyle] = next
            textView.didChangeText()
            notifySelectionAttributesChange()
            return
        }

        textView.textStorage?.beginEditing()
        textView.textStorage?.enumerateAttribute(.underlineStyle, in: range, options: []) { value, subrange, _ in
            let current = value as? Int ?? 0
            let next = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            textView.textStorage?.addAttribute(.underlineStyle, value: next, range: subrange)
        }
        textView.textStorage?.endEditing()
        textView.didChangeText()
        notifySelectionAttributesChange()
    }

    func apply(style: TextStyle) {
        guard let textView else { return }
        let range = selectedRange(in: textView)
        guard range.location != NSNotFound else { return }

        let currentFont = (textView.typingAttributes[.font] as? NSFont) ?? textView.font ?? .systemFont(ofSize: style.fontSize)
        let font = font(for: style, basedOn: currentFont)

        if range.length == 0 {
            let nsString = textView.string as NSString
            if range.location <= nsString.length {
                let paragraphLocation = min(range.location, max(nsString.length - 1, 0))
                let paragraphRange = nsString.paragraphRange(for: NSRange(location: paragraphLocation, length: 0))
                let paragraphText = nsString.substring(with: paragraphRange).trimmingCharacters(in: .newlines)

                if !paragraphText.isEmpty,
                   numberedListKind(in: paragraphText.trimmingCharacters(in: .whitespaces)) == nil,
                   !paragraphText.trimmingCharacters(in: .whitespaces).hasPrefix("•") {
                    textView.textStorage?.addAttribute(.font, value: font, range: paragraphRange)
                }
            }
            textView.typingAttributes[.font] = font
        } else {
            textView.textStorage?.addAttribute(.font, value: font, range: range)
            textView.typingAttributes[.font] = font
        }

        textView.didChangeText()
        notifySelectionAttributesChange()
    }

    func insertBulletedList() {
        toggleList(
            matchesLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed == "•" || trimmed.hasPrefix("• ")
            },
            replacement: { lines in
                lines.map { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let indent = self.leadingIndent(in: line)
                    return trimmed.isEmpty ? indent + "• " : indent + "• " + trimmed
                }
            }
        )
    }

    func insertNumberedList() {
        toggleList(
            matchesLine: { line in
                numberedListKind(in: line.trimmingCharacters(in: .whitespaces)) != nil
            },
            replacement: { lines in
                lines.enumerated().map { index, line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let indent = self.leadingIndent(in: line)
                    return trimmed.isEmpty ? indent + "\(index + 1). " : indent + "\(index + 1). " + trimmed
                }
            }
        )
    }

    func handleReturn() -> Bool {
        guard let textView else { return false }
        let selectedRange = textView.selectedRange()
        guard selectedRange.length == 0 else { return false }

        let nsString = textView.string as NSString
        guard selectedRange.location <= nsString.length else { return false }

        let paragraphRange = nsString.paragraphRange(for: NSRange(location: selectedRange.location, length: 0))
        let paragraph = nsString.substring(with: paragraphRange)
        let trimmedParagraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)

        let indent = leadingIndent(in: paragraph)

        if trimmedParagraph == "•" {
            textView.insertText("", replacementRange: paragraphRange)
            textView.didChangeText()
            return true
        }

        if let kind = numberedListKind(in: trimmedParagraph), trimmedParagraph == listMarker(for: kind) {
            textView.insertText("", replacementRange: paragraphRange)
            textView.didChangeText()
            return true
        }

        if trimmedParagraph.hasPrefix("• ") {
            insertContinuation(prefix: "\n\(indent)• ")
            return true
        }

        if let kind = numberedListKind(in: trimmedParagraph), trimmedParagraph.hasPrefix("\(listMarker(for: kind)) ") {
            insertContinuation(prefix: "\n\(indent)\(listMarker(for: nextListKind(after: kind))) ")
            return true
        }

        let currentStyle = currentTextStyle()
        if currentStyle != .body {
            insertBodyStyledNewline()
            return true
        }

        return false
    }

    func indentSelection() -> Bool {
        adjustIndentation(delta: 1)
    }

    func outdentSelection() -> Bool {
        adjustIndentation(delta: -1)
    }

    func normalizedAttributedText(_ attributedText: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutable.length)

        if mutable.length > 0 {
            mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        }

        return mutable
    }

    func currentTextStyle() -> TextStyle {
        guard let textView else { return .body }
        let font = currentSelectionFont(in: textView) ?? .systemFont(ofSize: TextStyle.body.fontSize)
        return textStyle(for: font)
    }

    func currentFormattingState() -> FormattingState {
        guard let textView else {
            return FormattingState(textStyle: .body, isBold: false, isItalic: false, isUnderlined: false)
        }

        let font = currentSelectionFont(in: textView) ?? .systemFont(ofSize: TextStyle.body.fontSize)
        let traits = NSFontManager.shared.traits(of: font)
        let underlineValue = underlineValueAtSelection(in: textView)

        return FormattingState(
            textStyle: textStyle(for: font),
            isBold: traits.contains(.boldFontMask),
            isItalic: traits.contains(.italicFontMask),
            isUnderlined: underlineValue != 0
        )
    }

    @discardableResult
    func handleAutoListTrigger(for affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let textView else { return false }
        guard replacementString == " ", affectedCharRange.location != NSNotFound, affectedCharRange.length == 0 else { return false }

        let nsString = textView.string as NSString
        guard affectedCharRange.location <= nsString.length else { return false }

        let paragraphRange = nsString.paragraphRange(for: NSRange(location: affectedCharRange.location, length: 0))
        let paragraph = nsString.substring(with: paragraphRange).trimmingCharacters(in: .newlines)
        let beforeCaretLocation = max(affectedCharRange.location - paragraphRange.location, 0)
        let beforeCaret = (paragraph as NSString).substring(to: beforeCaretLocation)
        let trigger = beforeCaret.trimmingCharacters(in: .whitespaces)

        let replacement: String
        switch trigger {
        case "-":
            replacement = "• "
        case "1", "1.":
            replacement = "1. "
        default:
            return false
        }

        let indent = leadingIndent(in: beforeCaret)
        let lineRange = NSRange(location: paragraphRange.location, length: beforeCaret.utf16.count)
        textView.insertText(indent + replacement, replacementRange: lineRange)
        textView.didChangeText()
        notifySelectionAttributesChange()
        return true
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let textView else { return }
        let range = selectedRange(in: textView)
        guard range.location != NSNotFound else { return }

        let applyConvertedFont: (NSFont) -> NSFont = { font in
            let manager = NSFontManager.shared
            if manager.traits(of: font).contains(trait) {
                return manager.convert(font, toNotHaveTrait: trait)
            }
            return manager.convert(font, toHaveTrait: trait)
        }

        if range.length == 0 {
            let currentFont = (textView.typingAttributes[.font] as? NSFont) ?? textView.font ?? .systemFont(ofSize: 15)
            textView.typingAttributes[.font] = applyConvertedFont(currentFont)
        } else {
            textView.textStorage?.beginEditing()
            textView.textStorage?.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let currentFont = (value as? NSFont) ?? textView.font ?? .systemFont(ofSize: 15)
                textView.textStorage?.addAttribute(.font, value: applyConvertedFont(currentFont), range: subrange)
            }
            textView.textStorage?.endEditing()
        }
        textView.didChangeText()
        notifySelectionAttributesChange()
    }

    private func selectedRange(in textView: NSTextView) -> NSRange {
        let selected = textView.selectedRange()
        if selected.location == NSNotFound {
            return NSRange(location: 0, length: textView.string.count)
        }
        return selected
    }

    private func toggleList(
        matchesLine: (String) -> Bool,
        replacement: ([String]) -> [String]
    ) {
        guard let textView else { return }

        let selectedRange = textView.selectedRange()
        let nsString = textView.string as NSString
        let paragraphRange = nsString.paragraphRange(for: selectedRange)
        let selectedText = nsString.substring(with: paragraphRange)
        let lines = selectedText.components(separatedBy: .newlines)

        let shouldRemove = lines.contains { matchesLine($0) }
        let transformedLines: [String]

        if shouldRemove {
            transformedLines = lines.map(removeListPrefix(from:))
        } else {
            transformedLines = replacement(lines)
        }

        let updatedText = transformedLines.joined(separator: "\n")
        textView.insertText(updatedText, replacementRange: paragraphRange)
        textView.didChangeText()
        notifySelectionAttributesChange()
    }

    private func adjustIndentation(delta: Int) -> Bool {
        guard let textView else { return false }

        let selectedRange = textView.selectedRange()
        let nsString = textView.string as NSString
        let blockRange = surroundingListBlockRange(in: nsString, around: selectedRange)
        let paragraphRange = nsString.paragraphRange(for: selectedRange)
        let selectedText = nsString.substring(with: paragraphRange)
        let lines = selectedText.components(separatedBy: .newlines)

        let transformed = lines.map { line in
            transformIndentation(for: line, delta: delta)
        }

        guard transformed != lines else { return false }

        let replacement = transformed.joined(separator: "\n")
        let blockText = nsString.substring(with: blockRange) as NSString
        let relativeParagraphRange = NSRange(location: paragraphRange.location - blockRange.location, length: paragraphRange.length)
        let updatedBlockText = blockText.replacingCharacters(in: relativeParagraphRange, with: replacement)
        let normalizedBlockText = renumberNumberedLists(in: updatedBlockText)

        textView.insertText(normalizedBlockText, replacementRange: blockRange)
        textView.didChangeText()
        notifySelectionAttributesChange()
        return true
    }

    private func insertContinuation(prefix: String) {
        guard let textView else { return }

        let insertionAttributes = typingAttributes(for: textView)
        textView.insertText(prefix, replacementRange: textView.selectedRange())
        let insertedRange = NSRange(location: textView.selectedRange().location - prefix.count, length: prefix.count)
        textView.textStorage?.addAttributes(insertionAttributes, range: insertedRange)
        textView.didChangeText()
        notifySelectionAttributesChange()
    }

    private func insertBodyStyledNewline() {
        guard let textView else { return }

        let currentFont = currentSelectionFont(in: textView) ?? .systemFont(ofSize: TextStyle.body.fontSize)
        var attributes = typingAttributes(for: textView)
        attributes[.font] = font(for: .body, basedOn: currentFont)
        textView.typingAttributes = attributes
        textView.insertText("\n", replacementRange: textView.selectedRange())
        textView.didChangeText()
        notifySelectionAttributesChange()
    }

    private func typingAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
        var attributes = textView.typingAttributes
        attributes[.foregroundColor] = NSColor.labelColor
        attributes[.paragraphStyle] = textView.defaultParagraphStyle ?? NSParagraphStyle.default
        return attributes
    }

    private func numberedListKind(in paragraph: String) -> NumberedListKind? {
        if let regex = try? NSRegularExpression(pattern: #"^(\d+)\."#) {
            let range = NSRange(location: 0, length: paragraph.utf16.count)
            if
                let match = regex.firstMatch(in: paragraph, options: [], range: range),
                let numberRange = Range(match.range(at: 1), in: paragraph),
                let value = Int(paragraph[numberRange])
            {
                return .decimal(value)
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"^([a-z])\."#, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: paragraph.utf16.count)
            if
                let match = regex.firstMatch(in: paragraph, options: [], range: range),
                let letterRange = Range(match.range(at: 1), in: paragraph),
                let value = paragraph[letterRange].lowercased().first
            {
                return .alphabetic(value)
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"^(i{1,3}|iv|v|vi{0,3}|ix|x)\."#, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: paragraph.utf16.count)
            if
                let match = regex.firstMatch(in: paragraph, options: [], range: range),
                let romanRange = Range(match.range(at: 1), in: paragraph)
            {
                return .roman(String(paragraph[romanRange]).lowercased())
            }
        }

        return nil
    }

    private func leadingIndent(in paragraph: String) -> String {
        String(paragraph.prefix { $0 == " " || $0 == "\t" })
    }

    private func transformIndentation(for line: String, delta: Int) -> String {
        let indent = leadingIndent(in: line)
        let content = String(line.dropFirst(indent.count))

        guard content.hasPrefix("• ") || numberedListKind(in: content) != nil else {
            return line
        }

        if delta > 0 {
            let targetLevel = min(listIndentLevel(for: indent) + delta, 2)
            return rebuildIndentedListLine(content: content, targetLevel: targetLevel)
        }

        let targetLevel = max(listIndentLevel(for: indent) + delta, 0)
        return rebuildIndentedListLine(content: content, targetLevel: targetLevel)
    }

    private func removeListPrefix(from line: String) -> String {
        let indent = leadingIndent(in: line)
        let content = String(line.dropFirst(indent.count))
        let trimmedContent = content.trimmingCharacters(in: .whitespaces)

        if trimmedContent == "•" {
            return indent
        }

        if trimmedContent.hasPrefix("• ") {
            let updated = trimmedContent.replacingOccurrences(of: "• ", with: "", options: [], range: trimmedContent.startIndex..<trimmedContent.index(trimmedContent.startIndex, offsetBy: 2))
            return indent + updated
        }

        if let range = numberedListPrefixRange(in: trimmedContent) {
            let updated = String(trimmedContent[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return indent + updated
        }

        return line
    }

    private func numberedListPrefixRange(in paragraph: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: #"^(?:\d+|[a-z]+|i{1,3}|iv|v|vi{0,3}|ix|x)\.(?:\s|$)"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(location: 0, length: paragraph.utf16.count)
        guard
            let match = regex.firstMatch(in: paragraph, options: [], range: range),
            let swiftRange = Range(match.range, in: paragraph)
        else {
            return nil
        }

        return swiftRange
    }

    private func surroundingListBlockRange(in nsString: NSString, around selectedRange: NSRange) -> NSRange {
        let initialParagraphRange = nsString.paragraphRange(for: selectedRange)
        var blockStart = initialParagraphRange.location
        var blockEnd = NSMaxRange(initialParagraphRange)

        var scanLocation = blockStart
        while scanLocation > 0 {
            let previousParagraphRange = nsString.paragraphRange(for: NSRange(location: max(scanLocation - 1, 0), length: 0))
            let line = nsString.substring(with: previousParagraphRange)
            guard isListLine(line) else { break }
            blockStart = previousParagraphRange.location
            scanLocation = previousParagraphRange.location
        }

        scanLocation = blockEnd
        while scanLocation < nsString.length {
            let nextParagraphRange = nsString.paragraphRange(for: NSRange(location: scanLocation, length: 0))
            if nextParagraphRange.location == initialParagraphRange.location && nextParagraphRange.length == initialParagraphRange.length {
                scanLocation = NSMaxRange(nextParagraphRange)
                continue
            }

            let line = nsString.substring(with: nextParagraphRange)
            guard isListLine(line) else { break }
            blockEnd = NSMaxRange(nextParagraphRange)
            scanLocation = blockEnd
        }

        return NSRange(location: blockStart, length: blockEnd - blockStart)
    }

    private func isListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("• ") || numberedListKind(in: trimmed) != nil
    }

    private func fontAtSelection(in textView: NSTextView, location: Int) -> NSFont? {
        guard let textStorage = textView.textStorage, textStorage.length > 0 else {
            return (textView.typingAttributes[.font] as? NSFont) ?? textView.font
        }

        let safeLocation = min(location, textStorage.length - 1)
        return (textStorage.attribute(.font, at: safeLocation, effectiveRange: nil) as? NSFont)
            ?? (textView.typingAttributes[.font] as? NSFont)
            ?? textView.font
    }

    private func currentSelectionFont(in textView: NSTextView) -> NSFont? {
        let range = selectedRange(in: textView)

        if range.length == 0, let typingFont = textView.typingAttributes[.font] as? NSFont {
            return typingFont
        }

        let location = max(0, min(range.location, max(textView.string.count - 1, 0)))
        return fontAtSelection(in: textView, location: location)
    }

    func notifySelectionAttributesChange() {
        onSelectionAttributesChange?(currentFormattingState())
    }

    private func underlineValueAtSelection(in textView: NSTextView) -> Int {
        let range = selectedRange(in: textView)
        if range.length == 0, let typingUnderline = textView.typingAttributes[.underlineStyle] as? Int {
            return typingUnderline
        }

        guard let textStorage = textView.textStorage, textStorage.length > 0 else {
            return textView.typingAttributes[.underlineStyle] as? Int ?? 0
        }

        let location = max(0, min(range.location, max(textView.string.count - 1, 0)))
        let safeLocation = min(location, textStorage.length - 1)
        return (textStorage.attribute(.underlineStyle, at: safeLocation, effectiveRange: nil) as? Int)
            ?? (textView.typingAttributes[.underlineStyle] as? Int)
            ?? 0
    }

    private func font(for style: TextStyle, basedOn currentFont: NSFont) -> NSFont {
        let traits = NSFontManager.shared.traits(of: currentFont)
        var symbolicTraits = currentFont.fontDescriptor.symbolicTraits

        if traits.contains(.italicFontMask) {
            symbolicTraits.insert(.italic)
        } else {
            symbolicTraits.remove(.italic)
        }

        let descriptor = currentFont.fontDescriptor
            .withSymbolicTraits(symbolicTraits)
            .addingAttributes([
                .traits: [
                    NSFontDescriptor.TraitKey.weight: style.weight
                ]
            ])

        return NSFont(descriptor: descriptor, size: style.fontSize)
            ?? NSFont.systemFont(ofSize: style.fontSize, weight: style.weight)
    }

    private func textStyle(for font: NSFont) -> TextStyle {
        if font.pointSize >= 22 {
            return .heading
        }
        if font.pointSize >= 17 {
            return .subheading
        }
        return .body
    }

    private func listIndentLevel(for indent: String) -> Int {
        let indentUnit = "    "
        let normalized = indent.replacingOccurrences(of: "\t", with: indentUnit)
        return min(normalized.count / indentUnit.count, 2)
    }

    private func rebuildIndentedListLine(content: String, targetLevel: Int) -> String {
        let indentUnit = "    "
        let targetIndent = String(repeating: indentUnit, count: targetLevel)

        if content.hasPrefix("• ") {
            return targetIndent + content
        }

        guard let range = numberedListPrefixRange(in: content) else {
            return targetIndent + content
        }

        let body = String(content[range.upperBound...])
        let marker = defaultListMarker(forLevel: targetLevel)
        return targetIndent + "\(marker) " + body
    }

    private func renumberNumberedLists(in text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var counters = [0, 0, 0]

        let normalizedLines = lines.map { line -> String in
            let indent = leadingIndent(in: line)
            let content = String(line.dropFirst(indent.count))

            guard numberedListKind(in: content) != nil else {
                if !content.hasPrefix("• ") {
                    counters = [0, 0, 0]
                }
                return line
            }

            let level = min(listIndentLevel(for: indent), 2)
            counters[level] += 1
            if level < 2 { counters[level + 1] = 0 }
            if level < 1 { counters[level + 2] = 0 }

            guard let prefixRange = numberedListPrefixRange(in: content) else {
                return line
            }

            let body = String(content[prefixRange.upperBound...])
            let marker = listMarker(forLevel: level, ordinal: counters[level])
            return String(repeating: "    ", count: level) + "\(marker) " + body
        }

        return normalizedLines.joined(separator: "\n")
    }

    private func defaultListMarker(forLevel level: Int) -> String {
        switch level {
        case 1:
            return "a."
        case 2:
            return "i."
        default:
            return "1."
        }
    }

    private func listMarker(forLevel level: Int, ordinal: Int) -> String {
        switch level {
        case 1:
            let scalarValue = UnicodeScalar((Character("a").unicodeScalars.first?.value ?? 97) + UInt32(max(ordinal - 1, 0))) ?? Character("z").unicodeScalars.first!
            return "\(Character(scalarValue))."
        case 2:
            return "\(romanNumeral(for: ordinal))."
        default:
            return "\(ordinal)."
        }
    }

    private func listMarker(for kind: NumberedListKind) -> String {
        switch kind {
        case .decimal(let value):
            return "\(value)."
        case .alphabetic(let character):
            return "\(character)."
        case .roman(let value):
            return "\(value)."
        }
    }

    private func nextListKind(after kind: NumberedListKind) -> NumberedListKind {
        switch kind {
        case .decimal(let value):
            return .decimal(value + 1)
        case .alphabetic(let character):
            let scalar = character.unicodeScalars.first?.value ?? Character("a").unicodeScalars.first!.value
            let nextScalar = UnicodeScalar(min(scalar + 1, Character("z").unicodeScalars.first!.value)) ?? Character("z").unicodeScalars.first!
            return .alphabetic(Character(nextScalar))
        case .roman(let value):
            return .roman(nextRomanNumeral(after: value))
        }
    }

    private func nextRomanNumeral(after value: String) -> String {
        let numerals = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]
        guard let index = numerals.firstIndex(of: value.lowercased()), index + 1 < numerals.count else {
            return "i"
        }
        return numerals[index + 1]
    }

    private func romanNumeral(for value: Int) -> String {
        let numerals = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]
        guard value >= 1, value <= numerals.count else {
            return numerals.last ?? "x"
        }
        return numerals[value - 1]
    }
}
