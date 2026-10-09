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

/// The EDID of a virtual monitor with one preferred mode, which a guest's display driver reads to choose its
/// resolution; without one, Windows' virtio-gpu driver falls back to 1024 by 768. The mode uses CVT reduced-blanking
/// timings at 60 Hz, which any size can have.
public enum DisplayEDID {
    public static func bytes(width: Int, height: Int) -> [UInt8] {
        // CVT-RB: a fixed 160-pixel horizontal blank, and at least 460 µs of vertical blank.
        let horizontalBlank = 160, horizontalFront = 48, horizontalSync = 32
        let verticalFront = 3, verticalSync = 6
        let linePeriod = (1_000_000.0 / 60 - 460) / Double(height)
        let verticalBlank = max(Int((460 / linePeriod).rounded(.up)), verticalFront + verticalSync + 6)
        let clock = (width + horizontalBlank) * (height + verticalBlank) * 60 / 10_000 // in 10 kHz units
        // At 96 dots per inch.
        let widthMM = width * 254 / 960, heightMM = height * 254 / 960

        var edid: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        edid += [0x38, 0x8C] // manufacturer "NDL"
        edid += [0x01, 0x00, 0, 0, 0, 0] // product 1, no serial number
        edid += [1, 36] // week 1 of 2026
        edid += [1, 4] // EDID 1.4
        edid += [0x80, UInt8(clamping: (widthMM + 5) / 10), UInt8(clamping: (heightMM + 5) / 10), 120]
        edid += [0x06] // sRGB, and the first detailed timing is the preferred mode
        edid += [0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54] // sRGB primaries and white
        edid += [0, 0, 0] // no established timings
        edid += Array(repeating: 0x01, count: 16) // no standard timings
        edid += [
            UInt8(clock & 0xFF), UInt8(clock >> 8),
            UInt8(width & 0xFF), UInt8(horizontalBlank & 0xFF), UInt8((width >> 8) << 4 | horizontalBlank >> 8),
            UInt8(height & 0xFF), UInt8(verticalBlank & 0xFF), UInt8((height >> 8) << 4 | verticalBlank >> 8),
            UInt8(horizontalFront & 0xFF), UInt8(horizontalSync & 0xFF), UInt8((verticalFront & 0x0F) << 4 | verticalSync & 0x0F),
            UInt8((horizontalFront >> 8) << 6 | (horizontalSync >> 8) << 4 | (verticalFront >> 4) << 2 | verticalSync >> 4),
            UInt8(widthMM & 0xFF), UInt8(heightMM & 0xFF), UInt8((widthMM >> 8) << 4 | heightMM >> 8),
            0, 0, 0x1A, // no borders; digital separate sync, horizontal positive, vertical negative
        ]
        edid += [0, 0, 0, 0xFC, 0] + Array("Noodle\n      ".utf8) // monitor name
        for _ in 0..<2 { edid += [0, 0, 0, 0x10] + Array(repeating: 0, count: 14) } // unused descriptors
        edid += [0] // no extensions
        edid.append(UInt8((256 - edid.reduce(0) { ($0 + Int($1)) % 256 }) % 256))
        return edid
    }
}

/// Windows' screen size. The virtio-gpu driver offers a new size once the display reports it, but Windows keeps its
/// mode until asked; the agent asks through the display settings API.
public enum WindowsDisplayMode {
    /// The sizes the driver takes.
    public static func fit(width: Int, height: Int) -> (width: Int, height: Int) {
        (min(max(width, 800), 4096), min(max(height, 600), 4096))
    }

    /// A command for the agent that switches the screen to `width` by `height`, as PowerShell's encoded command.
    public static func switchCommand(width: Int, height: Int) -> String {
        let script = #"""
            Add-Type @"
            using System; using System.Runtime.InteropServices;
            public class NoodleDisplay {
              [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct DEVMODE {
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
                public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
                public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
                public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
                public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
                public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight; }
              [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string name, int mode, ref DEVMODE devMode);
              [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ChangeDisplaySettings(ref DEVMODE devMode, int flags);
            }
            "@
            $m = New-Object NoodleDisplay+DEVMODE; $m.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($m)
            [void][NoodleDisplay]::EnumDisplaySettings($null, -1, [ref]$m)
            $m.dmPelsWidth = WIDTH; $m.dmPelsHeight = HEIGHT; $m.dmFields = 0x180000
            exit [NoodleDisplay]::ChangeDisplaySettings([ref]$m, 0)
            """#
            .replacingOccurrences(of: "WIDTH", with: String(width)).replacingOccurrences(of: "HEIGHT", with: String(height))
        let encoded = Data(script.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
        return "powershell -NoProfile -EncodedCommand " + encoded
    }
}
