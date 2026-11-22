#if canImport(AVFoundation) && canImport(CoreTransferable)
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Paste in a background editor on the Mac, which reads the clipboard itself: what a drop would take.
public enum BackgroundPaste {
    /// The item to load as a drop: a copied file when it is a picture, video or Metal shader, so a copied
    /// document never pastes as the icon copied with it; else the first copied item a drop takes. Nil when
    /// nothing copied can be a background, which leaves Paste off.
    public static func item(fileURLs: [URL], providers: [NSItemProvider]) -> NSItemProvider? {
        guard fileURLs.isEmpty else { return fileURLs.first(where: isMedia).map { NSItemProvider(object: $0 as NSURL) } }
        return providers.first(where: BackgroundDrop.accepts)
    }

    static func isMedia(_ url: URL) -> Bool {
        if ShaderSourceFile.isShader(url) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return BackgroundMedia.allowedContentTypes.contains { type.conforms(to: $0) }
    }
}

/// What the system's Paste control reads for a background on iPhone and iPad, where the app does not read
/// the clipboard itself: a video, a Metal shader or a picture, kept as a file until it is prepared as a
/// dropped file is.
public final class PastedBackground: Transferable, @unchecked Sendable {
    let file: URL
    private let directory: URL

    /// The kinds of copied content Paste takes, which turn the control on.
    public static var contentTypes: [UTType] { movies.map(\.type) + [.metalShader, .image] }

    private static let movies: [(type: UTType, suffix: String)] = [
        (.quickTimeMovie, "mov"), (.mpeg4Movie, "mp4"), (UTType(filenameExtension: "m4v") ?? .mpeg4Movie, "m4v")
    ]

    private init(directory: URL, file: URL) {
        self.directory = directory
        self.file = file
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    public static var transferRepresentation: some TransferRepresentation {
        // Videos before pictures, so a poster cannot replace a copied movie.
        FileRepresentation(importedContentType: movies[0].type) { try PastedBackground(copying: $0.file, suffix: movies[0].suffix) }
        FileRepresentation(importedContentType: movies[1].type) { try PastedBackground(copying: $0.file, suffix: movies[1].suffix) }
        FileRepresentation(importedContentType: movies[2].type) { try PastedBackground(copying: $0.file, suffix: movies[2].suffix) }
        FileRepresentation(importedContentType: .metalShader) { try PastedBackground(copying: $0.file, suffix: "metal") }
        FileRepresentation(importedContentType: .image) { try PastedBackground(copying: $0.file, suffix: $0.file.pathExtension) }
        DataRepresentation(importedContentType: .image) { data in
            guard !data.isEmpty, data.count <= BackgroundDrop.maximumBytes else { throw ConversationBackgroundError.invalidMedia }
            let pasted = try PastedBackground(suffix: "")
            try data.write(to: pasted.file, options: .atomic)
            return pasted
        }
    }

    private convenience init(suffix: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-background-paste-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.init(directory: directory, file: directory.appendingPathComponent("media").appendingPathExtension(suffix))
    }

    /// The pasted file goes when its transfer ends, so it is copied while it lasts.
    private convenience init(copying source: URL, suffix: String) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= BackgroundDrop.maximumBytes else {
            throw ConversationBackgroundError.invalidMedia
        }
        try self.init(suffix: suffix)
        try FileManager.default.copyItem(at: source, to: file)
    }

    /// Checked and converted as a dropped or chosen file is, with the same messages when it can't be used.
    public func prepare() async throws -> PreparedBackgroundFile {
        try await PreparedBackgroundFile.prepare(file)
    }
}
#endif
