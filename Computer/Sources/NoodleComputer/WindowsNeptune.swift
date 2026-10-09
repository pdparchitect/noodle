import Darwin
import CoreGraphics
import Foundation
import os
import Virtualization

private let log = Logger(subsystem: "com.pdparchitect.noodle.computer", category: "WindowsNeptune")

/// Direct3D for Windows on the Mac's GPU. UTM's viogpu3d driver and its Neptune user-mode driver send
/// Direct3D calls through virtio-gpu contexts of capset 7; virglrenderer's Neptune runs them on DXMT over Metal.
/// Each VM owns a sandboxed renderer process and one shared arena.
@available(macOS 27, *)
final class WindowsNeptune: @unchecked Sendable {
    /// The capsets the guest is offered, by index.
    static let capsets: [UInt32] = [1, 2, 7]
    static let sharedMemorySize: UInt64 = UInt64(NeptuneLibrary.arenaSize)

    struct Pending {
        let element: VZVirtioQueueElement
        let reply: Data
        let context: UInt32
        let ring: UInt32?
        let fence: UInt64
    }
    private struct Backing {
        var mappings: [VZGuestMemoryMapping]
        var iovecs: UnsafeMutablePointer<iovec>
        var count: Int
    }

    private let library: NeptuneLibrary
    private var resources: Set<UInt32> = []
    private var backings: [UInt32: Backing] = [:]
    private struct ArenaBlob {
        let context: UInt32
        let size: UInt64
        let flags: UInt32
        var attached: Set<UInt32> = []
        var offset: UInt64?
    }
    private var arenaBlobs: [UInt32: ArenaBlob] = [:]
    private var created: Set<UInt32> = []
    private var contexts: [UInt32: UInt32] = [:]
    private var generation: UInt64 = 0
    private var pending: [Pending] = []
    private var signalled: [String: UInt64] = [:]
    private var counts: [UInt32: Int] = [:]
    private var lastReport = Date()
    /// A single VZ mapping stays in place for the device lifetime. Neptune borrows
    /// exact slices, including 4 KiB offsets, rather than replacing VZ pages.
    /// Keep the backing until VZ releases the device; reset destroys all borrowers.
    private var filler: UnsafeMutableRawPointer?
    /// Hands a finished reply back on the device queue.
    var complete: ((VZVirtioQueueElement, Data) -> Void)?
    var deviceQueue: DispatchQueue?
    var onFrame: (@Sendable (CGImage) -> Void)?

    init?() {
        guard NeptuneLibrary.isAvailable else { return nil }
        self.library = NeptuneLibrary()
        self.library.onFailure = { [weak self] in self?.onFailure?() }
    }

    var onFailure: (() -> Void)?
    private var poller: DispatchSourceTimer?

