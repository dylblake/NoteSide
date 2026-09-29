import SwiftUI

/// The note drawer: one Liquid Glass sheet holding the title, the context
/// it's attached to, the formatting toolbar and the editor, with a small
/// glass footer for pin / delete and the dismiss hint.
struct FloatingNoteEditorView: View {
    @Environment(AppState.self) private var appState
    @State private var showingDeleteConfirmation = false

    var body: some View {
        @Bindable var editor = appState.editor

        VStack(spacing: Spacing.sm) {
            sheet
            footer
        }
        .padding(.top, Spacing.lg)
        .padding(.leading, Spacing.xl)
        .padding(.trailing, Spacing.md + Spacing.xxs)
        .padding(.bottom, Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear {
            DispatchQueue.main.async {
                appState.richTextController.focus()
            }
        }
        .onChange(of: editor.editorAttributedText) { _, _ in
            appState.editor.scheduleAutosave()
        }
        .onChange(of: editor.editorTitle) { _, _ in
            appState.editor.scheduleAutosave()
        }
        .onExitCommand {
            appState.saveAndDismissEditor()
        }
    }

    // MARK: Sheet

    private var sheet: some View {
        @Bindable var editor = appState.editor

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                TextField("Title", text: $editor.editorTitle, prompt: Text("Title"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(NoteSideTheme.primaryText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("noteTitleField")

                contextRow
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.md)

            FormattingToolbar()
                .environment(appState)
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.sm)

            RichTextEditor(
                attributedText: $editor.editorAttributedText,
                controller: appState.richTextController
            )
            .padding(.horizontal, Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            DictationIndicatorView(
                isDictating: appState.isDictating,
                partialText: appState.dictationPartialText,
                hotkeyLabel: appState.hotkeys.dictationHotKeyDisplayString
            )
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.2), value: appState.isDictating)
        }
        .frame(maxWidth: .infinity, minHeight: 380, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.panel, style: .continuous))
        .glassEffect(NoteSideTheme.sheetGlass, in: RoundedRectangle(cornerRadius: CornerRadius.panel, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noteEditorSheet")
    }

    private var contextRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: contextSymbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NoteSideTheme.secondaryText)

                Text(appState.editor.activeContext?.displayName ?? "Current Context")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NoteSideTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("noteContextName")

                if appState.editor.isViewingOrphanedNote {
                    Button("Attach to Current Context") {
                        appState.relinkOrphanedNoteToCurrentContext()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Re-attach this note to the app, page, or file currently in front")
                }
            }

            if let secondaryLabel = appState.editor.activeContext?.secondaryLabel, !secondaryLabel.isEmpty {
                Text(secondaryLabel)
                    .font(.caption)
                    .foregroundStyle(NoteSideTheme.tertiaryText)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 20)
            }

            if let errorMessage = appState.editor.editorErrorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(NoteSideTheme.warning)
                    .lineLimit(3)
            }
        }
    }

    private var contextSymbolName: String {
        switch appState.editor.activeContext?.kind {
        case .url: return "globe"
        case .file: return "doc"
        case .application, .none: return "app"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            ViewThatFits(in: .horizontal) {
                Text("Press \(appState.hotkeys.hotKeyDisplayString) again or Escape to dismiss")
                    .lineLimit(1)
                Text("Escape to dismiss")
                    .lineLimit(1)
            }
            .font(.footnote)
            .foregroundStyle(NoteSideTheme.secondaryText)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .glassEffect(.regular, in: Capsule(style: .continuous))

            Spacer(minLength: 0)

            GlassEffectContainer(spacing: Spacing.xs) {
                HStack(spacing: Spacing.xxs) {
                    IconButton(
                        systemName: appState.editor.isActiveNotePinned ? "pin.fill" : "pin",
                        accessibilityLabel: appState.editor.isActiveNotePinned ? "Unpin note" : "Pin note",
                        tint: appState.editor.isActiveNotePinned ? NoteSideTheme.accent : NoteSideTheme.primaryText,
                        size: 14,
                        hitSize: 34
                    ) {
                        appState.togglePinForActiveNote()
                    }
                    .accessibilityIdentifier("editorPinButton")

                    IconButton(
                        systemName: "trash",
                        accessibilityLabel: "Delete note",
                        size: 14,
                        hitSize: 34
                    ) {
                        showingDeleteConfirmation = true
                    }
                    .accessibilityIdentifier("editorDeleteButton")
                    .popover(isPresented: $showingDeleteConfirmation, arrowEdge: .bottom) {
                        DeleteConfirmationPopover(
                            onConfirm: {
                                showingDeleteConfirmation = false
                                appState.deleteActiveNote()
                            },
                            onCancel: {
                                showingDeleteConfirmation = false
                            }
                        )
                    }
                }
                .padding(Spacing.xxs)
                .glassEffect(.regular, in: Capsule(style: .continuous))
            }
        }
    }
}

private struct DictationIndicatorView: View {
    let isDictating: Bool
    let partialText: String
    let hotkeyLabel: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: Spacing.xs - 2) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDictating ? NoteSideTheme.accent : NoteSideTheme.quaternaryText)
                // Under Reduce Motion the tint change alone signals
                // listening — no perpetual pulse.
                .scaleEffect(x: 1.0, y: isDictating && !reduceMotion ? scale : 1.0)
                .animation(
                    isDictating && !reduceMotion
                        ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                        : .default,
                    value: scale
                )

            if isDictating {
                if !partialText.isEmpty {
                    Text(partialText)
                        .font(.caption)
                        .foregroundStyle(NoteSideTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            } else {
                Text("Hold \(hotkeyLabel) for voice dictation")
                    .font(.caption)
                    .foregroundStyle(NoteSideTheme.quaternaryText)
            }
        }
        .onChange(of: isDictating) { _, active in
            scale = active && !reduceMotion ? 1.4 : 1.0
        }
    }
}
