import Foundation
import LocalMacCore
import LocalMacPrivate
import Darwin

final class Terminal {
    let id = UUID()
    let pid: pid_t
    let handle: FileHandle
    private let lock = NSLock()
    private var bytes = Data()
    private var end: Int64 = 0
    private var exited = false
    private var closed = false
    init(home: String) throws {
        var master: Int32 = -1
        let child = NLMSpawnTerminal(home, &master)
        guard child > 0 else { Darwin.close(master); throw LocalMacError("Cannot launch the account shell.") }
        pid = child
        handle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if data.isEmpty { self.exited = true; handle.readabilityHandler = nil; return }
            self.bytes.append(data); self.end += Int64(data.count)
            if self.bytes.count > 262_144 { self.bytes = self.bytes.suffix(262_144) }
        }
        DispatchQueue.global().async { [weak self] in
            var result: Int32 = 0
            while waitpid(child, &result, 0) < 0 && errno == EINTR {}
            self?.lock.lock(); self?.exited = true; self?.lock.unlock()
        }
    }
    func read(offset: Int64) -> LocalMacReply {
        lock.lock(); defer { lock.unlock() }
        let start = end - Int64(bytes.count), position = max(start, min(offset, end))
        var value = LocalMacReply(); value.terminalID = id
        value.data = Data(bytes.dropFirst(Int(position - start)).prefix(65_536))
        value.offset = position + Int64(value.data!.count); value.exited = exited && value.offset == end
        return value
    }
    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    func resize(width: Int, height: Int) {
        var size = winsize(ws_row: UInt16(height), ws_col: UInt16(width), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(handle.fileDescriptor, UInt(TIOCSWINSZ), &size)
    }
    func close() {
        lock.lock(); let wasClosed = closed; closed = true; lock.unlock()
        guard !wasClosed else { return }
        handle.readabilityHandler = nil
        // Closing the PTY lets the kernel hang up its foreground job, without
        // signalling a numeric PID that another process could have reused.
        try? handle.close()
    }
    deinit { close() }
}
