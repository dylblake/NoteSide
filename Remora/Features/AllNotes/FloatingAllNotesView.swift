import SwiftUI

/// The All Notes drawer: the notes browser on one Liquid Glass sheet with
/// a small glass footer carrying the dismiss hint.
struct FloatingAllNotesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ContentView()
                .environment(appState)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.panel, style: .continuous))
                .glassEffect(RemoraTheme.sheetGlass, in: RoundedRectangle(cornerRadius: CornerRadius.panel, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("allNotesSheet")

            HStack {
                Spacer(minLength: 0)
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
                Spacer(minLength: 0)
            }
        }
        .padding(.top, Spacing.lg)
        .padding(.leading, Spacing.xl)
        .padding(.trailing, Spacing.md + Spacing.xxs)
        .padding(.bottom, Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onExitCommand {
            appState.dismissAllNotesPanel()
        }
    }
}
