import AppKit
import ComputerCore
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Same palette and circular icon treatment as Noodle's BotAvatar.
private let computerIconColours: [[Color]] = [
    [.blue, .cyan], [.purple, .pink], [.orange, .yellow],
    [.mint, .teal], [.indigo, .blue], [.pink, .orange]
]

struct ComputerIcon: View {
    let appearance: ComputerAppearance
    let symbol: String
    let size: CGFloat
    var body: some View {
        ZStack {
            if let data = appearance.iconImage, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(LinearGradient(colors: computerIconColours[max(0, min(5, appearance.iconColour))],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: appearance.iconSymbol ?? symbol)
                    .font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
            }
        }.frame(width: size, height: size).clipShape(Circle())
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1).accessibilityHidden(true)
    }
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
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ComputerAppearance
    @State private var failure: String?
    @State private var choosingFile = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    private let symbols = ["desktopcomputer", "terminal", "shippingbox", "server.rack", "laptopcomputer", "globe",
        "sparkles", "bolt.fill", "brain.head.profile", "hammer.fill", "paintbrush.fill", "gearshape.2.fill"]
    init(appearance: Binding<ComputerAppearance>, symbol: String) {
        _appearance = appearance; self.symbol = symbol
        _draft = State(initialValue: appearance.wrappedValue)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.blue)
                Spacer(); Text("Computer Icon").font(.headline).foregroundStyle(.primary); Spacer()
                Button("Done") { appearance = draft; dismiss() }.foregroundStyle(.blue)
                    .disabled(isLoadingPhoto)
            }.buttonStyle(.plain).padding(16)
            Divider()
            VStack(spacing: 18) {
                ComputerIcon(appearance: draft, symbol: symbol, size: 104)
                    .padding(.top, 4)
                GroupBox("Image") {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            ImageSourceMenu(
                                title: "Choose Image…",
                                chooseFile: { choosingFile = true },
                                choosePhoto: {
                                    photoSelection = nil; choosingPhoto = true
                                }
                            ).frame(minWidth: 0, maxWidth: .infinity)
                            NoodleImagePlaygroundButton(sourceImageData: draft.iconImage) { url in loadImage(url) }
                                .frame(minWidth: 0, maxWidth: .infinity)
                        }
                        Divider()
                        Button {
                            draft.iconImage = nil; photoSelection = nil
                        } label: {
                            Label(draft.iconImage == nil ? "Using Symbol" : "Use Symbol Instead",
                                  systemImage: draft.iconImage == nil ? "checkmark" : "square.grid.2x2")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).disabled(draft.iconImage == nil)
                        if isLoadingPhoto { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                    }.padding(8)
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                GroupBox("Colour") {
                    HStack(spacing: 12) {
                        ForEach(computerIconColours.indices, id: \.self) { index in
                            Button { draft.iconColour = index; draft.iconImage = nil } label: {
                                Circle().fill(LinearGradient(colors: computerIconColours[index], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 34, height: 34).overlay {
                                        if draft.iconImage == nil && draft.iconColour == index {
                                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                        }
                                    }
                            }.buttonStyle(.plain).accessibilityLabel("Colour \(index + 1)")
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                GroupBox("Symbol") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(symbols, id: \.self) { candidate in
                            let selected = draft.iconImage == nil && (draft.iconSymbol ?? symbol) == candidate
                            Button { draft.iconSymbol = candidate; draft.iconImage = nil } label: {
                                Image(systemName: candidate).font(.system(size: 18, weight: .semibold))
                                    .frame(maxWidth: .infinity).frame(height: 42)
                                    .background(selected ? Color.accentColor : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                                    .foregroundStyle(selected ? Color.white : .primary)
                            }.buttonStyle(.plain).accessibilityLabel(candidate)
                        }
                    }.padding(8)
                }
            }.padding(20)
        }.frame(width: 440).controlSize(.regular).noodleSheetSizing()
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url): loadImage(url)
                case .failure(let error): failure = error.localizedDescription
                }
            }
            .photosPicker(isPresented: $choosingPhoto, selection: $photoSelection, matching: .images, preferredItemEncoding: .current)
            .task(id: photoSelection) {
                guard let photoSelection else { return }
                isLoadingPhoto = true; failure = nil
                defer { isLoadingPhoto = false }
                do {
                    guard let photo = try await photoSelection.loadTransferable(type: ComputerBackgroundPhoto.self) else {
                        throw ComputerError("Photos could not provide this image. Try Choose File instead.")
                    }
                    guard !Task.isCancelled else { return }
                    draft.iconImage = try ComputerImageImport.prepare(photo.data, maxDimension: 512)
                } catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
    }
    private func loadImage(_ url: URL) {
        do { draft.iconImage = try ComputerImageImport.load(url, maxDimension: 512); failure = nil }
        catch { failure = error.localizedDescription }
    }
}

