import AppKit
import SwiftUI

/// Semantic colour tokens. Every value is backed by a system `NSColor` so
/// light/dark mode, Increase Contrast and the user's accent colour are
/// handled by AppKit — never hardcode a hex or RGB value for chrome.
enum RemoraTheme {
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let contentBackground = Color(nsColor: .controlBackgroundColor)
    static let secondaryBackground = Color(nsColor: .textBackgroundColor)
    static let elevatedBackground = Color(nsColor: .underPageBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let quaternaryText = Color(nsColor: .quaternaryLabelColor)
    static let accent = Color(nsColor: .controlAccentColor)
    static let activeFill = Color(nsColor: .selectedContentBackgroundColor)
    static let success = Color(nsColor: .systemGreen)
    static let danger = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)

    /// Per-context tints for note cards. System colours so they adapt to
    /// the appearance and accessibility settings like everything else.
    static let applicationTint = Color(nsColor: .systemBlue)
    static let urlTint = Color(nsColor: .systemGreen)
    static let fileTint = Color(nsColor: .systemOrange)

    /// Liquid Glass for the large floating sheets. A faint window-colour
    /// tint keeps body text legible over busy desktops while the glass
    /// still refracts what's behind the panel.
    static var sheetGlass: Glass {
        .regular.tint(windowBackground.opacity(0.45))
    }

    static func cardBackground(prominence: Double = 1.0) -> Color {
        contentBackground.opacity(prominence)
    }

    /// Card and inset-row fills for content that sits on `sheetGlass`
    /// (the About / Setup / License windows): translucent so the glass
    /// still reads through, opaque enough that body text stays legible.
    static let glassCardFill = cardBackground(prominence: 0.55)
    static let glassInsetRowFill = secondaryBackground.opacity(0.5)

    static func tintedTileFill(for tint: Color) -> Color {
        tint.opacity(0.12)
    }

    static func tintedTileStroke(for tint: Color) -> Color {
        tint.opacity(0.18)
    }
}

/// Point-based spacing rhythm shared by every screen (4/8/12/16/24/32/48).
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

/// Continuous corner radii. Panels use the large radius so they read as
/// a single floating glass sheet; controls and cards step down from there.
enum CornerRadius {
    static let control: CGFloat = 8
    static let card: CGFloat = 14
    static let sheet: CGFloat = 20
    static let panel: CGFloat = 26
}

/// One place for the app's card surface so every window draws it the
/// same way: a content-coloured rounded rect with a hairline stroke.
struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = CornerRadius.card
    var fill: Color = RemoraTheme.contentBackground
    var strokeOpacity: Double = 0.8
    /// Overrides the hairline colour (e.g. a success tint once granted).
    var strokeColor: Color? = nil

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(strokeColor ?? RemoraTheme.border.opacity(strokeOpacity), lineWidth: 1)
                    )
            )
    }
}

extension View {
    /// Standard card surface (see `CardSurface`).
    func cardSurface(
        cornerRadius: CGFloat = CornerRadius.card,
        fill: Color = RemoraTheme.contentBackground,
        strokeOpacity: Double = 0.8,
        strokeColor: Color? = nil
    ) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, fill: fill, strokeOpacity: strokeOpacity, strokeColor: strokeColor))
    }

    /// Nested inset row inside a card: a slightly recessed surface.
    func insetRowSurface(
        cornerRadius: CGFloat = CornerRadius.card,
        fill: Color = RemoraTheme.secondaryBackground
    ) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius, fill: fill, strokeOpacity: 0.7))
    }
}
