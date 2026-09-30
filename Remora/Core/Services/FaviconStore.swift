import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Website icons for web notes, keyed by host. An icon is downloaded from
/// the site itself the first time a note for that site is shown, then kept
/// on disk; nothing about the note is sent. Until it arrives, or when a
/// site has none, callers fall back to the browser's icon.
@Observable
final class FaviconStore {
    static let shared = FaviconStore()

    struct Favicon {
        /// A glyph on a transparent ground that is all dark or all light
        /// vanishes against a matching appearance and needs a backing.
        enum Tone { case regular, darkGlyph, lightGlyph }

        let image: NSImage
        let tone: Tone
    }

    private var icons: [String: Favicon] = [:]
    /// Hosts already looked up this launch (found, missing or in flight).
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let directory: URL?

    init() {
        // UI tests turn downloads off so runs stay offline and repeatable.
        guard ProcessInfo.processInfo.environment["REMORA_DISABLE_FAVICONS"] == nil,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            directory = nil
            return
        }
        let folder = caches
            .appending(path: Bundle.main.bundleIdentifier ?? "Remora", directoryHint: .isDirectory)
            .appending(path: "Favicons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder
    }

    /// The cached icon, or nil while it is being fetched (the view is
    /// redrawn when it lands) or when the site has none.
    func icon(forHost host: String) -> Favicon? {
        if let icon = icons[host] { return icon }
        guard let directory, FaviconFetcher.isFetchable(host: host), requested.insert(host).inserted else {
            return nil
        }
        Task { [weak self] in
            guard let data = await FaviconFetcher.icon(forHost: host, cacheDirectory: directory),
                  let image = NSImage(data: data) else { return }
            self?.icons[host] = Favicon(image: image, tone: FaviconFetcher.tone(ofPNG: data))
        }
        return nil
    }
}

