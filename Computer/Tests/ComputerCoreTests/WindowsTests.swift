import XCTest

@testable import ComputerCore

final class WindowsTests: XCTestCase {
    func testWindowsKindNeedsRoomForWindows() throws {
        var computer = Computer(name: "Windows", kind: .windows, cpuCount: 4, memoryGiB: 8, diskGiB: 64)
        XCTAssertEqual(computer.kind.title, "Windows")
        XCTAssertEqual(computer.displaySymbol, "pc")
        XCTAssertTrue(computer.hasDisplay)
        XCTAssertNoThrow(try computer.validate())
        computer.memoryGiB = 2
        XCTAssertThrowsError(try computer.validate())
        computer.memoryGiB = 8
        computer.diskGiB = 32
        XCTAssertThrowsError(try computer.validate())
        computer.diskGiB = 64
        computer.cpuCount = 1
        XCTAssertThrowsError(try computer.validate())
    }

    func testCatalogPicksArmProfessionalInTheRequestedLanguage() throws {
        let xml = """
            <?xml version="1.0"?><MCT><Catalogs><Catalog><PublishedMedia><Files>
            <File><FileName>x64.esd</FileName><LanguageCode>en-us</LanguageCode><Edition>Professional</Edition>
              <Architecture>x64</Architecture><Size>100</Size><Sha1>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</Sha1><FilePath>http://dl.delivery.mp.microsoft.com/x64.esd</FilePath></File>
            <File><FileName>arm-de.esd</FileName><LanguageCode>de-de</LanguageCode><Edition>Professional</Edition>
              <Architecture>ARM64</Architecture><Size>200</Size><Sha1>BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB</Sha1><FilePath>http://dl.delivery.mp.microsoft.com/arm-de.esd</FilePath></File>
            <File><FileName>arm-home.esd</FileName><LanguageCode>en-us</LanguageCode><Edition>Core</Edition>
              <Architecture>ARM64</Architecture><Size>300</Size><Sha1>cccccccccccccccccccccccccccccccccccccccc</Sha1><FilePath>http://dl.delivery.mp.microsoft.com/arm-home.esd</FilePath></File>
            <File><FileName>arm-en.esd</FileName><LanguageCode>en-us</LanguageCode><Edition>Professional</Edition>
              <Architecture>ARM64</Architecture><Size>4527171158</Size><Sha1>C78FD344E845D3B17CB91C40BF4A856459DA1B6C</Sha1>
              <FilePath>http://dl.delivery.mp.microsoft.com/files/arm-en.esd</FilePath></File>
            </Files></PublishedMedia></Catalog></Catalogs></MCT>
            """
        let english = try WindowsCatalog.armProfessional(in: Data(xml.utf8))
        XCTAssertEqual(english.fileName, "arm-en.esd")
        XCTAssertEqual(english.sha1, "c78fd344e845d3b17cb91c40bf4a856459da1b6c")
        XCTAssertEqual(english.size, 4_527_171_158)
        // Microsoft's delivery network serves the image only over http; the https catalogue's SHA-1 vouches for it.
        XCTAssertEqual(english.url.absoluteString, "http://dl.delivery.mp.microsoft.com/files/arm-en.esd")
        XCTAssertEqual(try WindowsCatalog.armProfessional(in: Data(xml.utf8), language: "de-DE").fileName, "arm-de.esd")
        // A language Microsoft does not offer falls back to English.
        XCTAssertEqual(try WindowsCatalog.armProfessional(in: Data(xml.utf8), language: "xx-yy").fileName, "arm-en.esd")
        XCTAssertThrowsError(try WindowsCatalog.armProfessional(in: Data("<MCT/>".utf8)))
        let elsewhere = xml.replacingOccurrences(of: "dl.delivery.mp.microsoft.com", with: "example.net")
        XCTAssertThrowsError(try WindowsCatalog.armProfessional(in: Data(elsewhere.utf8)))
    }

