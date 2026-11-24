import AppKit
import XCTest

@MainActor
final class CaptureNoteTests: XCTestCase {
    private func note(file: String, app: String, url: String? = nil) -> CaptureNote {
        CaptureNote(SavedCapture(file: URL(fileURLWithPath: "/tmp/" + file), width: 800, height: 420,
                                 context: CaptureContext(app: app, window: file, url: url)))
    }

    func testOldCopyActionCannotOverwriteTheVisibleSafariPrompt() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let notes = CaptureNotes()
        let code = note(file: "old-code.png", app: "Code")
        let safari = note(file: "new-safari.png", app: "Safari", url: "https://example.test/page")
        notes.show(code)
        let oldCopy = { try notes.copy(code, to: board) }
        notes.show(safari)
        safari.text = "Fix the alignment."
        board.setString(safari.capture.file.path, forType: .string)

        // An old window's delayed button action must preserve the new file path.
        XCTAssertFalse(try oldCopy())
        XCTAssertEqual(board.string(forType: .string), "/tmp/new-safari.png")
        XCTAssertTrue(try notes.copy(safari, to: board))
        XCTAssertFalse(try oldCopy())
        let destination = NSTextView(frame: .zero)
        XCTAssertTrue(destination.readSelection(from: board, type: .string))
        XCTAssertEqual(destination.string, """
        Fix the alignment.

        Screenshot: /tmp/new-safari.png
        App: Safari
        Window: new-safari.png
        URL: https://example.test/page
        Image: 800 × 420 px
        """)
        XCTAssertNil(notes.current)
        XCTAssertTrue(notes.drafts.isEmpty)
    }

    func testReplacingANotePreservesOnlyWrittenDraftsForExplicitResume() {
        let notes = CaptureNotes()
        let first = note(file: "first.png", app: "Code")
        let second = note(file: "second.png", app: "Safari")
        notes.show(first)
        first.text = "Keep this edit."
        notes.show(second)
        notes.dismiss(first)
        XCTAssertTrue(notes.current === second)
        XCTAssertEqual(notes.drafts.count, 1)
        notes.show(first)
        XCTAssertEqual(notes.current?.text, "Keep this edit.")
        XCTAssertTrue(notes.drafts.isEmpty)
    }

    func testNativeNoteShortcutsReadTheCurrentDraftAndRespectTextSelection() throws {
        _ = NSApplication.shared
        let notes = CaptureNotes()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let window = NoteWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = text
        XCTAssertTrue(window.makeFirstResponder(text))
        text.string = "Selected text"

        func key(_ chars: String, _ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code))
        }
        let code = note(file: "code.png", app: "Code")
        notes.show(code)
        window.submit = { _ = try? notes.copy(code, to: board) }

        for event in [try key("\r", 36), try key("c", 8)] {
            let safari = note(file: "safari.png", app: "Safari", url: "https://example.test/")
            notes.show(safari)
            window.submit = { _ = try? notes.copy(safari, to: board) }
            text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertEqual(board.string(forType: .string), safari.capture.prompt(note: ""))
        }

        // Command-C in a selection belongs to the native text system.
        notes.show(code)
        window.submit = { XCTFail("Selected-text copy submitted the capture") }
        text.setSelectedRange(NSRange(location: 0, length: 8))
        _ = window.performKeyEquivalent(with: try key("c", 8))
        XCTAssertTrue(notes.current === code)
    }
}
