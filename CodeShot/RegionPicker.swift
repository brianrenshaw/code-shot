import AppKit

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class RegionPicker {
    private var panels: [NSPanel] = []
    private var completion: ((CaptureRegion?) -> Void)?
    private var displayObserver: NSObjectProtocol?

    func begin(_ kind: CaptureKind, completion: @escaping (CaptureRegion?) -> Void) {
        self.completion = completion
        var pointerPanel: NSPanel?
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let canvas = SelectionCanvas(frame: CGRect(origin: .zero, size: screen.frame.size))
            canvas.kind = kind
            if kind == .window {
                canvas.windowAtPoint = { location in
                    let display = CGDisplayBounds(displayID)
                    let point = CGPoint(x: display.minX + location.x, y: display.minY + screen.frame.height - location.y)
                    guard let target = CaptureWindow.visible().first(where: { $0.bounds.contains(point) }) else { return nil }
                    let r = target.bounds
                    let local = CGRect(x: r.minX - display.minX, y: screen.frame.height - (r.maxY - display.minY),
                                       width: r.width, height: r.height)
                    return (target.id, local)
                }
                panel.acceptsMouseMovedEvents = true
            }
            canvas.finish = { [weak self] rect, id in
                let selection = rect.map {
                    CaptureRegion(displayID: displayID, screenFrame: screen.frame,
                                  rect: $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), windowID: id)
                }
                self?.finish(selection)
            }
            panel.contentView = canvas
            panel.setFrame(screen.frame, display: true)
            panel.makeFirstResponder(canvas)
            panel.orderFrontRegardless()
            panels.append(panel)
            if screen.frame.contains(NSEvent.mouseLocation) {
                pointerPanel = panel
                if kind == .window { canvas.highlightWindow(at: panel.mouseLocationOutsideOfEventStream) }
            }
        }
        guard !panels.isEmpty else { finish(nil); return }
        (pointerPanel ?? panels[0]).makeKey()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    func finish(_ result: CaptureRegion?) {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        let callback = completion
        completion = nil
        callback?(result)
    }
}

private final class SelectionCanvas: NSView {
    var kind = CaptureKind.area
    var finish: ((CGRect?, CGWindowID?) -> Void)?
    var windowAtPoint: ((CGPoint) -> (CGWindowID, CGRect)?)?
    private var hoveredID: CGWindowID?
    private var anchor: CGPoint?
    private var selection: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: kind == .window ? .pointingHand : .crosshair) }

    override func mouseDown(with event: NSEvent) {
        if kind == .window {
            highlightWindow(at: convert(event.locationInWindow, from: nil))
            return
        }
        anchor = convert(event.locationInWindow, from: nil)
        update(event)
    }
    func highlightWindow(at point: CGPoint) {
        let hit = windowAtPoint?(point)
        hoveredID = hit?.0
        selection = hit?.1
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        if kind == .window { highlightWindow(at: convert(event.locationInWindow, from: nil)) }
    }
    override func mouseDragged(with event: NSEvent) {
        if kind == .window { mouseMoved(with: event) } else { update(event) }
    }
    override func mouseUp(with event: NSEvent) {
        if kind == .window {
            highlightWindow(at: convert(event.locationInWindow, from: nil))
            if let hoveredID, let selection { finish?(selection, hoveredID) }
            return
        }
        update(event)
        if let selection, selection.width >= 8, selection.height >= 8 { finish?(selection, nil) }
        else { anchor = nil; selection = nil; needsDisplay = true }
    }
    override func rightMouseDown(with event: NSEvent) { finish?(nil, nil) }
    override func cancelOperation(_ sender: Any?) { finish?(nil, nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish?(nil, nil) } else { super.keyDown(with: event) }
    }

    private func update(_ event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        let x = min(max(point.x, bounds.minX), bounds.maxX)
        let y = min(max(point.y, bounds.minY), bounds.maxY)
        selection = CGRect(x: min(x, anchor.x), y: min(y, anchor.y),
                           width: abs(x - anchor.x), height: abs(y - anchor.y)).integral.intersection(bounds)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Clear the backing store too, so shrinking a selection paints the old outline away.
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        let shade = NSBezierPath(rect: bounds)
        if let selection { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.30).setFill()
        shade.fill()
        let label: String
        var center = CGPoint(x: bounds.midX, y: bounds.midY)
        if let selection {
            if kind == .window {
                // A fully transparent hole in a borderless panel passes clicks through to the app.
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16).setFill()
                selection.fill()
            }
            NSColor.white.setStroke()
            NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)).stroke()
            label = kind == .window ? "Click to capture this window   ·   Esc to cancel" : "\(Int(selection.width)) × \(Int(selection.height)) pt"
            center = CGPoint(x: selection.midX, y: selection.minY - 20)
        } else {
            switch kind {
            case .area: label = "Drag to capture an area   ·   Esc to cancel"
            case .scrolling: label = "Drag around the area you’ll scroll   ·   Esc to cancel"
            case .window: label = "Click a window to capture it   ·   Esc to cancel"
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                         .foregroundColor: NSColor.white]
        let string = NSAttributedString(string: label, attributes: attributes)
        let size = string.size()
        let box = CGRect(x: min(max(4, center.x - size.width / 2 - 12), bounds.width - size.width - 28),
                         y: min(max(4, center.y - 14), bounds.height - 32),
                         width: size.width + 24, height: 28)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        string.draw(at: CGPoint(x: box.minX + 12, y: box.midY - size.height / 2))
    }
}
