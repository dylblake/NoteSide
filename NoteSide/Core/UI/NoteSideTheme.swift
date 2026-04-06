import AppKit
import SwiftUI

enum NoteSideTheme {
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

    static func cardBackground(prominence: Double = 1.0) -> Color {
        contentBackground.opacity(prominence)
    }

    static func tintedTileFill(for tint: Color) -> Color {
        tint.opacity(0.12)
    }

    static func tintedTileStroke(for tint: Color) -> Color {
        tint.opacity(0.18)
    }
}