struct ComputerWallpaper: View {
    let appearance: ComputerAppearance
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if let data = appearance.backgroundImage, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if let preset = appearance.backgroundPreset {
                    LinearGradient(colors: colours(preset), startPoint: .topLeading, endPoint: .bottomTrailing)
                    Ellipse().fill(colours(preset)[1].opacity(0.5))
                        .frame(width: geometry.size.width * 1.4, height: geometry.size.height * 1.1)
                        .rotationEffect(.degrees(-35)).offset(x: geometry.size.width * 0.35).blur(radius: 50)
                }
                if appearance.backgroundImage != nil || appearance.backgroundPreset != nil { Color.black.opacity(0.25) }
            }.clipped()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func colours(_ preset: String) -> [Color] {
        switch preset {
        case "sunset": [Color(red: 0.96, green: 0.52, blue: 0.15), Color(red: 0.77, green: 0.43, blue: 0.67), Color(red: 0.46, green: 0.35, blue: 0.75)]
        case "ocean": [Color(red: 0.04, green: 0.26, blue: 0.50), Color(red: 0.08, green: 0.60, blue: 0.66), Color(red: 0.14, green: 0.30, blue: 0.62)]
        case "forest": [Color(red: 0.08, green: 0.24, blue: 0.18), Color(red: 0.34, green: 0.53, blue: 0.30), Color(red: 0.14, green: 0.34, blue: 0.39)]
        default: [Color(red: 0.18, green: 0.16, blue: 0.39), Color(red: 0.47, green: 0.29, blue: 0.60), Color(red: 0.73, green: 0.37, blue: 0.47)]
        }
    }
}

struct ComputerWindowWallpaper: View {
    @ObservedObject var session: ComputerSession
    var body: some View { ComputerWallpaper(appearance: session.computer.appearance ?? .init()) }
}

