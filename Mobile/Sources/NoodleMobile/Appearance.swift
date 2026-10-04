import AVFoundation
import HubLink
import ImagePlayground
import NoodleWallpaperCore
import PhotosUI
import SwiftUI

/// A conversation's backdrop, drawn as Noodle draws it on the Mac: a preset's gradient, a photo or
/// a silent video, dimmed so the bubbles stay readable.
struct ConversationBackdrop: View {
    let background: ConversationBackground
    var imageURL: URL?
    @State private var image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(.systemBackground)
                if let image, background.imageFilename != nil {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    if background.mediaKind == .video, let imageURL, !reduceMotion {
                        LoopingVideo(url: imageURL).frame(width: geometry.size.width, height: geometry.size.height)
                    }
                } else if let preset = background.preset {
                    let colors = Self.colors(preset)
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Ellipse().fill(colors[1].opacity(0.5))
                        .frame(width: geometry.size.width * 1.4, height: geometry.size.height * 1.1)
                        .rotationEffect(.degrees(-35)).offset(x: geometry.size.width * 0.35)
                        .blur(radius: 50)
                }
                if !background.isDefault { Color.black.opacity(0.25) }
            }
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: imageURL) {
            image = nil
            guard let imageURL else { return }
            let kind = background.mediaKind
            let poster = await Task.detached { await BackgroundMedia.poster(at: imageURL, kind: kind) }.value
            image = poster.map { UIImage(cgImage: $0) }
        }
    }

    /// The Mac's preset colours.
    static func colors(_ preset: ConversationBackgroundPreset) -> [Color] {
        switch preset {
        case .sunset: [Color(red: 0.96, green: 0.52, blue: 0.15), Color(red: 0.77, green: 0.43, blue: 0.67), Color(red: 0.46, green: 0.35, blue: 0.75)]
        case .ocean: [Color(red: 0.04, green: 0.26, blue: 0.50), Color(red: 0.08, green: 0.60, blue: 0.66), Color(red: 0.14, green: 0.30, blue: 0.62)]
        case .forest: [Color(red: 0.08, green: 0.24, blue: 0.18), Color(red: 0.34, green: 0.53, blue: 0.30), Color(red: 0.14, green: 0.34, blue: 0.39)]
        case .dusk: [Color(red: 0.18, green: 0.16, blue: 0.39), Color(red: 0.47, green: 0.29, blue: 0.60), Color(red: 0.73, green: 0.37, blue: 0.47)]
        }
    }
}

/// A background video, playing round and round without sound, as the Mac plays it.
private struct LoopingVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView { PlayerView() }

    func updateUIView(_ view: PlayerView, context: Context) { view.show(url) }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var url: URL?

        init() {
            super.init(frame: .zero)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            let layer = layer as! AVPlayerLayer
            layer.player = player
            layer.videoGravity = .resizeAspectFill
        }

        required init?(coder: NSCoder) { nil }

        func show(_ url: URL) {
            guard url != self.url else { return }
            self.url = url
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.play()
        }
    }
}

/// Picks a conversation's backdrop: the presets, a photo, or an image made with Image Playground.
/// It applies as it is chosen, on the Hub, for every device.
struct BackgroundEditor: View {
    let chats: HubChats
    let thread: HubThread
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State private var photo: PhotosPickerItem?
    @State private var creating = false
    @State private var busy = false
    @State private var problem: String?
    @State private var sourceImage: Image?
    @State private var screen: CGSize?