    func testAnswerFilesAreWellFormedAndCarryTheSettings() throws {
        let setup = WindowsAnswers.setup()
        XCTAssertNoThrow(try XMLDocument(xmlString: setup))
        XCTAssertTrue(setup.contains(#"noodle\install.cmd"#))
        XCTAssertTrue(setup.contains(#"processorArchitecture="arm64""#))

        let firstBoot = WindowsAnswers.firstBoot(user: "noodle", password: "p<&>\"'w", timeZone: "GMT Standard Time")
        let document = try XMLDocument(xmlString: firstBoot)
        let values = { (name: String) in try document.nodes(forXPath: "//*[local-name()='\(name)']").map { $0.stringValue ?? "" } }
        XCTAssertEqual(try values("TimeZone"), ["GMT Standard Time"])
        XCTAssertTrue(try values("Value").allSatisfy { $0 == "p<&>\"'w" })
        XCTAssertEqual(try values("Username"), ["noodle"])
        XCTAssertTrue(try values("CommandLine").contains { $0.contains(#"C:\noodle\setup.ps1"#) })
    }

    func testMacTimeZonesBecomeWindowsTimeZones() {
        XCTAssertEqual(WindowsAnswers.windowsTimeZone(for: "Europe/London"), "GMT Standard Time")
        XCTAssertEqual(WindowsAnswers.windowsTimeZone(for: "America/Los_Angeles"), "Pacific Standard Time")
        XCTAssertEqual(WindowsAnswers.windowsTimeZone(for: "Asia/Tokyo"), "Tokyo Standard Time")
        XCTAssertEqual(WindowsAnswers.windowsTimeZone(for: "Mars/Olympus_Mons"), "UTC")
    }

    func testFATImageHoldsTheTreeWithLongNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        var expected: [String: Data] = [:]
        func add(_ path: String, _ data: Data) throws {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            expected[path] = data
        }
        try add("autounattend.xml", Data("<unattend/>".utf8))
        try add("BOOTMGR.EFI", Data(repeating: 7, count: 10_000))
        try add("efi/boot/bootaa64.efi", Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 31) }))
        try add("noodle/drivers/NetKVM/netkvm.inf", Data("[Version]".utf8))
        try add("noodle/empty.txt", Data())
        try add("sources/A very long file name with spaces and ünïcödé.txt", Data("long".utf8))
        for index in 0..<150 { try add("many/file number \(index).dat", Data("\(index)".utf8)) }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty folder"), withIntermediateDirectories: true)

        let image = root.appendingPathComponent("media.img")
        var reported: Int64 = 0
        try FATImage.write(directory: source, to: image, label: "WINSETUP") { done, _ in reported = done }
        XCTAssertEqual(reported, expected.values.reduce(0) { $0 + Int64($1.count) })

        let volume = try FATReader(image: image)
        XCTAssertEqual(volume.label, "WINSETUP")
        XCTAssertEqual(try volume.files(), expected)
        XCTAssertTrue(try volume.directories().contains("empty folder"))
    }

    func testFATImageRefusesFilesFATCannotHold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let big = source.appendingPathComponent("install.wim")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        try FileHandle(forWritingTo: big).truncate(atOffset: 1 << 32)
        XCTAssertThrowsError(try FATImage.write(directory: source, to: root.appendingPathComponent("media.img"), label: "WINSETUP"))
    }

    func testAgentFramesSurviveArbitrarySplitsAndRejectNonsense() throws {
        let frames = [WindowsAgentFrame(type: 1, channel: 7, payload: Data("{\"cmd\":\"ver\"}".utf8)),
                      WindowsAgentFrame(type: 101, channel: 7, payload: Data(repeating: 65, count: 70_000)),
                      WindowsAgentFrame(type: 113, channel: 9, payload: Data())]
        let stream = frames.reduce(Data()) { $0 + $1.encoded }
        var decoder = WindowsAgentFrame.Decoder()
        var received: [WindowsAgentFrame] = []
        var offset = 0
        for size in [1, 3, 5, 9, 4096, 100_000] where offset < stream.count {
            let end = min(stream.count, offset + size)
            received += try decoder.append(stream.subdata(in: offset..<end))
            offset = end
        }
        received += try decoder.append(stream.subdata(in: offset..<stream.count))
        XCTAssertEqual(received, frames)

        var bad = WindowsAgentFrame.Decoder()
        XCTAssertThrowsError(try bad.append(Data([2, 0, 0, 0, 1, 0])))
        var huge = WindowsAgentFrame.Decoder()
        XCTAssertThrowsError(try huge.append(Data([0xff, 0xff, 0xff, 0x7f])))
    }

    func testGuestPathsMapToWindowsPaths() throws {
        XCTAssertNil(try WindowsPath.windows("/"))
        XCTAssertEqual(try WindowsPath.windows("/C"), #"C:\"#)
        XCTAssertEqual(try WindowsPath.windows("/C/Users/noodle/Desktop"), #"C:\Users\noodle\Desktop"#)
        XCTAssertEqual(try WindowsPath.windows("/d/x"), #"D:\x"#)
        XCTAssertThrowsError(try WindowsPath.windows("/CC/x"))
        XCTAssertThrowsError(try WindowsPath.windows("/1/x"))
        XCTAssertThrowsError(try WindowsPath.windows("/C/a\\b"))
        XCTAssertEqual(try WindowsPath.guest(#"C:\Users\noodle"#), "/C/Users/noodle")
        XCTAssertEqual(try WindowsPath.guest(#"C:\"#), "/C")
        XCTAssertEqual(WindowsPath.drive(#"C:\"#), "C")
        XCTAssertNil(WindowsPath.drive("C"))
    }

    func testFirmwareSessionsAreToldApartFromWindowsAndRebootsSeen() {
        var detector = FirmwareSessionDetector()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        // Power-on: the firmware resets the device in a burst, then brings it up.
        for offset in [0.0, 0.05, 0.1] { detector.reset(at: start + offset) }
        XCTAssertEqual(detector.driverReady(at: start + 0.2), .init(firmware: true, guestRebooted: false))
        // It retries after being refused, again after a burst.
        for offset in [1.0, 1.02] { detector.reset(at: start + offset) }
        XCTAssertEqual(detector.driverReady(at: start + 1.05), .init(firmware: true, guestRebooted: false))
        // Windows' driver comes up after a single reset, long after.
        detector.reset(at: start + 2)
        detector.reset(at: start + 40)
        XCTAssertEqual(detector.driverReady(at: start + 40.3), .init(firmware: false, guestRebooted: false))
        // A firmware session after Windows' own means the guest restarted in place.
        for offset in [300.0, 300.01, 300.02, 300.03] { detector.reset(at: start + offset) }
        XCTAssertEqual(detector.driverReady(at: start + 300.05), .init(firmware: true, guestRebooted: true))
        for offset in [301.0, 301.01] { detector.reset(at: start + offset) }
        XCTAssertEqual(detector.driverReady(at: start + 301.02), .init(firmware: true, guestRebooted: false))
    }

    func testInstallProgressLines() {
        XCTAssertEqual(WindowsInstallProgress.parse("step: Copying Windows"), .step("Copying Windows"))
        XCTAssertEqual(WindowsInstallProgress.parse("[=======   47.0%    ]"), .fraction(0.47))
        XCTAssertEqual(WindowsInstallProgress.parse("[==========================100.0%==========================]"), .fraction(1))
        XCTAssertNil(WindowsInstallProgress.parse("Deployment Image Servicing and Management tool"))
        XCTAssertNil(WindowsInstallProgress.parse("   "))
    }

    func testInstallingRefusesToStartWithoutTheSpaceItNeeds() throws {
        let gb: Int64 = 1_000_000_000
        XCTAssertEqual(WindowsInstallSpace.needed(hasDownload: false, hasMedia: false), 30 * gb)
        XCTAssertEqual(WindowsInstallSpace.needed(hasDownload: true, hasMedia: false), 25 * gb)
        XCTAssertEqual(WindowsInstallSpace.needed(hasDownload: true, hasMedia: true), 19 * gb)
        XCTAssertNoThrow(try WindowsInstallSpace.check(available: 30 * gb, hasDownload: false, hasMedia: false))
        XCTAssertThrowsError(try WindowsInstallSpace.check(available: 8 * gb + 1, hasDownload: false, hasMedia: false)) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Installing Windows needs about 30 GB of free disk space, and this Mac has 8 GB free. Free some space and try again.")
        }
    }

    func testNaturalScrollingIsTurnedBackForTheGuest() {
        let scroll = WindowsScroll(deltaX: 2, deltaY: -8, acceleratedDeltaX: 0.2, acceleratedDeltaY: -0.8)
        XCTAssertEqual(scroll.forGuest(directionInvertedFromDevice: false), scroll)
        XCTAssertEqual(scroll.forGuest(directionInvertedFromDevice: true),
                       WindowsScroll(deltaX: -2, deltaY: 8, acceleratedDeltaX: -0.2, acceleratedDeltaY: 0.8))
    }
}

/// An independent FAT32 reader: MBR, BPB, cluster chains and long names, as the spec describes them.
private struct FATReader {
    let data: Data
    let base: Int
    let bytesPerSector: Int, sectorsPerCluster: Int, reserved: Int, fats: Int, fatSize: Int, rootCluster: Int
    var clusterSize: Int { bytesPerSector * sectorsPerCluster }

    init(image: URL) throws {
        let data = try Data(contentsOf: image, options: .alwaysMapped)
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard data[510] == 0x55, data[511] == 0xaa, data[446 + 4] == 0x0c else { throw ComputerError("no MBR FAT32 partition") }
        // Windows leaves a disk without a signature offline when it cannot write one, as on read-only media.
        guard data[440..<444].contains(where: { $0 != 0 }) else { throw ComputerError("no MBR disk signature") }
        let base = u32(446 + 8) * 512
        guard data[base + 510] == 0x55, data[base + 511] == 0xaa,
              String(decoding: data[(base + 82)..<(base + 90)], as: UTF8.self) == "FAT32   " else { throw ComputerError("no FAT32 boot sector") }
        let bytesPerSector = u16(base + 11), reserved = u16(base + 14), fatSize = u32(base + 36)
        guard u32(base + bytesPerSector) == 0x41615252 else { throw ComputerError("no FSInfo") }
        let fat1 = data[(base + reserved * bytesPerSector)..<(base + (reserved + fatSize) * bytesPerSector)]
        let fat2 = data[(base + (reserved + fatSize) * bytesPerSector)..<(base + (reserved + 2 * fatSize) * bytesPerSector)]
        guard fat1.elementsEqual(fat2) else { throw ComputerError("FAT copies differ") }
        self.data = data; self.base = base; self.bytesPerSector = bytesPerSector; self.reserved = reserved; self.fatSize = fatSize
        sectorsPerCluster = Int(data[base + 13]); fats = Int(data[base + 16]); rootCluster = u32(base + 44)
    }

    var label: String? {
        try? entries(rootCluster).first { $0.attributes & 0x08 != 0 && $0.attributes != 0x0f }?.shortName
    }

    private func next(_ cluster: Int) -> Int {
        let o = base + reserved * bytesPerSector + cluster * 4
        return (Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24) & 0x0fff_ffff
    }
    private func chain(_ first: Int) -> [Int] {
        var clusters: [Int] = [], cluster = first
        while cluster >= 2, cluster < 0x0fff_fff8 { clusters.append(cluster); cluster = next(cluster) }
        return clusters
    }
    private func read(_ first: Int, size: Int? = nil) -> Data {
        let dataStart = base + (reserved + fats * fatSize) * bytesPerSector
        var out = Data()
        for cluster in chain(first) {
            let o = dataStart + (cluster - 2) * clusterSize
            out.append(data[o..<(o + clusterSize)])
        }
        return size.map { out.prefix($0) } ?? out
    }

    struct Entry { let name: String; let shortName: String; let attributes: UInt8; let cluster: Int; let size: Int }
    private func entries(_ cluster: Int) throws -> [Entry] {
        let raw = read(cluster)
        var result: [Entry] = [], long: [UInt16] = [], checksum: UInt8?
        for o in stride(from: 0, to: raw.count, by: 32) {
            let e = raw[(raw.startIndex + o)..<(raw.startIndex + o + 32)]
            let first = e[e.startIndex]
            if first == 0 { break }
            if first == 0xe5 { long = []; continue }
            let attributes = e[e.startIndex + 11]
            if attributes == 0x0f {
                if first & 0x40 != 0 { long = [] }
                checksum = e[e.startIndex + 13]
                let units = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30].map { UInt16(e[e.startIndex + $0]) | UInt16(e[e.startIndex + $0 + 1]) << 8 }
                long = units + long
                continue
            }
            let short = Array(e[e.startIndex..<(e.startIndex + 11)])
            var sum: UInt8 = 0
            for byte in short { sum = ((sum & 1) << 7) &+ (sum >> 1) &+ byte }
            let base = String(decoding: short[0..<8], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let ext = String(decoding: short[8..<11], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let shortName = attributes & 0x08 != 0 ? base + ext : ext.isEmpty ? base : base + "." + ext
            var name = shortName
            if !long.isEmpty {
                guard checksum == sum else { throw ComputerError("long name checksum mismatch for \(shortName)") }
                name = String(decoding: long.prefix { $0 != 0 && $0 != 0xffff }, as: UTF16.self)
            }
            long = []
            let cluster = Int(e[e.startIndex + 26]) | Int(e[e.startIndex + 27]) << 8 | Int(e[e.startIndex + 20]) << 16 | Int(e[e.startIndex + 21]) << 24
            let size = Int(e[e.startIndex + 28]) | Int(e[e.startIndex + 29]) << 8 | Int(e[e.startIndex + 30]) << 16 | Int(e[e.startIndex + 31]) << 24
            result.append(Entry(name: name, shortName: shortName, attributes: attributes, cluster: cluster, size: size))
        }
        return result
    }

    private func walk(_ cluster: Int, _ prefix: String, files: inout [String: Data], directories: inout [String]) throws {
        for entry in try entries(cluster) where entry.attributes & 0x08 == 0 && entry.name != "." && entry.name != ".." {
            let path = prefix.isEmpty ? entry.name : prefix + "/" + entry.name
            if entry.attributes & 0x10 != 0 {
                directories.append(path)
                try walk(entry.cluster, path, files: &files, directories: &directories)
            } else {
                files[path] = entry.size == 0 ? Data() : read(entry.cluster, size: entry.size)
            }
        }
    }
    func files() throws -> [String: Data] {
        var files: [String: Data] = [:], directories: [String] = []
        try walk(rootCluster, "", files: &files, directories: &directories)
        return files
    }
    func directories() throws -> [String] {
        var files: [String: Data] = [:], directories: [String] = []
        try walk(rootCluster, "", files: &files, directories: &directories)
        return directories
    }
}
