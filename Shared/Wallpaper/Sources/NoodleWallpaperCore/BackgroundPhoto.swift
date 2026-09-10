import Foundation
import CoreTransferable

/// Photos providers don't necessarily vend generic public.data. Negotiate an
/// image explicitly, and read temporary files inside the transfer's lifetime.
public struct BackgroundPhoto: Transferable {
    public let data: Data

    public static var transferRepresentation: some TransferRepresentation {
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
