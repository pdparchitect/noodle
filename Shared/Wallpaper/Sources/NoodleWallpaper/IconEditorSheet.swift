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
    private let faces: [Data]
    @Environment(\.dismiss) private var dismiss
    @State private var draft: IconEditorDraft
    @State private var failure: String?
    @State private var choosingFile = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var isLoadingImage = false
    @State private var takingPhoto = false
    @State private var choosingFace = false
    @State private var isDropTargeted = false
    @State private var dropTask: Task<Void, Never>?

    /// With `initials`, a person's: they come first among the symbols, chosen as no symbol. `takesPhotos`
    /// offers the camera, which only a person's picture does. `faces` are ready-made pictures, used as they are.
    public init(title: String, icon: Binding<IconAppearance>, symbol: String, symbols: [String], encoding: IconImageEncoding,
                avatar: AvatarIdea? = nil, initials: String? = nil, takesPhotos: Bool = false, faces: [Data] = []) {
        _icon = icon; self.title = title; self.symbol = symbol; self.symbols = symbols; self.encoding = encoding; self.avatar = avatar
        self.initials = initials; self.takesPhotos = takesPhotos; self.faces = faces
        _draft = State(initialValue: IconEditorDraft(icon.wrappedValue))
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(Color.accentColor)
                Spacer(); Text(title).font(.headline).foregroundStyle(.primary); Spacer()
                Button("Done") { icon = draft.chosen; dismiss() }.foregroundStyle(Color.accentColor)
                    .disabled(isLoadingImage)
            }.buttonStyle(.plain).padding(16)
            Divider()
            VStack(spacing: 18) {
                IconBadge(appearance: draft.chosen, symbol: symbol, size: 104, initials: initials)
                    .overlay {
                        Circle().inset(by: -5)
                            .strokeBorder(isDropTargeted && !isLoadingImage ? Color.accentColor : .clear, lineWidth: 3)
                    }
                    .padding(.top, 4)
                Picker("Show", selection: $draft.showsPicture) {
                    Text("Picture").tag(true)
                    Text("Symbol").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                if draft.showsPicture { pictureSources } else { symbolChoices }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }.padding(20)
        }.frame(width: 440).controlSize(.regular)
            .onDrop(of: BackgroundDrop.imageContentTypes, isTargeted: $isDropTargeted, perform: drop)
            .onDisappear { dropTask?.cancel(); dropTask = nil }
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

    private var pictureSources: some View {
        GroupBox { VStack(spacing: 8) {
            HStack(spacing: 8) {
                ImageSourceMenu(
                    title: "Choose Image…",
                    chooseFile: { choosingFile = true },
                    choosePhoto: { photoSelection = nil; choosingPhoto = true },
                    takePhoto: takesPhotos ? { takingPhoto = true } : nil
                ).frame(minWidth: 0, maxWidth: .infinity)
                if #available(macOS 15.1, *) {
                    // With a picture in place, Image Playground starts from it.
                    NoodleImagePlaygroundButton(sourceImageData: draft.icon.iconImage, concepts: draft.playgroundIdea(avatar)?.concepts ?? [],
                                                title: draft.icon.iconImage == nil ? "Create Image…" : "Edit Image…") { url in loadImage(url) }
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
            }
            if !faces.isEmpty {
                Button { choosingFace = true } label: {
                    Label("Choose Face…", systemImage: "face.smiling").frame(maxWidth: .infinity).frame(height: 20)
                }.buttonStyle(.bordered)
                    .popover(isPresented: $choosingFace, arrowEdge: .bottom) {
                        FacePicker(faces: faces, selection: draft.icon.iconImage) { face in
                            draft.setPicture(face); photoSelection = nil; choosingFace = false
                        }
                    }
            }
            if isLoadingImage { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
        }.padding(8) }
    }

    private var symbolChoices: some View {
        VStack(spacing: 18) {
            GroupBox("Colour") {
                HStack(spacing: 12) {
                    ForEach(IconPalette.gradients.indices, id: \.self) { index in
                        Button { draft.icon.iconColour = index } label: {
                            Circle().fill(LinearGradient(colors: IconPalette.gradients[index], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 34, height: 34).overlay {
                                    if IconPalette.index(for: draft.icon.iconColour) == index {
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
                        tile(nil, selected: draft.icon.iconSymbol == nil) {
                            Text(initials).font(.system(size: 16, weight: .semibold, design: .rounded))
                        }.accessibilityLabel("Initials")
                    }
                    ForEach(Array(symbols.enumerated()), id: \.offset) { _, candidate in
                        let chosen = draft.icon.iconSymbol ?? (initials == nil ? symbol : nil)
                        tile(candidate, selected: chosen == candidate) {
                            Image(systemName: candidate).font(.system(size: 18, weight: .semibold))
                        }.accessibilityLabel(candidate)
                    }
                }.padding(8)
            }
        }
    }

    private func tile(_ candidate: String?, selected: Bool, @ViewBuilder label: () -> some View) -> some View {
        Button { draft.icon.iconSymbol = candidate } label: {
            label()
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(selected ? Color.white : .primary)
        }.buttonStyle(.plain)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !isLoadingImage, let provider = providers.first(where: { provider in
            BackgroundDrop.imageContentTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }) else { return false }
        let encoding = encoding
        dropTask = Task {
            await load { try await BackgroundDrop.load(provider) { try IconImage.load($0, encoding: encoding) } }
        }
        return true
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
            draft.setPicture(data)
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

/// A picture and a symbol on a colour, both kept while the person switches between them;
/// Done saves the one showing.
struct IconEditorDraft: Equatable {
    /// The symbol and colour, and the picture whether it shows or not.
    var icon: IconAppearance
    var showsPicture: Bool

    init(_ icon: IconAppearance) {
        self.icon = icon
        showsPicture = icon.iconImage != nil
    }

    var chosen: IconAppearance {
        var chosen = icon
        if !showsPicture { chosen.iconImage = nil }
        return chosen
    }

    /// Image Playground starts from the bot's idea only for a new image; editing a picture is the person's prompt alone.
    func playgroundIdea(_ idea: AvatarIdea?) -> AvatarIdea? {
        icon.iconImage == nil ? idea : nil
    }

    mutating func setPicture(_ data: Data) {
        icon.iconImage = data
        showsPicture = true
    }
}

/// Ready-made faces in a grid, the chosen one ringed.
private struct FacePicker: View {
    let faces: [Data]
    let selection: Data?
    let choose: (Data) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 8), spacing: 8) {
                ForEach(faces.indices, id: \.self) { index in
                    let face = faces[index]
                    Button { choose(face) } label: {
                        FaceImage(data: face)
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                            .overlay { Circle().inset(by: -3).strokeBorder(face == selection ? Color.accentColor : .clear, lineWidth: 2.5) }
                    }.buttonStyle(.plain).accessibilityLabel("Face \(index + 1)")
                }
            }.padding(14)
        }.frame(width: 14 * 2 + 8 * 44 + 7 * 8, height: 360)
    }
}

private struct FaceImage: View {
    let data: Data
    var body: some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Circle().fill(.quaternary)
        }
    }
}
