import Darwin
import Foundation
import NeptuneTransport

private final class Backing {
    let bytes: UnsafeMutableRawPointer
    let vector: UnsafeMutablePointer<iovec>
    let size: Int
    init(_ data: Data) {
        size = data.count
        bytes = .allocate(byteCount: max(size, 1), alignment: 16)
        data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: size)
        vector = .allocate(capacity: 1)
        vector.initialize(to: iovec(iov_base: bytes, iov_len: size))
    }
    deinit { vector.deinitialize(count: 1); vector.deallocate(); bytes.deallocate() }
    var data: Data { Data(bytes: bytes, count: size) }
}

private final class FenceQueue {
    private let lock = NSLock()
    private var pending: [NeptuneFence] = []
    func append(_ fence: NeptuneFence) { lock.lock(); defer { lock.unlock() }; pending.append(fence) }
    func drain() -> [NeptuneFence] { lock.lock(); defer { lock.unlock() }; let result = pending; pending = []; return result }
}

private func run() throws {
    guard CommandLine.arguments.count == 3, let length = Int(CommandLine.arguments[2]), length == 2048 * 1024 * 1024 else { throw NeptuneWire.Failure.malformed }
    let arena = try NeptuneMemory(open: CommandLine.arguments[1], size: length + 64 * 1024 * 1024)
    let fences = FenceQueue()
    var backings: [UInt32: Backing] = [:]
    // Third-party diagnostics must never enter the response pipe.
    let output = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
    dup2(STDERR_FILENO, STDOUT_FILENO)
    guard let library = NativeNeptuneLibrary.shared else { throw NeptuneWire.Failure.closed }
    defer { library.shutdown() }
    while true {
        let message: NeptuneMessage, payload: Data
        do { (message, payload) = try NeptuneWire.read(from: .standardInput, timeout: -1) }
        catch NeptuneWire.Failure.closed { return }
        guard let operation = NeptuneOperation(rawValue: message.operation) else { throw NeptuneWire.Failure.malformed }
        let a = message.values
        let expected: Int
        switch operation {
        case .start, .poll, .reset: expected = 0
        case .capset, .contextDestroy, .unref, .attach, .detach, .map, .submit: expected = 1
        case .caps, .contextCreate, .contextAttach, .contextDetach, .fence: expected = 2
        case .contextFence: expected = 3
        case .createBlobAt: expected = 5
        case .createBlob: expected = 6
        case .resourceCreate: expected = 11
        case .transferWrite, .transferRead: expected = 12
        }
        guard a.count == expected else { throw NeptuneWire.Failure.malformed }
        func u(_ index: Int) -> UInt32 { UInt32(truncatingIfNeeded: a[index]) }
        var status: Int32 = 0, values: [UInt64] = [], data = Data()
        library.restoreCurrent()
        switch operation {
        case .start:
            status = library.start { context, ring, value in fences.append(NeptuneFence(context: context, ring: ring, value: value)) } ? 0 : -5
        case .poll: library.poll()
        case .capset:
            let (version, size) = library.capset(u(0)); values = [UInt64(version), UInt64(size)]
        case .caps: data = library.caps(u(0), version: u(1))
        case .contextCreate: status = library.contextCreate(u(0), flags: u(1), name: Array(payload.prefix(64)))
        case .contextDestroy: library.contextDestroy(u(0))
        case .contextAttach: library.contextAttach(u(0), u(1))
        case .contextDetach: library.contextDetach(u(0), u(1))
        case .resourceCreate:
            var args = VirglResourceArgs(handle: u(0), target: u(1), format: u(2), bind: u(3), width: u(4), height: u(5), depth: u(6), array_size: u(7), last_level: u(8), nr_samples: u(9), flags: u(10))
            status = library.resourceCreate(&args)
        case .createBlob:
            let backing = payload.isEmpty ? nil : Backing(payload)
            status = library.createBlob(id: u(0), context: u(1), memory: u(2), flags: u(3), blob: a[4], size: a[5], iovecs: backing?.vector, count: backing == nil ? 0 : 1)
            if status == 0 { backings[u(0)] = backing }
        case .createBlobAt:
            guard a[4] <= UInt64(length), a[3] <= UInt64(length) - a[4] else { throw NeptuneWire.Failure.malformed }
            status = library.createBlobAt(id: u(0), context: u(1), flags: u(2), size: a[3], pointer: arena.pointer + Int(a[4]))
        case .unref:
            library.unref(u(0)); backings.removeValue(forKey: u(0))
        case .attach:
            // Detach before replacing storage that the renderer may still reference.
            if backings[u(0)] != nil { library.detach(u(0)) }
            let backing = Backing(payload)
            status = library.attach(u(0), backing.vector, 1)
            if status == 0 { backings[u(0)] = backing }
        case .detach:
            library.detach(u(0)); backings.removeValue(forKey: u(0))
        case .map:
            if let (pointer, count) = library.map(u(0)) {
                if count <= 64 * 1024 * 1024 {
                    memcpy(arena.pointer + length, pointer, Int(count)); values = [count]
                } else { status = -22 }
                _ = library.unmap(u(0))
            } else { status = -5 }
        case .transferWrite, .transferRead:
            if !payload.isEmpty {
                guard let backing = backings[u(0)], payload.count == backing.size else { throw NeptuneWire.Failure.malformed }
                payload.copyBytes(to: backing.bytes.assumingMemoryBound(to: UInt8.self), count: payload.count)
            }
            var box = VirglBox(x: u(6), y: u(7), z: u(8), w: u(9), h: u(10), d: u(11))
            if operation == .transferWrite {
                status = library.transferWrite(u(0), context: u(1), level: u(2), stride: u(3), layerStride: u(4), box: &box, offset: a[5])
            } else {
                status = library.transferRead(u(0), context: u(1), level: u(2), stride: u(3), layerStride: u(4), box: &box, offset: a[5])
                if status == 0 { data = backings[u(0)]?.data ?? Data() }
            }
        case .submit:
            guard payload.count % 4 == 0 else { throw NeptuneWire.Failure.malformed }
            let buffer = Backing(payload)
            status = library.submit(buffer.bytes, context: u(0), words: Int32(payload.count / 4))
        case .fence: library.fence(u(0), context: u(1))
        case .contextFence: library.contextFence(u(0), ring: u(1), fence: a[2])
        case .reset:
            // All resources and contexts are released by the client before this barrier.
            backings = [:]
        }
        try NeptuneWire.write(NeptuneMessage(status, values, fences: fences.drain()), payload: data, to: output)
    }
}

do { try run() }
catch { fputs("Windows renderer stopped: \(error)\n", stderr); exit(1) }
