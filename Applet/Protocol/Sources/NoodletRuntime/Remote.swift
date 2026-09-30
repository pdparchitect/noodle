import Foundation
import NoodletFormat

/// The data and secrets of a noodlet kept on another Mac, such as a Hub: each call goes there,
/// in pieces small enough for one request each.
public struct RemoteNoodletStore: NoodletStore {
    /// Sends one piece of the encoded call `id`, starting at `offset` of `total` bytes; the last
    /// piece answers with the encoded `NoodletValue`.
    public typealias Send = @Sendable (_ id: UUID, _ offset: Int, _ total: Int, _ piece: Data) async throws -> Data?
    public static let pieceSize = 512 * 1024
    private let send: Send

    public init(send: @escaping Send) { self.send = send }

    public func perform(_ call: NoodletStoreCall) async throws -> NoodletValue {
        let data = try JSONEncoder().encode(call)
        let id = UUID()
        var offset = 0
        var answer: Data?
        while offset < data.count {
            let piece = data.subdata(in: offset..<min(data.count, offset + Self.pieceSize))
            answer = try await send(id, offset, data.count, piece)
            offset += piece.count
        }
        guard let answer else { throw AppletError("The noodlet's data did not answer.") }
        return try JSONDecoder().decode(NoodletValue.self, from: answer)
    }
}

/// Noodlets another Mac sent, kept on this device by revision: each is fetched once, and again
/// only when its files change. Older revisions go once a newer one is in.
public struct NoodletCache: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The noodlet's folder at `revision`, fetching its archive piece by piece from `offset` when
    /// this device does not have it yet.
    public func package(_ id: UUID, revision: String, byteCount: Int,
                        fetch: @Sendable (_ offset: Int) async throws -> Data) async throws -> URL {
        guard !revision.isEmpty, revision.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw AppletError("The noodlet arrived damaged.")
        }
        let fm = FileManager.default
        let folder = root.appendingPathComponent(id.uuidString.lowercased())
        let package = folder.appendingPathComponent(revision)
        if !fm.fileExists(atPath: package.appendingPathComponent("noodlet.json").path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let download = folder.appendingPathComponent(".\(UUID().uuidString)")
            defer { try? fm.removeItem(at: download) }
            fm.createFile(atPath: download.path, contents: nil)
            let output = try FileHandle(forWritingTo: download)
            var received = 0
            do {
                while received < byteCount {
                    let data = try await fetch(received)
                    guard !data.isEmpty else { throw AppletError("The noodlet arrived incomplete.") }
                    try output.write(contentsOf: data)
                    received += data.count
                }
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            try NoodletArchive.extract(download, to: package)
        }
        for old in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where old != revision && !old.hasPrefix(".") {
            try? fm.removeItem(at: folder.appendingPathComponent(old))
        }
        return package
    }
}

/// Where the person last chose to run each noodlet, on this device.
public struct NoodletPlaces {
    public var defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func chosen(_ noodlet: UUID) -> NoodletManifest.Placement? {
        defaults.string(forKey: key(noodlet)).flatMap(NoodletManifest.Placement.init(rawValue:))
    }

    public func choose(_ place: NoodletManifest.Placement, for noodlet: UUID) {
        defaults.set(place.rawValue, forKey: key(noodlet))
    }

    private func key(_ noodlet: UUID) -> String { "noodletPlace." + noodlet.uuidString.lowercased() }
}
