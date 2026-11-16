import AppIntents
import Foundation
import NoodleCore
import UniformTypeIdentifiers

/// What every app's Shortcuts actions share. Each app declares its own actions, since what Shortcuts shows of them
/// must be written out in full, but reads their conversations and files the same way.
enum ConversationIntentSupport {
    static func id(of entityID: String) throws -> UUID {
        guard let id = UUID(uuidString: entityID) else { throw ConversationIntentError.missingConversation }
        return id
    }

    /// A file Shortcuts passes, by its location when it has one, as a dropped file is copied.
    static func payload(_ file: IntentFile) -> AttachmentTransferPayload {
        if let url = file.fileURL { return .file(url) }
        let type = file.type ?? UTType(filenameExtension: (file.filename as NSString).pathExtension)
        return .data(file.data, originalFilename: file.filename,
                     mediaType: type?.preferredMIMEType ?? "application/octet-stream")
    }
}

enum ConversationIntentError: LocalizedError {
    case missingConversation

    var errorDescription: String? {
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "The app"
        return switch self {
        case .missingConversation: "That \(app) conversation is no longer available."
        }
    }
}
