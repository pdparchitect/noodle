import Foundation

/// How fast one viewer's video may go, worked out from what it has not received yet. Video
/// sent faster than the link carries waits in line and arrives late, so as soon as frames start
/// queueing the rate drops to what the link drains, and while the line stays empty it climbs
/// back. A viewer too far behind for that skips ahead to the next key frame instead.
///
/// It keeps no clock and does no I/O: callers say what time it is and how much is waiting, or
/// what the viewer has said it has shown.
public struct SurfaceFlow: Sendable {
    public enum Decision: Equatable, Sendable {
        case send
        /// Not this frame: the viewer is waiting for a key frame.
        case skip
        /// The viewer is too far behind and misses this frame, so it needs a key frame to go on.
        case skipUntilKeyFrame
    }

    /// Bits per second the encoder should aim for.
    public private(set) var bitRate: Double
    private let range: ClosedRange<Double>
    private var sent = 0
    private var last: (time: Double, delivered: Int, backlog: Int)?
    /// Bits per second the link carried while it had something to carry.
    private var drain: Double?
    /// What had been sent at the last cut.
    private var cutMark = 0
    private var waiting = false
    /// Climbing fast until the link first fills, as a new view does: it starts below what most
    /// links carry, so its first second is not spent behind video the link cannot take.
    private var starting = true
    /// A frame to go on from has been asked for and not come or been skipped since, and when.
    private var asked = false
    private var askedAt = 0.0
    /// How long an answer may take before it is asked for again, as when the companion lost it.
    private static let patience = 1.0
    /// Sending less for a moment so the line empties and the shortest round trip shows again,
    /// the rate to go back to, and the lowest the line called for meanwhile.
    private var draining: (until: Double, rate: Double, cut: Double)?
    /// Whether what was delivered came from what the viewer says it has shown.
    private var confirmed = false
    /// The first drain, once the viewer's first word has come.
    private var drained = false
    private var began: Double?
    /// Bytes of the first frame, which with a little more is all that goes before the viewer's first
    /// word, and of the frame sent last.
    private var opening: Int?
    private var lastSent = 0
    /// What may go before the viewer's first word besides the first frame: a slow link would
    /// otherwise fill with seconds of video before anything shows how slow it is.
    private static let window = 32_000
    /// How long to wait for a viewer's first word before taking it for one that never says.
    private static let silence = 1.0

    /// Waiting longer than this means the link is full.
    private static let congested = 0.05
    /// Waiting less than this means there is room.
    private static let clear = 0.01
    /// Waiting longer than this is too late to show, so the viewer skips ahead.
    private static let tooLate = 0.25

    public init(bitRate: Double, range: ClosedRange<Double>) {
        self.range = range
        self.bitRate = bitRate.clamped(to: range)
    }

    public var isDraining: Bool { draining != nil }

    /// Whether to send a frame of `bytes` now, learning of the link from what the viewer says it
    /// has shown, when it says, as well as from `pending`, the bytes not yet taken by the network.
    /// Until the viewer's first word it does not climb, and it drains the line once then and
    /// whenever the shortest round trip has not been seen for a while, since a line that never
    /// empties hides how long it is.
    mutating func admit(bytes: Int, keyFrame: Bool, pending: Int, delivery: SurfaceDelivery, now: Double) -> Decision {
        began = began ?? now
        // A viewer that will say what it shows is waited for; any other is sent to as it always was.
        let confirms = delivery.confirms, heardOrGaveUp = confirms || !delivery.announced || now - began! > Self.silence
        if !heardOrGaveUp, let opening, delivery.unshownBytes + bytes > opening + Self.window {
            // Skipped frames leave the viewer needing one to go on from, asked for once it has spoken.
            if !waiting { (waiting, asked) = (true, false) }
            return .skip
        }
        if confirms, draining == nil, !drained || delivery.fastestAge(at: now) > SurfaceDelivery.memory {
            drained = true
            delivery.beginProbe()
            drainLine(until: now + min(0.5, max(0.2, 2 * delivery.fastestTrip)))
        }
        // What the network stack has not taken shows a full link first, but the frame sent just
        // before is often still in it, which says nothing about the link.
        let backlog = delivery.announced ? max(delivery.late(at: now), pending - lastSent) : pending
        let decision = admit(bytes: bytes, keyFrame: keyFrame, backlog: backlog,
                             delivered: confirms ? delivery.delivered : nil, climb: heardOrGaveUp, now: now)
        if decision == .send {
            opening = opening ?? bytes
            lastSent = bytes
        }
        if draining == nil, delivery.isProbing { delivery.endProbe(at: now) }
        return decision
    }

    /// Sends half as much until `until`, then goes back to the rate before, or lower if the line called for it.
    mutating func drainLine(until: Double) {
        guard draining == nil else { return }
        draining = (until, bitRate, bitRate)
        bitRate = (bitRate / 2).clamped(to: range)
    }

