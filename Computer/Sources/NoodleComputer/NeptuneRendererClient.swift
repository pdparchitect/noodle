import Darwin
import Foundation
import NeptuneTransport
import os

private let rendererLog = Logger(subsystem: "com.pdparchitect.noodle.computer", category: "WindowsRendererClient")

/// One child, pipe pair and shared arena per Windows GPU. No renderer library is loaded in the app.
final class NeptuneLibrary: @unchecked Sendable {
    static let arenaSize = 2048 * 1024 * 1024
    static let snapshotSize = 64 * 1024 * 1024
    static var isAvailable: Bool { Bundle.main.executableURL.map { FileManager.default.isExecutableFile(atPath: $0.deletingLastPathComponent().appendingPathComponent("noodle-windows-renderer").path) } ?? false }
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var memory: NeptuneMemory?
    private var failed = false
    private var fenceCallback: ((UInt32, UInt32?, UInt64) -> Void)?
    private var backings: [UInt32: (UnsafeMutablePointer<iovec>, Int)] = [:]
    var onFailure: (() -> Void)?

    func arena() throws -> NeptuneMemory {
        if let memory { return memory }
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NoodleGPUGroup") as? String else { throw NeptuneWire.Failure.closed }
        let memory = try NeptuneMemory(group: group, size: Self.arenaSize + Self.snapshotSize)
        self.memory = memory
        return memory
    }

    func start(fence: @escaping (UInt32, UInt32?, UInt64) -> Void) -> Bool {
        fenceCallback = fence
        if process != nil { return !failed }
        do {
            let memory = try arena()
            guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("noodle-windows-renderer") else { return false }
            let child = Process(), commands = Pipe(), replies = Pipe()
            child.executableURL = executable
            child.arguments = [memory.name, String(Self.arenaSize)]
            child.standardInput = commands
            child.standardOutput = replies
            child.standardError = FileHandle.standardError
            try child.run()
            // Only the child owns these ends after spawn. EOF must remain observable.
            try commands.fileHandleForReading.close()
            try replies.fileHandleForWriting.close()
            input = commands.fileHandleForWriting; output = replies.fileHandleForReading
            process = child; failed = false
            let ready = perform(.start).0.operation == 0
            if ready { memory.unlink() }
            return ready
        } catch { fail(error); return false }
    }

