import SwiftUI

struct FloatingAllNotesView: View {
    @EnvironmentObject private var appState: AppState
    private let cardCornerRadius: CGFloat = 28

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 16) {
                ContentView(isFloatingPanel: true)
                    .environmentObject(appState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .background(
                        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                            .fill(NoteSideTheme.secondaryBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                                    .stroke(NoteSideTheme.border.opacity(0.8), lineWidth: 1)
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))

                ZStack {
                    GeometryReader { geometry in
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
                }
                .frame(height: 36)
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
        .onExitCommand {
            appState.dismissAllNotesPanel()
        }
    }

    private var footerRadialBackdrop: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let radius = max(size.width, size.height) / 2

            Rectangle()
                .fill(.regularMaterial)
                .mask(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black.opacity(0.85), location: 0.35),
                            .init(color: .clear, location: 1.0)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
                .padding(.horizontal, -40)
                .padding(.vertical, -16)
                .allowsHitTesting(false)
        }
    }
}
