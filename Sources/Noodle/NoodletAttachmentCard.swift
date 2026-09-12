import AppKit
import AppletBridge
import QuickLookThumbnailing
import SwiftUI

struct NoodletAttachmentCard: View {
    @Environment(NoodleStore.self) private var store
    let url: URL
    let shouldLoad: Bool
    @State private var title = "Noodlet"
    @State private var thumbnail: NSImage?
    @State private var unavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else { Image(systemName: unavailable ? "exclamationmark.link" : "square.grid.2x2")
                    .font(.system(size: 42)).foregroundStyle(.secondary) }
            }
            .frame(width: 280, height: 150)
            Text(title).font(.headline).lineLimit(1)
            Text(unavailable ? "Noodlet unavailable" : "Noodlet · Click to open")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 13))
        .task(id: shouldLoad) {
            guard shouldLoad else { return }
            do {
                let access = try await store.applets.resolvePreview(url)
                guard !Task.isCancelled else { return }
                title = access.title
                unavailable = false
                if let image = access.imageData.flatMap(NSImage.init(data:)) ?? NSImage(contentsOf: access.url.appendingPathComponent("preview.png")) {
                    thumbnail = image
                } else {
                    let request = QLThumbnailGenerator.Request(fileAt: access.url,
                        size: CGSize(width: 560, height: 300), scale: 1, representationTypes: .all)
                    let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                    guard !Task.isCancelled else { return }
                    thumbnail = result?.nsImage
                }
                withExtendedLifetime(access) {}
            } catch {
                if !Task.isCancelled { unavailable = true }
            }
        }
    }
}
