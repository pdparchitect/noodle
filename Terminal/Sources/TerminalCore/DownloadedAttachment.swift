import Foundation
#if os(macOS)
import Darwin
#endif

public enum DownloadedAttachment {
    public static func mark(_ file: URL) throws {
        #if os(macOS)
        let timestamp = String(Int(Date().timeIntervalSince1970), radix: 16)
        let value = Array("0001;\(timestamp);Noodle Terminal;".utf8)
        let result = file.path.withCString { path in
            value.withUnsafeBytes { bytes in
                setxattr(path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
        }
        if result != 0 { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: file]) }
        #elseif os(Windows)
        let path = file.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? file.path
        let stream = URL(fileURLWithPath: path + ":Zone.Identifier")
        try Data("[ZoneTransfer]\r\nZoneId=3\r\n".utf8).write(to: stream)
        #endif
    }

    public static func canOpen(_ file: URL) throws -> Bool {
        let trimmed = file.lastPathComponent.reversed().drop(while: { $0 == "." || $0 == " " })
        let name = String(trimmed.reversed()).lowercased()
        let blocked: Set<String> = ["app", "bat", "cmd", "com", "cpl", "desktop", "dll", "exe",
                                    "jar", "lnk", "msi", "msp", "pkg", "ps1", "reg", "scr", "sh",
                                    "url", "vbe", "vbs", "workflow", "wsf"]
        if let dot = name.lastIndex(of: "."), blocked.contains(String(name[name.index(after: dot)...])) { return false }
        #if !os(Windows)
        guard !FileManager.default.isExecutableFile(atPath: file.path) else { return false }
        #endif
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let prefix = Array(try handle.read(upToCount: 4) ?? Data())
        let signatures: [[UInt8]] = [
            [0x4d, 0x5a], [0x23, 0x21], [0x7f, 0x45, 0x4c, 0x46],
            [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
        ]
        return !signatures.contains { prefix.starts(with: $0) }
    }
}
