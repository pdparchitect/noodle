import CoreGraphics
import Foundation

/// A companion's side of its live views: while anyone watches, it captures the surface at a
/// steady rate, encodes each picture and pushes it to every viewer at once. A viewer that falls
/// behind misses frames instead of getting old ones late, and picks up again at the next key
/// frame. What viewers do comes back on their sockets and reaches the surface in order.
@MainActor public final class SurfaceStreamer {
    private struct Viewer {
        let socket: SurfaceSocket
        var fit: CGSize?
        /// Skipping frames until a key frame, as a new viewer and one that fell behind do.
        var waiting = true
    }

    /// Frames a viewer may have queued before it counts as behind.
    private static let behind = 3

    private let capture: @MainActor () async throws -> (image: CGImage, size: CGSize)?
    private let apply: @MainActor (SurfaceInput) async throws -> Void
    private let encoder: SurfaceEncoder
    private let interval: Duration
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var sequence: UInt64 = 0
    private var loop: Task<Void, Never>?
    private var wantsKeyFrame = false

    public init(fps: Int = 30, maxPixelSize: Int = 1600,
                capture: @escaping @MainActor () async throws -> (image: CGImage, size: CGSize)?,
                apply: @escaping @MainActor (SurfaceInput) async throws -> Void) {
        self.capture = capture
        self.apply = apply
        encoder = SurfaceEncoder(maxPixelSize: maxPixelSize, fps: Int32(fps))
        interval = .milliseconds(1000 / max(1, fps))
    }

    /// Someone is watching, which keeps bots off the surface until they leave.
    public var isWatched: Bool { !viewers.isEmpty }

    /// Starts pushing video to `socket` and taking its viewer's controls, until either side closes it.
    public func attach(_ socket: SurfaceSocket) {
        let id = ObjectIdentifier(socket)
        viewers[id] = Viewer(socket: socket)
        wantsKeyFrame = true
        if loop == nil { start() }
        Task { [weak self] in
            for await frame in socket.frames {
                guard let control = SurfaceControl(frame) else { continue }
                await self?.handle(control, from: id)
            }
            self?.viewers[id] = nil
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        viewers.values.forEach { $0.socket.close() }
        viewers = [:]
    }

    private func handle(_ control: SurfaceControl, from id: ObjectIdentifier) async {
        switch control {
        case .input(let input):
            try? await apply(input)
        case .view(let width, let height):
            viewers[id]?.fit = CGSize(width: width, height: height)
        case .keyFrame:
            viewers[id]?.waiting = true
            wantsKeyFrame = true
        }
    }

    private func start() {
        loop = Task { [weak self] in
            while let self, !Task.isCancelled, self.isWatched {
                await self.step()
                try? await Task.sleep(for: self.interval)
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

    private func step() async {
        guard let picture = try? await capture(),
              let encoded = try? encoder.encode(picture.image, size: picture.size, keyFrame: wantsKeyFrame, fitting: fit) else { return }
        if encoded.keyFrame { wantsKeyFrame = false }
        sequence += 1
        let packet = SurfacePacket(sequence: sequence, keyFrame: encoded.keyFrame, width: picture.size.width, height: picture.size.height,
                                   parameterSets: encoded.parameterSets, sample: encoded.sample)
        let frame = SurfacePacket.encode([packet])
        for (id, viewer) in viewers {
            if viewer.waiting, !packet.keyFrame { continue }
            if viewer.socket.pending >= Self.behind {
                viewers[id]?.waiting = true
                wantsKeyFrame = true
                continue
            }
            viewers[id]?.waiting = false
            viewer.socket.send(frame)
        }
    }
}
