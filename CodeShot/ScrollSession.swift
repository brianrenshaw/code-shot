import AppKit
import Carbon
import SwiftUI

@MainActor
final class ScrollSession: ObservableObject {
    @Published var playing = false
    @Published var frozen = false
    @Published var finishing = false
    @Published var status = "Scroll down inside the selected area."
    @Published var height: Int
    private let source: CaptureSource
    private let frames: ScrollFrames
    private let target: CaptureWindow?
    private let region: CaptureRegion
    private let completion: (Result<CGImage, Error>?) -> Void
    private var panel: NSPanel?
    private var outline: NSPanel?
    private var finishKey: SessionHotKey?
    private var loop: Task<Void, Never>?
    private var quiet = 0
    private var expectedShift: Int?
    private var misses = 0
    private var ended = false

    init(source: CaptureSource, first: CGImage, target: CaptureWindow?, region: CaptureRegion,
         completion: @escaping (Result<CGImage, Error>?) -> Void) throws {
        self.source = source
        self.frames = try ScrollFrames(first: first)
        self.target = target
        self.region = region
        self.height = first.height
        self.completion = completion
    }

    func start() {
        let border = makePanel(region.rect)
        border.setAccessibilityElement(false)
        border.ignoresMouseEvents = true
        border.hasShadow = false
        let borderView = NSView()
        borderView.wantsLayer = true
        borderView.layer?.borderWidth = 1
        borderView.layer?.borderColor = NSColor.systemBlue.cgColor
        border.contentView = borderView
        border.orderFrontRegardless()
        outline = border

        let visible = NSScreen.screens.first { $0.frame == region.screenFrame }?.visibleFrame ?? region.screenFrame
        let w: CGFloat = min(430, visible.width)
        let h: CGFloat = 66
        let x = max(visible.minX, min(region.rect.midX - w / 2, visible.maxX - w))
        var y = region.rect.minY - h - 8
        if y < visible.minY {
            y = region.rect.maxY + h + 8 <= visible.maxY ? region.rect.maxY + 8 : visible.minY + 8
        }
        let controls = makePanel(CGRect(x: x, y: y, width: w, height: h))
        controls.title = "Scrolling Capture"
        controls.setAccessibilityTitle("Scrolling Capture")
        controls.isMovableByWindowBackground = true
        controls.contentView = NSHostingView(rootView: ScrollControls(session: self))
        controls.orderFrontRegardless()
        panel = controls
        finishKey = SessionHotKey(key: kVK_Return, modifiers: cmdKey) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        loop = Task { [weak self] in await self?.run() }
    }

    private func makePanel(_ rect: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    func toggleAutoScroll() {
        if playing {
            playing = false
            expectedShift = nil
            status = "Paused. You can still scroll down manually."
            return
        }
        guard AXIsProcessTrusted() else {
            status = "Enable Accessibility in CodeShot Settings to auto-scroll."
            return
        }
        guard target != nil else { status = "Scroll manually inside the selected area."; return }
        guard canScrollAtSelection() else { return }
        // WebKit and some AppKit panes use the hover target when routing precise wheel input.
        // A click on Play leaves the real pointer on our controls.
        let point = region.quartzCenter
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        quiet = 0
        misses = 0
        expectedShift = nil
        playing = true
        status = "Auto-scrolling…"
    }

    func finish() {
        guard !ended else { return }
        playing = false
        finishing = true
    }

    func cancel() { end(nil) }

    private func end(_ result: Result<CGImage, Error>?) {
        guard !ended else { return }
        ended = true
        loop?.cancel()
        loop = nil
        finishKey = nil
        panel?.orderOut(nil)
        panel = nil
        outline?.orderOut(nil)
        outline = nil
        completion(result)
    }

    private func run() async {
        while !ended {
            if !frozen {
                do {
                    let frame = try await source.frame()
                    guard !ended else { return }
                    let (update, pixels) = try await frames.add(frame, expectedShift: (playing || finishing) ? expectedShift : nil)
                    guard !ended else { return }
                    height = pixels
                    switch update {
                    case .added:
                        misses = 0
                        quiet = 0
                        status = playing ? "Auto-scrolling…" : "Scroll down to continue, or finish."
                    case .stationary:
                        misses = 0
                        if playing {
                            quiet += 1
                            if quiet >= 8 {
                                playing = false
                                status = "Reached the end. Press ⌘↩ to finish, or keep scrolling."
                            }
                        }
                    case .lostOverlap:
                        misses += 1
                        if !playing || misses >= 3 {
                            playing = false
                            status = "Lost overlap. Scroll back up slowly to reconnect."
                        }
                    case .limit:
                        frozen = true
                        playing = false
                        status = "Image limit reached. Press ⌘↩ to finish."
                    }
                } catch {
                    guard !ended else { return }
                    frozen = true
                    playing = false
                    status = "Capture interrupted. Finish to save the frames collected."
                }
            }
            if finishing {
                do { end(.success(try await frames.result())) }
                catch { end(.failure(error)) }
                return
            }
            if playing && misses == 0 { scrollDown() }
            try? await Task.sleep(for: .milliseconds(180))
        }
    }

    private func canScrollAtSelection() -> Bool {
        guard let target, CaptureWindow.visible().first(where: { $0.bounds.contains(region.quartzCenter) })?.id == target.id else {
            playing = false
            status = "The selected window moved. Scroll manually or start again."
            return false
        }
        if let panel, panel.frame.contains(CGPoint(x: region.rect.midX, y: region.rect.midY)) {
            playing = false
            status = "Move the controls outside the middle of your selection."
            return false
        }
        return true
    }

    private func scrollDown() {
        guard canScrollAtSelection(), let target else { return }
        let step = Int32(min(42, max(3, region.rect.height / 12)))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -step, wheel2: 0, wheel3: 0) else {
            playing = false
            status = "Couldn’t send scroll input. Scroll manually to continue."
            return
        }
        event.location = region.quartzCenter
        event.flags = []
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.id))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.id))
        expectedShift = Int((CGFloat(step) * CGFloat(source.config.height) / region.rect.height).rounded())
        event.post(tap: .cghidEventTap)
    }
}

private struct ScrollControls: View {
    @ObservedObject var session: ScrollSession
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Cancel") { session.cancel() }
                    Text("\(session.height) px").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { session.toggleAutoScroll() } label: {
                    Image(systemName: session.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 18)
                }
                .controlSize(.large)
                .disabled(session.frozen || session.finishing)
                .accessibilityLabel(session.playing ? "Pause Auto-Scroll" : "Auto-Scroll")
                .help(session.playing ? "Pause auto-scroll" : "Auto-scroll down the selection")
                Button { session.finish() } label: {
                    HStack(spacing: 5) {
                        Text("Finish")
                        Text("⌘↩").opacity(0.7)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.finishing)
                .accessibilityLabel("Finish")
                .help("Finish the capture (⌘↩)")
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
