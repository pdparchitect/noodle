import AppKit
import CoreTransferable
import PhotosUI
import SwiftUI
import NoodleCore
import UniformTypeIdentifiers

struct ConversationBackgroundSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversation: BotConversation
    @State private var selected = ConversationBackground()
    @State private var original = ConversationBackground()
    @State private var imageData: Data?
    @State private var image: NSImage?
    @State private var preparedFile: PreparedBackgroundFile?
    @State private var choosingImage = false
    @State private var choosingPhoto = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .disabled(busy)
                Spacer()
                Text("Conversation Background").font(.headline)
                Spacer()
                Button("Apply") {
                    busy = true
                    Task {
                        do {
                            try await store.setBackground(selected, imageData: imageData, file: preparedFile, for: conversation)
                            dismiss()
                        } catch { failure = error.localizedDescription; busy = false }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .disabled(busy || (selected == original && imageData == nil && preparedFile == nil))
                .keyboardShortcut(.defaultAction)
            }
            Text(store.title(for: conversation)).foregroundStyle(.secondary)
            ConversationBackgroundView(background: selected,
                imageURL: preparedFile?.url ?? store.repository.backgroundImageURL(selected, conversationID: conversation.id), previewImage: image)
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
            HStack(spacing: 8) {
                ImageSourceMenu(
                    title: "Choose Background…",
                    chooseFile: { choosingImage = true },
                    choosePhoto: {
                        photoSelection = nil
                        choosingPhoto = true
                    }
                )
                .frame(minWidth: 0, maxWidth: .infinity)

                if #available(macOS 15.1, *) {
                    NoodleImagePlaygroundButton(sourceImageData: imageData) { url in
                        Task { await loadGeneratedImage(at: url) }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
            }
            .disabled(busy)
            if busy { ProgressView().controlSize(.small) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .padding(24).frame(width: 520)
        .onAppear { original = store.background(for: conversation); selected = original }
        .onDisappear { preparedFile = nil }
        .interactiveDismissDisabled(busy)
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: BackgroundMedia.allowedContentTypes) { result in
            switch result {
            case .success(let url):
                busy = true
                Task {
                    do {
                        let file = try await Task.detached { try await PreparedBackgroundFile.prepare(url) }.value
                        preparedFile = file
                        imageData = nil; image = nil
                        selected = ConversationBackground(imageFilename: "preview", mediaKind: file.kind)
                        failure = nil
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
                    failure = "Photos couldn’t provide this image. If it’s in iCloud, open it in Photos and let it download, then try again. You can also use Choose Background → Choose File."
                }
            }
        }
    }

    private func useImage(_ data: Data) throws {
        guard data.count <= 50 * 1024 * 1024, let preview = NSImage(data: data) else {
            throw ConversationBackgroundError.invalidImage
        }
        imageData = data
        preparedFile = nil
        image = preview
        selected = ConversationBackground(imageFilename: "preview")
        failure = nil
    }

    @MainActor
    private func loadGeneratedImage(at url: URL) async {
        busy = true
        failure = nil
        defer { busy = false }

        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
            try useImage(data)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func choice(_ title: String, background: ConversationBackground) -> some View {
        Button {
            selected = background; imageData = nil; image = nil; preparedFile = nil; failure = nil
        } label: {
            VStack(spacing: 6) {
                ConversationBackgroundView(background: background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected == background ? Color.accentColor : .clear, lineWidth: 2))
                Text(title).font(.caption)
            }
            // The wallpaper artwork intentionally ignores input. Give the
            // enclosing label its own hit area, including the swatch and gaps.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: .infinity)
        .accessibilityLabel(title)
        .accessibilityValue(selected == background ? "Selected" : "Not selected")
        .disabled(busy)
    }
}

struct ConversationBackgroundSettingsRow: View {
    @Environment(NoodleStore.self) private var store
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
        .sheet(isPresented: $editing) {
            ConversationBackgroundSheet(conversation: conversation)
                .environment(store)
                .noodleSheetSizing()
        }
    }
}
