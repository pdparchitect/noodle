import Foundation

/// CLI-only file conveniences. The broker and remote server still exchange MCP JSON.
public enum MCPFileContent {
    public static let directory = ".noodle/mcp-attachments"

    public static func arguments(_ data: Data, workspace: URL, currentDirectory: URL) throws -> Data {
        guard data.count <= MCPBridgeFiles.maxRequestBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConnectionError.message("Tool arguments must be a JSON object no larger than 1 MiB.")
        }
        var changed = false
        var encodedFileBytes = 0
        func expand(_ value: Any) throws -> Any {
            if let string = value as? String, string.hasPrefix("@") {
                changed = true
                if string.hasPrefix("@@") { return String(string.dropFirst()) }
                let path = String(string.dropFirst())
                let relative = try ComputerWorkspaceFiles.relativePath(path, currentDirectory: currentDirectory, workspace: workspace)
                let parts = relative.split(separator: "/").filter { $0 != "." }
                let parent = parts.dropLast().joined(separator: "/")
                let file: Data
                do {
                    let folder = try WorkspaceMailbox(workspace: workspace, path: parent)
                    file = try folder.read(String(parts.last!), limit: MCPBridgeFiles.maxRequestBytes / 4 * 3)
                } catch {
                    throw MCPConnectionError.message("Cannot read MCP file reference @\(path). Use a regular workspace file without links, within the 1 MiB encoded input limit.")
                }
                let encoded = file.base64EncodedString()
                encodedFileBytes += encoded.utf8.count
                guard encodedFileBytes <= MCPBridgeFiles.maxRequestBytes else {
                    throw MCPConnectionError.message("Tool arguments exceed 1 MiB after expanding file references.")
                }
                return encoded
            }
            if let object = value as? [String: Any] { return try object.mapValues { try expand($0) } }
            if let array = value as? [Any] { return try array.map { try expand($0) } }
            return value
        }
        let expanded = try expand(object)
        guard changed else { return data }
        let result = try JSONSerialization.data(withJSONObject: expanded, options: [.sortedKeys, .withoutEscapingSlashes])
        guard result.count <= MCPBridgeFiles.maxRequestBytes else {
            throw MCPConnectionError.message("Tool arguments exceed 1 MiB after expanding file references.")
        }
        return result
    }

    /// Replace only protocol-defined binary blocks; structuredContent and links are opaque.
    /// Validate every block before writing, and roll back this invocation's files on failure.
    public static func result(_ data: Data, workspace: URL, callID: UUID, raw: Bool = false,
                              resourceRead: Bool = false) throws -> Data {
        guard data.count <= MCPBridgeFiles.maxResultBytes else {
            throw MCPConnectionError.message("MCP result exceeds 8 MiB.")
        }
        if raw { return data }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPConnectionError.message("Invalid MCP result.")
        }
        let key = resourceRead ? "contents" : "content"
        guard var content = object[key] as? [[String: Any]] else { return data }
        var files: [(index: Int, data: Data, mimeType: String, sourceType: String)] = []
        for (index, block) in content.enumerated() {
            let type = resourceRead ? "resource" : block["type"] as? String
            let resource = resourceRead ? block : block["resource"] as? [String: Any]
            let encoded: Any?
            let mime: Any?
            switch type {
            case "image", "audio": encoded = block["data"]; mime = block["mimeType"]
            case "resource":
                guard resource?["blob"] != nil else { continue }
                encoded = resource?["blob"]; mime = resource?["mimeType"]
            default: continue
            }
            guard let encoded = encoded as? String, let decoded = Data(base64Encoded: encoded) else {
                throw MCPConnectionError.message("Invalid base64 in MCP content item \(index + 1).")
            }
            files.append((index, decoded, mime as? String ?? "application/octet-stream", type!))
        }
        guard !files.isEmpty else { return data }
        let parent = try WorkspaceMailbox(workspace: workspace, path: directory, create: true)
        let name = callID.uuidString.lowercased()
        let folder = try WorkspaceMailbox(workspace: workspace, path: directory + "/" + name, create: true)
        var written: [String] = []
        do {
            for file in files {
                let filename = String(format: "%03d", file.index + 1) + "." + fileExtension(for: file.mimeType)
                try folder.writeNewData(file.data, named: filename)
                written.append(filename)
                var block = content[file.index]
                if file.sourceType == "resource", !resourceRead {
                    var resource = block["resource"] as! [String: Any]
                    resource.removeValue(forKey: "blob")
                    block["resource"] = resource
                } else {
                    block.removeValue(forKey: resourceRead ? "blob" : "data")
                }
                block["type"] = "file"
                block["sourceType"] = file.sourceType
                block["path"] = folder.url.appendingPathComponent(filename).path
                block["mimeType"] = file.mimeType
                block["bytes"] = file.data.count
                content[file.index] = block
            }
            object[key] = content
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            for filename in written { folder.remove(filename) }
            parent.removeEmptyDirectory(name)
            throw error
        }
    }

    private static func fileExtension(for mimeType: String) -> String {
        let mime = mimeType.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        // UniformTypeIdentifiers can require a LaunchServices lookup that a harness
        // sandbox denies. Keep common types deterministic without extra permissions.
        return extensions[mime] ?? "bin"
    }

    private static let extensions = [
        "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
        "image/avif": "avif", "image/heic": "heic", "image/heif": "heif", "image/tiff": "tiff",
        "image/bmp": "bmp", "image/svg+xml": "svg", "image/x-icon": "ico",
        "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav", "audio/vnd.wave": "wav",
        "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a", "audio/aac": "aac",
        "audio/ogg": "ogg", "audio/opus": "opus", "audio/flac": "flac", "audio/x-flac": "flac",
        "audio/webm": "webm", "audio/aiff": "aiff", "audio/x-aiff": "aiff",
        "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov", "video/mpeg": "mpeg",
        "application/pdf": "pdf", "application/zip": "zip", "application/gzip": "gz",
        "application/x-tar": "tar", "application/json": "json", "application/xml": "xml",
        "application/rtf": "rtf", "application/msword": "doc", "application/vnd.ms-excel": "xls",
        "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "text/plain": "txt", "text/csv": "csv", "text/html": "html", "text/markdown": "md"
    ]
}
