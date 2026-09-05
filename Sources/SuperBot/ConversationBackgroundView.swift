import AppKit
import CoreTransferable
import PhotosUI
import SwiftUI
import SuperBotCore
import UniformTypeIdentifiers

/// Photos providers don't necessarily vend generic public.data. Negotiate an
/// image explicitly, and read temporary files inside the transfer's lifetime.
private struct BackgroundPhoto: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard data.count <= 50 * 1024 * 1024 else { throw ConversationBackgroundError.invalidImage }
            return BackgroundPhoto(data: data)
        }
        FileRepresentation(importedContentType: .image) { received in
            let url = received.file
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 50 * 1024 * 1024 else { throw ConversationBackgroundError.invalidImage }
            return BackgroundPhoto(data: try Data(contentsOf: url))
        }
    }
}

/// One window-sized wallpaper. Load its replacement before fading so image-backed
/// conversations never flash the default canvas during a switch.
struct ConversationWallpaper: View {
    let background: ConversationBackground
    var imageURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed = Layer(request: Request(background: ConversationBackground()))

    private struct Request: Equatable {
        let background: ConversationBackground
        var imageURL: URL?
    }

    private struct Layer: Identifiable {
        let id = UUID()
        let request: Request
        var image: NSImage?
    }

    var body: some View {
        let request = Request(background: background, imageURL: imageURL)
        ZStack {
            Color(nsColor: .textBackgroundColor)
            ConversationBackgroundView(background: displayed.request.background, previewImage: displayed.image)
                .id(displayed.id)
                .transition(.opacity)
                .zIndex(1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: request) {
            guard request != displayed.request else { return }
            let image: NSImage?
            if let url = request.imageURL {
                image = await Task.detached { NSImage(contentsOf: url) }.value
            } else {
                image = nil
            }
            guard !Task.isCancelled else { return }
            // Keep this transaction local to the wallpaper, not the transcript.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                displayed = Layer(request: request, image: image)
            }
        }
    }
}

/// An edge-to-edge fade on the wallpaper, underneath both split-view columns.
/// It must not wash over sidebar content or stop at the conversation boundary.
struct ConversationWindowHeaderShade: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.24), location: 0),
                    .init(color: .black.opacity(0.10), location: 0.5),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.88), location: 0.55),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(height: 88)
            .shadow(color: .black.opacity(0.24), radius: 14, y: 5)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ConversationBackgroundView: View {
    let background: ConversationBackground
    var imageURL: URL?
    var previewImage: NSImage?
    @State private var loadedImage: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if let image = previewImage ?? loadedImage, background.imageFilename != nil {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if let preset = background.preset {
                    LinearGradient(colors: colors(preset), startPoint: .topLeading, endPoint: .bottomTrailing)
                    Ellipse().fill(colors(preset)[1].opacity(0.5))
                        .frame(width: geometry.size.width * 1.4, height: geometry.size.height * 1.1)
                        .rotationEffect(.degrees(-35)).offset(x: geometry.size.width * 0.35)
                        .blur(radius: 50)
                }
                if !background.isDefault { Color.black.opacity(0.25) }
            }
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: imageURL) {
            loadedImage = nil
            guard let imageURL else { return }
            let image = await Task.detached { NSImage(contentsOf: imageURL) }.value
            guard !Task.isCancelled else { return }
            loadedImage = image
        }
    }

    private func colors(_ preset: ConversationBackgroundPreset) -> [Color] {
        switch preset {
        case .sunset: return [Color(red: 0.96, green: 0.52, blue: 0.15), Color(red: 0.77, green: 0.43, blue: 0.67), Color(red: 0.46, green: 0.35, blue: 0.75)]
        case .ocean: return [Color(red: 0.04, green: 0.26, blue: 0.50), Color(red: 0.08, green: 0.60, blue: 0.66), Color(red: 0.14, green: 0.30, blue: 0.62)]
        case .forest: return [Color(red: 0.08, green: 0.24, blue: 0.18), Color(red: 0.34, green: 0.53, blue: 0.30), Color(red: 0.14, green: 0.34, blue: 0.39)]
        case .dusk: return [Color(red: 0.18, green: 0.16, blue: 0.39), Color(red: 0.47, green: 0.29, blue: 0.60), Color(red: 0.73, green: 0.37, blue: 0.47)]
        }
    }
}

