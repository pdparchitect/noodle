import AppletBridge
import Darwin
import Foundation

public final class InstanceLock {
    private let fd: Int32
    public init(location: URL, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(
            NoodletPackage.digest(
                Data(location.resolvingSymlinksInPath().standardizedFileURL.path.utf8)) + ".lock"
        ).path
        fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppletError("Cannot create instance lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw AppletError("This noodlet is already running in another Applet process.")
        }
    }
    deinit {
        flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}
