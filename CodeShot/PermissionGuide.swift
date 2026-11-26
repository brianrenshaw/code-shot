import AppKit
import SwiftUI

/// The one place CodeShot asks for a macOS permission.
///
/// macOS's own request prompt and a CodeShot alert used to appear together, one on top of the
/// other. Now only one surface shows at a time: the first request uses the system prompt alone,
/// and every other request opens the right System Settings pane with a small guide panel docked
/// beside it (never on top of it), which follows that window and closes itself once access is on.
enum Permission: String {
    case screenRecording = "ScreenCapture"
    case accessibility = "Accessibility"

    var granted: Bool {
        switch self {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        }
    }

    var title: String {
        switch self {
        case .screenRecording: "Turn on Screen Recording"
        case .accessibility: "Turn on Accessibility"
        }
    }

    /// Screen Recording only takes effect after macOS reopens the app; Accessibility applies right away.
    var needsRelaunch: Bool { self == .screenRecording }

    fileprivate var askedKey: String { "asked." + rawValue }
}

final class PermissionGuide: NSObject, ObservableObject {
    @Published private(set) var permission = Permission.screenRecording
    @Published private(set) var granted = false
    @Published private(set) var didReset = false

    private var panel: NSPanel?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private static let settingsBundle = "com.apple.systempreferences"
    private static let gap: CGFloat = 12

    /// Ask for `permission`, showing exactly one thing on screen.
    func request(_ permission: Permission) {
        guard !permission.granted else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: permission.askedKey) {
            // First time: macOS's prompt is the only thing on screen. Its own button opens
            // System Settings, and the guide joins that window when it comes forward.
            defaults.set(true, forKey: permission.askedKey)
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            switch permission {
            case .screenRecording: _ = CGRequestScreenCaptureAccess()
            case .accessibility:
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            }
            showWhenSettingsOpens(permission)
            // macOS skips its prompt when it thinks it already has an answer (for example, an
            // entry left by an older copy). The prompt takes focus when it appears, so if nothing
            // took focus, nothing is on screen: open Settings with the guide instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.activationObserver != nil, !permission.granted,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == front else { return }
                self.open(permission)
            }
        } else {
            open(permission)
        }
    }

    func close() {
        stopWaiting()
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    // MARK: Actions from the panel

    /// Clears an entry macOS keeps for an older copy of CodeShot with a different signature.
    /// That entry looks switched on in System Settings but doesn't apply to this copy.
    func reset() {
        guard let bundle = Bundle.main.bundleIdentifier else { return }
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", permission.rawValue, bundle]
        tccutil.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.didReset = true
                // Reload the pane so the removed entry disappears from the list.
                Self.openPane(self.permission)
            }
        }
        try? tccutil.run()
    }

    // MARK: Showing

    private func open(_ permission: Permission) {
        stopWaiting()
        Self.openPane(permission)
        show(permission)
    }

    private static func openPane(_ permission: Permission) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + permission.rawValue) {
            NSWorkspace.shared.open(url)
        }
    }

    private func showWhenSettingsOpens(_ permission: Permission) {
        stopWaiting()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self, app?.bundleIdentifier == Self.settingsBundle else { return }
            self.stopWaiting()
            if !permission.granted { self.show(permission) }
        }
        // If the prompt was dismissed instead, stop listening; the next request shows the guide.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.stopWaiting() }
    }

    private func stopWaiting() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func show(_ permission: Permission) {
        self.permission = permission
        granted = false
        didReset = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frame(for: panel.frame.size), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            panel.animator().alphaValue = 1
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        guard let panel, panel.isVisible else { close(); return }
        if permission.granted, !granted {
            granted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.granted else { return }
                self.close()
            }
        }
        let target = frame(for: panel.frame.size)
        if target.integral != panel.frame.integral { panel.setFrame(target, display: true, animate: true) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        let host = NSHostingController(rootView: PermissionGuideView(guide: self))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)
        return panel
    }

    // MARK: Docking beside System Settings

    /// To the right of the System Settings window, else its left, else tucked into its
    /// lower-right corner. With no Settings window on screen, the upper right of the main display.
    private func frame(for size: CGSize) -> CGRect {
        guard let settings = Self.settingsWindowFrame(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings) }) ?? NSScreen.main else {
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            return CGRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24,
                          width: size.width, height: size.height)
        }
        let visible = screen.visibleFrame
        var origin = CGPoint(x: settings.maxX + Self.gap, y: settings.maxY - size.height)
        if origin.x + size.width > visible.maxX {
            origin.x = settings.minX - Self.gap - size.width
            if origin.x < visible.minX {
                origin = CGPoint(x: settings.maxX - size.width - 20, y: settings.minY + 20)
            }
        }
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    /// Window bounds and owners are readable without Screen Recording access; titles are not,
    /// so this picks the largest normal window System Settings has on screen.
    private static func settingsWindowFrame() -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundle).first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let frames = windows.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 200 else { return nil }
            return rect
        }
        guard let quartz = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        // Quartz puts the origin at the top left of the primary display; AppKit at its bottom left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: quartz.minX, y: primaryHeight - quartz.maxY, width: quartz.width, height: quartz.height)
    }
}

extension PermissionGuide: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

struct PermissionGuideView: View {
    @ObservedObject var guide: PermissionGuide
    @State private var hoveringIcon = false

    private var permission: Permission { guide.permission }

    private var steps: [String] {
        var steps = [guide.didReset ? "Drag this icon into the list, then switch CodeShot on."
                                    : "Switch on CodeShot in the list."]
        if permission.needsRelaunch { steps.append("When macOS asks, choose Quit & Reopen.") }
        return steps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .scaleEffect(hoveringIcon ? 1.05 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.9), value: hoveringIcon)
                    .onHover { inside in
                        hoveringIcon = inside
                        if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                    }
                    .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                    .help("Drag CodeShot into the list in System Settings")
                    .accessibilityLabel("CodeShot app icon")
                    .accessibilityHint("Drag into the list in System Settings")
                VStack(alignment: .leading, spacing: 7) {
                    Text(permission.title).font(.system(size: 14, weight: .semibold))
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "\(index + 1).").monospacedDigit()
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if guide.granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.secondary)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if !guide.didReset {
                        Text("Not in the list? Drag this icon into it.")
                    }
                    HStack(spacing: 4) {
                        Text("Already on but not working?")
                        Button("Reset Permission", action: guide.reset)
                            .buttonStyle(.link)
                            .help("Removes an entry left by an older copy of CodeShot.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 26)
        .padding(.bottom, 16)
        .frame(width: 340)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: guide.granted)
    }
}
