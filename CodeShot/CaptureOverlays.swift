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
        let view = NSHostingView(rootView: PaletteView(selection: selection, choose: { [weak self] in self?.select($0) },
                                                       dismiss: { [weak self] in self?.orderOut(nil) }))
        let size = view.fittingSize
        contentView = view
        setContentSize(size)
        if let visible = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.visibleFrame {
            setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
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
    let choose: (CaptureAction) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor).frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Text("Capture Palette").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: dismiss) { Keycap("esc") }
                    .buttonStyle(.plain).accessibilityLabel("Close palette")
            }.padding(.horizontal, 16).padding(.vertical, 13)
            Divider()
            VStack(spacing: 8) {
                section("Copy to Clipboard", withNote: false)
                section("With a Note", withNote: true)
            }.padding(8)
            Divider()
            HStack(spacing: 5) {
                Keycap("↑"); Keycap("↓")
                Text("Navigate")
                Spacer()
                Keycap("↩")
                Text("Capture")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(width: 350)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator).allowsHitTesting(false) }
    }

    @ViewBuilder
    private func section(_ title: String, withNote: Bool) -> some View {
        let rows = selection.actions.enumerated().filter { $0.element.opensNote == withNote }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 10).padding(.top, 4).padding(.bottom, 2)
                ForEach(rows, id: \.element) { index, action in
                    let selected = action == selection.highlighted
                    Button { choose(action) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: action.symbol).frame(width: 20)
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                            Text(action.menuTitle).font(.system(size: 13, weight: selected ? .semibold : .regular))
                            Spacer()
                            Keycap(String(index + 1))
                        }
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
        Text(verbatim: key).font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary).padding(.horizontal, 4).frame(minWidth: 20, minHeight: 18)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5) }
    }
}
