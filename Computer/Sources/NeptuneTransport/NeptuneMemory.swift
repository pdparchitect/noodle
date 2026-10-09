import Darwin
import Foundation
import NeptunePOSIX

/// Each VM owns a distinct arena; only that VM's renderer opens its unpredictable name.
/// The name is unlinked after the child opens it. Both mappings survive until their owners stop.
public final class NeptuneMemory {
    public let name: String
    public let size: Int
    public let pointer: UnsafeMutableRawPointer
    private var ownsName: Bool
    public convenience init(group: String, size: Int) throws {
        try self.init(name: group + "/" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8), size: size, create: true)
    }
    public convenience init(open name: String, size: Int) throws {
        try self.init(name: name, size: size, create: false)
    }
    private init(name: String, size: Int, create: Bool) throws {
        guard name.utf8.count <= 30, size > 0, size <= 4 * 1024 * 1024 * 1024, size % 16_384 == 0 else {
            throw POSIXError(.EINVAL)
        }
        self.name = name; self.size = size; self.ownsName = create
        let fd = noodle_neptune_shm_open(name, create ? O_RDWR | O_CREAT | O_EXCL : O_RDWR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        if create, ftruncate(fd, off_t(size)) != 0 {
            let error = errno; shm_unlink(name)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == size else {
            if create { shm_unlink(name) }; throw POSIXError(.EINVAL)
        }
        let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mapped != MAP_FAILED, let mapped else {
            let error = errno; if create { shm_unlink(name) }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .ENOMEM)
        }
        pointer = mapped
    }
    public func unlink() {
        guard ownsName else { return }
        shm_unlink(name); ownsName = false
    }
    deinit { unlink(); munmap(pointer, size) }
}
