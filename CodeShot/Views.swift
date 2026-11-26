import AppKit
import Combine
import ImageIO
import SwiftUI

final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published var folder: URL { didSet { defaults.set(folder.path, forKey: "folder") } }
    @Published var includeContext: Bool { didSet { defaults.set(includeContext, forKey: "includeContext") } }
    @Published var includeURL: Bool { didSet { defaults.set(includeURL, forKey: "includeURL") } }

    init() {
        defaults.register(defaults: ["includeContext": true, "includeURL": true])
        folder = defaults.string(forKey: "folder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? CaptureFiles.defaultFolder
        includeContext = defaults.bool(forKey: "includeContext")
        includeURL = defaults.bool(forKey: "includeURL")
    }

    func chooseFolder() {
        let picker = NSOpenPanel()
        picker.title = "Screenshot Folder"
        picker.prompt = "Choose Folder"
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = folder
        if picker.runModal() == .OK, let url = picker.url { folder = url }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var shortcuts: Shortcuts
    let requestPermission: (Permission) -> Void
    let capture: (CaptureAction) -> Void
    @State private var showIndividual = false
    @State private var screenAccess = CGPreflightScreenCaptureAccess()
    @State private var accessibility = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Keyboard shortcuts") {
                LabeledContent {
                    recorder(for: .palette)
                } label: {
                    Label("Capture Palette", systemImage: "command").fontWeight(.medium)
                }
                if let shared = shortcuts.sharedShortcut {
                    HStack {
                        Label("All captures use " + shared.description, systemImage: "link")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use Individual Shortcuts") {
                            shortcuts.useIndividualShortcuts()
                            showIndividual = true
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Button("Assign Everything the Same Shortcut") {
                            if shortcuts.assignAllToPalette() { capture(.palette) }
                        }
                        Text("Use the palette shortcut for all six captures.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 2)
                    DisclosureGroup("Individual capture shortcuts", isExpanded: $showIndividual) {
                        ForEach(CaptureAction.captures, id: \.self) { action in
                            LabeledContent(action.title) { recorder(for: action) }
                        }
                    }
                }
                if let message = shortcuts.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section("After capture") {
                LabeledContent("Save PNGs to") {
                    Text(prefs.folder.path(percentEncoded: false).abbreviatingHome)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(prefs.folder.path)
                    Button("Choose…") { prefs.chooseFolder() }
                }
                Toggle("Include app and window title", isOn: $prefs.includeContext)
                Toggle("Include browser URL when available", isOn: $prefs.includeURL)
                    .disabled(!prefs.includeContext)
            }
            Section("Permissions") {
                permission("Screen Recording", detail: "Needed to capture the selected area.", granted: screenAccess) {
                    requestPermission(.screenRecording)
                }
                permission("Accessibility", detail: "Optional for auto-scroll and browser URLs.", granted: accessibility) {
                    requestPermission(.accessibility)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Label("CodeShot lives in your menu bar.", systemImage: "viewfinder")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu("Capture") {
                    ForEach(CaptureAction.captures, id: \.self) { action in
                        Button(action.title) { capture(action) }
                    }
                }.fixedSize()
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }
        .frame(width: 510, height: min(690, (NSScreen.main?.visibleFrame.height ?? 650) - 60))
        .onReceive(timer) { _ in
            screenAccess = CGPreflightScreenCaptureAccess()
            accessibility = AXIsProcessTrusted()
        }
        .onDisappear { shortcuts.stopListening() }
    }

    private func recorder(for action: CaptureAction) -> some View {
        let recording = shortcuts.recording == action
        return Button(recording ? "Press keys…   Esc to cancel" : shortcuts.bindings[action]?.description ?? "Set Shortcut") {
            shortcuts.listen(for: action)
        }
        .accessibilityLabel("Change " + action.title + " shortcut")
        .accessibilityValue(recording ? "Recording" : shortcuts.bindings[action]?.description ?? "Unassigned")
        .help("Click, then press a new shortcut.")
    }

    private func permission(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary) }
            else { Button("Enable…", action: action).accessibilityLabel("Enable " + title) }
        } label: {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private extension String {
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}

struct EditorView: View {
    private var capture: SavedCapture { draft.capture }
    let pathCopied: Bool
    private let thumbnail: NSImage?
    let copy: () -> Void
    let close: () -> Void
    @ObservedObject var draft: CaptureNote
    @FocusState private var focused: Bool
    @State private var showingDetails = false

    init(draft: CaptureNote, pathCopied: Bool, copy: @escaping () -> Void, close: @escaping () -> Void) {
        self.pathCopied = pathCopied
        self.draft = draft
        self.copy = copy
        self.close = close
        self.thumbnail = Self.thumbnail(for: draft.capture.file)
    }

    private static func thumbnail(for file: URL) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 256]
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static let initialSize = CGSize(width: 470, height: 265)

    private var title: String {
        [capture.context.window, capture.context.app].compactMap { $0 }.first { !$0.isEmpty }
            ?? capture.file.lastPathComponent
    }

    private var source: String {
        let app = capture.context.app == title ? nil : capture.context.app
        return [app, capture.context.displayURL].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            header
            VStack(alignment: .leading, spacing: 7) {
                Text("What do you want to change?").font(.body.weight(.medium))
                TextEditor(text: $draft.text)
                    .font(.system(size: 14))
                    .focused($focused)
                    .accessibilityLabel("Capture note")
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor),
                                          lineWidth: focused ? 2 : 1)
                            .allowsHitTesting(false)
                    }
                    .frame(minHeight: 87)
            }
            HStack {
                Button { showingDetails.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showingDetails ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Capture details").font(.callout)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Capture details")
                .accessibilityValue(showingDetails ? "Expanded" : "Collapsed")
                .popover(isPresented: $showingDetails, arrowEdge: .bottom) { details }
                Spacer()
                Button(action: copy) {
                    HStack(spacing: 9) {
                        Text("Copy Prompt").fontWeight(.medium)
                        Text("⌘↩").opacity(0.78)
                    }
                    .padding(.horizontal, 3)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Copy Prompt")
                .help("Copy the note and screenshot details (⌘↩)")
            }
        }
        .padding(18)
        .frame(minWidth: 400, idealWidth: Self.initialSize.width, minHeight: 255, idealHeight: Self.initialSize.height)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand {
            if showingDetails { showingDetails = false } else { close() }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 60)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.separator) }
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.system(size: 17, weight: .semibold))
                    .lineLimit(1).help(title)
                if !source.isEmpty {
                    Text(verbatim: source).font(.body).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(capture.context.url ?? source)
                }
                HStack(spacing: 5) {
                    Text(verbatim: "\(capture.width) × \(capture.height) px")
                    Text("·")
                    if pathCopied {
                        Label("Path copied", systemImage: "checkmark")
                    } else {
                        Text("Saved")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .vertical) {
                detailFields
                ScrollView { detailFields }
            }
            Divider()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([capture.file])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
        .padding(16)
        .frame(width: 350)
        .frame(maxHeight: 320)
    }

    private var detailFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([("File", capture.file.path)] + capture.context.fields, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: value).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
