import Foundation
import AppletBridge

/// Holds the provider's temporary file access while the attachment thumbnail loads.
final class NoodletPreviewAccess {
    let url: URL
    let title: String
    let imageData: Data?
    private let accessing: Bool
    init(response: AppletResponse, expectedID: UUID) throws {
        guard response.noodletID == expectedID, let bookmark = response.previewBookmark,
              bookmark.count <= 1_048_576 else { throw AppletError("Invalid noodlet preview response.") }
        var stale = false
        url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)
        guard url.isFileURL, url.pathExtension == "noodlet" else { throw AppletError("Invalid noodlet package location.") }
        title = response.title ?? url.deletingPathExtension().lastPathComponent
        imageData = response.mediaType == "image/png" && (response.data?.count ?? 0) <= 4 * 1_048_576 ? response.data : nil
        accessing = url.startAccessingSecurityScopedResource()
        guard FileManager.default.isReadableFile(atPath: url.appendingPathComponent("noodlet.json").path) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw AppletError("The noodlet is unavailable or cannot be accessed for preview.")
        }
    }
    deinit { if accessing { url.stopAccessingSecurityScopedResource() } }
}
