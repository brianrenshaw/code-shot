import AppKit
import Carbon

enum CaptureAction: UInt32, CaseIterable {
    // Declaration order is the palette order. Raw values are persisted shortcut IDs.
    case area = 1, areaNote = 3
    case scrolling = 2, scrollingNote = 6
    case window = 4, windowNote = 7
    case palette = 5

    static let captures = allCases.filter { $0 != .palette }

    var kind: CaptureKind? {
        switch self {
        case .area, .areaNote: return .area
        case .scrolling, .scrollingNote: return .scrolling
        case .window, .windowNote: return .window
        case .palette: return nil
        }
    }

    var opensNote: Bool {
        switch self {
        case .areaNote, .scrollingNote, .windowNote: return true
        case .area, .scrolling, .window, .palette: return false
        }
    }

    var title: String {
        guard self != .palette else { return "Capture Palette" }
        return opensNote ? menuTitle : menuTitle + " to Clipboard"
    }

    var menuTitle: String {
        let name: String
        switch kind {
        case .area: name = "Capture Screen Area"
        case .scrolling: name = "Scrolling Capture"
        case .window: name = "Capture Window"
        case nil: return "Open Capture Palette"
        }
        return opensNote ? name + " with a Note" : name
    }

    var symbol: String {
        switch kind {
        case .area: return "viewfinder"
        case .scrolling: return "arrow.up.and.down.text.horizontal"
        case .window: return "macwindow"
        case nil: return "command"
        }
    }

    var initial: Shortcut {
        let pair: (Int, String)
        switch self {
        case .area: pair = (kVK_ANSI_S, "S")
        case .areaNote: pair = (kVK_ANSI_N, "N")
        case .scrolling, .scrollingNote: pair = (kVK_ANSI_L, "L")
        case .window, .windowNote: pair = (kVK_ANSI_W, "W")
        case .palette: return Shortcut(key: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey), label: "4")
        }
        let modifiers = controlKey | optionKey | (self == .scrollingNote || self == .windowNote ? shiftKey : 0)
        return Shortcut(key: UInt32(pair.0), modifiers: UInt32(modifiers), label: pair.1)
    }

    static func choices(for shortcut: Shortcut, in bindings: [Self: Shortcut]) -> [Self] {
        let matches = captures.filter { bindings[$0]?.chord == shortcut.chord }
        if matches.count > 1 { return matches }
        return bindings[.palette]?.chord == shortcut.chord ? captures : matches
    }
}

struct Shortcut: Codable, Equatable {
    var key: UInt32
    var modifiers: UInt32
    var label: String

    struct Chord: Hashable {
        let key: UInt32
        let modifiers: UInt32
    }

    var chord: Chord { Chord(key: key, modifiers: modifiers) }

    var description: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + label
    }

    init(key: UInt32, modifiers: UInt32, label: String) {
        self.key = key
        self.modifiers = modifiers
        self.label = label
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let chars = event.characters(byApplyingModifiers: []), chars.count == 1,
              let scalar = chars.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.illegalCharacters.contains(scalar), scalar.value < 0xF700 || scalar.value > 0xF8FF
        else { return nil }
        let masks: [(NSEvent.ModifierFlags, Int)] = [
            (.command, cmdKey), (.option, optionKey), (.control, controlKey), (.shift, shiftKey)
        ]
        key = UInt32(event.keyCode)
        modifiers = masks.reduce(0) { flags.contains($1.0) ? $0 | UInt32($1.1) : $0 }
        label = chars == " " ? "Space" : chars.uppercased()
    }
}

private let signature: OSType = 0x43734874 // CsHt

