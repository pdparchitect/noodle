import CoreGraphics
import Foundation

/// A companion's side of its live views: while anyone watches, it captures the surface on a
/// steady beat, encodes each picture away from the main thread while the next is captured, and
/// pushes it to every viewer at once. A beat that comes while the encoder is still busy is skipped. A viewer that falls
/// behind misses frames instead of getting old ones late, and picks up again at the next key
/// frame, or at a much smaller recovery frame when it says what it has shown. What viewers do
/// comes back on their sockets and reaches the surface in order. Once
/// the picture settles it is looked at only a few times a second, until it changes or a viewer
/// does something.
@MainActor public final class SurfaceStreamer {
    private struct Viewer {
        let socket: SurfaceSocket
        var fit: CGSize?
        /// Skipping frames until a key frame, as a new viewer and one that fell behind do.
        var waiting = true
        /// Bits per second the viewer's link takes, once it has said.
        var rate: Double?
        /// The last frame the viewer has shown, once it has said.
        var shown: UInt64?
    }

    /// Frames a viewer may have queued before it counts as behind.
    private static let behind = 3

    private let capture: @MainActor () async throws -> (image: CGImage, size: CGSize)?
    private let apply: @MainActor (SurfaceInput) async throws -> Void
    private let encoder: EncoderQueue
    private let fps: Int
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var sequence: UInt64 = 0
    private var loop: Task<Void, Never>?
    private var wantsKeyFrame = false
    private var wantsRecovery = false
    /// Frames since the last key frame that not every viewer has shown yet, and the last one they all have.
    private var unacknowledged: [(sequence: UInt64, token: Int)] = []
    private var acknowledged: UInt64 = 0
    private var encoding = false
    /// The picture had stayed the same long enough that the encoder sent nothing for it.
    private var settled = false
    private var lastCapture: ContinuousClock.Instant?
    private struct FileWait {
        var viewer: ObjectIdentifier
        var continuation: CheckedContinuation<(names: [String], bodies: [Data])?, Never>
        var files = 0
        var names: [Int: String] = [:]
        var partCounts: [Int: Int] = [:]
        var parts: [Int: [Int: Data]] = [:]
    }
    /// A file request, answered only by the viewer who clicked.
    private var fileWaits: [UUID: FileWait] = [:]
    /// The viewer whose latest click has not yet asked for a file.
    private var fileViewer: ObjectIdentifier?
    /// What capture times count from.
    private let began = ContinuousClock.now
    /// Full pace until then, as after a viewer arrives or acts: what they did takes a few frames to show.
    private var busyUntil = ContinuousClock.now
    /// How often a settled picture is looked at, and how long full pace lasts after a viewer acts.
    private static let settledInterval = Duration.milliseconds(100)
    private static let busyAfterAction = Duration.seconds(1)

    public init(fps: Int = 60, maxPixelSize: Int = 1600,
                capture: @escaping @MainActor () async throws -> (image: CGImage, size: CGSize)?,
                apply: @escaping @MainActor (SurfaceInput) async throws -> Void) {
        self.capture = capture
        self.apply = apply
        encoder = EncoderQueue(SurfaceEncoder(maxPixelSize: maxPixelSize, fps: Int32(fps)))
        self.fps = fps
    }

    /// Someone is watching, which keeps bots off the surface until they leave.
    public var isWatched: Bool { !viewers.isEmpty }

    /// Asks the viewer who clicked to choose files, and waits until they do, they cancel, or they leave.
    public func requestFiles(multiple: Bool, directories: Bool) async -> (names: [String], bodies: [Data])? {
        guard let viewer = fileViewer, let socket = viewers[viewer]?.socket else { return nil }
        fileViewer = nil
        let id = UUID()
        let ask = SurfaceFileAsk(id: id, multiple: multiple, directories: directories).encoded
        return await withCheckedContinuation { continuation in
            fileWaits[id] = FileWait(viewer: viewer, continuation: continuation)
            guard socket.send(ask) else { finishFiles(id, with: nil); return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                self?.finishFiles(id, with: nil)
            }
        }
    }

    private func finishFiles(_ id: UUID, with files: (names: [String], bodies: [Data])?) {
        fileWaits.removeValue(forKey: id)?.continuation.resume(returning: files)
    }

    /// Why the surface shows nothing new, which viewers are told as they arrive and as it changes.
    public var notice: SurfaceNotice? {
        didSet {
            guard notice != oldValue else { return }
            let status = SurfaceStatus(notice: notice).encoded
            viewers.values.forEach { $0.socket.send(status) }
        }
    }

    /// Told when the first viewer arrives and when the last one leaves.
    public var watchingChanged: (@MainActor (Bool) -> Void)?

