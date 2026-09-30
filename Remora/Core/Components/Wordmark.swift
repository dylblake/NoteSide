import SwiftUI

/// The Remora wordmark as a template image, tinted like label text. The
/// SVG is 70×12 with the glyphs spanning 10 of those units, so a 12pt frame
/// draws a ~10pt "R" — about the cap height of `.headline`.
struct Wordmark: View {
    var height: CGFloat = 12

    var body: some View {
        Image("Wordmark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(RemoraTheme.primaryText)
            .accessibilityLabel("Remora")
            .accessibilityIdentifier("remoraWordmark")
    }
}