    func start() -> Bool {
        let run = generation
        let started = library.start(fence: { [weak self] context, ring, fence in
            guard let self, let queue = self.deviceQueue else { return }
            queue.async { if self.generation == run { self.signal(context: context, ring: ring, fence: fence) } }
        })
        // Both GL and Neptune fences retire when virglrenderer is polled.
        if started, poller == nil, let queue = deviceQueue {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                guard let self, !self.pending.isEmpty else { return }
                self.library.restoreCurrent()
                self.library.poll()
            }
            timer.resume()
            poller = timer
        }
        return started
    }

    func owns(_ resource: UInt32) -> Bool { resources.contains(resource) }

    private var mapping = NeptuneArenaMapping()
    private var arenaWaiters: [(Bool) -> Void] = []

    func fill(_ region: VZVirtioSharedMemoryRegion) {
        guard let token = mapping.begin() else { return }
        if filler == nil {
            do { filler = try library.arena().pointer }
            catch {
                log.error("Creating the Windows graphics arena failed: \(String(describing: error), privacy: .public)")
                mapping.complete(token, succeeded: false)
                let waiters = arenaWaiters; arenaWaiters = []
                waiters.forEach { $0(false) }
                onFailure?()
                return
            }
        }
        region.mapMemory(filler!, atOffset: 0, size: region.size) { [weak self] error in
            guard let self, self.mapping.complete(token, succeeded: error == nil) else { return }
            // VZ invokes completion on the device queue.
            if let error { log.error("filling the arena failed: \(error.localizedDescription, privacy: .public)") }
            else { log.info("arena ready: \(region.size >> 20) MiB") }
            let waiters = self.arenaWaiters; self.arenaWaiters = []
            waiters.forEach { $0(error == nil) }
        }
    }

    private func mapArenaBlob(_ id: UInt32, offset: UInt64, capacity: UInt64) -> Bool {
        guard var blob = arenaBlobs[id], let filler,
              offset % 4096 == 0, blob.size > 0,
              offset <= capacity, blob.size <= capacity - offset else { return false }
        if let previous = blob.offset { return previous == offset }
        // Sub-page neighbours are valid; overlapping live resources are not.
        guard !arenaBlobs.contains(where: { other, value in
            guard other != id, let start = value.offset else { return false }
            return offset < start + value.size && start < offset + blob.size
        }) else { return false }
        let pointer = filler + Int(offset)
        memset(pointer, 0, Int(blob.size))
        let result = library.createBlobAt(id: id, context: blob.context, flags: blob.flags, size: blob.size, pointer: pointer)
        guard result == 0 else {
            log.error("arena blob \(id) creation failed: \(result)")
            return false
        }
        blob.offset = offset
        arenaBlobs[id] = blob
        created.insert(id)
        for context in blob.attached { library.contextAttach(context, id) }
        log.debug("arena blob \(id) at \(offset), \(blob.size) bytes")
        return true
    }

    private func key(_ context: UInt32, _ ring: UInt32?) -> String { ring.map { "\(context)/\($0)" } ?? "global" }

    private var logged = 0

    private func signal(context: UInt32, ring: UInt32?, fence: UInt64) {
        let key = key(context, ring)
        if logged < 400 { log.debug("fence signalled \(key, privacy: .public) \(fence), waiting \(self.pending.count)") }
        signalled[key] = max(signalled[key] ?? 0, fence)
        pending.removeAll { item in
            guard self.key(item.context, item.ring) == key, item.fence <= fence else { return false }
            complete?(item.element, item.reply)
            return true
        }
    }

    func reset() {
        generation &+= 1
        for id in contexts.keys { library.contextDestroy(id) }
        contexts = [:]
        for id in Array(backings.keys) { detach(id) }
        for id in created { library.unref(id) }
        created = []
        resources = []
        arenaBlobs = [:]
        pending = []
        signalled = [:]
    }

    /// VZ drops runtime BAR mappings when the VM stops. A device reset alone
    /// keeps them; a later host start must map the arena again before guest use.
    func stop() {
        reset()
        mapping.stopped()
        let waiters = arenaWaiters; arenaWaiters = []
        waiters.forEach { $0(false) }
        poller?.cancel()
        poller = nil
        library.shutdown()
        filler = nil
    }

    private func detach(_ id: UInt32) {
        guard let backing = backings.removeValue(forKey: id) else { return }
        library.detach(id)
        backing.iovecs.deallocate()
    }

    private func report(_ type: UInt32) {
        counts[type, default: 0] += 1
        guard Date().timeIntervalSince(lastReport) > 5 else { return }
        lastReport = Date()
        let summary = counts.sorted { $0.key < $1.key }.map { String(format: "%04x:%d", $0.key, $0.value) }.joined(separator: " ")
        log.debug("commands \(summary, privacy: .public); resources \(self.resources.count), pending \(self.pending.count)")
    }

    /// Handles a 3D command, or a 2D one on a resource of its own. Returns nil for commands it leaves to the 2D device;
    /// otherwise the reply, or `.held` when the reply waits for a fence or a mapping.
    enum Outcome { case reply(UInt32, Data), held }

    func handle(_ request: Data, element: VZVirtioQueueElement, device: VZCustomVirtioDevice?) -> Outcome? {
        func u32(_ offset: Int) -> UInt32 { request.count >= offset + 4 ? request.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } : 0 }
        func u64(_ offset: Int) -> UInt64 { request.count >= offset + 8 ? request.subdata(in: offset..<offset + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } : 0 }
        let type = u32(0), flags = u32(4), fence = u64(8), context = u32(16)
        let ring: UInt32? = flags & 2 != 0 ? UInt32(request.count > 20 ? request[20] : 0) : nil
        if logged < 400 {
            logged += 1
            log.debug("command \(String(format: "%04x", type), privacy: .public) flags \(flags) fence \(fence) context \(context) ring \(ring.map(String.init) ?? "-", privacy: .public) bytes \(request.count)")
        }
        library.restoreCurrent()
        var reply: UInt32 = 0x1100
        var body = Data()
        func check(_ result: Int32) { if result != 0 { reply = 0x1200; log.error("command \(String(type, radix: 16), privacy: .public) failed: \(result)") } }
        switch type {
        case 0x0108: // GET_CAPSET_INFO: index
            let index = Int(u32(24))
            let id = index < Self.capsets.count ? Self.capsets[index] : 0
            let (version, size) = library.capset(id)
            reply = 0x1102
            body = Self.words(id, version, size, 0)
        case 0x0109: // GET_CAPSET: id, version
            reply = 0x1103
            body = library.caps(u32(24), version: u32(28))
        case 0x0200: // CTX_CREATE: name length, context_init, name
            let length = min(Int(u32(24)), 64)
            let name = request.count >= 32 + length ? Array(request[32..<32 + length]) : []
            check(library.contextCreate(context, flags: u32(28) & 0xFF, name: name))
            if reply == 0x1100 { contexts[context] = u32(28) & 0xFF }
            log.log("context \(context) created for capset \(u32(28) & 0xFF)")
        case 0x0201:
            library.contextDestroy(context)
            contexts.removeValue(forKey: context)
            for id in Array(arenaBlobs.keys) { arenaBlobs[id]?.attached.remove(context) }
        case 0x0202:
            let id = u32(24)
            if arenaBlobs[id] != nil {
                arenaBlobs[id]?.attached.insert(context)
                if created.contains(id) { library.contextAttach(context, id) }
            } else { library.contextAttach(context, id) }
        case 0x0203:
            let id = u32(24)
            if arenaBlobs[id] != nil {
                arenaBlobs[id]?.attached.remove(context)
                if created.contains(id) { library.contextDetach(context, id) }
            } else { library.contextDetach(context, id) }
        case 0x0204: // RESOURCE_CREATE_3D
            var args = VirglResourceArgs(handle: u32(24), target: u32(28), format: u32(32), bind: u32(36), width: u32(40), height: u32(44),
                                         depth: u32(48), array_size: u32(52), last_level: u32(56), nr_samples: u32(60), flags: u32(64))
            check(library.resourceCreate(&args))
            if reply == 0x1100 { resources.insert(u32(24)); created.insert(u32(24)) }
        case 0x010c: // RESOURCE_CREATE_BLOB: id, blob_mem, blob_flags, entries, blob_id, size, then entries
            let id = u32(24), count = Int(u32(36))
            guard id != 0, !resources.contains(id) else { reply = 0x1200; break }
            if contexts[context] == 7, u32(28) == 2, u32(32) & 1 != 0, u64(40) == 0 {
                // CREATE_BLOB does not contain the BAR offset. Windows chooses it
                // independently and supplies it in MAP_BLOB; defer host allocation.
                guard count == 0, u64(48) > 0, u64(48) <= Self.sharedMemorySize else { reply = 0x1200; break }
                arenaBlobs[id] = ArenaBlob(context: context, size: u64(48), flags: u32(32))
                resources.insert(id)
                break
            }
            var mappings: [VZGuestMemoryMapping] = []
            for index in 0..<min(count, 65_536) where 56 + index * 16 + 16 <= request.count {
                if let mapping = device?.guestMemoryMapping(atPhysicalAddress: u64(56 + index * 16), length: Int(u32(64 + index * 16))) {
                    mappings.append(mapping)
                }
            }
            let iovecs = UnsafeMutablePointer<iovec>.allocate(capacity: max(mappings.count, 1))
            for (index, mapping) in mappings.enumerated() { iovecs[index] = iovec(iov_base: mapping.mutableBytes, iov_len: mapping.length) }
            check(library.createBlob(id: id, context: context, memory: u32(28), flags: u32(32), blob: u64(40), size: u64(48),
                                     iovecs: mappings.isEmpty ? nil : iovecs, count: UInt32(mappings.count)))
            if reply == 0x1100 {
                resources.insert(id)
                created.insert(id)
                if !mappings.isEmpty { backings[id] = Backing(mappings: mappings, iovecs: iovecs, count: mappings.count) } else { iovecs.deallocate() }
            } else {
                iovecs.deallocate()
            }
        case 0x0208: // RESOURCE_MAP_BLOB: id, padding, offset
            let id = u32(24), offset = u64(32)
            guard arenaBlobs[id] != nil, let region = device?.sharedMemoryRegions.first else { reply = 0x1200; break }
            if mapping.isReady {
                guard mapArenaBlob(id, offset: offset, capacity: region.size) else { reply = 0x1200; break }
                return .reply(0x1106, Self.words(1, 0)) // CACHED, matching the arena's host mapping.
            }
            let token = generation
            arenaWaiters.append { [weak self] ready in
                guard let self, self.generation == token else { return }
                let ok = ready && self.mapArenaBlob(id, offset: offset, capacity: region.size)
                self.complete?(element, Self.header(ok ? 0x1106 : 0x1200, request) + (ok ? Self.words(1, 0) : Data()))
            }
            fill(region)
            return .held
        case 0x0209: // RESOURCE_UNMAP_BLOB
            // The guest drops its CPU mapping; the renderer may still own rings.
            // Keep the slice reserved until RESOURCE_UNREF. No VZ unmap is needed.
            if arenaBlobs[u32(24)] == nil { reply = 0x1200 }
        case 0x0205, 0x0206: // TRANSFER_TO/FROM_HOST_3D
            var box = VirglBox(x: u32(24), y: u32(28), z: u32(32), w: u32(36), h: u32(40), d: u32(44))
            if type == 0x0205 {
                check(library.transferWrite(u32(56), context: context, level: u32(60), stride: u32(64), layerStride: u32(68), box: &box, offset: u64(48)))
            } else {
                check(library.transferRead(u32(56), context: context, level: u32(60), stride: u32(64), layerStride: u32(68), box: &box, offset: u64(48)))
            }
        case 0x0207: // SUBMIT_3D: size, padding, commands
            let size = Int(u32(24))
            guard request.count >= 32 + size, size % 4 == 0 else { reply = 0x1200; break }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(size, 8), alignment: 8)
            defer { buffer.deallocate() }
            request.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), from: 32..<32 + size)
            check(library.submit(buffer, context: context, words: Int32(size / 4)))
        case 0x0102 where owns(u32(24)): // RESOURCE_UNREF
            let id = u32(24)
            detach(id)
            if created.remove(id) != nil { library.unref(id) }
            arenaBlobs.removeValue(forKey: id)
            resources.remove(id)
        case 0x0106 where owns(u32(24)): // RESOURCE_ATTACH_BACKING
            let id = u32(24), count = Int(u32(28))
            var mappings: [VZGuestMemoryMapping] = []
            for index in 0..<min(count, 65_536) where 32 + index * 16 + 16 <= request.count {
                if let mapping = device?.guestMemoryMapping(atPhysicalAddress: u64(32 + index * 16), length: Int(u32(40 + index * 16))) {
                    mappings.append(mapping)
                }
            }
            detach(id)
            let iovecs = UnsafeMutablePointer<iovec>.allocate(capacity: max(mappings.count, 1))
            for (index, mapping) in mappings.enumerated() { iovecs[index] = iovec(iov_base: mapping.mutableBytes, iov_len: mapping.length) }
            backings[id] = Backing(mappings: mappings, iovecs: iovecs, count: mappings.count)
            check(library.attach(id, iovecs, Int32(mappings.count)))
        case 0x0107 where owns(u32(24)): // RESOURCE_DETACH_BACKING
            detach(u32(24))
        case 0x0105 where owns(u32(48)): // TRANSFER_TO_HOST_2D on a 3D resource
            var box = VirglBox(x: u32(24), y: u32(28), z: 0, w: u32(32), h: u32(36), d: 1)
            check(library.transferWrite(u32(48), context: 0, level: 0, stride: 0, layerStride: 0, box: &box, offset: u64(40)))
        case 0x010d: // SET_SCANOUT_BLOB: rect, scanout, resource, width, height, format, padding, strides, offsets
            guard request.count >= 96, u32(40) == 0 else { reply = 0x1200; break }
            let id = u32(44)
            if id == 0 { break }
            guard let (pointer, size) = library.map(id), size <= UInt64(Int.max) else { reply = 0x1200; break }
            defer { _ = library.unmap(id) }
            let crop = CGRect(x: Int(u32(24)), y: Int(u32(28)), width: Int(u32(32)), height: Int(u32(36)))
            guard let image = NeptuneScanout.image(UnsafeRawBufferPointer(start: pointer, count: Int(size)),
                width: Int(u32(48)), height: Int(u32(52)), stride: Int(u32(64)), offset: Int(u32(80)),
                format: u32(56), crop: crop) else { reply = 0x1200; break }
            onFrame?(image)
            if counts[type, default: 0] == 0 { log.info("first Neptune frame: \(image.width)x\(image.height)") }
        default:
            return nil
        }
        report(type)
        let answer = Self.header(reply, request) + body
        guard flags & 1 != 0, reply == 0x1100 || reply >= 0x1101 && reply < 0x1200 else {
            return .reply(reply, body)
        }
        // A fenced command answers once its fence signals.
        if let ring { library.contextFence(context, ring: ring, fence: fence) } else { library.fence(UInt32(truncatingIfNeeded: fence), context: context) }
        if let done = signalled[key(context, ring)], done >= fence { return .reply(reply, body) }
        pending.append(Pending(element: element, reply: answer, context: context, ring: ring, fence: fence))
        return .held
    }

    static func header(_ type: UInt32, _ request: Data) -> Data {
        var header = words(type, request.count >= 8 ? request.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } & 3 : 0)
        header.append(request.subdata(in: 8..<24))
        return header
    }

    static func words(_ values: UInt32...) -> Data {
        values.reduce(into: Data()) { data, value in withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    }
}

