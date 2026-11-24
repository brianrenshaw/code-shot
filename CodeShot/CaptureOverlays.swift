import AppKit
import Carbon
import SwiftUI

@MainActor
private final class PaletteSelection: ObservableObject {
    let actions: [CaptureAction]
    let displayOrder: [CaptureAction]
    @Published var highlighted: CaptureAction

    init(_ actions: [CaptureAction]) {
        self.actions = actions
        displayOrder = actions.filter { !$0.opensNote } + actions.filter(\.opensNote)
        highlighted = displayOrder[0]
    }

    func move(_ offset: Int) {
        guard let index = displayOrder.firstIndex(of: highlighted) else { return }
        highlighted = displayOrder[(index + offset + displayOrder.count) % displayOrder.count]
    }
}

@MainActor
final class CapturePalette: NSPanel {
    private let selection: PaletteSelection
    private var choose: ((CaptureAction) -> Void)?
    override var canBecomeKey: Bool { true }

    init(actions: [CaptureAction], choose: @escaping (CaptureAction) -> Void) {
        self.selection = PaletteSelection(actions)
        self.choose = choose
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        title = "Capture Palette"
        setAccessibilityTitle(title)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let view = PaletteView(selection: selection, width: min(520, visible.width - 24),
                               maxHeight: visible.height - 24,
                               choose: { [weak self] in self?.select($0) },
                               dismiss: { [weak self] in self?.orderOut(nil) })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        contentView = host
        setContentSize(size)
        setFrameOrigin(CGPoint(x: (visible.midX - size.width / 2).rounded(),
                               y: (visible.midY - size.height / 2).rounded()))
    }

    private func select(_ action: CaptureAction) {
        let callback = choose
        choose = nil
        orderOut(nil)
        callback?(action)
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { super.sendEvent(event); return }
        switch Int(event.keyCode) {
        case kVK_Escape: orderOut(nil)
        case kVK_UpArrow: selection.move(-1)
        case kVK_DownArrow: selection.move(1)
        case kVK_Tab: selection.move(event.modifierFlags.contains(.shift) ? -1 : 1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !event.isARepeat { select(selection.highlighted) }
        default:
            if let text = event.characters(byApplyingModifiers: []), let number = Int(text),
               (1...selection.actions.count).contains(number) {
                if !event.isARepeat { select(selection.actions[number - 1]) }
            } else {
                super.sendEvent(event)
            }
        }
    }

    override func resignKey() {
        super.resignKey()
        if isVisible { orderOut(nil) }
    }
}

private struct PaletteView: View {
    @ObservedObject var selection: PaletteSelection
    @Environment(\.colorScheme) private var colorScheme
    let width: CGFloat
    let maxHeight: CGFloat
    let choose: (CaptureAction) -> Void
    let dismiss: () -> Void

    private let graphite = Color(red: 0.10, green: 0.13, blue: 0.15)
    private let coral = Color(red: 1, green: 0.51, blue: 0.35)
    private var selectionFill: Color { colorScheme == .dark ? Color(white: 0.90) : graphite }
    private var selectionText: Color { colorScheme == .dark ? graphite : .white }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 42, height: 42)
                    .accessibilityHidden(true)
                Text("Capture Palette")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button(action: dismiss) { Keycap("esc").foregroundStyle(.white) }
                    .buttonStyle(.plain).accessibilityLabel("Close palette")
            }
            .padding(.leading, 16).padding(.trailing, 20).padding(.vertical, 12)
            .background(graphite)

            ViewThatFits(in: .vertical) {
                sections.fixedSize(horizontal: false, vertical: true)
                ScrollViewReader { proxy in
                    ScrollView { sections }
                        .onChange(of: selection.highlighted) { _, action in proxy.scrollTo(action) }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Keycap("↑")
                Keycap("↓")
                Text("Navigate")
                Spacer()
                Keycap("↩")
                Text("Capture")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 9)
        }
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.23), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var sections: some View {
        VStack(spacing: 12) {
            section("Copy to Clipboard", withNote: false)
            section("With a Note", withNote: true)
        }
        .padding(12)
    }

    @ViewBuilder
    private func section(_ title: String, withNote: Bool) -> some View {
        let rows = selection.actions.enumerated().filter { $0.element.opensNote == withNote }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12).padding(.bottom, 3)
                ForEach(rows, id: \.element) { index, action in
                    let selected = action == selection.highlighted
                    Button { choose(action) } label: {
                        HStack(spacing: 13) {
                            Image(systemName: action.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 24)
                                .foregroundStyle(selected ? (colorScheme == .light ? coral : selectionText) : Color.secondary)
                            Text(action.menuTitle).font(.system(size: 16, weight: .medium))
                            Spacer()
                            Keycap(String(index + 1))
                        }
                        .foregroundStyle(selected ? selectionText : .primary)
                        .padding(.horizontal, 12).frame(height: 40)
                        .background(selected ? selectionFill : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(action)
                    .onHover { entered in if entered { selection.highlighted = action } }
                    .accessibilityLabel(action.title)
                    .accessibilityValue("Key " + String(index + 1))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

private struct Keycap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(verbatim: key)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5).frame(minWidth: 25, minHeight: 22)
            .background(.foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.foreground.opacity(0.22)) }
    }
}
