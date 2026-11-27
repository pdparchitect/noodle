#if os(Windows)
import CRT
@_exported import CWindowsPOSIX

// POSIX spellings over CWindowsPOSIX. A module that uses `stat` or `dirent` as types also declares
// `typealias stat = WindowsPOSIX.stat` and the like on Windows, since its own declarations, unlike these,
// take precedence over the C runtime's types of the same names.

public typealias stat = noodle_stat
public typealias dirent = noodle_dirent

public func open(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 { noodle_open(path, flags, mode) }

public func openat(_ folder: Int32, _ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 {
    noodle_openat(folder, path, flags, mode)
}

public func fstat(_ descriptor: Int32, _ status: UnsafeMutablePointer<stat>) -> Int32 { noodle_fstat(descriptor, status) }

public func fstatat(_ folder: Int32, _ path: String, _ status: UnsafeMutablePointer<stat>, _ flags: Int32) -> Int32 {
    noodle_fstatat(folder, path, status, flags)
}

public func lstat(_ path: String, _ status: UnsafeMutablePointer<stat>) -> Int32 {
    noodle_fstatat(AT_FDCWD, path, status, AT_SYMLINK_NOFOLLOW)
}

public func unlinkat(_ folder: Int32, _ path: String, _ flags: Int32) -> Int32 { noodle_unlinkat(folder, path, flags) }

public func unlink(_ path: String) -> Int32 { noodle_unlinkat(AT_FDCWD, path, 0) }

public func rmdir(_ path: String) -> Int32 { noodle_unlinkat(AT_FDCWD, path, AT_REMOVEDIR) }

/// Replaces what is at `new`, as rename(2) does and the C runtime's does not.
public func rename(_ old: String, _ new: String) -> Int32 { noodle_renameat(AT_FDCWD, old, AT_FDCWD, new) }

public func renameat(_ fromFolder: Int32, _ from: String, _ toFolder: Int32, _ to: String) -> Int32 {
    noodle_renameat(fromFolder, from, toFolder, to)
}

/// Fails with EEXIST when `to` exists, as renameat2's RENAME_NOREPLACE does.
public func renameatExclusive(_ fromFolder: Int32, _ from: String, _ toFolder: Int32, _ to: String) -> Int32 {
    noodle_renameat_exclusive(fromFolder, from, toFolder, to)
}

public func mkdir(_ path: String, _ mode: mode_t) -> Int32 { noodle_mkdirat(AT_FDCWD, path, mode) }

public func mkdirat(_ folder: Int32, _ path: String, _ mode: mode_t) -> Int32 { noodle_mkdirat(folder, path, mode) }

public func chmod(_ path: String, _ mode: mode_t) -> Int32 { noodle_fchmodat(AT_FDCWD, path, mode) }

public func fchmod(_ descriptor: Int32, _ mode: mode_t) -> Int32 { noodle_fchmod(descriptor, mode) }

public func fchmodat(_ folder: Int32, _ path: String, _ mode: mode_t, _ flags: Int32) -> Int32 {
    noodle_fchmodat(folder, path, mode)
}

public func flock(_ descriptor: Int32, _ operation: Int32) -> Int32 { noodle_flock(descriptor, operation) }

public func pread(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ offset: Int64) -> Int {
    Int(noodle_pread(descriptor, buffer, count, offset))
}

public func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    Int(CRT._read(descriptor, buffer, UInt32(clamping: count)))
}

public func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    Int(CRT._write(descriptor, buffer, UInt32(clamping: count)))
}

public func fsync(_ descriptor: Int32) -> Int32 { noodle_fsync(descriptor) }

public func ftruncate(_ descriptor: Int32, _ length: Int64) -> Int32 { noodle_ftruncate(descriptor, length) }

public func fdopendir(_ descriptor: Int32) -> OpaquePointer? { noodle_fdopendir(descriptor) }

public func readdir(_ folder: OpaquePointer) -> UnsafeMutablePointer<dirent>? { noodle_readdir(folder) }

public func closedir(_ folder: OpaquePointer) -> Int32 { noodle_closedir(folder) }

public func rewinddir(_ folder: OpaquePointer) { noodle_rewinddir(folder) }

public func symlinkat(_ target: String, _ folder: Int32, _ path: String) -> Int32 { noodle_symlinkat(target, folder, path) }

public func symlink(_ target: String, _ path: String) -> Int32 { noodle_symlinkat(target, AT_FDCWD, path) }

public func readlinkat(_ folder: Int32, _ path: String, _ buffer: UnsafeMutablePointer<CChar>, _ size: Int) -> Int {
    Int(noodle_readlinkat(folder, path, buffer, size))
}

/// The canonical path of an existing item, links resolved; free() it. `resolved` must be nil.
public func realpath(_ path: String, _ resolved: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    precondition(resolved == nil, "realpath on Windows allocates its result.")
    return noodle_realpath(path)
}

/// Ends the process, or with a negative number its whole tree; Windows has no gentler signal to send.
public func kill(_ process: pid_t, _ signal: Int32) -> Int32 { noodle_kill(process, signal) }

/// Windows has no process groups, so each process leads its own.
public func getpgrp() -> pid_t { noodle_getpid() }

public func getpgid(_ process: pid_t) -> pid_t { noodle_getpgid(process) }

@discardableResult public func usleep(_ microseconds: UInt32) -> Int32 { noodle_usleep(microseconds) }

public func mkstemp(_ template: UnsafeMutablePointer<CChar>) -> Int32 { noodle_mkstemp(template) }

/// Windows has no user numbers; items the current user owns report 0, as this does.
public func getuid() -> uid_t { 0 }

public func geteuid() -> uid_t { 0 }

/// Windows has no creation mask; new items take what their folder passes down.
@discardableResult public func umask(_ mask: mode_t) -> mode_t { 0o022 }
#endif
