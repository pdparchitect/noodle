import AppKit
import NoodleWallpaper
import PhotosUI
import SwiftUI

struct AppletBackgroundSheet: View {
    @ObservedObject var store: AppletBackgroundStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ConversationBackground
    @State private var preparedFile: PreparedBackgroundFile?
    @State private var imageData: Data?
    @State private var choosingFile = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var busy = false
    @State private var failure: String?

    init(store: AppletBackgroundStore) {
        self.store = store
        _selected = State(initialValue: store.background)
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.blue)
                    .keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                Text("Library Background").font(.headline).foregroundStyle(.primary)
                Spacer()
                Button("Apply") {
                    busy = true; failure = nil
                    Task {
                        defer { busy = false }
                        do {
                            try await store.apply(selected, file: preparedFile)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .foregroundStyle(.blue)
                .disabled(busy || (selected == store.background && preparedFile == nil))
            }.buttonStyle(.plain)
            ConversationBackgroundView(background: selected,
                imageURL: preparedFile?.url ?? (selected.imageFilename == nil ? nil : store.imageURL))
                .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 12) {
                choice("Default", background: ConversationBackground())
                ForEach(ConversationBackgroundPreset.allCases, id: \.self) { preset in
                    choice(preset.rawValue.capitalized, background: ConversationBackground(preset: preset))
                }
            }
            HStack(spacing: 8) {
                ImageSourceMenu(title: "Choose Background…",
                    chooseFile: { choosingFile = true },
                    choosePhoto: { photoSelection = nil; choosingPhoto = true })
                    .frame(minWidth: 0, maxWidth: .infinity)
                if #available(macOS 15.1, *) {
                    NoodleImagePlaygroundButton(sourceImageData: imageData) { url in
                        busy = true
                        Task { await loadGeneratedImage(url) }
                    }.frame(minWidth: 0, maxWidth: .infinity)
                }
            }.disabled(busy)
            if busy { ProgressView().controlSize(.small) }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24).frame(width: 520).controlSize(.regular)
        .fixedSize(horizontal: false, vertical: true).presentationSizing(.fitted)
        .interactiveDismissDisabled(busy)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: BackgroundMedia.allowedContentTypes) { result in
            switch result {
            case .success(let url):
                busy = true; failure = nil
                Task {
                    defer { busy = false }
                    do {
                        useBackground(try await Task.detached { try await PreparedBackgroundFile.prepare(url) }.value)
                    } catch { failure = error.localizedDescription }
                }
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
                useBackground(file)
                imageData = photo.data
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    private func useBackground(_ file: PreparedBackgroundFile) {
        preparedFile = file; imageData = nil; failure = nil
        selected = ConversationBackground(imageFilename: "preview", mediaKind: file.kind)
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

    private func choice(_ title: String, background: ConversationBackground) -> some View {
        Button {
            selected = background; preparedFile = nil; imageData = nil; failure = nil
        } label: {
            VStack(spacing: 6) {
                ConversationBackgroundView(background: background)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(selected == background ? Color.accentColor : .clear, lineWidth: 2))
                Text(title).font(.caption)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).frame(minWidth: 0, maxWidth: .infinity).disabled(busy)
        .accessibilityLabel(title)
        .accessibilityValue(selected == background ? "Selected" : "Not selected")
    }
}
