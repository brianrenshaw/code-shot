import AppKit
import Combine

final class CaptureNote: ObservableObject {
    let capture: SavedCapture
    let returnApp: NSRunningApplication?
    @Published var text = ""

    init(_ capture: SavedCapture, returnApp: NSRunningApplication? = nil) {
        self.capture = capture
        self.returnApp = returnApp
    }
}

@MainActor
final class CaptureNotes {
    private(set) var current: CaptureNote?
    private(set) var drafts: [CaptureNote] = []

    func show(_ note: CaptureNote) {
        guard current !== note else { return }
        setAside()
        drafts.removeAll { $0 === note }
        current = note
    }

    func setAside() {
        if let current, !current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts.append(current)
        }
        current = nil
    }

    func dismiss(_ note: CaptureNote) {
        if current === note { current = nil }
    }

    /// A button or key event queued for a retired view must never touch the pasteboard.
    @discardableResult
    func copy(_ note: CaptureNote, to board: NSPasteboard) throws -> Bool {
        guard current === note else { return false }
        let prompt = note.capture.prompt(note: note.text)
        board.clearContents()
        guard board.setString(prompt, forType: .string) else {
            throw CaptureError("Your note is still open. Try copying again.")
        }
        current = nil
        return true
    }
}

final class NoteWindow: NSWindow {
    var submit: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, modifiers == .command, let submit {
            let isReturn = [36, 76].contains(event.keyCode)
            let editor = firstResponder as? NSTextView
            let copyFromEditor = event.charactersIgnoringModifiers?.lowercased() == "c"
                && editor?.isEditable == true && editor?.selectedRange().length == 0
            if isReturn || copyFromEditor {
                if !event.isARepeat { submit() }
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
