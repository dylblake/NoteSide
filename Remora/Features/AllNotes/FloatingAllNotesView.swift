import SwiftUI

/// The All Notes drawer: the notes browser on one Liquid Glass sheet with
/// a small glass footer carrying the dismiss hint.
struct FloatingAllNotesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ContentView()
                .environment(appState)
                // Beside the note drawer the sheet runs under it; the
                // content stops short, so only glass is covered.
                .padding(.trailing, appState.allNotesUsesStackedLayout ? PanelLayout.stackedContentInset : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.panel, style: .continuous))
                .glassEffect(RemoraTheme.sheetGlass, in: RoundedRectangle(cornerRadius: CornerRadius.panel, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("allNotesSheet")

            HStack {
                Spacer(minLength: 0)
                // Beside the note, the note's footer carries the one hint
                // for both; this footer only keeps the sheets level.
                if !appState.allNotesUsesStackedLayout {
                    ViewThatFits(in: .horizontal) {
                        Text("Press \(appState.hotkeys.allNotesHotKeyDisplayString) again or Escape to dismiss")
                            .lineLimit(1)
                        Text("Escape to dismiss")
                            .lineLimit(1)
                    }
                    .font(.footnote)
                    .foregroundStyle(RemoraTheme.secondaryText)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .glassEffect(.regular, in: Capsule(style: .continuous))
                }
                Spacer(minLength: 0)
            }
            // As tall as the note drawer's footer, so beside it the two
            // sheets end on the same line.
            .frame(height: PanelLayout.footerHeight)
            .padding(.trailing, appState.allNotesUsesStackedLayout ? PanelLayout.stackedContentInset : 0)
        }
        .padding(.top, Spacing.lg)
        .padding(.leading, Spacing.xl)
        .padding(.trailing, Spacing.md + Spacing.xxs)
        .padding(.bottom, Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onExitCommand {
            // Beside the note, Escape closes the pair, as it does from
            // the note.
            if appState.isAllNotesStacked {
                appState.saveAndDismissEditor()
            } else {
                appState.dismissAllNotesPanel()
            }
        }
    }
}
