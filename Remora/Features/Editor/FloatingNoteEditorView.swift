import SwiftUI

/// The note drawer: one Liquid Glass sheet holding the title, the context
/// it's attached to, the formatting toolbar and the editor, with a small
/// glass footer for pin / delete and the dismiss hint.
struct FloatingNoteEditorView: View {
    @Environment(AppState.self) private var appState
    @State private var showingDeleteConfirmation = false
    @FocusState private var isTitleFocused: Bool

    /// A generated title fades in on its own field: no overlay, no drift,
    /// no blur — it isn't there, then it is. The same gentle ease-out as
    /// the drawer's slide.
    private static let titleReveal = Animation.timingCurve(0.5, 1, 0.89, 1, duration: 0.35)

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
                titleSlot

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
        .glassEffect(RemoraTheme.sheetGlass, in: RoundedRectangle(cornerRadius: CornerRadius.panel, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noteEditorSheet")
    }

    // MARK: Title

    /// With automatic titles on, an empty title shows nothing — no "Title"
    /// placeholder waiting to be replaced — unless the user is in the field
    /// to type one. (An explicitly empty prompt: a nil prompt makes SwiftUI
    /// fall back to the label "Title".) A generated title lands in a
    /// hidden field (see `EditorState.revealGeneratedTitle`), then fades in.
    private var titleSlot: some View {
        @Bindable var editor = appState.editor
        let showsPlaceholder = !appState.isAutoTitleEnabled || isTitleFocused

        return TextField("Title", text: $editor.editorTitle, prompt: showsPlaceholder ? Text("Title") : Text(verbatim: ""))
            .font(.title2.weight(.semibold))
            .foregroundStyle(RemoraTheme.primaryText)
            .textFieldStyle(.plain)
            .focused($isTitleFocused)
            .accessibilityIdentifier("noteTitleField")
            .opacity(appState.editor.isTitleRevealPending ? 0 : 1)
            .onChange(of: appState.editor.titleRevealToken) { _, _ in
                // The field was hidden a turn ago and now holds the title.
                PanelMotionTrace.mark("titleArrived")
                withAnimation(Self.titleReveal) {
                    appState.editor.finishTitleReveal()
                }
            }
    }

    private var contextRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                // The same marker the note carries in All Notes.
                if let context = appState.editor.activeContext {
                    NoteContextIcon(context: context, size: Self.contextIconSize)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RemoraTheme.secondaryText)
                        .frame(width: Self.contextIconSize, height: Self.contextIconSize)
                }

                Text(appState.editor.activeContext?.displayName ?? "Current Context")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(RemoraTheme.primaryText)
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
                    .foregroundStyle(RemoraTheme.tertiaryText)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, Self.contextIconSize + Spacing.xs)
            }

            if let errorMessage = appState.editor.editorErrorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(RemoraTheme.warning)
                    .lineLimit(3)
            }

        }
    }

    private static let contextIconSize: CGFloat = 16

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
            .foregroundStyle(RemoraTheme.secondaryText)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .glassEffect(.regular, in: Capsule(style: .continuous))

            Spacer(minLength: 0)

            GlassEffectContainer(spacing: Spacing.xs) {
                HStack(spacing: Spacing.xxs) {
                    IconButton(
                        systemName: appState.editor.isActiveNotePinned ? "pin.fill" : "pin",
                        accessibilityLabel: appState.editor.isActiveNotePinned ? "Remove from To-Do" : "Add to To-Do",
                        tint: appState.editor.isActiveNotePinned ? RemoraTheme.accent : RemoraTheme.primaryText,
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
                .foregroundStyle(isDictating ? RemoraTheme.accent : RemoraTheme.quaternaryText)
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
                        .foregroundStyle(RemoraTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            } else {
                Text("Hold \(hotkeyLabel) for voice dictation")
                    .font(.caption)
                    .foregroundStyle(RemoraTheme.quaternaryText)
            }
        }
        .onChange(of: isDictating) { _, active in
            scale = active && !reduceMotion ? 1.4 : 1.0
        }
    }
}