struct ConversationBackgroundSheet: View {
    @Environment(SuperBotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversation: BotConversation
    @State private var selected = ConversationBackground()
    @State private var original = ConversationBackground()
    @State private var imageData: Data?
    @State private var image: NSImage?
    @State private var choosingImage = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text("Conversation Background").font(.headline)
                Spacer()
                Button("Apply") {
                    busy = true
                    Task {
                        do {
                            try await store.setBackground(selected, imageData: imageData, for: conversation)
                            dismiss()
                        } catch { failure = error.localizedDescription; busy = false }
                    }
                }
                .disabled(busy || (selected == original && imageData == nil))
                .keyboardShortcut(.defaultAction)
            }
            Text(store.title(for: conversation)).foregroundStyle(.secondary)
            ConversationBackgroundView(background: selected,
                imageURL: store.repository.backgroundImageURL(selected, conversationID: conversation.id), previewImage: image)
                .overlay {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Make this space your own.").padding(10).background(.regularMaterial, in: Capsule())
                        HStack { Spacer(); Text("Looks good!").padding(10).background(.regularMaterial, in: Capsule()) }
                    }.padding(24)
                }
                .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 12) {
                choice("Default", background: ConversationBackground())
                ForEach(ConversationBackgroundPreset.allCases, id: \.self) { preset in
                    choice(preset.rawValue.capitalized, background: ConversationBackground(preset: preset))
                }
            }
            HStack {
                Menu {
                    Button("Choose File…", systemImage: "folder") { choosingImage = true }
                    Button("Photos Library…", systemImage: "photo.on.rectangle") {
                        photoSelection = nil
                        choosingPhoto = true
                    }
                } label: {
                    Label("Choose Image…", systemImage: "photo")
                }
                .fixedSize()
                if !selected.isDefault {
                    Button("Remove Background") { selected = ConversationBackground(); imageData = nil; image = nil }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }.disabled(busy)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .padding(24).frame(width: 520)
        .onAppear { original = store.background(for: conversation); selected = original }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                busy = true
                Task {
                    do {
                        let data = try await Task.detached {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size <= 50 * 1024 * 1024 else { throw ConversationBackgroundError.invalidImage }
                            return try Data(contentsOf: url)
                        }.value
                        try useImage(data)
                    } catch { failure = error.localizedDescription }
                    busy = false
                }
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoSelection,
            matching: .images, preferredItemEncoding: .current)
        .task(id: photoSelection) {
            guard let photoSelection else { return }
            busy = true
            failure = nil
            defer { busy = false }
            do {
                guard let photo = try await photoSelection.loadTransferable(type: BackgroundPhoto.self) else {
                    throw ConversationBackgroundError.invalidImage
                }
                guard !Task.isCancelled else { return }
                try useImage(photo.data)
            } catch {
                guard !Task.isCancelled else { return }
                if let imageError = error as? ConversationBackgroundError {
                    failure = imageError.localizedDescription
                } else {
                    failure = "Photos couldn’t provide this image. If it’s in iCloud, open it in Photos and let it download, then try again. You can also use Choose Image → Choose File."
                }
            }
        }
    }

    private func useImage(_ data: Data) throws {
        guard data.count <= 50 * 1024 * 1024, let preview = NSImage(data: data) else {
            throw ConversationBackgroundError.invalidImage
        }
        imageData = data
        image = preview
        selected = ConversationBackground(imageFilename: "preview")
        failure = nil
    }

    private func choice(_ title: String, background: ConversationBackground) -> some View {
        Button {
            selected = background; imageData = nil; image = nil; failure = nil
        } label: {
            VStack(spacing: 6) {
                ConversationBackgroundView(background: background)
                    .frame(width: 80, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected == background ? Color.accentColor : .clear, lineWidth: 2))
                Text(title).font(.caption)
            }
            // The wallpaper artwork intentionally ignores input. Give the
            // enclosing label its own hit area, including the swatch and gaps.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected == background ? "Selected" : "Not selected")
        .disabled(busy)
    }
}

struct ConversationBackgroundSettingsRow: View {
    @Environment(SuperBotStore.self) private var store
    let conversation: BotConversation
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            HStack {
                Label("Conversation Background", systemImage: "photo")
                Spacer()
                Text(store.background(for: conversation).isDefault ? "Default" : "Custom")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $editing) { ConversationBackgroundSheet(conversation: conversation).environment(store) }
    }
}
