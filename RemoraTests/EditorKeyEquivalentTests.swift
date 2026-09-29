import AppKit
import XCTest
@testable import Remora

/// Text size is keyboard-only (no toolbar control), so the shortcuts are
/// its whole interface.
@MainActor
final class EditorKeyEquivalentTests: XCTestCase {
    private func command(for characters: String, _ modifiers: NSEvent.ModifierFlags) -> RichTextEditorController.Command? {
        let textView = EditorTextView(frame: .zero)
        var received: RichTextEditorController.Command?
        textView.onCommand = { received = $0; return true }
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
        )!
        _ = textView.performKeyEquivalent(with: event)
        return received
    }

    func testZoomShortcuts() {
        guard case .zoomIn = command(for: "=", .command) else { return XCTFail("⌘= should zoom in") }
        guard case .zoomIn = command(for: "+", .command) else { return XCTFail("⌘+ should zoom in") }
        guard case .zoomOut = command(for: "-", .command) else { return XCTFail("⌘− should zoom out") }
        guard case .resetZoom = command(for: "0", .command) else { return XCTFail("⌘0 should reset zoom") }
    }

    func testNoQuoteSelectionShortcut() {
        // Quoting the host app's selection happens when the drawer opens;
        // there is no in-drawer quote action any more.
        XCTAssertNil(command(for: "q", [.command, .shift]))
    }
}
