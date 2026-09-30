import AppKit
import SwiftUI

/// The icon of where a note lives: the site's own icon for a web page
/// (the browser's until that has been fetched), the app a note is
/// attached to, or the file's Finder icon. Falls back to a symbol when
/// the app isn't installed on this Mac.
struct NoteContextIcon: View {
    let context: NoteContext
    var size: CGFloat = 16

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let favicon {
                let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                if let backing = backing(for: favicon.tone) {
                    // A black mark on dark glass (or white on light) would
                    // disappear, so it sits on a small contrasting plate.
                    Image(nsImage: favicon.image)
                        .resizable()
                        .interpolation(.high)
                        .padding(size * 0.12)
                        .background(backing, in: shape)
                } else {
                    // Site icons are bare squares; app and file icons
                    // already carry their own shape.
                    Image(nsImage: favicon.image)
                        .resizable()
                        .interpolation(.high)
                        .clipShape(shape)
                }
            } else if let icon = NoteContextIconCache.icon(for: context) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.8, weight: .medium))
                    .foregroundStyle(RemoraTheme.secondaryText)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var favicon: FaviconStore.Favicon? {
        context.siteHost.flatMap { FaviconStore.shared.icon(forHost: $0) }
    }

    private func backing(for tone: FaviconStore.Favicon.Tone) -> Color? {
        switch (tone, colorScheme) {
        case (.darkGlyph, .dark): return Color.white.opacity(0.9)
        case (.lightGlyph, .light): return Color.black.opacity(0.75)
        default: return nil
        }
    }

    private var fallbackSymbol: String {
        switch context.kind {
        case .application: return "app.dashed"
        case .url: return "globe"
        case .file: return "doc"
        }
    }
}

/// Icon lookups hit Launch Services, so each answer (including "no such
/// app") is remembered for the life of the process.
private enum NoteContextIconCache {
    private static var appIcons: [String: NSImage?] = [:]
    private static var fileIcons: [String: NSImage] = [:]
    private static var defaultBrowserIcon: NSImage?? = nil

    static func icon(for context: NoteContext) -> NSImage? {
        switch context.kind {
        case .application:
            for bundleIdentifier in applicationBundleIdentifiers(for: context) {
                if let icon = appIcon(bundleIdentifier: bundleIdentifier) { return icon }
            }
            return nil
        case .url:
            if let bundleIdentifier = context.sourceBundleIdentifier,
               let icon = appIcon(bundleIdentifier: bundleIdentifier) {
                return icon
            }
            return browserIcon()
        case .file:
            return fileIcon(path: context.identifier)
        }
    }

    /// App notes don't record a bundle identifier: either the identifier
    /// is one, or it carries the prefix of an app with per-conversation /
    /// per-file notes (see the title parsers).
    private static func applicationBundleIdentifiers(for context: NoteContext) -> [String] {
        let identifier = context.identifier
        if identifier.hasPrefix("slack:") {
            return ["com.tinyspeck.slackmacgap", "com.tinyspeck.slackmacgap2"]
        }
        if identifier.hasPrefix("figma:") {
            return ["com.figma.Desktop"]
        }
        if identifier.hasPrefix("linear:") {
            return ["com.linear"]
        }
        return [identifier]
    }

    private static func appIcon(bundleIdentifier: String) -> NSImage? {
        if let cached = appIcons[bundleIdentifier] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        appIcons[bundleIdentifier] = icon
        return icon
    }

    /// Web notes captured before the browser was recorded show the
    /// default browser.
    private static func browserIcon() -> NSImage? {
        if let cached = defaultBrowserIcon { return cached }
        let icon = URL(string: "https://example.com")
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        defaultBrowserIcon = icon
        return icon
    }

    private static func fileIcon(path: String) -> NSImage {
        if let cached = fileIcons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        fileIcons[path] = icon
        return icon
    }
}