    /// Starts pushing video to `socket` and taking its viewer's controls, until either side closes it.
    public func attach(_ socket: SurfaceSocket) {
        let id = ObjectIdentifier(socket)
        let first = viewers.isEmpty
        viewers[id] = Viewer(socket: socket)
        if notice != nil { socket.send(SurfaceStatus(notice: notice).encoded) }
        wantsKeyFrame = true
        wake()
        if first { watchingChanged?(true) }
        if loop == nil { start() }
        Task { [weak self] in
            for await frame in socket.frames {
                guard let control = SurfaceControl(frame) else { continue }
                await self?.handle(control, from: id)
            }
            self?.leave(id)
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        viewers.values.forEach { $0.socket.close() }
        let watched = isWatched
        viewers = [:]
        if watched { watchingChanged?(false) }
    }

    private func leave(_ id: ObjectIdentifier) {
        guard viewers.removeValue(forKey: id) != nil else { return }
        if fileViewer == id { fileViewer = nil }
        for ask in fileWaits.filter({ $0.value.viewer == id }).map(\.key) { finishFiles(ask, with: nil) }
        encoder.setBitRate(rate)
        if viewers.isEmpty {
            watchingChanged?(false)
            let pending = Array(fileWaits.keys)
            pending.forEach { finishFiles($0, with: nil) }
        }
    }

    private func handle(_ control: SurfaceControl, from id: ObjectIdentifier) async {
        switch control {
        case .input(let input):
            if case .pointer(.down, _, _, _) = input { fileViewer = id }
            wake()
            try? await apply(input)
        case .view(let width, let height):
            viewers[id]?.fit = CGSize(width: width, height: height)
        case .keyFrame:
            viewers[id]?.waiting = true
            wantsKeyFrame = true
            wake()
        case .rate(let bitsPerSecond):
            viewers[id]?.rate = bitsPerSecond
            encoder.setBitRate(rate)
        case .shown(let sequence):
            let before = viewers[id]?.shown ?? 0
            viewers[id]?.shown = max(before, sequence)
            acknowledgeShown()
        case .recover:
            viewers[id]?.waiting = true
            if viewers[id]?.shown != nil { wantsRecovery = true } else { wantsKeyFrame = true }
            wake()
        case .files(let fileID, let names, let bodies):
            guard fileWaits[fileID]?.viewer == id else { return }
            guard names.count == bodies.count else { finishFiles(fileID, with: nil); return }
            finishFiles(fileID, with: (names, bodies))
        case .filePart(let fileID, let file, let files, let part, let parts, let name, let body):
            acceptFilePart(fileID, from: id, file: file, files: files, part: part, parts: parts, name: name, body: body)
        }
    }

    private func acceptFilePart(_ id: UUID, from viewer: ObjectIdentifier, file: Int, files: Int, part: Int, parts: Int, name: String, body: Data) {
        guard var wait = fileWaits[id], wait.viewer == viewer else { return }
        guard files > 0, parts > 0, file >= 0, file < files, part >= 0, part < parts else { finishFiles(id, with: nil); return }
        if wait.files == 0 { wait.files = files }
        guard wait.files == files else { finishFiles(id, with: nil); return }
        if let count = wait.partCounts[file], count != parts { finishFiles(id, with: nil); return }
        wait.partCounts[file] = parts
        if let previous = wait.names[file], previous != name { finishFiles(id, with: nil); return }
        wait.names[file] = name
        var received = wait.parts[file] ?? [:]
        if let previous = received[part], previous != body { finishFiles(id, with: nil); return }
        received[part] = body
        wait.parts[file] = received
        fileWaits[id] = wait
        guard wait.partCounts.count == files, wait.parts.allSatisfy({ $0.value.count == (wait.partCounts[$0.key] ?? -1) }) else { return }
        var names: [String] = []
        var bodies: [Data] = []
        for index in 0..<files {
            guard let fileName = wait.names[index], let expected = wait.partCounts[index], let chunks = wait.parts[index], chunks.count == expected else {
                finishFiles(id, with: nil); return
            }
            var body = Data()
            for number in 0..<expected {
                guard let chunk = chunks[number] else { finishFiles(id, with: nil); return }
                body.append(chunk)
            }
            names.append(fileName)
            bodies.append(body)
        }
        finishFiles(id, with: (names, bodies))
    }

    /// Tells the encoder which frames every viewer that says what it has shown has shown, so
    /// recovery frames are built only on those.
    private func acknowledgeShown() {
        guard let shown = viewers.values.compactMap(\.shown).min(), shown > acknowledged else { return }
        let due = unacknowledged.filter { $0.sequence <= shown }.map(\.token)
        unacknowledged.removeAll { $0.sequence <= shown }
        acknowledged = shown
        encoder.acknowledge(due)
    }

    private func start() {
        loop = Task { [weak self, fps] in
            var pacer = SurfacePacer(fps: fps)
            let start = ContinuousClock.now
            while let self, !Task.isCancelled, self.isWatched {
                await self.step()
                let due = pacer.next(after: (ContinuousClock.now - start) / .seconds(1))
                try? await Task.sleep(until: start + .seconds(due), clock: .continuous)
            }
            self?.loop = nil
        }
    }

    /// The largest window any viewer shows the surface in, or none when one has not said.
    private var fit: CGSize? {
        let fits = viewers.values.map(\.fit)
        guard !fits.isEmpty, fits.allSatisfy({ $0 != nil }) else { return nil }
        return fits.compactMap { $0 }.reduce(.zero) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
    }

    /// One encoding serves every viewer, so it goes at the pace of the slowest link.
    private var rate: Double? { viewers.values.compactMap(\.rate).min() }

    private func wake() {
        settled = false
        busyUntil = .now + Self.busyAfterAction
    }

    private func step() async {
        let now = ContinuousClock.now
        if settled, !wantsKeyFrame, !wantsRecovery, now >= busyUntil, let lastCapture, now - lastCapture < Self.settledInterval { return }
        guard !encoding else { return }
        lastCapture = now
        guard let picture = try? await capture() else { return }
        let taken = (ContinuousClock.now - began) / .seconds(1)
        let keyFrame = wantsKeyFrame, recover = wantsRecovery && !wantsKeyFrame
        (wantsKeyFrame, wantsRecovery) = (false, false)
        // A recovery frame is built on frames up to this one, which viewers need to have shown.
        let base = acknowledged
        encoding = true
        Task {
            let (encoded, settled) = await encoder.encode(picture.image, size: picture.size, keyFrame: keyFrame, fitting: fit,
                                                          at: taken, recover: recover)
            encoding = false
            self.settled = settled
            if let encoded { send(encoded, size: picture.size, base: base) }
            else if keyFrame { wantsKeyFrame = true }
            else if recover { wantsRecovery = true }
        }
    }

    private func send(_ encoded: SurfaceEncoder.Frame, size: CGSize, base: UInt64) {
        sequence += 1
        if encoded.keyFrame { (unacknowledged, acknowledged) = ([], 0) }
        if let token = encoded.token { unacknowledged.append((sequence, token)) }
        var packet = SurfacePacket(sequence: sequence, keyFrame: encoded.keyFrame, recoverable: !encoded.keyFrame, width: size.width,
                                   height: size.height, parameterSets: encoded.parameterSets, sample: encoded.sample)
        let frame = SurfacePacket.encode([packet])
        packet.recovery = true
        let recovery = SurfacePacket.encode([packet])
        for (id, viewer) in viewers {
            let recovers = encoded.recovery && (viewer.shown ?? 0) >= base && viewer.shown != nil
            if viewer.waiting, !encoded.keyFrame, !recovers { continue }
            if viewer.socket.pending >= Self.behind {
                viewers[id]?.waiting = true
                if viewer.shown != nil { wantsRecovery = true } else { wantsKeyFrame = true }
                continue
            }
            viewers[id]?.waiting = false
            viewer.socket.send(recovers ? recovery : frame)
        }
    }
}

/// The encoder on a queue of its own, so encoding a frame never holds the main thread.
/// Nothing touches the encoder except on that queue.
private final class EncoderQueue: @unchecked Sendable {
    private let encoder: SurfaceEncoder
    private let queue = DispatchQueue(label: "com.pdparchitect.noodle.surface-encoder", qos: .userInteractive)

    init(_ encoder: SurfaceEncoder) { self.encoder = encoder }

    /// The frame, if any, and whether the picture has settled. A frame can also be missing because
    /// the encoder dropped it to keep to the rate, which says nothing about the picture.
    func encode(_ image: CGImage, size: CGSize, keyFrame: Bool,
                fitting: CGSize?, at time: Double, recover: Bool) async -> (frame: SurfaceEncoder.Frame?, settled: Bool) {
        await withCheckedContinuation { done in
            queue.async { [self] in
                let frame = try? encoder.encode(image, size: size, keyFrame: keyFrame, fitting: fitting, at: time, recover: recover)
                done.resume(returning: (frame ?? nil, encoder.isSettled))
            }
        }
    }

    func acknowledge(_ tokens: [Int]) {
        queue.async { [self] in encoder.acknowledge(tokens) }
    }

    func setBitRate(_ bitRate: Double?) {
        queue.async { [self] in encoder.bitRate = bitRate }
    }
}