    /// Whether to send a frame of `bytes` now, with `backlog` bytes sent before still on their way,
    /// and `delivered` bytes through, when that is known better than from what was sent.
    public mutating func admit(bytes: Int, keyFrame: Bool, backlog: Int, delivered known: Int? = nil, climb: Bool = true,
                               now: Double) -> Decision {
        if let draining, now >= draining.until {
            bitRate = min(draining.rate, draining.cut)
            self.draining = nil
        }
        // Counting what got through another way starts the count again.
        if (known != nil) != confirmed { (confirmed, last) = (known != nil, nil) }
        let delivered = known ?? sent - backlog
        let elapsed = last.map { now - $0.time } ?? 0
        if let last, elapsed > 0, last.backlog > 0 {
            // Only a busy link shows how fast it goes; an idle one only shows how fast video came.
            let carried = Double(delivered - last.delivered) * 8 / elapsed
            drain = drain.map { $0 * 0.8 + carried * 0.2 } ?? carried
        }
        last = (now, delivered, backlog)
        let speed = max(drain ?? bitRate, range.lowerBound)
        let delay = Double(backlog) * 8 / speed
        // Frames already in line say nothing new about the link, so one cut holds until they are through.
        if delivered >= cutMark {
            if delay > Self.congested {
                // Below what the link carries, by enough to clear the line in half a second.
                let target = max(speed - Double(backlog) * 8 / 0.5, speed / 2)
                bitRate = min(bitRate, target).clamped(to: range)
                if let cut = draining?.cut { draining?.cut = min(cut, target) }
                cutMark = sent
                starting = false
            } else if delay > Self.clear, bitRate > speed * 0.9 {
                // A line starting to form: stay under the link, with room for the next key frame.
                bitRate = (speed * 0.9).clamped(to: range)
                if let cut = draining?.cut { draining?.cut = min(cut, speed * 0.9) }
                cutMark = sent
                starting = false
            } else if delay < Self.clear, climb, draining == nil {
                bitRate = (bitRate * (1 + (starting ? 1 : 0.3) * elapsed)).clamped(to: range)
            }
        }
        // A viewer starting again waits for a clear line rather than filling it straight back up.
        // Every answer goes to every viewer of the surface, so it asks once, and again only when
        // an answer came too soon to use and there is room now.
        if waiting {
            if keyFrame, delay > Self.congested { asked = false }
            if asked, now - askedAt > Self.patience { asked = false }
            if !keyFrame || delay > Self.congested {
                guard !asked, delay <= Self.congested else { return .skip }
                (asked, askedAt) = (true, now)
                return .skipUntilKeyFrame
            }
        } else if delay > Self.tooLate {
            (waiting, asked, askedAt) = (true, true, now)
            return .skipUntilKeyFrame
        }
        waiting = false
        sent += bytes
        return .send
    }
}

/// A steady beat for capturing frames. Each frame is due a fixed interval after the one before,
/// however long capturing and encoding took, and a frame that ran over gives up the beats it
/// missed rather than rushing to make them up.
public struct SurfacePacer: Sendable {
    private let interval: Double
    private var due: Double?

    public init(fps: Int) { interval = 1 / Double(max(1, fps)) }