/// Disk cache and download, off the main actor.
nonisolated enum FaviconFetcher {
    private static let retryInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let maxIconBytes = 1_000_000
    private static let maxPageBytes = 300_000
    /// Stored size: enough for an 18pt icon on a 2x display with headroom.
    private static let storedPixelSize = 64

    private enum Outcome {
        case icon(Data)
        /// The site answered but has no usable icon: don't ask again soon.
        case none
        /// Offline or unreachable: try again next launch.
        case unreachable
    }

    /// Public sites only: a dotted name made of host characters, so it is
    /// also safe to use as a file name.
    static func isFetchable(host: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        return host.contains(".")
            && !host.hasPrefix(".")
            && host.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// PNG data for the host's icon: from disk, else downloaded and saved.
    static func icon(forHost host: String, cacheDirectory: URL) async -> Data? {
        let iconFile = cacheDirectory.appending(path: "\(host).png")
        let missFile = cacheDirectory.appending(path: "\(host).miss")

        if let cached = try? Data(contentsOf: iconFile) { return cached }
        if let missedAt = (try? missFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           missedAt.timeIntervalSinceNow > -retryInterval {
            return nil
        }

        switch await download(host: host) {
        case .icon(let png):
            try? png.write(to: iconFile, options: .atomic)
            try? FileManager.default.removeItem(at: missFile)
            return png
        case .none:
            try? Data().write(to: missFile)
            return nil
        case .unreachable:
            return nil
        }
    }

    private static func download(host: String) async -> Outcome {
        guard let site = URL(string: "https://\(host)/") else { return .none }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            // Most sites answer at the conventional path in one request.
            if let data = try await fetch(site.appending(path: "favicon.ico"), limit: maxIconBytes, session: session)?.data,
               let png = normalizedPNG(from: data) {
                return .icon(png)
            }

            // Otherwise the home page says where the icon is.
            guard let page = try await fetch(site, limit: maxPageBytes, truncating: true, session: session) else {
                return .none
            }
            let html = String(decoding: page.data, as: UTF8.self)
            for candidate in FaviconLocator.iconURLs(inHTML: html, baseURL: page.url).prefix(3) {
                if let data = try await fetch(candidate, limit: maxIconBytes, session: session)?.data,
                   let png = normalizedPNG(from: data) {
                    return .icon(png)
                }
            }
            return .none
        } catch {
            return .unreachable
        }
    }

    /// A 2xx body of at most `limit` bytes (or its first `limit` bytes when
    /// `truncating`), with the URL it was finally served from. Nil for an
    /// HTTP error or an oversized body; throws when the site can't be reached.
    private static func fetch(
        _ url: URL,
        limit: Int,
        truncating: Bool = false,
        session: URLSession
    ) async throws -> (data: Data, url: URL)? {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }

        var data = Data()
        data.reserveCapacity(min(limit, 64_000))
        for try await byte in bytes {
            if data.count == limit {
                bytes.task.cancel()
                return truncating ? (data, http.url ?? url) : nil
            }
            data.append(byte)
        }
        return (data, http.url ?? url)
    }

    /// Whether the icon is a dark (or light) shape on a see-through ground.
    static func tone(ofPNG data: Data) -> FaviconStore.Favicon.Tone {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return .regular }

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .regular }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var clear = 0
        var weight = 0.0
        var luminance = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            if alpha < 0.1 { clear += 1 }
            // Premultiplied, so each pixel already counts by its opacity.
            luminance += (0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])) / 255
            weight += alpha
        }
        guard weight > 0, Double(clear) / Double(width * height) > 0.1 else { return .regular }

        let mean = luminance / weight
        if mean < 0.25 { return .darkGlyph }
        if mean > 0.85 { return .lightGlyph }
        return .regular
    }

    /// Decodes whatever the site served (ICO, PNG, JPEG, GIF, WebP) and
    /// re-encodes its largest image as a small PNG. Nil for anything
    /// ImageIO can't read, such as SVG or an HTML error page.
    static func normalizedPNG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // An .ico holds several sizes; take the biggest.
        var bestIndex = 0
        var bestWidth = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            if width > bestWidth {
                bestWidth = width
                bestIndex = index
            }
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: storedPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, bestIndex, options as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Finds the icons a page declares in its `<link>` tags.
nonisolated enum FaviconLocator {
    private static let linkTag = try! NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive])
    private static let attribute = try! NSRegularExpression(
        pattern: #"([a-zA-Z][\w-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
    )

    /// Icon URLs declared by the page, best first: the largest raster icon
    /// (an Apple touch icon counts as 180px), then any of unknown size.
    /// SVG and mask icons are skipped; they can't be drawn as a bitmap here.
    static func iconURLs(inHTML html: String, baseURL: URL) -> [URL] {
        let nsHTML = html as NSString
        var candidates: [(url: URL, size: Int)] = []

        for tag in linkTag.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)) {
            let attributes = self.attributes(in: nsHTML.substring(with: tag.range))
            guard let href = attributes["href"], !href.isEmpty, !href.hasPrefix("data:") else { continue }

            let rel = Set((attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let isTouchIcon = rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed")
            guard isTouchIcon || rel.contains("icon") else { continue }

            let type = (attributes["type"] ?? "").lowercased()
            guard !type.contains("svg"),
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.pathExtension.lowercased() != "svg" else { continue }

            let declared = (attributes["sizes"] ?? "").lowercased()
                .split(whereSeparator: \.isWhitespace)
                .compactMap { Int($0.split(separator: "x").first ?? "") }
                .max()
            candidates.append((url, declared ?? (isTouchIcon ? 180 : 0)))
        }

        var seen = Set<URL>()
        return candidates
            .enumerated()
            .sorted { $0.element.size != $1.element.size ? $0.element.size > $1.element.size : $0.offset < $1.offset }
            .map(\.element.url)
            .filter { seen.insert($0).inserted }
    }

    private static func attributes(in tag: String) -> [String: String] {
        let nsTag = tag as NSString
        var result: [String: String] = [:]
        for match in attribute.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)) {
            let name = nsTag.substring(with: match.range(at: 1)).lowercased()
            let valueRange = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }
            if let valueRange, result[name] == nil {
                result[name] = nsTag.substring(with: valueRange)
            }
        }
        return result
    }
}
