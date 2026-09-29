//
//  FormattingState.swift
//  NoteSide
//

import CoreGraphics
import Observation

/// Observable mirror of the editor's formatting at the current selection,
/// plus the actions the formatting toolbar and menus call.
@MainActor
@Observable
final class FormattingState {
    typealias TextStyle = RichTextEditorController.TextStyle
    typealias ListKind = RichTextEditorController.ListKind

    var currentEditorTextStyle: TextStyle = .body
    var isEditorBoldActive = false
    var isEditorItalicActive = false
    var isEditorUnderlineActive = false
    var isEditorStrikethroughActive = false
    var activeListKind: ListKind?
    var isInTable = false

    @ObservationIgnored private let richTextController: RichTextEditorController

    init(richTextController: RichTextEditorController) {
        self.richTextController = richTextController

        richTextController.onSelectionAttributesChange = { [weak self] state in
            guard let self else { return }
            currentEditorTextStyle = state.textStyle
            isEditorBoldActive = state.isBold
            isEditorItalicActive = state.isItalic
            isEditorUnderlineActive = state.isUnderlined
            isEditorStrikethroughActive = state.isStrikethrough
            activeListKind = state.listKind
            isInTable = state.isInTable
        }
    }

    // MARK: Paragraph styles

    func apply(style: TextStyle) {
        richTextController.apply(style: style)
    }

    func applyHeadingStyle() { apply(style: .heading) }
    func applySubheadingStyle() { apply(style: .subheading) }
    func applyBodyStyle() { apply(style: .body) }

    // MARK: Character traits

    func toggleBold() { richTextController.toggleBold() }
    func toggleItalic() { richTextController.toggleItalic() }
    func toggleUnderline() { richTextController.toggleUnderline() }
    func toggleStrikethrough() { richTextController.toggleStrikethrough() }

    // MARK: Lists and tables

    func insertBulletedList() { richTextController.toggleList(.bulleted) }
    func insertNumberedList() { richTextController.toggleList(.numbered) }
    func insertTable() { richTextController.insertTable() }
    func performTableEdit(_ edit: RichTextEditorController.TableEdit) { richTextController.performTableEdit(edit) }

    /// Caret's cell and the table's size, or nil outside a table.
    var currentTableCell: (row: Int, column: Int, rows: Int, columns: Int)? {
        richTextController.currentTableCell
    }
}