final class Shortcuts: ObservableObject {
    @Published private(set) var bindings: [CaptureAction: Shortcut] = [:]
    @Published private(set) var sharedShortcut: Shortcut?
    private let defaults: UserDefaults
    private let sharedKey = "shortcut.shared"
    @Published var recording: CaptureAction?
    @Published var message: String?
    private var registered: [Shortcut.Chord: (id: UInt32, ref: EventHotKeyRef)] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private var monitor: Any?
    var perform: (([CaptureAction]) -> Void)?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let handler { RemoveEventHandler(handler) }
        for entry in registered.values { UnregisterEventHotKey(entry.ref) }
    }

    func start() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            guard let info, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout.size(ofValue: id), nil, &id)
            guard result == noErr, id.signature == signature
            else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<Shortcuts>.fromOpaque(info).takeUnretainedValue()
            guard let chord = owner.registered.first(where: { $0.value.id == id.id })?.key,
                  let shortcut = owner.bindings.values.first(where: { $0.chord == chord }) else { return noErr }
            if let recording = owner.recording {
                owner.accept(shortcut, for: recording)
            } else { owner.perform?(CaptureAction.choices(for: shortcut, in: owner.bindings)) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { message = "Global shortcuts are unavailable. Use the menu bar to capture."; return }
        if let saved = savedShortcut(forKey: sharedKey) {
            sharedShortcut = saved
            do { try useSharedBinding(saved) } catch { message = error.localizedDescription }
        } else {
            loadIndividualBindings()
        }
    }

    /// Keep each individual shortcut in its original preference. One override switches the entire set.
    @discardableResult
    func assignAllToPalette() -> Bool {
        stopListening()
        let shortcut = bindings[.palette] ?? savedShortcut(forKey: key(for: .palette)) ?? CaptureAction.palette.initial
        do {
            try saveSharedShortcut(shortcut)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func useIndividualShortcuts() {
        stopListening()
        loadIndividualBindings()
        defaults.removeObject(forKey: sharedKey)
        sharedShortcut = nil
    }

    private func loadIndividualBindings() {
        var next = [CaptureAction: Shortcut]()
        var unavailable = [String]()
        for action in CaptureAction.allCases {
            let shortcut = savedShortcut(forKey: key(for: action)) ?? action.initial
            do {
                try reserve(shortcut)
                next[action] = shortcut
            } catch { unavailable.append(action.title) }
        }
        replaceBindings(with: next)
        message = unavailable.isEmpty ? nil : "Choose another shortcut for " + unavailable.joined(separator: ", ") + "."
    }

    private func useSharedBinding(_ shortcut: Shortcut) throws {
        try reserve(shortcut)
        replaceBindings(with: Dictionary(uniqueKeysWithValues: CaptureAction.allCases.map { ($0, shortcut) }))
    }

    private func saveSharedShortcut(_ shortcut: Shortcut) throws {
        let data = try JSONEncoder().encode(shortcut)
        try useSharedBinding(shortcut)
        defaults.set(data, forKey: sharedKey)
        sharedShortcut = shortcut
        message = nil
    }

    func listen(for action: CaptureAction) {
        let alreadyListening = recording == action
        stopListening()
        guard !alreadyListening else { return }
        recording = action
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording == action else { return event }
            if event.keyCode == kVK_Escape { self.stopListening(); return nil }
            guard let shortcut = Shortcut(event: event) else {
                self.message = "Use a letter, number, or symbol with Control, Option, or Command."
                return nil
            }
            self.accept(shortcut, for: action)
            return nil
        }
    }

    private func accept(_ shortcut: Shortcut, for action: CaptureAction) {
        do {
            if sharedShortcut != nil {
                try saveSharedShortcut(shortcut)
            } else {
                let data = try JSONEncoder().encode(shortcut)
                try reserve(shortcut)
                var next = bindings
                next[action] = shortcut
                replaceBindings(with: next)
                defaults.set(data, forKey: key(for: action))
            }
            stopListening()
            message = nil
        } catch { message = error.localizedDescription }
    }

    func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private func key(for action: CaptureAction) -> String { "shortcut.\(action.rawValue)" }

    private func savedShortcut(forKey key: String) -> Shortcut? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    private func reserve(_ shortcut: Shortcut) throws {
        guard handler != nil else { throw CaptureError("Global shortcuts are unavailable. Reopen CodeShot and try again.") }
        guard registered[shortcut.chord] == nil else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: nextID)
        guard RegisterEventHotKey(shortcut.key, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { throw CaptureError("This shortcut is unavailable. Choose another combination.") }
        registered[shortcut.chord] = (nextID, ref)
        nextID += 1
    }

    private func replaceBindings(with next: [CaptureAction: Shortcut]) {
        let active = Set(next.values.map(\.chord))
        for chord in Set(registered.keys).subtracting(active) {
            if let entry = registered.removeValue(forKey: chord) { UnregisterEventHotKey(entry.ref) }
        }
        bindings = next
    }
}

private let sessionSignature: OSType = 0x43735373 // CsSs

/// A global shortcut that exists only while it's retained, such as ⌘↩ to finish a scrolling capture
/// while another app stays frontmost. Uses its own signature so the capture handler passes it through.
final class SessionHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(key: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            guard let info, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout.size(ofValue: id), nil, &id)
            guard result == noErr, id.signature == sessionSignature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<SessionHotKey>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { owner.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: sessionSignature, id: 1)
        guard RegisterEventHotKey(UInt32(key), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr,
              ref != nil else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
