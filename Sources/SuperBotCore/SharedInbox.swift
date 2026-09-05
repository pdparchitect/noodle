import Foundation

public struct ShareDestination: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let isGroup: Bool

    public init(id: UUID, name: String, isGroup: Bool) {
        self.id = id
        self.name = name
        self.isGroup = isGroup
    }
}

public struct SharedRequest: Identifiable, Codable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let body: String
    public let filenames: [String]

    public init(id: UUID, conversationID: UUID, body: String, filenames: [String]) {
        self.id = id
        self.conversationID = conversationID
        self.body = body
        self.filenames = filenames
    }
}

public enum SharedInboxError: LocalizedError {
    case unavailable, invalidRequest, emptyContent

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Sharing is unavailable in this build. Open the signed SuperBot app once, then try again."
        case .invalidRequest: return "The shared item could not be read safely. Please share it again."
        case .emptyContent: return "Choose text, a web page, or files to send."
        }
    }
}

/// The extension sees only the destination catalogue and explicitly shared items, not transcripts.
public struct SharedInbox: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) { self.rootURL = rootURL }

    public static func configured(bundle: Bundle = .main) throws -> SharedInbox {
        guard let identifier = bundle.object(forInfoDictionaryKey: "SuperBotSharedGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else { throw SharedInboxError.unavailable }
        return SharedInbox(rootURL: container.appendingPathComponent("Sharing", isDirectory: true))
    }

    public func saveDestinations(_ destinations: [ShareDestination]) throws {
        try prepare()
        let url = rootURL.appendingPathComponent("destinations.json")
        let data = try JSONEncoder().encode(destinations)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
    }

    public func loadDestinations() throws -> [ShareDestination] {
        let url = rootURL.appendingPathComponent("destinations.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ShareDestination].self, from: Data(contentsOf: url))
    }

    public func draftDirectory(_ id: UUID) throws -> URL {
        try prepare()
        let directory = rootURL.appendingPathComponent("Drafts/\(id.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func publish(_ request: SharedRequest) throws {
        guard !request.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !request.filenames.isEmpty else {
            throw SharedInboxError.emptyContent
        }
        let draft = try draftDirectory(request.id)
        _ = try validatedFiles(request.filenames, in: draft)
        try JSONEncoder().encode(request).write(to: draft.appendingPathComponent("request.json"), options: .atomic)
        // Readers never see partially copied items or a half-written manifest.
        try FileManager.default.moveItem(at: draft, to: pendingDirectory(request.id))
    }

    public func pending() throws -> [SharedRequest] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: rootURL.appendingPathComponent("Pending"),
            includingPropertiesForKeys: nil).compactMap { directory in
                guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
                let request = try JSONDecoder().decode(SharedRequest.self,
                    from: Data(contentsOf: directory.appendingPathComponent("request.json")))
                guard request.id == id else { throw SharedInboxError.invalidRequest }
                return request
            }
    }

    public func files(for request: SharedRequest) throws -> [URL] {
        try validatedFiles(request.filenames, in: pendingDirectory(request.id))
    }

    public func acknowledge(_ id: UUID) throws {
        try FileManager.default.removeItem(at: pendingDirectory(id))
    }

    public func cancelDraft(_ id: UUID) {
        let url = rootURL.appendingPathComponent("Drafts/\(id.uuidString.lowercased())")
        try? FileManager.default.removeItem(at: url)
    }

    private func pendingDirectory(_ id: UUID) -> URL {
        rootURL.appendingPathComponent("Pending/\(id.uuidString.lowercased())", isDirectory: true)
    }

    private func prepare() throws {
        for name in ["Drafts", "Pending"] {
            try FileManager.default.createDirectory(at: rootURL.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    private func validatedFiles(_ names: [String], in directory: URL) throws -> [URL] {
        try names.map { name in
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), name != "request.json" else {
                throw SharedInboxError.invalidRequest
            }
            let url = directory.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath()
            else { throw SharedInboxError.invalidRequest }
            return url
        }
    }
}
