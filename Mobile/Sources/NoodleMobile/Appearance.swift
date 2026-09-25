import HubLink
import ImagePlayground
import NoodleWallpaperCore
import PhotosUI
import SwiftUI

/// A conversation's backdrop, drawn as Noodle draws it on the Mac: a preset's gradient or a photo,
/// dimmed so the bubbles stay readable.
struct ConversationBackdrop: View {
    let background: ConversationBackground
    var imageURL: URL?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(.systemBackground)
                if let image, background.imageFilename != nil {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
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
            let poster = await Task.detached { await BackgroundMedia.poster(at: imageURL, kind: .image) }.value
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

/// Picks a conversation's backdrop: the presets, a photo, or an image made with Image Playground.
/// It applies as it is chosen; it is this phone's look alone.
struct BackgroundEditor: View {
    let chats: HubChats
    let agent: LinkBot
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State private var photo: PhotosPickerItem?
    @State private var creating = false
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        let background = chats.background(for: agent)
        Form {
            Section {
                ZStack {
                    ConversationBackdrop(background: background, imageURL: chats.backgroundImageURL(for: agent))
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
        .imagePlaygroundSheet(isPresented: $creating, concepts: [], sourceImage: nil) { url in
            Task { await apply { try Data(contentsOf: url) } }
        }
    }

    private func apply(_ load: () async throws -> Data?) async {
        busy = true
        problem = nil
        defer { busy = false }
        do {
            guard let data = try await load() else { throw ConversationBackgroundError.invalidImage }
            try chats.setBackground(photo: data, for: agent)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func swatch(_ title: String, _ background: ConversationBackground, selected: Bool) -> some View {
        Button {
            problem = nil
            do { try chats.setBackground(background, for: agent) } catch { problem = error.localizedDescription }
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
                    draft.avatarImageData = nil
                } label: {
                    Label(draft.avatarImageData == nil ? "Using Symbol" : "Use Symbol Instead",
                          systemImage: draft.avatarImageData == nil ? "checkmark" : "square.grid.2x2")
                }
                .disabled(draft.avatarImageData == nil)
                if loading { ProgressView() }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            Section("Colour") {
                HStack(spacing: 12) {
                    ForEach(0..<AgentAvatar.colourCount, id: \.self) { index in
                        Button {
                            draft.avatarColorIndex = index
                            draft.avatarImageData = nil
                        } label: {
                            AgentAvatar.swatch(index).frame(width: 34, height: 34).overlay {
                                if draft.avatarImageData == nil && AgentAvatar.colourIndex(draft.avatarColorIndex) == index {
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
                        let selected = draft.avatarImageData == nil && (draft.avatarSymbolName ?? "sparkles") == symbol
                        Button {
                            draft.avatarSymbolName = symbol
                            draft.avatarImageData = nil
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
        .imagePlaygroundSheet(isPresented: $creating, concepts: [], sourceImage: draft.avatarImageData.flatMap(UIImage.init(data:)).map(Image.init(uiImage:))) { url in
            Task { await load { try Data(contentsOf: url) } }
        }
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
