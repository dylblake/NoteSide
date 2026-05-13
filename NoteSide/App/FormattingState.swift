//
//  FormattingState.swift
//  NoteSide
//

import Observation

@MainActor
@Observable
final class FormattingState {
    var currentEditorTextStyle: RichTextEditorController.TextStyle = .body
    var isEditorBoldActive = false
    var isEditorItalicActive = false
    var isEditorUnderlineActive = false

    @ObservationIgnored private let richTextController: RichTextEditorController

    init(richTextController: RichTextEditorController) {
        self.richTextController = richTextController

        richTextController.onSelectionAttributesChange = { [weak self] formattingState in
            self?.currentEditorTextStyle = formattingState.textStyle
            self?.isEditorBoldActive = formattingState.isBold
            self?.isEditorItalicActive = formattingState.isItalic
            self?.isEditorUnderlineActive = formattingState.isUnderlined
        }
    }

    func applyHeadingStyle() {
        richTextController.apply(style: .heading)
    }

    func applySubheadingStyle() {
        richTextController.apply(style: .subheading)
    }

    func applyBodyStyle() {
        richTextController.apply(style: .body)
    }

    func toggleBold() {
        richTextController.toggleBold()
    }

    func toggleItalic() {
        richTextController.toggleItalic()
    }

    func toggleUnderline() {
        richTextController.toggleUnderline()
    }

    func insertBulletedList() {
        richTextController.insertBulletedList()
    }

    func insertNumberedList() {
        richTextController.insertNumberedList()
    }
}
