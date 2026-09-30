import AppKit
import XCTest
@testable import Remora

/// Finding a site's icon in its home page, and which hosts are asked at all.
final class FaviconLocatorTests: XCTestCase {
    private let base = URL(string: "https://example.com/docs/")!

    private func urls(_ html: String) -> [String] {
        FaviconLocator.iconURLs(inHTML: html, baseURL: base).map(\.absoluteString)
    }

    func testLargestDeclaredIconComesFirstAndTouchIconCountsAsLarge() {
        let html = """
        <head>
          <link rel="icon" sizes="16x16" href="/small.png">
          <link rel="apple-touch-icon" href="/touch.png">
          <link rel="icon" sizes="32x32 96x96" href="/big.png">
          <link rel="shortcut icon" href="/plain.ico">
        </head>
        """
        XCTAssertEqual(urls(html), [
            "https://example.com/touch.png",
            "https://example.com/big.png",
            "https://example.com/small.png",
            "https://example.com/plain.ico"
        ])
    }

    func testRelativeProtocolRelativeAndAbsoluteLinksResolve() {
        let html = """
        <link rel=icon href=icon.png>
        <LINK REL='ICON' HREF='//cdn.example.net/a.png'>
        <link href="https://static.example.org/b.png" rel="icon">
        """
        XCTAssertEqual(urls(html), [
            "https://example.com/docs/icon.png",
            "https://cdn.example.net/a.png",
            "https://static.example.org/b.png"
        ])
    }

    func testSkipsVectorMaskDataAndUnrelatedLinks() {
        let html = """
        <link rel="stylesheet" href="/site.css">
        <link rel="mask-icon" href="/mask.svg" color="#000">
        <link rel="icon" type="image/svg+xml" href="/vector">
        <link rel="icon" href="/logo.svg">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="/real.png">
        <link rel="icon" href="/real.png">
        """
        XCTAssertEqual(urls(html), ["https://example.com/real.png"])
    }

    func testOnlyPublicLookingHostsAreFetched() {
        XCTAssertTrue(FaviconFetcher.isFetchable(host: "github.com"))
        XCTAssertTrue(FaviconFetcher.isFetchable(host: "docs.my-site.co.uk"))
        XCTAssertFalse(FaviconFetcher.isFetchable(host: "localhost"))
        XCTAssertFalse(FaviconFetcher.isFetchable(host: "../etc"))
        XCTAssertFalse(FaviconFetcher.isFetchable(host: "exa mple.com"))
        XCTAssertFalse(FaviconFetcher.isFetchable(host: "bücher.de"))
    }

    func testNormalizingRejectsNonImagesAndShrinksLargeOnes() throws {
        XCTAssertNil(FaviconFetcher.normalizedPNG(from: Data("<html>404</html>".utf8)))

        let big = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        let source = try XCTUnwrap(big?.representation(using: .png, properties: [:]))
        let png = try XCTUnwrap(FaviconFetcher.normalizedPNG(from: source))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, 64)
    }
}
