import AppKit
import XCTest
@testable import Remora

/// Exercises the editing engine against a real (offscreen) NSTextView so
/// paragraph ranges, undo plumbing and attribute preservation are tested
/// the way the app uses them.
@MainActor
final class RichTextEditorControllerTests: XCTestCase {
    private var controller: RichTextEditorController!
    private var textView: NSTextView!

    override func setUp() async throws {
        controller = RichTextEditorController()
        controller.setZoom(1)
        textView = NSTextView(usingTextLayoutManager: false)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        textView.defaultParagraphStyle = controller.defaultParagraphStyle
        textView.typingAttributes = controller.defaultTypingAttributes
        controller.attach(textView)
    }

    private func load(_ string: String) {
        let attributed = NSAttributedString(string: string, attributes: controller.defaultTypingAttributes)
        textView.textStorage?.setAttributedString(controller.normalizedAttributedText(attributed))
        textView.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
    }

    private func caret(_ location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    private var text: String { textView.string }

    private func font(at location: Int) -> NSFont {
        textView.attributedString().attribute(.font, at: location, effectiveRange: nil) as! NSFont
    }

    private func paragraphStyle(at location: Int) -> NSParagraphStyle {
        textView.attributedString().attribute(.paragraphStyle, at: location, effectiveRange: nil) as! NSParagraphStyle
    }

    // MARK: Styles

    func testApplyHeadingChangesWholeParagraphAndReportsStyle() {
        load("First line\nSecond line")
        caret(3)
        controller.apply(style: .heading)

        XCTAssertEqual(font(at: 0).pointSize, 22)
        XCTAssertTrue(font(at: 0).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(font(at: 9).pointSize, 22, "whole paragraph takes the style")
        XCTAssertEqual(font(at: 12).pointSize, 15, "next paragraph untouched")
        XCTAssertEqual(controller.currentFormattingState().textStyle, .heading)
    }

    func testReturnAtEndOfHeadingDropsToBody() {
        load("Heading")
        controller.apply(style: .heading)
        caret(7)
        XCTAssertTrue(controller.handleReturn())
        XCTAssertEqual(text, "Heading\n")
        XCTAssertEqual(controller.currentFormattingState().textStyle, .body)
        XCTAssertEqual((textView.typingAttributes[.font] as? NSFont)?.pointSize, 15)
    }

    func testStyleSurvivesRTFRoundTripAsSystemFont() throws {
        load("Title here\nbody")
        caret(0)
        controller.apply(style: .title)
        let canonical = try XCTUnwrap(controller.currentAttributedText())
        let rtf = try canonical.data(from: NSRange(location: 0, length: canonical.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let restored = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)

        let normalized = controller.normalizedAttributedText(restored)
        let restoredFont = normalized.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertEqual(restoredFont.pointSize, 28)
        XCTAssertTrue(restoredFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(restoredFont.familyName, NSFont.systemFont(ofSize: 28).familyName, "reloaded text uses the system font, not Helvetica Neue")
        XCTAssertEqual(RichTextEditorController.TextStyle.style(forCanonicalSize: restoredFont.pointSize, monospaced: false), .title)
    }

    // MARK: Traits

    func testBoldTogglesOnSelectionAndPreservesItalic() {
        load("hello world")
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        controller.toggleItalic()
        controller.toggleBold()

        let traits = font(at: 0).fontDescriptor.symbolicTraits
        XCTAssertTrue(traits.contains(.bold))
        XCTAssertTrue(traits.contains(.italic))
        XCTAssertFalse(font(at: 7).fontDescriptor.symbolicTraits.contains(.bold))

        controller.toggleBold()
        XCTAssertFalse(font(at: 0).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font(at: 0).fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testStrikethroughAndUnderlineToggle() {
        load("abc")
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        controller.toggleStrikethrough()
        controller.toggleUnderline()
        var state = controller.currentFormattingState()
        XCTAssertTrue(state.isStrikethrough)
        XCTAssertTrue(state.isUnderlined)

        controller.toggleStrikethrough()
        state = controller.currentFormattingState()
        XCTAssertFalse(state.isStrikethrough)
        XCTAssertTrue(state.isUnderlined)
    }

    // MARK: Zoom

    func testZoomScalesDisplayButNotPersistedSizes() throws {
        load("Body text")
        controller.apply(style: .heading)
        controller.setZoom(1.5)

        XCTAssertEqual(font(at: 0).pointSize, 33, accuracy: 0.01)
        XCTAssertEqual(controller.currentFormattingState().textStyle, .heading)
        let canonical = try XCTUnwrap(controller.currentAttributedText())
        XCTAssertEqual((canonical.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 22)

        controller.setZoom(1)
        XCTAssertEqual(font(at: 0).pointSize, 22, accuracy: 0.01)
    }

    func testZoomStepsClamp() {
        controller.setZoom(1)
        for _ in 0..<20 { controller.zoomIn() }
        XCTAssertEqual(controller.zoom, RichTextEditorController.zoomSteps.last!)
        for _ in 0..<20 { controller.zoomOut() }
        XCTAssertEqual(controller.zoom, RichTextEditorController.zoomSteps.first!)
        controller.setZoom(1)
    }

    // MARK: Lists

    func testBulletedListTogglesOnAndOffForSelection() {
        load("one\ntwo\nthree")
        textView.setSelectedRange(NSRange(location: 0, length: 9))
        controller.toggleList(.bulleted)

        XCTAssertEqual(text, "•\tone\n•\ttwo\n•\tthree")
        XCTAssertEqual(paragraphStyle(at: 0).headIndent, 26)
        XCTAssertEqual(controller.currentFormattingState().listKind, .bulleted)

        controller.toggleList(.bulleted)
        XCTAssertEqual(text, "one\ntwo\nthree")
        XCTAssertEqual(paragraphStyle(at: 0).headIndent, 0)
        XCTAssertNil(controller.currentFormattingState().listKind)
    }

    func testNumberedListNumbersSequentiallyAndSwitchesKind() {
        load("a\nb\nc")
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        controller.toggleList(.numbered)
        XCTAssertEqual(text, "1.\ta\n2.\tb\n3.\tc")

        controller.toggleList(.bulleted)
        XCTAssertEqual(text, "•\ta\n•\tb\n•\tc", "switching kinds replaces the markers")
    }

    func testReturnContinuesNumberedListAndRenumbers() {
        load("first")
        caret(0)
        controller.toggleList(.numbered)
        caret((text as NSString).length)
        XCTAssertTrue(controller.handleReturn())
        textView.insertText("second", replacementRange: textView.selectedRange())
        XCTAssertTrue(controller.handleReturn())
        textView.insertText("third", replacementRange: textView.selectedRange())
        XCTAssertEqual(text, "1.\tfirst\n2.\tsecond\n3.\tthird")

        // Insert an item between 1 and 2.
        caret(8)
        XCTAssertTrue(controller.handleReturn())
        textView.insertText("new", replacementRange: textView.selectedRange())
        controller.renumberLists(around: textView.selectedRange())
        XCTAssertEqual(text, "1.\tfirst\n2.\tnew\n3.\tsecond\n4.\tthird")
    }

    func testNumberedListAfterBulletsStartsAtOne() {
        load("a\nb\nc\nd")
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        controller.toggleList(.bulleted)
        let numberedStart = (text as NSString).range(of: "c").location
        textView.setSelectedRange(NSRange(location: numberedStart, length: 3))
        controller.toggleList(.numbered)
        XCTAssertEqual(text, "•\ta\n•\tb\n1.\tc\n2.\td")
    }

    func testReturnOnEmptyItemEndsList() {
        load("item")
        caret(0)
        controller.toggleList(.bulleted)
        caret((text as NSString).length)
        XCTAssertTrue(controller.handleReturn())
        XCTAssertEqual(text, "•\titem\n•\t")
        XCTAssertTrue(controller.handleReturn())
        XCTAssertEqual(text, "•\titem\n")
        XCTAssertNil(controller.currentFormattingState().listKind)
    }

    func testDeleteBackwardAfterMarkerRemovesMarker() {
        load("item")
        caret(0)
        controller.toggleList(.bulleted)
        caret(2)
        XCTAssertTrue(controller.handleDeleteBackward())
        XCTAssertEqual(text, "item")
        caret(1)
        XCTAssertFalse(controller.handleDeleteBackward(), "ordinary deletes are left to the text view")
    }

    func testTabIndentsAndOutdentsWithNestedNumbering() {
        load("one\ntwo\nthree")
        textView.setSelectedRange(NSRange(location: 0, length: 13))
        controller.toggleList(.numbered)

        XCTAssertEqual(text, "1.\tone\n2.\ttwo\n3.\tthree")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 22), "selection grows to cover the markers")

        caret(11) // inside "two"
        XCTAssertTrue(controller.indentSelection())
        XCTAssertEqual(text, "1.\tone\na.\ttwo\n2.\tthree")
        XCTAssertEqual(paragraphStyle(at: 7).firstLineHeadIndent, 24)
        XCTAssertEqual(paragraphStyle(at: 7).headIndent, 50)
        XCTAssertEqual(textView.selectedRange().location, 11, "caret keeps its place in the item")

        XCTAssertTrue(controller.outdentSelection())
        XCTAssertEqual(text, "1.\tone\n2.\ttwo\n3.\tthree")
        XCTAssertEqual(paragraphStyle(at: 7).firstLineHeadIndent, 0)
    }

    func testTabOutsideListInsertsNothing() {
        load("plain")
        caret(2)
        XCTAssertFalse(controller.indentSelection())
        XCTAssertFalse(controller.outdentSelection())
    }

    func testDashSpaceStartsBulletedList() {
        load("")
        textView.insertText("-", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.handleAutoListTrigger(for: NSRange(location: 1, length: 0), replacementString: " "))
        XCTAssertEqual(text, "•\t")
        XCTAssertEqual(controller.currentFormattingState().listKind, .bulleted)
        XCTAssertEqual(textView.selectedRange().location, 2)
    }

    func testOneDotSpaceStartsNumberedList() {
        load("")
        textView.insertText("1.", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.handleAutoListTrigger(for: NSRange(location: 2, length: 0), replacementString: " "))
        XCTAssertEqual(text, "1.\t")
    }

    func testListMarkerKeepsInlineFormatting() {
        load("bold word")
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        controller.toggleBold()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.toggleList(.bulleted)

        XCTAssertEqual(text, "•\tbold word")
        XCTAssertFalse(font(at: 0).fontDescriptor.symbolicTraits.contains(.bold), "marker is regular weight")
        XCTAssertTrue(font(at: 2).fontDescriptor.symbolicTraits.contains(.bold), "content formatting survives")
    }

    func testLegacyListsMigrateOnLoad() {
        let legacy = NSAttributedString(string: "• old bullet\n1. old number\n    a. nested\nplain", attributes: controller.defaultTypingAttributes)
        let migrated = controller.normalizedAttributedText(legacy)
        XCTAssertEqual(migrated.string, "•\told bullet\n1.\told number\na.\tnested\nplain")
        let nested = migrated.attribute(.paragraphStyle, at: 27, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(nested.firstLineHeadIndent, 24)
    }

    func testListRoundTripsThroughRTF() throws {
        load("one\ntwo")
        textView.setSelectedRange(NSRange(location: 0, length: 7))
        controller.toggleList(.numbered)
        let canonical = try XCTUnwrap(controller.currentAttributedText())
        let rtf = try canonical.data(from: NSRange(location: 0, length: canonical.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let restored = controller.normalizedAttributedText(try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
        XCTAssertEqual(restored.string, "1.\tone\n2.\ttwo")
        XCTAssertEqual((restored.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle).headIndent, 26)
    }

    // MARK: Quotes

    private var samplePassage: Passage {
        Passage(text: "the quick brown fox", sourceURL: URL(string: "https://example.com/story?utm_source=x"))
    }

    func testInsertQuoteAddsLinkedIndentedParagraphAndBodyLineAfter() throws {
        load("")
        controller.insertQuote(samplePassage)
        XCTAssertEqual(text, "\u{201C}the quick brown fox\u{201D}\n")
        let link = try XCTUnwrap(textView.attributedString().attribute(.link, at: 1, effectiveRange: nil) as? URL)
        XCTAssertEqual(link.absoluteString, "https://example.com/story#:~:text=the%20quick%20brown%20fox")
        XCTAssertEqual(paragraphStyle(at: 0).headIndent, 16)
        XCTAssertEqual(textView.selectedRange().location, (text as NSString).length, "caret on the line after the quote")
        XCTAssertNil(textView.typingAttributes[.link])
        XCTAssertEqual((textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.headIndent, 0, "next paragraph is Body")
    }

    func testInsertQuoteAfterExistingParagraphKeepsExistingText() {
        load("notes so far")
        caret(5)
        controller.insertQuote(samplePassage)
        XCTAssertEqual(text, "notes so far\n\u{201C}the quick brown fox\u{201D}\n")
    }

    func testReturnAtEndOfQuoteDropsToBody() {
        load("")
        controller.insertQuote(samplePassage)
        let quoteEnd = (text as NSString).length - 1
        caret(quoteEnd)
        XCTAssertTrue(controller.handleReturn())
        XCTAssertEqual((textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.headIndent, 0)
        XCTAssertNil(textView.typingAttributes[.link])
    }

    func testAppendingQuoteKeepsExistingNoteAndLinks() throws {
        let existing = NSAttributedString(string: "first thought", attributes: controller.defaultTypingAttributes)
        let appended = controller.appendingQuote(samplePassage, to: existing)
        XCTAssertEqual(appended.string, "first thought\n\u{201C}the quick brown fox\u{201D}\n")
        let linkLocation = (appended.string as NSString).range(of: "quick").location
        XCTAssertEqual((appended.attribute(.link, at: linkLocation, effectiveRange: nil) as? URL)?.absoluteString, "https://example.com/story#:~:text=the%20quick%20brown%20fox")
        XCTAssertEqual((appended.attribute(.paragraphStyle, at: linkLocation, effectiveRange: nil) as? NSParagraphStyle)?.headIndent, 16)
        XCTAssertEqual((appended.attribute(.font, at: linkLocation, effectiveRange: nil) as? NSFont)?.pointSize, 15, "canonical size, not zoomed")

        let twice = controller.appendingQuote(Passage(text: "second", sourceURL: nil), to: appended)
        XCTAssertEqual(twice.string, "first thought\n\u{201C}the quick brown fox\u{201D}\n\u{201C}second\u{201D}\n")
        XCTAssertEqual(controller.appendingQuote(samplePassage, to: NSAttributedString()).string, "\u{201C}the quick brown fox\u{201D}\n")
    }

    func testQuoteQueuedUntilTextViewAttaches() {
        let detached = RichTextEditorController()
        detached.insertQuote(samplePassage)
        let view = NSTextView(usingTextLayoutManager: false)
        view.isRichText = true
        view.typingAttributes = detached.defaultTypingAttributes
        detached.attach(view)
        let flushed = expectation(description: "queued passage inserted after attach")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 2)
        XCTAssertEqual(view.string, "\u{201C}the quick brown fox\u{201D}\n")
    }

    func testQuoteLinkSurvivesRTFRoundTrip() throws {
        load("")
        controller.insertQuote(samplePassage)
        let canonical = try XCTUnwrap(controller.currentAttributedText())
        let rtf = try canonical.data(from: NSRange(location: 0, length: canonical.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let restored = controller.normalizedAttributedText(try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
        let link = restored.attribute(.link, at: 1, effectiveRange: nil)
        let linkString = (link as? URL)?.absoluteString ?? (link as? String)
        XCTAssertEqual(linkString, "https://example.com/story#:~:text=the%20quick%20brown%20fox")
        XCTAssertEqual((restored.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent, 16)
    }

    // MARK: Tables

    func testInsertTableCreatesCellsAndExitParagraph() {
        load("intro")
        caret(5)
        controller.insertTable(rows: 2, columns: 2)

        XCTAssertEqual(text, "intro\n\n\n\n\n\n")
        XCTAssertTrue(controller.currentFormattingState().isInTable)
        let cellStyle = paragraphStyle(at: 6)
        let block = cellStyle.textBlocks.first as? NSTextTableBlock
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.table.numberOfColumns, 2)
        XCTAssertEqual(block?.startingRow, 0)
        XCTAssertEqual(block?.startingColumn, 0)
        XCTAssertEqual(textView.selectedRange().location, 6, "caret lands in the first cell")

        let exit = paragraphStyle(at: 10)
        XCTAssertTrue(exit.textBlocks.isEmpty, "a plain paragraph follows the table")
    }

    func testTabMovesBetweenCellsAndAppendsRow() {
        load("")
        controller.insertTable(rows: 1, columns: 2)
        textView.insertText("A", replacementRange: textView.selectedRange())
        XCTAssertTrue(controller.indentSelection())
        textView.insertText("B", replacementRange: textView.selectedRange())
        XCTAssertEqual(text, "A\nB\n\n")

        XCTAssertTrue(controller.indentSelection(), "tab on the last cell adds a row")
        XCTAssertEqual(text, "A\nB\n\n\n\n")
        let newCell = paragraphStyle(at: textView.selectedRange().location).textBlocks.first as? NSTextTableBlock
        XCTAssertEqual(newCell?.startingRow, 1)
        XCTAssertEqual(newCell?.startingColumn, 0)

        XCTAssertTrue(controller.outdentSelection())
        let previous = paragraphStyle(at: textView.selectedRange().location).textBlocks.first as? NSTextTableBlock
        XCTAssertEqual(previous?.startingRow, 0)
        XCTAssertEqual(previous?.startingColumn, 1)
    }

    func testTableSurvivesRTFRoundTrip() throws {
        load("")
        controller.insertTable(rows: 2, columns: 3)
        textView.insertText("x", replacementRange: textView.selectedRange())
        let canonical = try XCTUnwrap(controller.currentAttributedText())
        let rtf = try canonical.data(from: NSRange(location: 0, length: canonical.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let restored = controller.normalizedAttributedText(try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
        let style = restored.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.table.numberOfColumns, 3)
        XCTAssertTrue(block.table.collapsesBorders)
    }

    func testAddAndDeleteRowsAndColumns() {
        load("")
        controller.insertTable(rows: 2, columns: 2)
        textView.insertText("A", replacementRange: textView.selectedRange())   // (0,0)
        XCTAssertEqual(controller.currentTableCell?.row, 0)
        XCTAssertEqual(controller.currentTableCell?.column, 0)

        controller.performTableEdit(.addColumnAfter)
        XCTAssertEqual(controller.currentTableCell?.columns, 3)
        XCTAssertEqual(controller.currentTableCell?.column, 1, "caret moves into the new column")
        textView.insertText("B", replacementRange: textView.selectedRange())
        XCTAssertEqual(text, "A\nB\n\n\n\n\n\n", "row 0: A, B, empty; row 1: three empties; exit paragraph")

        controller.performTableEdit(.addRowBelow)
        XCTAssertEqual(controller.currentTableCell?.rows, 3)
        XCTAssertEqual(controller.currentTableCell?.row, 1)
        XCTAssertEqual(controller.currentTableCell?.column, 1, "column is kept when adding a row")

        controller.performTableEdit(.deleteRow)
        XCTAssertEqual(controller.currentTableCell?.rows, 2)

        controller.performTableEdit(.deleteColumn)
        XCTAssertEqual(controller.currentTableCell?.columns, 2)
        XCTAssertTrue(text.hasPrefix("A\n"), "content in other cells survives a rebuild: \(text.debugDescription)")

        controller.performTableEdit(.deleteTable)
        XCTAssertNil(controller.currentTableCell)
        XCTAssertEqual(text, "\n", "only the exit paragraph remains")
        XCTAssertTrue(((textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.isEmpty) ?? true)
    }

    func testTableEditKeepsCellFormatting() {
        load("")
        controller.insertTable(rows: 1, columns: 2)
        textView.insertText("bold", replacementRange: textView.selectedRange())
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        controller.toggleBold()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.performTableEdit(.addRowAbove)
        let boldLocation = (text as NSString).range(of: "bold").location
        XCTAssertTrue(font(at: boldLocation).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(controller.currentTableCell?.rows, 2)
    }

    func testDeletingLastRowRemovesTable() {
        load("intro")
        caret(5)
        controller.insertTable(rows: 1, columns: 1)
        controller.performTableEdit(.deleteRow)
        XCTAssertNil(controller.currentTableCell)
        XCTAssertEqual(text, "intro\n\n")
    }

    func testInsertTableIsIgnoredInsideTable() {
        load("")
        controller.insertTable(rows: 1, columns: 1)
        let before = text
        controller.insertTable(rows: 1, columns: 1)
        XCTAssertEqual(text, before)
    }
}
