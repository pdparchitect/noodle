import AppKit
import Combine
import BrowserCore
import BrowserBridge
import ImageIO
import NoodleWallpaper
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// Same palette and circular icon treatment as Noodle's BotAvatar.
private let browserIconColours: [[Color]] = [
    [.blue, .cyan], [.purple, .pink], [.orange, .yellow],
    [.mint, .teal], [.indigo, .blue], [.pink, .orange]
]

struct BrowserIcon: View {
    let appearance: BrowserIconAppearance
    let symbol: String
    let size: CGFloat
    var body: some View {
        ZStack {
            if let data = appearance.iconImage, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(LinearGradient(colors: browserIconColours[max(0, min(5, appearance.iconColour))],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: appearance.iconSymbol ?? symbol)
                    .font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
            }
        }.frame(width: size, height: size).clipShape(Circle())
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1).accessibilityHidden(true)
    }
}

struct BrowserIconButton: View {
    @Binding var appearance: BrowserIconAppearance
    let symbol: String
    @State private var editing = false
    var body: some View {
        Button { editing = true } label: {
            ZStack(alignment: .bottomTrailing) {
                BrowserIcon(appearance: appearance, symbol: symbol, size: 64)
                Image(systemName: "pencil.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor).font(.system(size: 21))
                    .background(.background, in: Circle())
            }
        }.buttonStyle(.plain).help("Change Browser Icon").accessibilityLabel("Change Browser Icon")
            .sheet(isPresented: $editing) { BrowserIconSheet(appearance: $appearance, symbol: symbol) }
    }
}

struct BrowserIconSheet: View {
    @Binding var appearance: BrowserIconAppearance
    let symbol: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BrowserIconAppearance
    @State private var failure: String?
    @State private var choosingFile = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    private let symbols = ["desktopcomputer", "terminal", "shippingbox", "server.rack", "laptopcomputer", "globe",
        "sparkles", "bolt.fill", "brain.head.profile", "hammer.fill", "paintbrush.fill", "gearshape.2.fill"]
    init(appearance: Binding<BrowserIconAppearance>, symbol: String) {
        _appearance = appearance; self.symbol = symbol
        _draft = State(initialValue: appearance.wrappedValue)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.blue)
                Spacer(); Text("Browser Icon").font(.headline).foregroundStyle(.primary); Spacer()
                Button("Done") { appearance = draft; dismiss() }.foregroundStyle(.blue)
                    .disabled(isLoadingPhoto)
            }.buttonStyle(.plain).padding(16)
            Divider()
            VStack(spacing: 18) {
                BrowserIcon(appearance: draft, symbol: symbol, size: 104)
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
                        ForEach(browserIconColours.indices, id: \.self) { index in
                            Button { draft.iconColour = index; draft.iconImage = nil } label: {
                                Circle().fill(LinearGradient(colors: browserIconColours[index], startPoint: .topLeading, endPoint: .bottomTrailing))
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
                    guard let photo = try await photoSelection.loadTransferable(type: BackgroundPhoto.self) else {
                        throw BrowserError("Photos could not provide this image. Try Choose File instead.")
                    }
                    guard !Task.isCancelled else { return }
                    draft.iconImage = try BrowserImageImport.prepare(photo.data, maxDimension: 512)
                } catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
    }
    private func loadImage(_ url: URL) {
        do { draft.iconImage = try BrowserImageImport.load(url, maxDimension: 512); failure = nil }
        catch { failure = error.localizedDescription }
    }
}

struct BrowserIconAppearance: Equatable {
    var iconSymbol: String?
    var iconColour: Int
    var iconImage: Data?
    init(symbol: String? = nil, colour: Int = 0, image: Data? = nil) {
        iconSymbol = symbol; iconColour = colour; iconImage = image
    }
}

@MainActor private enum BrowserImageImport {
    static func load(_ url: URL, maxDimension: Int) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50 * 1024 * 1024 else { throw BrowserError("Choose an image smaller than 50 MB.") }
        return try prepare(Data(contentsOf: url), maxDimension: maxDimension)
    }
    static func prepare(_ data: Data, maxDimension: Int) throws -> Data {
        guard data.count <= 50 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw BrowserError("Choose an image smaller than 50 MB.") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]),
              data.count <= (maxDimension <= 512 ? 2 : 8) * 1024 * 1024 else {
            throw BrowserError("The image is too large. Choose a smaller image.")
        }
        return data
    }
}
