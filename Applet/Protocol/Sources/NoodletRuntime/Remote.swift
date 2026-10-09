import Foundation
import NoodletFormat
import SwiftUI

/// The data and secrets of a noodlet kept on another Mac, such as a Hub: each call goes there,
/// in pieces small enough for one request each.
public struct RemoteNoodletStore: NoodletStore {
    /// Sends one piece of the encoded call `id`, starting at `offset` of `total` bytes; the last
    /// piece answers with the encoded `NoodletValue`.
    public typealias Send = @Sendable (_ id: UUID, _ offset: Int, _ total: Int, _ piece: Data) async throws -> Data?
    /// Given why a call failed, regains access to the other Mac if it lost track of this device:
    /// whether it did, so the call goes again from its first piece.
    public typealias Renew = @Sendable (Error) async throws -> Bool
    public static let pieceSize = 512 * 1024
    private let send: Send
    private let renew: Renew

    public init(send: @escaping Send, renew: @escaping Renew = { _ in false }) {
        self.send = send
        self.renew = renew
    }

    public func perform(_ call: NoodletStoreCall) async throws -> NoodletValue {
        let data = try JSONEncoder().encode(call)
        do {
            return try await perform(data)
        } catch {
            guard try await renew(error) else { throw error }
            return try await perform(data)
        }
    }

    private func perform(_ data: Data) async throws -> NoodletValue {
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

/// How far a noodlet from another Mac has come: its archive arriving, then unpacking.
public enum NoodletArrival: Equatable, Sendable {
    case downloading(received: Int, total: Int)
    case unpacking
}

/// What a noodlet waits on before its page shows: the Hub preparing it, its files arriving on this
/// device and unpacking, then its page starting.
public struct NoodletLoadingView: View {
    public enum Stage: Equatable, Sendable {
        case preparing
        case arriving(NoodletArrival)
        case starting
    }

    var stage: Stage
    /// How long the last piece took to arrive: the bar moves to each next one over as long, so it
    /// glides rather than jumping a piece at a time.
    @State private var pace = 0.25
    @State private var lastPiece = Date.now
    /// The size of the last download, still shown while it unpacks.
    @State private var size = 0

    public init(_ stage: Stage) { self.stage = stage }

    public var body: some View {
        // The same three lines at every step, so nothing moves as the steps change.
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            NoodletProgressBar(fraction: downloading.map { Double($0.received) / Double(max($0.total, 1)) }, pace: pace)
            Text(detail).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(width: 240, alignment: .leading)
        .padding(20)
        // Readable over whatever colour the noodlet asked for.
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .padding()
        .onChange(of: downloading?.received) {
            pace = min(max(Date.now.timeIntervalSince(lastPiece), 0.05), 1)
            lastPiece = .now
            if let total = downloading?.total { size = total }
        }
    }

    private var title: String {
        switch stage {
        case .preparing: "Preparing on Hub"
        case .arriving(.downloading): "Downloading"
        case .arriving(.unpacking): "Unpacking"
        case .starting: "Starting"
        }
    }

    private var detail: String {
        switch stage {
        case .preparing: "Packing its files"
        case .arriving(.downloading(let received, let total)): "\(Self.size(received)) of \(Self.size(total))"
        case .arriving(.unpacking): size > 0 ? Self.size(size) : "Unpacking its files"
        case .starting: "Opening its page"
        }
    }

    private var downloading: (received: Int, total: Int)? {
        if case .arriving(.downloading(let received, let total)) = stage { (received, total) } else { nil }
    }

    /// Megabytes with one decimal always, so the count keeps its width as it grows.
    private static func size(_ bytes: Int) -> String {
        (Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(1)).grouping(.never)) + " MB"
    }
}

/// A thin bar: filled to `fraction` and gliding there over `pace`, or with a band sweeping across
/// while there is no fraction to show. The same size either way.
struct NoodletProgressBar: View {
    var fraction: Double?
    var pace: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let fraction {
                    Capsule().fill(.tint)
                        .frame(width: width * min(max(fraction, 0), 1))
                        .animation(.linear(duration: pace), value: fraction)
                } else {
                    TimelineView(.animation) { time in
                        let phase = time.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule().fill(.tint)
                            .frame(width: width * 0.3)
                            .offset(x: -width * 0.3 + phase * width * 1.3)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}

/// Noodlets another Mac sent, kept on this device by revision: each is fetched once, and again
/// only when its files change. Older revisions go once a newer one is in.
public struct NoodletCache: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The noodlet's folder at `revision`, fetching its archive piece by piece from `offset` when
    /// this device does not have it yet, and telling `progress` how far it has come.
    public func package(_ id: UUID, revision: String, byteCount: Int,
                        progress: @Sendable (NoodletArrival) -> Void = { _ in },
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
                progress(.downloading(received: 0, total: byteCount))
                while received < byteCount {
                    let data = try await fetch(received)
                    guard !data.isEmpty else { throw AppletError("The noodlet arrived incomplete.") }
                    try output.write(contentsOf: data)
                    received += data.count
                    progress(.downloading(received: received, total: byteCount))
                }
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            progress(.unpacking)
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
