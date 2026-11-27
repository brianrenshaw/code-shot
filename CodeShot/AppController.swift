import AppKit
import Sparkle
import SwiftUI

@main
enum CodeShotMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private let preferences = Preferences()
    private let shortcuts = Shortcuts()
    private let picker = RegionPicker()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let notes = CaptureNotes()
    private let permissions = PermissionGuide()
    private var palette: CapturePalette?
    private var noteWindow: NoteWindow?
    private var scrolling: ScrollSession?
    private var busy = false
    private lazy var updates = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
    private var availableUpdate: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "CodeShot")
        statusItem.button?.toolTip = "CodeShot"
        let menu = NSMenu(title: "CodeShot")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updates.startUpdater()
        shortcuts.perform = { [weak self] actions in self?.dispatch(actions) }
        shortcuts.start()
        menuNeedsUpdate(menu)
        makeApplicationMenu()
        if !UserDefaults.standard.bool(forKey: "openedBefore") || shortcuts.message != nil {
            UserDefaults.standard.set(true, forKey: "openedBefore")
            openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !busy { openSettings() }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let scrolling {
            item("Finish Scrolling Capture", #selector(finishScroll), menu)
            item("Cancel Capture", #selector(cancelScroll), menu)
            item(scrolling.playing ? "Pause Auto-Scroll" : "Play Auto-Scroll", #selector(toggleScroll), menu)
                .isEnabled = !scrolling.frozen && !scrolling.finishing
        } else {
            addCaptureCommand(.palette, to: menu)
            menu.addItem(.separator())
            for action in CaptureAction.captures {
                addCaptureCommand(action, to: menu)
            }
        }
        if !notes.drafts.isEmpty && !busy {
            let submenu = NSMenu(title: "Resume Draft")
            for draft in notes.drafts.reversed() {
                let entry = item(draft.capture.file.lastPathComponent, #selector(resumeDraft(_:)), submenu)
                entry.representedObject = draft
                entry.toolTip = draft.text
            }
            let drafts = NSMenuItem(title: "Resume Draft", action: nil, keyEquivalent: "")
            drafts.submenu = submenu
            menu.addItem(drafts)
        }
        guard menu === statusItem?.menu else { return }
        menu.addItem(.separator())
        item("Settings…", #selector(openSettings), menu, key: ",").isEnabled = !busy
        addUpdateCommand(to: menu)
        item("Quit CodeShot", #selector(quit), menu, key: "q")
    }

    private func addUpdateCommand(to menu: NSMenu) {
        let title = availableUpdate.map { "Update to CodeShot " + $0 + "…" } ?? "Check for Updates…"
        let command = menu.addItem(withTitle: title, action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        command.target = updates
        command.isEnabled = updates.updater.canCheckForUpdates
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false // Offer background updates from the status menu without interrupting a capture.
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        availableUpdate = update.displayVersionString
        statusItem.button?.toolTip = "CodeShot " + update.displayVersionString + " is available"
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableUpdate = nil
        statusItem.button?.toolTip = "CodeShot"
    }

    private func addCaptureCommand(_ action: CaptureAction, to menu: NSMenu) {
        let command = item(action.menuTitle, #selector(captureCommand(_:)), menu)
        command.representedObject = action
        command.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        command.isEnabled = !busy
        command.setAccessibilityLabel(action.title)
        if let shortcut = shortcuts.bindings[action] {
            let opensFullPalette = CaptureAction.choices(for: shortcut, in: shortcuts.bindings) == CaptureAction.captures
            if (action == .palette) == opensFullPalette {
                command.badge = NSMenuItemBadge(string: shortcut.description)
            }
        }
    }

    @discardableResult
    private func item(_ title: String, _ action: Selector, _ menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func makeApplicationMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        item("Settings…", #selector(openSettings), appMenu, key: ",")
        addUpdateCommand(to: appMenu)
        item("Quit CodeShot", #selector(quit), appMenu, key: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let captureMenu = NSMenu(title: "Capture")
        captureMenu.delegate = self
        captureMenu.autoenablesItems = false
        menuNeedsUpdate(captureMenu)
        let captureItem = NSMenuItem()
        captureItem.submenu = captureMenu
        main.addItem(captureItem)
        let edit = NSMenu(title: "Edit")
        for (name, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                      ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func captureCommand(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? CaptureAction else { return }
        dispatch(action == .palette ? CaptureAction.captures : [action])
    }
    @objc private func finishScroll() { scrolling?.finish() }
    @objc private func cancelScroll() { scrolling?.cancel() }
    @objc private func toggleScroll() { scrolling?.toggleAutoScroll() }

    @objc private func openSettings() {
        guard !busy else { return }
        if settingsWindow == nil {
            let view = SettingsView(prefs: preferences, shortcuts: shortcuts, updater: updates.updater,
                                    requestPermission: { [weak self] in self?.permissions.request($0) }) { [weak self] action in
                guard let self else { return }
                if action == .palette { self.dispatch(CaptureAction.captures) }
                else { self.trigger(action) }
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable]
            window.title = "CodeShot Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func dispatch(_ actions: [CaptureAction]) {
        if let scrolling, actions.contains(where: { $0.kind == .scrolling }) { scrolling.finish(); return }
        guard !busy, !actions.isEmpty else { return }
        palette?.orderOut(nil)
        let returnApp = NSWorkspace.shared.frontmostApplication
        if actions.count == 1 { trigger(actions[0], returnApp: returnApp); return }
        let chooser = CapturePalette(actions: actions) { [weak self] action in
            self?.trigger(action, returnApp: returnApp)
        }
        palette = chooser
        chooser.makeKeyAndOrderFront(nil)
    }

    private func trigger(_ action: CaptureAction, returnApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        guard !busy, let kind = action.kind else { return }
        shortcuts.stopListening()
        guard Permission.screenRecording.granted else {
            permissions.request(.screenRecording)
            return
        }
        busy = true
        // Hide our note/settings windows so the selection matches the image saved by the filter.
        settingsWindow?.orderOut(nil)
        noteWindow?.orderOut(nil)
        picker.begin(kind) { [weak self] region in
            guard let self else { return }
            guard let region else { self.completeCapture(); return }
            Task { await self.capture(region, action: action, returnApp: returnApp) }
        }
    }

    private func capture(_ region: CaptureRegion, action: CaptureAction, returnApp: NSRunningApplication?) async {
        let includeContext = preferences.includeContext, includeURL = preferences.includeURL
        do {
            let target = CaptureWindow.visible().first { window in
                if let id = region.windowID { return window.id == id }
                return window.bounds.contains(region.quartzCenter)
            }
            let context = target?.context(includeContext: includeContext, includeURL: includeURL) ?? CaptureContext()
            let source = try await CaptureSource.prepare(region)
            let first = try await source.frame()
            if action.kind == .scrolling {
                let session = try ScrollSession(source: source, first: first, target: target, region: region) { [weak self] result in
                    guard let self else { return }
                    self.scrolling = nil
                    switch result {
                    case .success(let image):
                        Task { await self.save(image, context: context, action: action, returnApp: returnApp) }
                    case .failure(let error):
                        self.completeCapture()
                        self.report("Couldn’t finish the scrolling capture", error)
                    case nil: self.completeCapture()
                    }
                }
                self.scrolling = session
                session.start()
            } else {
                await save(first, context: context, action: action, returnApp: returnApp)
            }
        } catch {
            completeCapture()
            report("Couldn’t capture this area", error)
        }
    }

    private func save(_ image: CGImage, context: CaptureContext, action: CaptureAction, returnApp: NSRunningApplication?) async {
        while true {
            let folder = preferences.folder
            do {
                let file = try await Task.detached(priority: .userInitiated) { try CaptureFiles.save(image, in: folder) }.value
                let capture = SavedCapture(file: file, width: image.width, height: image.height, context: context)
                if action.opensNote {
                    let pathCopied = copyText(file.path)
                    busy = false
                    openEditor(CaptureNote(capture, returnApp: returnApp), pathCopied: pathCopied)
                } else {
                    notes.setAside()
                    noteWindow?.close()
                    let prompt = capture.prompt(note: "")
                    while !copyText(prompt) {
                        let alert = NSAlert()
                        alert.messageText = "Couldn’t copy the capture"
                        alert.informativeText = "Your screenshot was saved at " + file.path
                        alert.addButton(withTitle: "Try Copy Again")
                        alert.addButton(withTitle: "Done")
                        NSApp.activate(ignoringOtherApps: true)
                        if alert.runModal() != .alertFirstButtonReturn { break }
                    }
                    busy = false
                }
                return
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t save the screenshot"
                alert.informativeText = "\(folder.path)\n\n\(error.localizedDescription)"
                alert.addButton(withTitle: "Choose Another Folder…")
                alert.addButton(withTitle: "Discard")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { completeCapture(); return }
                preferences.chooseFolder()
            }
        }
    }

    private func copyText(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }

    private func completeCapture() {
        busy = false
        noteWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func resumeDraft(_ sender: NSMenuItem) {
        guard !busy, let draft = sender.representedObject as? CaptureNote else { return }
        openEditor(draft, pathCopied: false)
    }

    private func openEditor(_ note: CaptureNote, pathCopied: Bool) {
        notes.show(note)
        let window = noteWindow ?? NoteWindow(contentRect: NSRect(origin: .zero, size: EditorView.initialSize),
                                              styleMask: [.titled, .closable, .resizable],
                                              backing: .buffered, defer: false)
        if noteWindow == nil {
            window.title = "Capture Note"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.level = .floating
            window.delegate = self
            window.center()
            noteWindow = window
        }

        let copy = { [weak self, weak window] in
            guard let self, let window, window.isVisible, !self.busy else { return }
            do {
                guard try self.notes.copy(note, to: .general) else { return }
                window.close()
                if note.returnApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    note.returnApp?.activate(options: [])
                }
            } catch { self.report("Couldn’t copy the prompt", error) }
        }
        window.submit = copy
        let view = EditorView(draft: note, pathCopied: pathCopied, copy: copy) { [weak self, weak window] in
            if self?.notes.current === note { window?.close() }
        }
        window.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow { shortcuts.stopListening() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow { shortcuts.stopListening(); settingsWindow = nil }
        if window === noteWindow {
            if let current = notes.current { notes.dismiss(current) }
            noteWindow?.submit = nil
            noteWindow = nil
        }
    }

    private func report(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
