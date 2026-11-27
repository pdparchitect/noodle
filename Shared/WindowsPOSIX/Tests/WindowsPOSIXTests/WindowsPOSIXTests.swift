#if os(Windows)
import Foundation
import WindowsPOSIX
import XCTest

typealias stat = WindowsPOSIX.stat

final class WindowsPOSIXTests: XCTestCase {
    private var root: URL!
    private var folder: Int32 = -1

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("windows-posix-\(UUID().uuidString)")
        XCTAssertEqual(mkdir(root.path, 0o700), 0)
        folder = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(folder, 0)
    }

    override func tearDownWithError() throws {
        if folder >= 0 { _ = close(folder) }
        try? FileManager.default.removeItem(at: root)
    }

    private func create(_ name: String, _ contents: String = "x") {
        let descriptor = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0, "create \(name): errno \(errno)")
        _ = contents.withCString { write(descriptor, $0, strlen($0)) }
        _ = close(descriptor)
    }

    func testOwnerOnlyModeComesBackFromTheACL() {
        var info = stat()
        XCTAssertEqual(fstat(folder, &info), 0)
        XCTAssertEqual(info.st_mode & Int32(_S_IFMT), Int32(_S_IFDIR))
        XCTAssertEqual(info.st_mode & 0o077, 0)
        XCTAssertEqual(info.st_uid, getuid())
        create("secret")
        XCTAssertEqual(fstatat(folder, "secret", &info, AT_SYMLINK_NOFOLLOW), 0)
        XCTAssertEqual(info.st_mode & Int32(_S_IFMT), Int32(_S_IFREG))
        XCTAssertEqual(info.st_mode & 0o077, 0)
        XCTAssertEqual(info.st_size, 1)
    }

    func testRelativeOpenRefusesALinkWithNoFollow() throws {
        create("target")
        do {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path,
                                                       withDestinationPath: root.appendingPathComponent("target").path)
        } catch {
            throw XCTSkip("Creating symbolic links needs Developer Mode or an administrator here.")
        }
        XCTAssertEqual(openat(folder, "link", O_RDONLY | O_NOFOLLOW), -1)
        XCTAssertEqual(errno, ELOOP)
        var info = stat()
        XCTAssertEqual(fstatat(folder, "link", &info, AT_SYMLINK_NOFOLLOW), 0)
        XCTAssertEqual(info.st_mode & Int32(_S_IFMT), S_IFLNK)
        let followed = openat(folder, "link", O_RDONLY)
        XCTAssertGreaterThanOrEqual(followed, 0)
        _ = close(followed)
    }

    func testRelativeNamesCannotClimbOutOrNameAStream() {
        create("file")
        XCTAssertEqual(openat(folder, "../outside", O_RDONLY), -1)
        XCTAssertEqual(errno, EINVAL)
        XCTAssertEqual(openat(folder, "file:hidden", O_WRONLY | O_CREAT, 0o600), -1)
        XCTAssertEqual(errno, EINVAL)
    }

    func testExclusiveRenameRefusesAnExistingTargetAndPlainRenameReplacesIt() {
        create("one", "1")
        create("two", "2")
        XCTAssertEqual(renameatExclusive(folder, "one", folder, "two"), -1)
        XCTAssertEqual(errno, EEXIST)
        XCTAssertEqual(renameatExclusive(folder, "one", folder, "three"), 0)
        XCTAssertEqual(renameat(folder, "three", folder, "two"), 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("two"), encoding: .utf8), "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("three").path))
    }

    func testAnOpenFileCanBeRemovedAndItsNameGoesAtOnce() {
        create("open")
        let descriptor = openat(folder, "open", O_RDONLY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(unlinkat(folder, "open", 0), 0)
        var info = stat()
        XCTAssertEqual(fstatat(folder, "open", &info, AT_SYMLINK_NOFOLLOW), -1)
        XCTAssertEqual(errno, ENOENT)
        _ = close(descriptor)
    }

    func testLocksExcludeEachOtherWithoutBlockingReadsOrWrites() {
        create("lock", "123")
        let first = openat(folder, "lock", O_RDONLY | O_NOFOLLOW)
        let second = openat(folder, "lock", O_RDONLY | O_NOFOLLOW)
        XCTAssertEqual(flock(first, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(flock(second, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        var buffer = [UInt8](repeating: 0, count: 3)
        XCTAssertEqual(pread(second, &buffer, 3, 0), 3)
        XCTAssertEqual(buffer, Array("123".utf8))
        let writer = openat(folder, "lock", O_WRONLY | O_TRUNC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(writer, 0)
        XCTAssertEqual("9".withCString { write(writer, $0, 1) }, 1)
        _ = close(writer)
        _ = close(first)
        XCTAssertEqual(flock(second, LOCK_EX | LOCK_NB), 0, "closing the holder lets the lock go")
        _ = close(second)
    }

    func testFolderListingNamesWhatIsThere() throws {
        create("a")
        XCTAssertEqual(mkdirat(folder, "b", 0o700), 0)
        let listed = openat(folder, ".", O_RDONLY | O_DIRECTORY)
        let listing = try XCTUnwrap(fdopendir(listed))
        var names: [String] = []
        while let entry = readdir(listing) {
            names.append(withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            })
        }
        _ = closedir(listing)
        XCTAssertEqual(Set(names).subtracting([".", ".."]), ["a", "b"])
    }

    func testLinksMadeBelowAFolderReadBackAsGivenAndPointTheRightWay() throws {
        create("AGENTS.md", "rules")
        XCTAssertEqual(mkdirat(folder, "skills", 0o700), 0)
        guard symlinkat("AGENTS.md", folder, "CLAUDE.md") == 0 else {
            throw XCTSkip("Creating symbolic links needs the right to, or Developer Mode: errno \(errno)")
        }
        XCTAssertEqual(symlinkat("skills", folder, "linked"), 0)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlinkat(folder, "CLAUDE.md", &buffer, buffer.count - 1)
        XCTAssertEqual(length, 9)
        XCTAssertEqual(String(cString: buffer), "AGENTS.md")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "rules")
        var info = stat()
        XCTAssertEqual(fstatat(folder, "linked", &info, 0), 0)
        XCTAssertEqual(info.st_mode & Int32(_S_IFMT), Int32(_S_IFDIR), "a link to a folder opens as one")
        XCTAssertEqual(readlinkat(folder, "AGENTS.md", &buffer, buffer.count - 1), -1)
        XCTAssertEqual(errno, EINVAL)
    }

    func testRealpathResolvesToTheFolderItself() throws {
        let resolved = try XCTUnwrap(realpath(root.appendingPathComponent(".").path, nil))
        defer { free(resolved) }
        XCTAssertEqual(String(cString: resolved).lowercased(), root.standardizedFileURL.path.lowercased()
            .replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
#endif
