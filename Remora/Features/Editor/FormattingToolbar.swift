import SwiftUI

/// Formatting controls for the note editor: paragraph style, character
/// traits, lists and tables. (Text size is keyboard-only: ⌘+ / ⌘− / ⌘0.) Sits on a single glass capsule so
/// it reads as one floating control, and folds its less-used items into an
/// overflow menu when the pane is narrow.
struct FormattingToolbar: View {
    @Environment(AppState.self) private var appState

    private typealias TextStyle = RichTextEditorController.TextStyle

    /// Three tiers, widest first: full, compact (no menu chevron), narrow
    /// (lists and table fold into an overflow menu).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            toolbar(tier: .full)
            toolbar(tier: .compact)
            toolbar(tier: .narrow)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("formattingToolbar")
    }

    private enum Tier { case full, compact, narrow }

    private func toolbar(tier: Tier) -> some View {
        HStack(spacing: Spacing.xxs) {
            stylePicker(compact: tier != .full)

            toolbarDivider

            boldToggle
            italicToggle
            underlineToggle

            if tier == .narrow {
                overflowMenu
            } else {
                strikethroughToggle

                toolbarDivider

                bulletedListToggle
                numberedListToggle
                tableControl
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .glassEffect(.regular, in: Capsule(style: .continuous))
    }

    // MARK: Items

    private var boldToggle: some View {
        ToolbarToggle(systemImage: "bold", label: "Bold", shortcut: "⌘B", isOn: appState.formatting.isEditorBoldActive) {
            appState.formatting.toggleBold()
        }
        .accessibilityIdentifier("formatBold")
    }

    private var italicToggle: some View {
        ToolbarToggle(systemImage: "italic", label: "Italic", shortcut: "⌘I", isOn: appState.formatting.isEditorItalicActive) {
            appState.formatting.toggleItalic()
        }
        .accessibilityIdentifier("formatItalic")
    }

    private var underlineToggle: some View {
        ToolbarToggle(systemImage: "underline", label: "Underline", shortcut: "⌘U", isOn: appState.formatting.isEditorUnderlineActive) {
            appState.formatting.toggleUnderline()
        }
        .accessibilityIdentifier("formatUnderline")
    }

    private var strikethroughToggle: some View {
        ToolbarToggle(systemImage: "strikethrough", label: "Strikethrough", shortcut: "⇧⌘X", isOn: appState.formatting.isEditorStrikethroughActive) {
            appState.formatting.toggleStrikethrough()
        }
        .accessibilityIdentifier("formatStrikethrough")
    }

    private var bulletedListToggle: some View {
        ToolbarToggle(systemImage: "list.bullet", label: "Bulleted List", shortcut: "⇧⌘7", isOn: appState.formatting.activeListKind == .bulleted) {
            appState.formatting.insertBulletedList()
        }
        .accessibilityIdentifier("formatBulletedList")
    }

    private var numberedListToggle: some View {
        ToolbarToggle(systemImage: "list.number", label: "Numbered List", shortcut: "⇧⌘9", isOn: appState.formatting.activeListKind == .numbered) {
            appState.formatting.insertNumberedList()
        }
        .accessibilityIdentifier("formatNumberedList")
    }

    /// Inserts a table outside one; inside, becomes a menu of row/column edits.
    @ViewBuilder
    private var tableControl: some View {
        if appState.formatting.isInTable {
            Menu {
                tableEditItems
            } label: {
                Image(systemName: "tablecells")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RemoraTheme.accent)
                    .frame(width: 30, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                            .fill(RemoraTheme.accent.opacity(0.18))
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Table")
            .accessibilityLabel("Table, \(tablePositionLabel)")
            .accessibilityIdentifier("formatTable")
        } else {
            ToolbarToggle(systemImage: "tablecells", label: "Insert Table", shortcut: "⌥⌘T", isOn: false) {
                appState.formatting.insertTable()
            }
            .accessibilityIdentifier("formatTable")
        }
    }

    private var tablePositionLabel: String {
        guard let cell = appState.formatting.currentTableCell else { return "" }
        return "row \(cell.row + 1) of \(cell.rows), column \(cell.column + 1) of \(cell.columns)"
    }

    private var tableEditItems: some View {
        ForEach(RichTextEditorController.TableEdit.allCases) { edit in
            if edit == .deleteRow {
                Divider()
            }
            Button(edit.title, role: edit.isDestructive ? .destructive : nil) {
                appState.formatting.performTableEdit(edit)
            }
        }
    }

    /// Narrow pane: everything that didn't fit, as a menu.
    private var overflowMenu: some View {
        Menu {
            Button {
                appState.formatting.toggleStrikethrough()
            } label: {
                Label("Strikethrough", systemImage: appState.formatting.isEditorStrikethroughActive ? "checkmark" : "strikethrough")
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])

            Divider()

            Button {
                appState.formatting.insertBulletedList()
            } label: {
                Label("Bulleted List", systemImage: appState.formatting.activeListKind == .bulleted ? "checkmark" : "list.bullet")
            }
            .keyboardShortcut("7", modifiers: [.command, .shift])

            Button {
                appState.formatting.insertNumberedList()
            } label: {
                Label("Numbered List", systemImage: appState.formatting.activeListKind == .numbered ? "checkmark" : "list.number")
            }
            .keyboardShortcut("9", modifiers: [.command, .shift])

            Divider()

            if appState.formatting.isInTable {
                Menu("Table") {
                    tableEditItems
                }
            } else {
                Button("Insert Table") {
                    appState.formatting.insertTable()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More formatting")
        .accessibilityLabel("More formatting")
        .accessibilityIdentifier("formatMore")
    }

    // MARK: Style

    private func stylePicker(compact: Bool) -> some View {
        let selection = Binding<TextStyle>(
            get: { appState.formatting.currentEditorTextStyle },
            set: { appState.formatting.apply(style: $0) }
        )

        return Menu {
            ForEach(TextStyle.allCases) { style in
                Button {
                    selection.wrappedValue = style
                } label: {
                    if style == selection.wrappedValue {
                        Label(style.title, systemImage: "checkmark")
                    } else {
                        Text(style.title)
                    }
                }
                .keyboardShortcut(KeyEquivalent(style.shortcutKey), modifiers: [.command, .shift])
            }
        } label: {
            Text(selection.wrappedValue.title)
                .lineLimit(1)
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: compact ? 0 : 76, alignment: .leading)
            .frame(height: 28)
            .padding(.horizontal, Spacing.xs)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact ? .hidden : .visible)
        .fixedSize()
        .help("Paragraph style")
        .accessibilityLabel("Paragraph style, \(selection.wrappedValue.title)")
        .accessibilityIdentifier("formatStyleMenu")
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 2)
    }
}

/// A toolbar toggle: icon button with an accent tint when active. Hand-
/// rolled because the system toggle styles don't sit on glass well; keeps
/// the standard Button semantics (mouse-up, VoiceOver role, help tag).
private struct ToolbarToggle: View {
    let systemImage: String
    let label: String
    let shortcut: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? RemoraTheme.accent : RemoraTheme.primaryText)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                        .fill(background)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(label) (\(shortcut))")
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var background: Color {
        if isOn { return RemoraTheme.accent.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.08) }
        return .clear
    }
}
