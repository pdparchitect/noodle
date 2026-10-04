import AppKit
import NoodleWallpaperCore
import PhotosUI
import SwiftUI

/// Edits an `IconAppearance`. Each app supplies its own title, the symbols it
/// offers, the symbol drawn before one is chosen, and how it stores images.
/// The presenting app applies its own sheet sizing.
public struct IconEditorSheet: View {
    @Binding private var icon: IconAppearance
    private let title: String
    private let symbol: String
    private let symbols: [String]
    private let encoding: IconImageEncoding
    private let avatar: AvatarIdea?
    private let initials: String?
    private let takesPhotos: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: IconAppearance
    @State private var failure: String?
    @State private var choosingFile = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var isLoadingImage = false
    @State private var takingPhoto = false

    /// With `initials`, a person's: they come first among the symbols, chosen as no symbol. `takesPhotos`
    /// offers the camera, which only a person's picture does.
    public init(title: String, icon: Binding<IconAppearance>, symbol: String, symbols: [String], encoding: IconImageEncoding,
                avatar: AvatarIdea? = nil, initials: String? = nil, takesPhotos: Bool = false) {
        _icon = icon; self.title = title; self.symbol = symbol; self.symbols = symbols; self.encoding = encoding; self.avatar = avatar
        self.initials = initials; self.takesPhotos = takesPhotos
        _draft = State(initialValue: icon.wrappedValue)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.blue)
                Spacer(); Text(title).font(.headline).foregroundStyle(.primary); Spacer()
                Button("Done") { icon = draft; dismiss() }.foregroundStyle(.blue)
                    .disabled(isLoadingImage)
            }.buttonStyle(.plain).padding(16)
            Divider()
            VStack(spacing: 18) {
                IconBadge(appearance: draft, symbol: symbol, size: 104, initials: initials)
                    .padding(.top, 4)
                GroupBox("Image") {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            ImageSourceMenu(
                                title: "Choose Image…",
                                chooseFile: { choosingFile = true },
                                choosePhoto: { photoSelection = nil; choosingPhoto = true },
                                takePhoto: takesPhotos ? { takingPhoto = true } : nil
                            ).frame(minWidth: 0, maxWidth: .infinity)
                            if #available(macOS 15.1, *) {
                                NoodleImagePlaygroundButton(sourceImageData: draft.iconImage, concepts: avatar?.concepts ?? []) { url in loadImage(url) }
                                    .frame(minWidth: 0, maxWidth: .infinity)
                            }
                        }
                        Divider()
                        Button {
                            draft.iconImage = nil; photoSelection = nil
                        } label: {
                            Label(draft.iconImage == nil ? "Using Symbol" : "Use Symbol Instead",
                                  systemImage: draft.iconImage == nil ? "checkmark" : "square.grid.2x2")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).disabled(draft.iconImage == nil)
                        if isLoadingImage { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                    }.padding(8)
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                GroupBox("Colour") {
                    HStack(spacing: 12) {
                        ForEach(IconPalette.gradients.indices, id: \.self) { index in
                            Button { draft.iconColour = index; draft.iconImage = nil } label: {
                                Circle().fill(LinearGradient(colors: IconPalette.gradients[index], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 34, height: 34).overlay {
                                        if draft.iconImage == nil && IconPalette.index(for: draft.iconColour) == index {
                                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                        }
                                    }
                            }.buttonStyle(.plain).accessibilityLabel("Colour \(index + 1)")
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                GroupBox("Symbol") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        if let initials {
                            tile(nil, selected: draft.iconImage == nil && draft.iconSymbol == nil) {
                                Text(initials).font(.system(size: 16, weight: .semibold, design: .rounded))
                            }.accessibilityLabel("Initials")
                        }
                        ForEach(Array(symbols.enumerated()), id: \.offset) { _, candidate in
                            let chosen = draft.iconSymbol ?? (initials == nil ? symbol : nil)
                            tile(candidate, selected: draft.iconImage == nil && chosen == candidate) {
                                Image(systemName: candidate).font(.system(size: 18, weight: .semibold))
                            }.accessibilityLabel(candidate)
                        }
                    }.padding(8)
                }
            }.padding(20)
        }.frame(width: 440).controlSize(.regular)
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url): loadImage(url)
                case .failure(let error): failure = error.localizedDescription
                }
            }
            .sheet(isPresented: $takingPhoto) {
                CameraPhotoSheet { frame in
                    let encoding = encoding
                    Task { await load { try await Task.detached { try IconImage.photo(frame, encoding: encoding) }.value } }
                }
            }
            .photosPicker(isPresented: $choosingPhoto, selection: $photoSelection, matching: .images, preferredItemEncoding: .current)
            .task(id: photoSelection) {
                guard let photoSelection else { return }
                let encoding = encoding
                await load {
                    guard let photo = try await photoSelection.loadTransferable(type: BackgroundPhoto.self) else {
                        throw IconImageError.photosUnavailable
                    }
                    return try await Task.detached { try IconImage.prepare(photo.data, encoding: encoding) }.value
                }
            }
    }

    private func tile(_ candidate: String?, selected: Bool, @ViewBuilder label: () -> some View) -> some View {
        Button { draft.iconSymbol = candidate; draft.iconImage = nil } label: {
            label()
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(selected ? Color.white : .primary)
        }.buttonStyle(.plain)
    }

    private func loadImage(_ url: URL) {
        let encoding = encoding
        Task { await load { try await Task.detached { try IconImage.load(url, encoding: encoding) }.value } }
    }

    private func load(_ image: () async throws -> Data) async {
        isLoadingImage = true; failure = nil
        defer { isLoadingImage = false }
        do {
            let data = try await image()
            guard !Task.isCancelled else { return }
            draft.iconImage = data
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}
