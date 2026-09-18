import AppKit
import NoodleWallpaperCore
import PhotosUI
import SwiftUI

/// What a background editor currently shows. The editor owns an imported file
/// until it applies or discards the selection.
public struct BackgroundSelection: Equatable {
    public var background: ConversationBackground
    public var file: PreparedBackgroundFile?

    public init(background: ConversationBackground = ConversationBackground(), file: PreparedBackgroundFile? = nil) {
        self.background = background
        self.file = file
    }

    public static func imported(_ file: PreparedBackgroundFile) -> BackgroundSelection {
        BackgroundSelection(background: ConversationBackground(imageFilename: "preview", mediaKind: file.kind), file: file)
    }
}

/// The preset swatches and the Choose Background and Create Image row shared by
/// every background editor. Its two rows join the enclosing stack, so the editor
/// keeps its own header, preview, extra controls and status lines.
public struct BackgroundPicker: View {
    @Binding private var selection: BackgroundSelection
    @Binding private var busy: Bool
    @Binding private var failure: String?
    @State private var choosingFile = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var importTask: Task<Void, Never>?
    @State private var sourceImageData: Data?

    public init(selection: Binding<BackgroundSelection>, busy: Binding<Bool>, failure: Binding<String?>) {
        _selection = selection
        _busy = busy
        _failure = failure
    }

    public var body: some View {
        HStack(spacing: 12) {
            choice("Default", background: ConversationBackground())
            ForEach(ConversationBackgroundPreset.allCases, id: \.self) { preset in
                choice(preset.rawValue.capitalized, background: ConversationBackground(preset: preset))
            }
        }
        HStack(spacing: 8) {
            ImageSourceMenu(title: "Choose Background…",
                chooseFile: { choosingFile = true },
                choosePhoto: { photoSelection = nil; choosingPhoto = true },
                chooseWallpaper: { url in load { try await PreparedBackgroundFile.prepare(url) } })
                .frame(minWidth: 0, maxWidth: .infinity)
            if #available(macOS 15.1, *) {
                NoodleImagePlaygroundButton(sourceImageData: sourceImageData) { url in
                    load { try Self.generatedImage(at: url) }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
        }
        .disabled(busy)
        .onDisappear { importTask?.cancel(); importTask = nil }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: BackgroundMedia.allowedContentTypes) { result in
            switch result {
            case .success(let url): load { try await PreparedBackgroundFile.prepare(url) }
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoSelection,
            matching: .images, preferredItemEncoding: .current)
        .task(id: photoSelection) {
            guard let photoSelection else { return }
            busy = true; failure = nil
            defer { busy = false }
            do {
                guard let photo = try await photoSelection.loadTransferable(type: BackgroundPhoto.self) else {
                    throw ConversationBackgroundError.invalidImage
                }
                try Task.checkCancellation()
                let file = try await Task.detached { try PreparedBackgroundFile.prepare(imageData: photo.data) }.value
                try Task.checkCancellation()
                selection = .imported(file)
            } catch {
                guard !Task.isCancelled else { return }
                failure = (error as? ConversationBackgroundError)?.localizedDescription
                    ?? "Photos couldn’t provide this image. If it’s in iCloud, open it in Photos and let it download, then try again. You can also use Choose Background → Choose File."
            }
        }
        // Image Playground starts from the still image being previewed, if any.
        .task(id: selection.file?.url) {
            sourceImageData = nil
            guard let file = selection.file, file.kind == .image else { return }
            let url = file.url
            sourceImageData = await Task.detached { try? Data(contentsOf: url) }.value
        }
    }

    private func load(_ prepare: @escaping @Sendable () async throws -> PreparedBackgroundFile) {
        busy = true; failure = nil
        importTask?.cancel()
        importTask = Task {
            defer { busy = false }
            do {
                let file = try await Task.detached(operation: prepare).value
                guard !Task.isCancelled else { return }
                selection = .imported(file)
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }

    private nonisolated static func generatedImage(at url: URL) throws -> PreparedBackgroundFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 50 * 1024 * 1024 else {
            throw ConversationBackgroundError.invalidImage
        }
        return try PreparedBackgroundFile.prepare(imageData: Data(contentsOf: url))
    }

    private func choice(_ title: String, background: ConversationBackground) -> some View {
        let selected = selection.background == background
        return Button {
            selection = BackgroundSelection(background: background); failure = nil
        } label: {
            VStack(spacing: 6) {
                ConversationBackgroundView(background: background)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                Text(title).font(.caption)
            }
            // The wallpaper artwork intentionally ignores input. Give the
            // enclosing label its own hit area, including the swatch and gaps.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: .infinity)
        .disabled(busy)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}
