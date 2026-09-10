import AppKit
import Combine
import ComputerCore
import ImageIO
import NoodleWallpaper
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
    @State private var imageData: Data?
    @State private var failure: String?
    @State private var busy = false
    @State private var choosingFile = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
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
            HStack(spacing: 12) {
                choice(nil)
                ForEach(ConversationBackgroundPreset.allCases, id: \.self) { choice($0.rawValue) }
            }
            HStack(spacing: 8) {
                ImageSourceMenu(
                    title: "Choose Background…",
                    chooseFile: { choosingFile = true },
                    choosePhoto: {
                        photoSelection = nil; choosingPhoto = true
                    }
                ).frame(minWidth: 0, maxWidth: .infinity)
                NoodleImagePlaygroundButton(sourceImageData: imageData) { url in
                    busy = true
                    Task { await loadGeneratedImage(url) }
                }.frame(minWidth: 0, maxWidth: .infinity)
            }
            .disabled(busy)
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
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: BackgroundMedia.allowedContentTypes) { result in
                switch result {
                case .success(let url):
                    busy = true
                    Task {
                        defer { busy = false }
                        do { useBackground(try await Task.detached { try await PreparedBackgroundFile.prepare(url) }.value) }
                        catch { failure = error.localizedDescription }
                    }
                case .failure(let error): failure = error.localizedDescription
                }
            }
            .photosPicker(isPresented: $choosingPhoto, selection: $photoSelection, matching: .images, preferredItemEncoding: .current)
            .task(id: photoSelection) {
                guard let photoSelection else { return }
                busy = true; failure = nil
                defer { busy = false }
                do {
                    guard let photo = try await photoSelection.loadTransferable(type: BackgroundPhoto.self) else {
                        throw ConversationBackgroundError.invalidImage
                    }
                    guard !Task.isCancelled else { return }
                    let file = try await Task.detached { try PreparedBackgroundFile.prepare(imageData: photo.data) }.value
                    guard !Task.isCancelled else { return }
                    useBackground(file)
                    imageData = photo.data
                } catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
    }
    private func useBackground(_ file: PreparedBackgroundFile) {
        imageData = nil
        draft.backgroundFile = file
        draft.backgroundImage = nil; draft.backgroundPreset = nil
        draft.backgroundFilename = nil; draft.backgroundMediaKind = nil
        failure = nil
    }
    private func loadGeneratedImage(_ url: URL) async {
        defer { busy = false }
        do {
            let (file, data) = try await Task.detached {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 50 * 1024 * 1024 else {
                    throw ConversationBackgroundError.invalidImage
                }
                let data = try Data(contentsOf: url)
                return (try PreparedBackgroundFile.prepare(imageData: data), data)
            }.value
            useBackground(file)
            imageData = data
        } catch { failure = error.localizedDescription }
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
        return Button {
            draft.backgroundPreset = preset; draft.backgroundImage = nil
            draft.backgroundFilename = nil; draft.backgroundMediaKind = nil; draft.backgroundFile = nil
            imageData = nil
            failure = nil
        } label: {
            VStack(spacing: 6) {
                ComputerWallpaper(appearance: sample).frame(maxWidth: .infinity).frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                        draft.background.imageFilename == nil && draft.backgroundPreset == preset ? Color.accentColor : .clear, lineWidth: 2))
                Text(preset?.capitalized ?? "Default").font(.caption)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).frame(minWidth: 0, maxWidth: .infinity).disabled(busy)
            .accessibilityLabel(preset?.capitalized ?? "Default")
            .accessibilityValue(draft.background.imageFilename == nil && draft.backgroundPreset == preset ? "Selected" : "Not selected")
    }
}

func computerColour(_ hex: String) -> NSColor {
    let value = UInt32(hex, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
}

@MainActor private enum ComputerImageImport {
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
