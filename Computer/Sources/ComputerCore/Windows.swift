import Foundation

/// Microsoft's catalogue of Windows 11 installation images (ESD files), as the Media Creation Tool reads it.
public enum WindowsCatalog {
    /// A CAB holding products.xml.
    public static let productsURL = URL(string: "https://go.microsoft.com/fwlink/?LinkId=2156292")!
    /// Where the images are. It serves them only over http, so the app allows http for it alone; the SHA-1 from
    /// the https catalogue vouches for what it sends.
    public static let deliveryHost = "dl.delivery.mp.microsoft.com"

    public struct Image: Equatable, Sendable {
        public let fileName: String
        public let url: URL
        public let sha1: String
        public let size: Int64
    }

    /// The Arm64 Windows 11 Pro image, in `language` if Microsoft offers it, otherwise in English.
    public static func armProfessional(in productsXML: Data, language: String = "en-us") throws -> Image {
        let document = try XMLDocument(data: productsXML)
        let images = try document.nodes(forXPath: "//File").compactMap { node -> (language: String, image: Image)? in
            func value(_ name: String) -> String {
                ((try? node.nodes(forXPath: name))?.first?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard value("Architecture").lowercased() == "arm64", value("Edition") == "Professional",
                  let url = URL(string: value("FilePath")), url.host() == deliveryHost, let size = Int64(value("Size")),
                  value("Sha1").range(of: "^[0-9A-Fa-f]{40}$", options: .regularExpression) != nil else { return nil }
            return (value("LanguageCode").lowercased(),
                    Image(fileName: value("FileName"), url: url, sha1: value("Sha1").lowercased(), size: size))
        }
        guard let match = images.first(where: { $0.language == language.lowercased() })
                ?? images.first(where: { $0.language == "en-us" }) ?? images.first else {
            throw ComputerError("Microsoft's catalogue has no Windows 11 for Arm.")
        }
        return match.image
    }
}

/// The answer files that make Windows install and set itself up without questions.
public enum WindowsAnswers {
    /// Read by Windows Setup from the install media in WinPE: it only runs noodle\install.cmd, which installs
    /// Windows in place of Setup (Setup itself fails on this hardware) and shuts the machine down.
    public static func setup() -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-International-Core-WinPE" \(component)>
              <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
              <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
            </component>
            <component name="Microsoft-Windows-Setup" \(component)>
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>cmd /c for %d in (C D E F G H I J K L) do if exist %d:\\noodle\\install.cmd call %d:\\noodle\\install.cmd %d</Path></RunSynchronousCommand>
              </RunSynchronous>
              <UserData><AcceptEula>true</AcceptEula></UserData>
            </component>
          </settings>
        </unattend>

        """
    }

    /// Copied into the installed Windows: its first start skips the welcome screens, makes the account and signs
    /// it in, and runs C:\noodle\setup.ps1, which builds and starts the Noodle agent.
    public static func firstBoot(user: String, password: String, timeZone: String) -> String {
        let user = escape(user), password = escape(password), timeZone = escape(timeZone)
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="specialize">
            <component name="Microsoft-Windows-Deployment" \(component)>
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-International-Core" \(component)>
              <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
            </component>
            <component name="Microsoft-Windows-Shell-Setup" \(component)>
              <TimeZone>\(timeZone)</TimeZone>
              <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <ProtectYourPC>3</ProtectYourPC>
              </OOBE>
              <UserAccounts>
                <LocalAccounts>
                  <LocalAccount wcm:action="add">
                    <Name>\(user)</Name><Group>Administrators</Group>
                    <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
                  </LocalAccount>
                </LocalAccounts>
              </UserAccounts>
              <AutoLogon>
                <Enabled>true</Enabled><Username>\(user)</Username>
                <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
              </AutoLogon>
              <FirstLogonCommands>
                <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -File C:\\noodle\\setup.ps1</CommandLine></SynchronousCommand>
              </FirstLogonCommands>
            </component>
          </settings>
        </unattend>

        """
    }

    /// Windows' name for an IANA time zone, from CLDR's table; UTC when it has none.
    public static func windowsTimeZone(for identifier: String) -> String { timeZones[identifier] ?? "UTC" }

    private static let timeZones: [String: String] = {
        guard let url = ComputerCoreResources.bundle.url(forResource: "windows-time-zones", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    private static let component = #"processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS""#

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// One message between the Mac and the Noodle agent in Windows, over a virtio-serial port:
/// a little-endian u32 length of what follows, a type byte, a u32 channel and the payload.
public struct WindowsAgentFrame: Equatable, Sendable {
    public static let maximumLength = 64 << 20
    public let type: UInt8
    public let channel: UInt32
    public let payload: Data

    public init(type: UInt8, channel: UInt32, payload: Data = Data()) {
        self.type = type; self.channel = channel; self.payload = payload
    }

    public var encoded: Data {
        var data = Data(capacity: 9 + payload.count)
        withUnsafeBytes(of: UInt32(5 + payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(type)
        withUnsafeBytes(of: channel.littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// Reassembles frames from a byte stream that arrives in pieces of any size.
    public struct Decoder: Sendable {
        private var buffer = Data()
        public init() {}
        public mutating func append(_ data: Data) throws -> [WindowsAgentFrame] {
            buffer.append(data)
            var frames: [WindowsAgentFrame] = []
            while buffer.count >= 4 {
                let start = buffer.startIndex
                let length = Int(UInt32(buffer[start]) | UInt32(buffer[start + 1]) << 8 | UInt32(buffer[start + 2]) << 16 | UInt32(buffer[start + 3]) << 24)
                guard (5...WindowsAgentFrame.maximumLength).contains(length) else {
                    throw ComputerError("The Windows agent sent a malformed message.")
                }
                guard buffer.count >= 4 + length else { break }
                let channel = UInt32(buffer[start + 5]) | UInt32(buffer[start + 6]) << 8 | UInt32(buffer[start + 7]) << 16 | UInt32(buffer[start + 8]) << 24
                frames.append(WindowsAgentFrame(type: buffer[start + 4], channel: channel,
                                                payload: Data(buffer[(start + 9)..<(start + 4 + length)])))
                buffer = Data(buffer[(start + 4 + length)...])
            }
            return frames
        }
    }
}

/// Noodle's file views use slash paths; in Windows the first component is the drive: /C/Users is C:\Users,
/// and / lists the drives.
public enum WindowsPath {
    public static func windows(_ path: String) throws -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), let drive = parts.first else { return nil }
        guard drive.count == 1, let letter = drive.unicodeScalars.first, ("A"..."Z").contains(letter) || ("a"..."z").contains(letter) else {
            throw ComputerError("Windows paths start with a drive letter.")
        }
        let invalid = CharacterSet(charactersIn: "\\:*?\"<>|")
        guard parts.dropFirst().allSatisfy({ $0.rangeOfCharacter(from: invalid) == nil && $0 != ".." }) else {
            throw ComputerError("Windows file names cannot contain \\ : * ? \" < > |.")
        }
        return drive.uppercased() + ":\\" + parts.dropFirst().joined(separator: "\\")
    }

    public static func guest(_ path: String) throws -> String {
        guard let drive = drive(String(path.prefix(3))) else { throw ComputerError("Windows returned a path without a drive.") }
        let rest = path.dropFirst(3).split(separator: "\\").map(String.init)
        return "/" + ([drive] + rest).joined(separator: "/")
    }

    /// "C" for a drive root such as "C:\".
    public static func drive(_ root: String) -> String? {
        let characters = Array(root)
        guard characters.count == 3, characters[1] == ":", characters[2] == "\\", characters[0].isASCII, characters[0].isLetter else { return nil }
        return characters[0].uppercased()
    }
}

/// VZ's firmware drives any virtio-gpu it finds, at power-on and after every guest restart, and the VM process
/// crashes when the firmware tears that display down as it hands over to Windows. The firmware brings the device
/// up after a burst of resets; Windows' display driver after a single one. Telling them apart lets the device
/// refuse the firmware, and a firmware session after Windows' own means the guest restarted in place.
public struct FirmwareSessionDetector: Sendable {
    public struct Session: Equatable, Sendable {
        public let firmware: Bool
        public let guestRebooted: Bool
        public init(firmware: Bool, guestRebooted: Bool) { self.firmware = firmware; self.guestRebooted = guestRebooted }
    }
    private var resets: [Date] = []
    private var systemSeen = false
    public init() {}

    public mutating func reset(at date: Date) {
        resets = resets.filter { date.timeIntervalSince($0) < 5 } + [date]
    }

    public mutating func driverReady(at date: Date) -> Session {
        let firmware = resets.filter { date.timeIntervalSince($0) < 1 }.count >= 2
        defer { systemSeen = !firmware }
        return Session(firmware: firmware, guestRebooted: firmware && systemSeen)
    }
}

/// What WinPE reports while it installs: "step: …" lines from noodle\install.cmd, and DISM's progress bars.
public enum WindowsInstallProgress: Equatable, Sendable {
    case step(String)
    case fraction(Double)

    public static func parse(_ line: String) -> Self? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("step: ") { return .step(String(line.dropFirst(6))) }
        guard line.hasPrefix("["), let range = line.range(of: #"[0-9]+(\.[0-9]+)?%"#, options: .regularExpression),
              let value = Double(line[range].dropLast()) else { return nil }
        return .fraction(min(1, value / 100))
    }
}

/// The disk space making the Windows base takes at its largest, while Windows installs: the download and the install
/// media, both kept until the base exists, Windows itself and room to spare. Files already made need no more.
public enum WindowsInstallSpace {
    static let gigabyte: Int64 = 1_000_000_000
    static let download = 5 * gigabyte, media = 6 * gigabyte, installed = 15 * gigabyte, spare = 4 * gigabyte

    public static func needed(hasDownload: Bool, hasMedia: Bool) -> Int64 {
        (hasDownload ? 0 : download) + (hasMedia ? 0 : media) + installed + spare
    }

    public static func check(available: Int64, hasDownload: Bool, hasMedia: Bool) throws {
        let needed = needed(hasDownload: hasDownload, hasMedia: hasMedia)
        guard available < needed else { return }
        throw ComputerError("Installing Windows needs about \(needed / gigabyte) GB of free disk space, and this Mac has \(available / gigabyte) GB free. Free some space and try again.")
    }
}

/// The deltas of a scroll for VZ's pointing device. Windows applies its own scroll direction, so a scroll macOS has
/// already turned around for natural scrolling is turned back, or the guest would reverse it a second time.
public struct WindowsScroll: Equatable, Sendable {
    public var deltaX, deltaY, acceleratedDeltaX, acceleratedDeltaY: Double

    public init(deltaX: Double, deltaY: Double, acceleratedDeltaX: Double, acceleratedDeltaY: Double) {
        self.deltaX = deltaX; self.deltaY = deltaY
        self.acceleratedDeltaX = acceleratedDeltaX; self.acceleratedDeltaY = acceleratedDeltaY
    }

    public func forGuest(directionInvertedFromDevice: Bool) -> WindowsScroll {
        guard directionInvertedFromDevice else { return self }
        return WindowsScroll(deltaX: -deltaX, deltaY: -deltaY, acceleratedDeltaX: -acceleratedDeltaX, acceleratedDeltaY: -acceleratedDeltaY)
    }
}
