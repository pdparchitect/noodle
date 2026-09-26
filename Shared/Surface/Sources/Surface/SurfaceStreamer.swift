import CoreGraphics
import Foundation

/// A companion's side of one live view: while someone reads from it, it captures the surface
/// at a steady rate, encodes each picture, and keeps what a reader has not taken yet. Reading
/// is also the watcher's lease: a surface counts as watched until reads stop, so bots can be
/// kept off it without anyone having to say they left.
@MainActor public final class SurfaceStreamer {
    private let lease: Duration
    private let capture: @MainActor () async throws -> (image: CGImage, size: CGSize)?
    private let encoder: SurfaceEncoder
    private let interval: Duration
    private var packets: [SurfacePacket] = []
    private var sequence: UInt64 = 0
    private var readAt: ContinuousClock.Instant?
    private var loop: Task<Void, Never>?
    private var wantsKeyFrame = false
    /// Why the last capture failed, for the next read to report.
    private var failure: Error?

    /// `lease` is how long a surface stays watched after its last read.
    public init(fps: Int = 30, maxPixelSize: Int = 1600, lease: Duration = .seconds(3),
                capture: @escaping @MainActor () async throws -> (image: CGImage, size: CGSize)?) {
        self.lease = lease
        self.capture = capture
        encoder = SurfaceEncoder(maxPixelSize: maxPixelSize, fps: Int32(fps))
        interval = .milliseconds(1000 / max(1, fps))
    }

    /// Someone is watching: they read within the lease.
    public var isWatched: Bool {
        guard let readAt else { return false }
        return ContinuousClock.now - readAt < lease
    }

    /// The packets after `sequence`, starting at the latest key frame for a new reader (0) or one
    /// that fell too far behind. Starts capturing if nothing is.
    public func read(after sequence: UInt64) throws -> [SurfacePacket] {
        readAt = .now
        if loop == nil { start() }
        if let failure { self.failure = nil; throw failure }
        guard let first = packets.first else { return [] }
        // Anyone without the frames just before these has to start again at the key frame.
        if sequence == 0 || sequence + 1 < first.sequence || sequence > packets.last!.sequence {
            return Array(packets[(packets.lastIndex(where: \.keyFrame) ?? 0)...])
        }
        return packets.filter { $0.sequence > sequence }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        packets = []
    }

    private func start() {
        wantsKeyFrame = true
        loop = Task { [weak self] in
            while let self, !Task.isCancelled, self.isWatched {
                await self.step()
                try? await Task.sleep(for: self.interval)
            }
            self?.loop = nil
            self?.packets = []
        }
    }

    private func step() async {
        do {
            guard let picture = try await capture(),
                  let encoded = try encoder.encode(picture.image, size: picture.size, keyFrame: wantsKeyFrame) else { return }
            wantsKeyFrame = false
            sequence += 1
            let packet = SurfacePacket(sequence: sequence, keyFrame: encoded.keyFrame, width: picture.size.width, height: picture.size.height,
                                       parameterSets: encoded.parameterSets, sample: encoded.sample)
            // Keep one group of pictures: from the latest key frame on.
            if packet.keyFrame { packets = [packet] } else { packets.append(packet) }
            if packets.count > 120 { packets.removeFirst(packets.count - 120) }
        } catch {
            failure = error
        }
    }
}
