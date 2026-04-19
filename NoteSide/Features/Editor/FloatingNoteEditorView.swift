import SwiftUI

struct FloatingNoteEditorView: View {
    @Environment(AppState.self) private var appState
    @State private var showingDeleteConfirmation = false
    private let noteCardCornerRadius: CGFloat = 28

    var body: some View {
        @Bindable var appState = appState
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(0.7)
                            .foregroundStyle(NoteSideTheme.secondaryText)

                        TextField("Note title", text: $appState.editorTitle)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(NoteSideTheme.primaryText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)

                    Divider()
                        .padding(.horizontal, 14)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Current context")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(0.7)
                            .foregroundStyle(NoteSideTheme.secondaryText)

                        Text(appState.activeContext?.displayName ?? "Current Context")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(NoteSideTheme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let secondaryLabel = appState.activeContext?.secondaryLabel, !secondaryLabel.isEmpty {
                            Text(secondaryLabel)
                                .font(.subheadline)
                                .foregroundStyle(NoteSideTheme.secondaryText)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        if let errorMessage = appState.editorErrorMessage, !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(NoteSideTheme.warning)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 18)

                    HStack(spacing: 10) {
                        Spacer(minLength: 0)

                        Menu {
                            Button {
                                appState.applyHeadingStyle()
                            } label: {
                                Text(RichTextEditorController.TextStyle.heading.title)
                                    .font(.system(size: RichTextEditorController.TextStyle.heading.fontSize, weight: .bold))
                            }

                            Button {
                                appState.applySubheadingStyle()
                            } label: {
                                Text(RichTextEditorController.TextStyle.subheading.title)
                                    .font(.system(size: RichTextEditorController.TextStyle.subheading.fontSize, weight: .semibold))
                            }

                            Button {
                                appState.applyBodyStyle()
                            } label: {
                                Text(RichTextEditorController.TextStyle.body.title)
                                    .font(.system(size: RichTextEditorController.TextStyle.body.fontSize, weight: .regular))
                            }
                        } label: {
                            formattingButtonLabel(appState.currentEditorTextStyle.title)
                        }

                        formattingButton("B", isActive: appState.isEditorBoldActive) {
                            appState.toggleBold()
                        }

                        formattingButton("I", isActive: appState.isEditorItalicActive) {
                            appState.toggleItalic()
                        }

                        formattingButton("U", isActive: appState.isEditorUnderlineActive) {
                            appState.toggleUnderline()
                        }

                        formattingButton("•") {
                            appState.insertBulletedList()
                        }

                        formattingButton("1.") {
                            appState.insertNumberedList()
                        }
                    }

                    RichTextEditor(
                        attributedText: $appState.editorAttributedText,
                        controller: appState.richTextController
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    DictationIndicatorView(
                        isDictating: appState.isDictating,
                        partialText: appState.dictationPartialText,
                        hotkeyLabel: appState.dictationHotKeyDisplayString
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.2), value: appState.isDictating)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, minHeight: 380, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .background(
                    RoundedRectangle(cornerRadius: noteCardCornerRadius, style: .continuous)
                        .fill(NoteSideTheme.secondaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: noteCardCornerRadius, style: .continuous)
                                .stroke(NoteSideTheme.border.opacity(0.8), lineWidth: 1)
                        )
                )

                ZStack {
                    GeometryReader { geometry in
                        // Hide the dismiss hint when the panel is too
                        // narrow (e.g. portrait / vertical displays where
                        // pane width = screen.width / 3 is small) — the
                        // text would otherwise overlap the pin/trash
                        // icons in the right-hand HStack.
                        if geometry.size.width >= 380 {
                            HStack {
                                Spacer()
                                Text("Press the hotkey again or Escape to dismiss.")
                                    .font(.footnote)
                                    .foregroundStyle(NoteSideTheme.secondaryText)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }

                    HStack {
                        Spacer()

                        HStack(spacing: 4) {
                            ClickableIconView(
                                iconName: appState.isActiveNotePinned ? "pin.fill" : "pin",
                                iconColor: appState.isActiveNotePinned ? .controlAccentColor : .labelColor,
                                size: 16
                            ) {
                                appState.togglePinForActiveNote()
                            }
                            .frame(width: 50, height: 50)

                            ClickableIconView(
                                iconName: "trash",
                                iconColor: .labelColor,
                                size: 16
                            ) {
                                showingDeleteConfirmation = true
                            }
                            .frame(width: 50, height: 50)
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
                    }
                }
                .frame(height: 50)
                .background(footerRadialBackdrop)

                Spacer(minLength: 0)
            }
            .padding(.top, 28)
            .padding(.leading, 34)
            .padding(.trailing, 22)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .clipped()
        .onAppear {
            DispatchQueue.main.async {
                appState.richTextController.focus()
            }
        }
        .onExitCommand {
            appState.saveAndDismissEditor()
        }
    }

    /// Soft radial blur sitting behind the footer row (pin / trash / hint).
    /// Strong system blur in the middle, fading out to fully transparent at
    /// the edges so the effect looks like a spotlight rather than a hard
    /// rectangle. Uses the system Material as the fill so it picks up the
    /// `behindWindow` blending automatically (the panel is a transparent
    /// NSPanel, so the material blurs whatever is on the desktop behind it).
    private var footerRadialBackdrop: some View {
        Rectangle()
            .fill(.thickMaterial)
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.6), location: 0.15),
                        .init(color: .black, location: 0.35),
                        .init(color: .black, location: 0.65),
                        .init(color: .black.opacity(0.6), location: 0.85),
                        .init(color: .clear, location: 1.0)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .padding(.horizontal, -40)
            .padding(.vertical, -16)
            .allowsHitTesting(false)
    }

    private func formattingButton(_ title: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            formattingButtonLabel(title, isActive: isActive)
        }
        .buttonStyle(.plain)
    }

    private func formattingButtonLabel(_ title: String, isActive: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(isActive ? Color.white : NoteSideTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? NoteSideTheme.accent : NoteSideTheme.contentBackground)
            )
    }
}

private struct DictationIndicatorView: View {
    let isDictating: Bool
    let partialText: String
    let hotkeyLabel: String
    @State private var scale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDictating ? NoteSideTheme.accent : NoteSideTheme.quaternaryText)
                .scaleEffect(x: 1.0, y: isDictating ? scale : 1.0)
                .animation(
                    isDictating
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
        .padding(.bottom, 4)
        .onChange(of: isDictating) { _, active in
            scale = active ? 1.4 : 1.0
        }
    }
}
