import Foundation
import Testing
@testable import TerminalCore

struct DownloadedAttachmentTests {
    @Test func openAllowsDocumentsAndRefusesExecutables() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = directory.appendingPathComponent("notes.txt")
        try Data("Notes".utf8).write(to: document)
        #expect(try DownloadedAttachment.canOpen(document))

        let script = directory.appendingPathComponent("run.CMD")
        try Data("echo hello".utf8).write(to: script)
        #expect(try !DownloadedAttachment.canOpen(script))

        let renamed = directory.appendingPathComponent("renamed.txt")
        try Data([0x4d, 0x5a, 0x00, 0x00]).write(to: renamed)
        #expect(try !DownloadedAttachment.canOpen(renamed))
    }
}