    /// When the next frame is due, the work for the last one having finished at `now`.
    public mutating func next(after now: Double) -> Double {
        let next = (due ?? now) + interval
        due = next > now ? next : next + ((now - next) / interval).rounded(.down) * interval + interval
        return due!
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

/// How far behind a viewer is, from the frames it says it has shown. Video sent longer ago than
/// the shortest round trip, and not shown yet, is waiting somewhere on the way: in the network
/// as much as on this Mac, where the network stack takes megabytes without saying. A viewer
/// that never says leaves it at nothing.
public final class SurfaceDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var unshown: [(sequence: UInt64, bytes: Int, sent: Double)] = []
    /// The shortest round trip lately, and when it was seen.
    private var fastest: (seconds: Double, at: Double)?
    /// The shortest round trip since a probe began, which replaces `fastest` when it ends.
    private var probe: Double?
    /// The last round trip and how much one differs from the next on average: a link that
    /// wavers makes frames later than the fastest without any queue. It starts at what Wi-Fi
    /// commonly adds, so the first few frames of a view are not taken for a queue.
    private var previousTrip: Double?
    private var wavering = 0.01
    /// Bytes the viewer has shown.
    private var shownBytes = 0
    /// The viewer has said it says what it shows, if only that it has shown nothing yet.
    private var speaks = false
    /// How long the shortest round trip stands before the line is drained to see it again, so a
    /// path that gets slower is learnt again.
    static let memory = 10.0
    /// Frames kept for a viewer that never says what it has shown.
    private static let limit = 1024

    public init() {}

    /// The viewer has shown the frame `sequence` and every one sent before it.
    public func shown(_ sequence: UInt64) { shown(sequence, at: now) }

    var now: Double { (ContinuousClock.now - origin) / .seconds(1) }

    func sent(_ sequence: UInt64, bytes: Int, at time: Double) {
        lock.withLock {
            unshown.append((sequence, bytes, time))
            if unshown.count > Self.limit { unshown.removeFirst(unshown.count - Self.limit) }
        }
    }

    func shown(_ sequence: UInt64, at time: Double) {
        lock.withLock {
            speaks = true
            guard let index = unshown.lastIndex(where: { $0.sequence <= sequence }) else { return }
            if unshown[index].sequence == sequence {
                let trip = time - unshown[index].sent
                if fastest.map({ trip <= $0.seconds }) ?? true { fastest = (trip, time) }
                if let previousTrip { wavering += (abs(trip - previousTrip) - wavering) / 8 }
                previousTrip = trip
                probe = probe.map { min($0, trip) }
            }
            shownBytes += unshown[...index].reduce(0) { $0 + $1.bytes }
            unshown.removeFirst(index + 1)
        }
    }

    /// The viewer says what it has shown.
    var confirms: Bool { lock.withLock { fastest != nil } }

    /// The viewer has said it will say what it shows, though perhaps nothing yet.
    var announced: Bool { lock.withLock { speaks } }

    var delivered: Int { lock.withLock { shownBytes } }

    /// Bytes sent that the viewer has not shown.
    var unshownBytes: Int { lock.withLock { unshown.reduce(0) { $0 + $1.bytes } } }

    /// The shortest round trip lately, or none yet.
    var fastestTrip: Double { lock.withLock { fastest?.seconds ?? 0 } }

    /// How long ago the shortest round trip was seen.
    func fastestAge(at time: Double) -> Double { lock.withLock { fastest.map { time - $0.at } ?? 0 } }

    var isProbing: Bool { lock.withLock { probe != nil } }

    /// Starts looking for the shortest round trip afresh, while the line drains.
    func beginProbe() { lock.withLock { probe = .infinity } }

    /// The shortest round trip while the line drained stands from now on.
    func endProbe(at time: Double) {
        lock.withLock {
            if let probe, probe.isFinite { fastest = (probe, time) }
            probe = nil
        }
    }

    /// Bytes the viewer has not shown that were sent longer ago than the shortest round trip,
    /// and than the link wavers by. That room stops at a tenth of a second, more than Wi-Fi
    /// wavers: round trips also swing as a line fills and empties, and room for that would hide it.
    func late(at time: Double) -> Int {
        lock.withLock {
            guard let fastest else { return 0 }
            let due = time - fastest.seconds - min(0.1, max(0.01, 3 * wavering))
            return unshown.reduce(0) { $0 + ($1.sent < due ? $1.bytes : 0) }
        }
    }
}

public extension SurfaceSocket {
    /// Passes this companion's video on to one viewer, through `send`, only as fast as the
    /// viewer's link takes it; `backlog` is the bytes sent that have not left yet, and `delivery`
    /// what the viewer says it has shown, which also counts what the network holds. It asks the
    /// companion for less video as the line grows and, after skipping frames, for a key frame, or
    /// for a far smaller recovery frame when both ends can make and use one. It returns when the
    /// companion ends the view.
    func relay(to send: @escaping @Sendable (Data) -> Void, backlog: @escaping @Sendable () -> Int,
               delivery: SurfaceDelivery = SurfaceDelivery()) async {
        // The encoder never goes above what its picture size calls for, so this only caps.
        var flow = SurfaceFlow(bitRate: 2_000_000, range: 300_000...20_000_000)
        var asked = flow.bitRate
        // Before the first frame, so the key frame a new view starts with already fits.
        self.send(SurfaceControl.rate(bitsPerSecond: asked).encoded)
        // Key frames never say whether the companion can recover, so the last other frame does.
        var recoverable = false
        for await frame in frames {
            // Few and small, a status always goes through, whatever the video is doing.
            if SurfaceStatus(frame) != nil {
                send(frame)
                continue
            }
            let packets = SurfacePacket.decode(frame)
            let now = delivery.now
            // A viewer can go on from a recovery frame as from a key frame.
            let resumes = packets?.first.map { $0.keyFrame || $0.recovery } ?? false
            if let packet = packets?.first, !packet.keyFrame { recoverable = packet.recoverable }
            let decision = flow.admit(bytes: frame.count, keyFrame: resumes, pending: backlog(), delivery: delivery, now: now)
            // The new rate goes first, so a key frame asked for comes at it.
            if abs(flow.bitRate - asked) > asked / 10 {
                asked = flow.bitRate
                self.send(SurfaceControl.rate(bitsPerSecond: asked).encoded)
            }
            switch decision {
            case .send:
                if let sequence = packets?.last?.sequence { delivery.sent(sequence, bytes: frame.count, at: now) }
                send(frame)
            case .skip: break
            case .skipUntilKeyFrame:
                self.send((recoverable && delivery.confirms ? SurfaceControl.recover : .keyFrame).encoded)
            }
        }
    }
}