struct ComputerAppearanceRow: View {
    @Binding var appearance: ComputerAppearance
    @State private var editing = false
    var body: some View {
        Button { editing = true } label: {
            HStack {
                Label("Background & Terminal", systemImage: "photo")
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .sheet(isPresented: $editing) { ComputerAppearanceSheet(appearance: $appearance) }
    }
}

struct ComputerAppearanceSheet: View {
    @Binding var appearance: ComputerAppearance
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ComputerAppearance
    @State private var failure: String?
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    init(appearance: Binding<ComputerAppearance>) {
        _appearance = appearance; _draft = State(initialValue: appearance.wrappedValue)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.blue)
                Spacer(); Text("Background & Terminal").font(.headline).foregroundStyle(.primary); Spacer()
                Button("Apply") { appearance = draft; dismiss() }.keyboardShortcut(.defaultAction).foregroundStyle(.blue)
            }.buttonStyle(.plain)
            ComputerWallpaper(appearance: draft).overlay {
                Text("/workspace # Hello, world!").font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color(computerColour(draft.terminalForeground)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(14)
                    .background(Color(computerColour(draft.terminalBackground)).opacity(draft.terminalOpacity))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(16)
            }.frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 12) {
                choice(nil)
                ForEach(["sunset", "ocean", "forest", "dusk"], id: \.self) { choice($0) }
            }
            HStack(spacing: 8) {
                ImageSourceMenu(
                    title: "Choose Background…",
                    chooseFile: {
                        do {
                            if let data = try ComputerImageImport.choose(maxDimension: 2560) { useBackground(data) }
                        } catch { failure = error.localizedDescription }
                    },
                    choosePhoto: {
                        photoSelection = nil; choosingPhoto = true
                    }
                ).frame(minWidth: 0, maxWidth: .infinity)
                NoodleImagePlaygroundButton(sourceImageData: draft.backgroundImage) { url in
                    do { useBackground(try ComputerImageImport.load(url, maxDimension: 2560)) }
                    catch { failure = error.localizedDescription }
                }.frame(minWidth: 0, maxWidth: .infinity)
            }
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
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }.padding(24).frame(width: 520).controlSize(.regular).noodleSheetSizing()
            .photosPicker(isPresented: $choosingPhoto, selection: $photoSelection, matching: .images, preferredItemEncoding: .current)
            .task(id: photoSelection) {
                guard let photoSelection else { return }
                do {
                    guard let photo = try await photoSelection.loadTransferable(type: ComputerBackgroundPhoto.self) else {
                        throw ComputerError("Photos could not provide this image. Try Choose File instead.")
                    }
                    guard !Task.isCancelled else { return }
                    useBackground(try ComputerImageImport.prepare(photo.data, maxDimension: 2560))
                } catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
    }
    private func useBackground(_ data: Data) {
        draft.backgroundImage = data; draft.backgroundPreset = nil; failure = nil
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
    private func choice(_ preset: String?) -> some View {
        var sample = ComputerAppearance()
        sample.backgroundPreset = preset
        return Button { draft.backgroundPreset = preset; draft.backgroundImage = nil } label: {
            VStack(spacing: 6) {
                ComputerWallpaper(appearance: sample).frame(maxWidth: .infinity).frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                        draft.backgroundImage == nil && draft.backgroundPreset == preset ? Color.accentColor : .clear, lineWidth: 2))
                Text(preset?.capitalized ?? "Default").font(.caption)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).frame(minWidth: 0, maxWidth: .infinity)
    }
}

func computerColour(_ hex: String) -> NSColor {
    let value = UInt32(hex, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
}

@MainActor private enum ComputerImageImport {
    static func choose(maxDimension: Int) throws -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try load(url, maxDimension: maxDimension)
    }
    static func load(_ url: URL, maxDimension: Int) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50 * 1024 * 1024 else { throw ComputerError("Choose an image smaller than 50 MB.") }
        return try prepare(Data(contentsOf: url), maxDimension: maxDimension)
    }
    static func prepare(_ data: Data, maxDimension: Int) throws -> Data {
        guard data.count <= 50 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw ComputerError("Choose an image smaller than 50 MB.") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]),
              data.count <= (maxDimension <= 512 ? 2 : 8) * 1024 * 1024 else {
            throw ComputerError("The image is too large. Choose a smaller image.")
        }
        return data
    }
}

private struct ComputerBackgroundPhoto: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard data.count <= 50 * 1024 * 1024 else { throw ComputerError("Choose an image smaller than 50 MB.") }
            return ComputerBackgroundPhoto(data: data)
        }
        FileRepresentation(importedContentType: .image) { received in
            let url = received.file
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 50 * 1024 * 1024 else {
                throw ComputerError("Choose an image smaller than 50 MB.")
            }
            return ComputerBackgroundPhoto(data: try Data(contentsOf: url))
        }
    }
}

/// SwiftTerm needs a compositing host window for its translucent background.
struct ComputerWindowCompositing: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {}
}