    private func fail(_ error: Error) {
        guard !failed else { return }
        failed = true
        rendererLog.error("Windows renderer connection failed: \(String(describing: error), privacy: .public)")
        onFailure?()
    }
    private func perform(_ operation: NeptuneOperation, _ values: [UInt64] = [], data: Data = Data()) -> (NeptuneMessage, Data) {
        guard !failed, let input, let output else { return (NeptuneMessage(-5), Data()) }
        do {
            try NeptuneWire.write(NeptuneMessage(operation.rawValue, values), payload: data, to: input)
            let reply = try NeptuneWire.read(from: output)
            for fence in reply.0.fences { fenceCallback?(fence.context, fence.ring, fence.value) }
            return reply
        } catch { fail(error); return (NeptuneMessage(-5), Data()) }
    }
    func shutdown() {
        let child = process
        process = nil
        try? input?.close(); try? output?.close()
        input = nil; output = nil; fenceCallback = nil; backings = [:]
        memory = nil
        // EOF permits orderly cleanup. A wedged renderer must not keep the VM or app alive.
        if let child {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if child.isRunning { child.terminate() } }
        }
        failed = false
    }
    deinit { shutdown() }
    func restoreCurrent() {} // The child serializes every renderer operation on its one thread.
    func poll() { _ = perform(.poll) }
    func capset(_ id: UInt32) -> (UInt32, UInt32) {
        let result = perform(.capset, [UInt64(id)]).0
        guard result.operation == 0, result.values.count == 2 else { return (0, 0) }
        return (UInt32(truncatingIfNeeded: result.values[0]), UInt32(truncatingIfNeeded: result.values[1]))
    }
    func caps(_ id: UInt32, version: UInt32) -> Data { perform(.caps, [UInt64(id), UInt64(version)]).1 }
    func contextCreate(_ id: UInt32, flags: UInt32, name: [UInt8]) -> Int32 { perform(.contextCreate, [UInt64(id), UInt64(flags)], data: Data(name)).0.operation }
    func contextDestroy(_ id: UInt32) { _ = perform(.contextDestroy, [UInt64(id)]) }
    func contextAttach(_ context: UInt32, _ id: UInt32) { _ = perform(.contextAttach, [UInt64(context), UInt64(id)]) }
    func contextDetach(_ context: UInt32, _ id: UInt32) { _ = perform(.contextDetach, [UInt64(context), UInt64(id)]) }
    func resourceCreate(_ args: inout VirglResourceArgs) -> Int32 {
        perform(.resourceCreate, [args.handle, args.target, args.format, args.bind, args.width, args.height, args.depth, args.array_size, args.last_level, args.nr_samples, args.flags].map(UInt64.init)).0.operation
    }
    private func bytes(_ vectors: UnsafeMutablePointer<iovec>?, _ count: Int) -> Data {
        guard let vectors else { return Data() }
        var data = Data()
        for index in 0..<count {
            guard vectors[index].iov_len <= NeptuneWire.maximumPayload - data.count else { fail(NeptuneWire.Failure.malformed); return Data() }
            if let pointer = vectors[index].iov_base { data.append(Data(bytes: pointer, count: vectors[index].iov_len)) }
        }
        return data
    }
    func createBlob(id: UInt32, context: UInt32, memory: UInt32, flags: UInt32, blob: UInt64, size: UInt64, iovecs: UnsafeMutablePointer<iovec>?, count: UInt32) -> Int32 {
        let result = perform(.createBlob, [UInt64(id), UInt64(context), UInt64(memory), UInt64(flags), blob, size], data: bytes(iovecs, Int(count))).0.operation
        if result == 0, let iovecs { backings[id] = (iovecs, Int(count)) }
        return result
    }
    func createBlobAt(id: UInt32, context: UInt32, flags: UInt32, size: UInt64, pointer: UnsafeMutableRawPointer) -> Int32 {
        guard let memory else { return -5 }
        let offset = pointer - memory.pointer
        guard offset >= 0 else { return -22 }
        return perform(.createBlobAt, [UInt64(id), UInt64(context), UInt64(flags), size, UInt64(offset)]).0.operation
    }
    func unref(_ id: UInt32) { _ = perform(.unref, [UInt64(id)]); backings.removeValue(forKey: id) }
    func attach(_ id: UInt32, _ iovecs: UnsafeMutablePointer<iovec>, _ count: Int32) -> Int32 {
        let result = perform(.attach, [UInt64(id)], data: bytes(iovecs, Int(count))).0.operation
        if result == 0 { backings[id] = (iovecs, Int(count)) }
        return result
    }
    func detach(_ id: UInt32) { _ = perform(.detach, [UInt64(id)]); backings.removeValue(forKey: id) }
    func map(_ id: UInt32) -> (UnsafeMutableRawPointer, UInt64)? {
        let reply = perform(.map, [UInt64(id)]).0
        guard reply.operation == 0, reply.values.count == 1, reply.values[0] <= Self.snapshotSize, let memory else { return nil }
        return (memory.pointer + Self.arenaSize, reply.values[0])
    }
    func unmap(_ id: UInt32) -> Int32 { 0 } // The child copied and unmapped before replying.
    private func transfer(_ operation: NeptuneOperation, _ id: UInt32, context: UInt32, level: UInt32, stride: UInt32, layerStride: UInt32, box: VirglBox, offset: UInt64) -> Int32 {
        let backing = backings[id]
        let data = operation == .transferWrite ? bytes(backing?.0, backing?.1 ?? 0) : Data()
        let result = perform(operation, [UInt64(id), UInt64(context), UInt64(level), UInt64(stride), UInt64(layerStride), offset, UInt64(box.x), UInt64(box.y), UInt64(box.z), UInt64(box.w), UInt64(box.h), UInt64(box.d)], data: data)
        if result.0.operation == 0, operation == .transferRead, let (vectors, count) = backing {
            let total = (0..<count).reduce(0) { $0 + vectors[$1].iov_len }
            guard result.1.count == total else { fail(NeptuneWire.Failure.malformed); return -5 }
            var position = 0
            for index in 0..<count {
                let length = vectors[index].iov_len
                if let pointer = vectors[index].iov_base { result.1.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), from: position..<position + length) }
                position += length
            }
        }
        return result.0.operation
    }
    func transferWrite(_ id: UInt32, context: UInt32, level: UInt32, stride: UInt32, layerStride: UInt32, box: inout VirglBox, offset: UInt64) -> Int32 { transfer(.transferWrite, id, context: context, level: level, stride: stride, layerStride: layerStride, box: box, offset: offset) }
    func transferRead(_ id: UInt32, context: UInt32, level: UInt32, stride: UInt32, layerStride: UInt32, box: inout VirglBox, offset: UInt64) -> Int32 { transfer(.transferRead, id, context: context, level: level, stride: stride, layerStride: layerStride, box: box, offset: offset) }
    func submit(_ buffer: UnsafeMutableRawPointer, context: UInt32, words: Int32) -> Int32 { perform(.submit, [UInt64(context)], data: Data(bytes: buffer, count: Int(words) * 4)).0.operation }
    func fence(_ fence: UInt32, context: UInt32) { _ = perform(.fence, [UInt64(fence), UInt64(context)]) }
    func contextFence(_ context: UInt32, ring: UInt32, fence: UInt64) { _ = perform(.contextFence, [UInt64(context), UInt64(ring), fence]) }
}
