import AppKit
import Combine
import ComputerCore
import NoodleWallpaper
import SwiftUI

extension ComputerAppearance {
    /// The icon fields, in the form the suite's shared icon views take.
    var icon: IconAppearance {
        get { IconAppearance(symbol: iconSymbol, colour: iconColour, image: iconImage).clampingColour() }
        set { iconSymbol = newValue.iconSymbol; iconColour = newValue.iconColour; iconImage = newValue.iconImage }
    }
}

struct ComputerIcon: View {
    let appearance: ComputerAppearance
    let symbol: String
    let size: CGFloat
    var body: some View { IconBadge(appearance: appearance.icon, symbol: symbol, size: size) }
}

struct ComputerIconButton: View {
    @Binding var appearance: ComputerAppearance
    let symbol: String
    @State private var editing = false
    var body: some View {
        Button { editing = true } label: {
            ZStack(alignment: .bottomTrailing) {
                ComputerIcon(appearance: appearance, symbol: symbol, size: 64)
                Image(systemName: "pencil.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor).font(.system(size: 21))
                    .background(.background, in: Circle())
            }
        }.buttonStyle(.plain).help("Change Computer Icon").accessibilityLabel("Change Computer Icon")
            .sheet(isPresented: $editing) { ComputerIconSheet(appearance: $appearance, symbol: symbol) }
    }
}

struct ComputerIconSheet: View {
    @Binding var appearance: ComputerAppearance
    let symbol: String
    private let symbols = ["desktopcomputer", "terminal", "shippingbox", "server.rack", "laptopcomputer", "globe",
        "sparkles", "bolt.fill", "brain.head.profile", "hammer.fill", "paintbrush.fill", "gearshape.2.fill"]
    var body: some View {
        IconEditorSheet(title: "Computer Icon", icon: $appearance.icon,
            symbol: symbol, symbols: symbols, encoding: .png(maxBytes: 2 * 1024 * 1024))
            .noodleSheetSizing()
    }
}

struct ComputerWallpaper: View {
    let appearance: ComputerAppearance
    var directory: URL?
    var body: some View {
        ConversationBackgroundView(background: appearance.background,
            imageURL: appearance.backgroundURL(in: directory),
            previewImage: appearance.backgroundImage.flatMap { NSImage(data: $0) })
    }
}

struct ComputerWindowWallpaper: View {
    @ObservedObject var store: ComputerStore
    private struct Selection: Equatable {
        var appearance = ComputerAppearance()
        var directory: URL?
    }
    @State private var selection = Selection()
    var body: some View {
        ConversationWallpaper(background: selection.appearance.background,
            imageURL: selection.appearance.backgroundURL(in: selection.directory),
            imageData: selection.appearance.backgroundImage)
            .overlay(alignment: .top) {
                ConversationWindowHeaderShade()
            }
            .onReceive(appearancePublisher) { if selection != $0 { selection = $0 } }
    }

    private var appearancePublisher: AnyPublisher<Selection, Never> {
        if let session = store.selected {
            let directory = store.library.directory(for: session.id)
            return session.$computer.map { Selection(appearance: $0.appearance ?? .init(), directory: directory) }.eraseToAnyPublisher()
        }
        return Just(Selection()).eraseToAnyPublisher()
    }
}

struct ComputerAppearanceRow: View {
    @Binding var appearance: ComputerAppearance
    var directory: URL?
    @State private var editing = false
    var body: some View {
        Button { editing = true } label: {
            HStack {
                Label("Background & Terminal", systemImage: "photo")
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .sheet(isPresented: $editing) { ComputerAppearanceSheet(appearance: $appearance, directory: directory) }
    }
}

struct ComputerAppearanceSheet: View {
    @Binding var appearance: ComputerAppearance
    let directory: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ComputerAppearance
    @State private var failure: String?
    @State private var busy = false
    init(appearance: Binding<ComputerAppearance>, directory: URL? = nil) {
        self.directory = directory
        _appearance = appearance; _draft = State(initialValue: appearance.wrappedValue)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.blue).disabled(busy)
                Spacer(); Text("Background & Terminal").font(.headline).foregroundStyle(.primary); Spacer()
                Button("Apply") { appearance = draft; dismiss() }.keyboardShortcut(.defaultAction).foregroundStyle(.blue)
                    .disabled(busy || draft == appearance)
            }.buttonStyle(.plain)
            ComputerWallpaper(appearance: draft, directory: directory).overlay {
                Text("/workspace # Hello, world!").font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color(computerColour(draft.terminalForeground)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(14)
                    .background(Color(computerColour(draft.terminalBackground)).opacity(draft.terminalOpacity))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(16)
            }.frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 16))
            .backgroundDropTarget(isBusy: $busy, failure: $failure) { selection.wrappedValue = .imported($0); failure = nil }
            BackgroundPicker(selection: selection, busy: $busy, failure: $failure)
            GroupBox("Terminal") {
                VStack(alignment: .leading, spacing: 12) {
                    colourRow("Text colour", key: \.terminalForeground)
                    Divider()
                    colourRow("Background colour", key: \.terminalBackground)
                    Divider()
                    HStack {
                        Text("Background opacity")
                        Slider(value: $draft.terminalOpacity, in: 0...1)
                            .accessibilityLabel("Background opacity")
                        Text(draft.terminalOpacity, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 42)
                    }
                    Text("At 0%, the wallpaper shows through; text stays opaque.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            if busy { ProgressView().controlSize(.small) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 520).controlSize(.regular).noodleSheetSizing()
            .interactiveDismissDisabled(busy)
    }
    /// The picker's selection, stored in the draft.
    private var selection: Binding<BackgroundSelection> {
        Binding(get: { BackgroundSelection(background: draft.background, file: draft.backgroundFile) },
                set: { draft.chooseBackground(preset: $0.background.preset, file: $0.file) })
    }
    private func colourRow(_ title: String, key: WritableKeyPath<ComputerAppearance, String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            ColorPicker(title, selection: colourBinding(key), supportsOpacity: false)
                .labelsHidden().frame(width: 44)
        }
    }
    private func colourBinding(_ key: WritableKeyPath<ComputerAppearance, String>) -> Binding<Color> {
        Binding(get: { Color(computerColour(draft[keyPath: key])) }, set: { colour in
            guard let rgb = NSColor(colour).usingColorSpace(.sRGB) else { return }
            draft[keyPath: key] = String(format: "%02X%02X%02X", Int(round(rgb.redComponent * 255)),
                Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
        })
    }
}

func computerColour(_ hex: String) -> NSColor {
    let value = UInt32(hex, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
}

typealias ComputerWindowCompositing = ConversationWindowCompositing