    var body: some View {
        let background = chats.background(for: thread)
        Form {
            Section {
                ZStack {
                    ConversationBackdrop(background: background, imageURL: chats.backgroundImageURL(for: thread))
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Make this space your own.").padding(10).background(.regularMaterial, in: Capsule())
                        HStack { Spacer(); Text("Looks good!").padding(10).background(.regularMaterial, in: Capsule()) }
                    }
                    .padding(20)
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                HStack(spacing: 10) {
                    swatch("Default", ConversationBackground(), selected: background.isDefault)
                    ForEach(ConversationBackgroundPreset.allCases, id: \.self) { preset in
                        swatch(preset.rawValue.capitalized, ConversationBackground(preset: preset), selected: background.preset == preset)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                PhotosPicker(selection: $photo, matching: .images) { Label("Choose Photo", systemImage: "photo") }
                if supportsImagePlayground {
                    Button { creating = true } label: { Label("Create Image", systemImage: "apple.image.playground") }
                }
            }
            if busy { ProgressView() }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
        .navigationTitle("Background")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .task(id: photo) {
            guard let photo else { return }
            await apply { try await photo.loadTransferable(type: BackgroundPhoto.self)?.data }
            self.photo = nil
        }
        .imagePlaygroundSheet(isPresented: $creating, sourceImage: sourceImage) { url in
            Task { await apply { try Data(contentsOf: url) } }
        }
        .noodleImagePlayground(shapedLike: screen)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
        // Image Playground starts from the photo in use, as on the Mac.
        .task(id: chats.backgroundImageURL(for: thread)) {
            sourceImage = nil
            guard let url = chats.backgroundImageURL(for: thread) else { return }
            sourceImage = await Task.detached { UIImage(contentsOfFile: url.path) }.value.map(Image.init(uiImage:))
        }
    }

    private func apply(_ load: () async throws -> Data?) async {
        busy = true
        problem = nil
        defer { busy = false }
        do {
            guard let data = try await load() else { throw ConversationBackgroundError.invalidImage }
            try await chats.setBackground(photo: data, for: thread)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func swatch(_ title: String, _ background: ConversationBackground, selected: Bool) -> some View {
        Button {
            problem = nil
            Task {
                busy = true
                defer { busy = false }
                do { try await chats.setBackground(background, for: thread) } catch { problem = error.localizedDescription }
            }
        } label: {
            VStack(spacing: 6) {
                ConversationBackdrop(background: background)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color(.separator),
                                                                      lineWidth: selected ? 2 : 0.5))
                Text(title).font(.caption2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

/// Edits a bot's picture as the Mac's Bot Icon sheet does: an image of its own, or a symbol on a colour.
struct BotPictureEditor: View {
    @Binding var draft: LinkBotDraft
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State private var photo: PhotosPickerItem?
    @State private var creating = false
    @State private var loading = false
    @State private var problem: String?

    private var avatar: AvatarIdea {
        AvatarIdea(name: draft.name, description: draft.publicDescription, backstory: draft.backstory)
    }

    /// The Mac's bot symbols, in its order.
    static let symbols = [
        "sparkles", "bolt.fill", "brain.head.profile", "hammer.fill", "terminal.fill", "magnifyingglass",
        "shippingbox.fill", "paintbrush.fill", "checkmark.seal.fill", "ladybug.fill", "wand.and.stars", "gearshape.2.fill",
    ]

    var body: some View {
        Form {
            Section {
                AgentAvatar(draft: draft, size: 104)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            Section("Image") {
                PhotosPicker(selection: $photo, matching: .images) { Label("Choose Photo", systemImage: "photo") }
                if supportsImagePlayground {
                    Button { creating = true } label: { Label("Create Image", systemImage: "apple.image.playground") }
                }
                Button {
                    draft.removePicture()
                } label: {
                    Label(draft.hasPicture ? "Use Symbol Instead" : "Using Symbol",
                          systemImage: draft.hasPicture ? "square.grid.2x2" : "checkmark")
                }
                .disabled(!draft.hasPicture)
                if loading { ProgressView() }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            Section("Colour") {
                HStack(spacing: 12) {
                    ForEach(0..<AgentAvatar.colourCount, id: \.self) { index in
                        Button {
                            draft.avatarColorIndex = index
                            draft.removePicture()
                        } label: {
                            AgentAvatar.swatch(index).frame(width: 34, height: 34).overlay {
                                if !draft.hasPicture && AgentAvatar.colourIndex(draft.avatarColorIndex) == index {
                                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(index + 1)")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            Section("Symbol") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        let selected = !draft.hasPicture && (draft.avatarSymbolName ?? "sparkles") == symbol
                        Button {
                            draft.avatarSymbolName = symbol
                            draft.removePicture()
                        } label: {
                            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                                .frame(maxWidth: .infinity).frame(height: 42)
                                .background(selected ? Color.accentColor : Color.secondary.opacity(0.14),
                                            in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(selected ? Color.white : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Bot Picture")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: photo) {
            guard let photo else { return }
            await load { try await photo.loadTransferable(type: BackgroundPhoto.self)?.data }
            self.photo = nil
        }
        .imagePlaygroundSheet(isPresented: $creating, concepts: avatar.concepts, sourceImage: draft.avatarImageData.flatMap(UIImage.init(data:)).map(Image.init(uiImage:))) { url in
            Task { await load { try Data(contentsOf: url) } }
        }
        .noodleImagePlayground()
    }

    private func load(_ source: () async throws -> Data?) async {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            guard let data = try await source() else { throw LinkError("Photos could not provide this image.") }
            draft.avatarImageData = try BotPicture.prepare(data)
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A person's picture on a Hub, or their initials on a colour while they have chosen none.
struct PersonAvatar: View {
    let name: String
    let avatar: LinkAvatar?
    /// Gives someone who chose no picture a colour of their own.
    var id: UUID?
    let size: CGFloat

    var body: some View {
        Group {
            if let data = avatar?.image, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                AgentAvatar.swatch(AgentAvatar.colourIndex((avatar ?? .standard(for: id)).colour)).overlay {
                    if let symbol = avatar?.symbol {
                        Image(systemName: symbol).font(.system(size: size * 0.45, weight: .semibold))
                    } else {
                        Text(LinkAvatar.initials(of: name)).font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Edits this user's picture on a Hub, as everyone there sees it: a photo, or a symbol or their
/// initials on a colour. It is kept on the Hub, for every device.
struct PersonPictureEditor: View {
    let pairing: HubPairing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    private let original: LinkAvatar
    @State private var draft: LinkAvatar
    @State private var photo: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var creating = false
    @State private var loading = false
    @State private var saving = false
    @State private var problem: String?

    /// After the initials, in the bot symbols' style.
    static let symbols = [
        "person.fill", "face.smiling", "star.fill", "heart.fill", "leaf.fill", "pawprint.fill",
        "music.note", "gamecontroller.fill", "book.fill", "cup.and.saucer.fill", "sun.max.fill",
    ]

    init(pairing: HubPairing) {
        self.pairing = pairing
        original = pairing.avatar ?? .standard(for: pairing.status?.userID)
        _draft = State(initialValue: original)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PersonAvatar(name: pairing.userName, avatar: draft, size: 104)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                Section("Photo") {
                    if CameraPicker.isAvailable {
                        Button { takingPhoto = true } label: { Label("Take Photo", systemImage: "camera") }
                    }
                    PhotosPicker(selection: $photo, matching: .images) { Label("Choose Photo", systemImage: "photo") }
                    if supportsImagePlayground {
                        Button { creating = true } label: { Label("Create Image", systemImage: "apple.image.playground") }
                    }
                    if draft.hasImage {
                        Button(role: .destructive) { draft.removeImage() } label: { Label("Remove Photo", systemImage: "trash") }
                    }
                    if loading { ProgressView() }
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
                Section("Colour") {
                    HStack(spacing: 12) {
                        ForEach(0..<AgentAvatar.colourCount, id: \.self) { index in
                            Button {
                                draft.colour = index
                                draft.removeImage()
                            } label: {
                                AgentAvatar.swatch(index).frame(width: 34, height: 34).overlay {
                                    if !draft.hasImage && AgentAvatar.colourIndex(draft.colour) == index {
                                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Colour \(index + 1)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                Section("Symbol") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        tile(nil) { Text(LinkAvatar.initials(of: pairing.userName)).font(.system(size: 16, weight: .semibold, design: .rounded)) }
                            .accessibilityLabel("Initials")
                        ForEach(Self.symbols, id: \.self) { symbol in
                            tile(symbol) { Image(systemName: symbol).font(.system(size: 18, weight: .semibold)) }
                                .accessibilityLabel(symbol)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Your Picture")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Done", action: save).disabled(loading) }
                }
            }
            .task(id: photo) {
                guard let photo else { return }
                await load { try await photo.loadTransferable(type: BackgroundPhoto.self)?.data }
                self.photo = nil
            }
            .fullScreenCover(isPresented: $takingPhoto) {
                // Square, as the picture shows.
                CameraPicker(cropsSquare: true) { image in
                    Task { await load { image.jpegData(compressionQuality: 0.9) } }
                }
                .ignoresSafeArea()
            }
            .imagePlaygroundSheet(isPresented: $creating, sourceImage: draft.image.flatMap(UIImage.init(data:)).map(Image.init(uiImage:))) { url in
                Task { await load { try Data(contentsOf: url) } }
            }
            .noodleImagePlayground()
        }
    }

    private func tile(_ symbol: String?, @ViewBuilder label: () -> some View) -> some View {
        let selected = !draft.hasImage && draft.symbol == symbol
        return Button {
            draft.symbol = symbol
            draft.removeImage()
        } label: {
            label()
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(selected ? Color.white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func load(_ source: () async throws -> Data?) async {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            guard let data = try await source() else { throw LinkError("Photos could not provide this image.") }
            draft.image = try BotPicture.prepare(data)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func save() {
        guard draft != original else { return dismiss() }
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                try await pairing.setAvatar(draft)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
