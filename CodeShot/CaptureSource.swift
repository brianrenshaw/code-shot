import AppKit
import ApplicationServices
import ScreenCaptureKit

struct CaptureSource {
    let filter: SCContentFilter
    let config: SCStreamConfiguration

    static func prepare(_ region: CaptureRegion) async throws -> CaptureSource {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if let id = region.windowID {
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError("The selected window closed. Choose another window.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.ignoreShadowsSingleWindow = true
            config.width = max(1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
            config.height = max(1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
            config.showsCursor = false
            config.colorSpaceName = CGColorSpace.sRGB
            return CaptureSource(filter: filter, config: config)
        }
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw CaptureError("The selected display was disconnected. Select an area again.")
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRect
        config.width = Int((region.rect.width * CGFloat(filter.pointPixelScale)).rounded())
        config.height = Int((region.rect.height * CGFloat(filter.pointPixelScale)).rounded())
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        return CaptureSource(filter: filter, config: config)
    }

    func frame() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

struct CaptureWindow {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let title: String?
    let owner: String?

    static func visible() -> [Self] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary), !bounds.isEmpty else { return nil }
            return Self(id: id, pid: pid, bounds: bounds, title: window[kCGWindowName as String] as? String,
                        owner: window[kCGWindowOwnerName as String] as? String)
        }
    }

    func context(includeContext: Bool, includeURL: Bool) -> CaptureContext {
        guard includeContext else { return CaptureContext() }
        let running = NSRunningApplication(processIdentifier: pid)
        var context = CaptureContext(app: running?.localizedName ?? owner, window: title)
        if includeURL, AXIsProcessTrusted(), Self.isBrowser(running?.bundleIdentifier) {
            context.url = BrowserURL.read(pid: pid, bounds: bounds, title: title)
        }
        return context
    }

    private static func isBrowser(_ identifier: String?) -> Bool {
        guard let id = identifier?.lowercased() else { return false }
        return ["com.apple.safari", "com.google.chrome", "org.chromium.chromium", "org.mozilla.firefox",
                "com.microsoft.edgemac", "com.brave.browser", "com.vivaldi.vivaldi", "company.thebrowser.browser",
                "com.operasoftware.opera", "org.mozilla.nightly", "app.zen-browser.zen", "com.duckduckgo.macos.browser",
                "com.kagi.kagimacOS".lowercased()].contains { id.hasPrefix($0) }
    }
}

private enum BrowserURL {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func read(pid: pid_t, bounds: CGRect, title: String?) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let candidates = windows.filter { window in
            guard let pos = attribute(window, kAXPositionAttribute), CFGetTypeID(pos) == AXValueGetTypeID(),
                  let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID()
            else { return false }
            var origin = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return false }
            return abs(origin.x - bounds.minX) < 3 && abs(origin.y - bounds.minY) < 3
                && abs(extent.width - bounds.width) < 3 && abs(extent.height - bounds.height) < 3
        }
        let window: AXUIElement?
        if candidates.count == 1 { window = candidates.first }
        else if let title {
            let available = candidates.isEmpty ? windows : candidates
            let titled = available.filter { attribute($0, kAXTitleAttribute) as? String == title }
            window = titled.count == 1 ? titled.first : nil
        } else { window = nil }
        guard let window else { return nil }
        if let url = webURL(attribute(window, kAXDocumentAttribute)) { return url }
        // Stay in browser chrome. Never traverse the page's form fields or read their values.
        var addressFieldURL: String?
        var queue = [window]
        var index = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        while index < queue.count, index < 220, ProcessInfo.processInfo.systemUptime < deadline {
            let item = queue[index]
            index += 1
            let role = attribute(item, kAXRoleAttribute) as? String
            if role == "AXWebArea" {
                if let url = webURL(attribute(item, kAXURLAttribute)) { return url }
                continue
            }
            if role == kAXTextFieldRole, addressFieldURL == nil,
               let identifier = attribute(item, kAXIdentifierAttribute) as? String,
               ["WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD", "urlbar-input"].contains(identifier),
               attribute(item, kAXFocusedAttribute) as? Bool != true {
                addressFieldURL = webURL(attribute(item, kAXValueAttribute))
            }
            if let children = attribute(item, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(max(0, 240 - queue.count)))
            }
        }
        return addressFieldURL
    }

    static func webURL(_ value: CFTypeRef?) -> String? {
        let text = (value as? URL)?.absoluteString ?? value as? String
        guard let text, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["https", "http", "file"].contains(scheme) else { return nil }
        return url.absoluteString
    }
}
