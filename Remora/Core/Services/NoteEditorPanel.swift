import AppKit

final class NoteEditorPanel: NSPanel {
    /// The other panel of the stack while the note and All Notes are on
    /// screen together. Liquid Glass draws a window as active while it is
    /// key or main, and the two can't both be key, so whichever of them
    /// takes the keyboard makes the other main, inside the same event: a
    /// later fix-up would leave the other sheet a frame without either,
    /// which shows as a flash of the lighter inactive glass.
    weak var stackSibling: NSWindow?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        handMainToSibling()
    }

    /// AppKit makes a window that takes key main as well when it can be;
    /// that would strip the sibling. Main goes straight back to it.
    override func becomeMain() {
        super.becomeMain()
        if isKeyWindow {
            handMainToSibling()
        }
    }

    private func handMainToSibling() {
        if let sibling = stackSibling, sibling.isVisible, !sibling.isMainWindow {
            sibling.makeMain()
        }
    }
}
