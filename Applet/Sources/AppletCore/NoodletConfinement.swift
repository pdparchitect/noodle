import AppletBridge
import Foundation

/// One toolchain process Applet wants run: the compiler, or a native noodlet.
public struct NoodletLaunch: Codable, Sendable {
  public var id: String
  public var executable: String
  public var arguments: [String]
  public var environment: [String: String]
  public var directory: String
  public var readable: [String]
  public var writable: [String]
  /// Manifest permissions the user granted that need a sandbox operation.
  public var devices: [String]
  public init(
    id: String = UUID().uuidString, executable: String, arguments: [String],
    environment: [String: String], directory: String, readable: [String], writable: [String],
    devices: [String] = []
  ) {
    self.id = id
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.directory = directory
    self.readable = readable
    self.writable = writable
    self.devices = devices
  }
}

/// Native noodlet code is untrusted. App Sandbox refuses a nested sandbox, so the
/// unsandboxed host service applies this profile instead; outside a bundle Applet
/// applies it directly. Files are limited to the system, the toolchain and the
/// directories named in the launch. User-selected files arrive through Applet.
public enum NoodletConfinement {
  /// Apple developer directories and the compiler front end each one provides.
  public static let toolchains = [
    "/Applications/Xcode.app/Contents/Developer":
      "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
    "/Library/Developer/CommandLineTools": "/Library/Developer/CommandLineTools/usr/bin/swift-frontend",
  ]
  static let system = [
    "/System", "/usr", "/bin", "/sbin", "/dev", "/Library/Apple", "/Library/Fonts", "/private/etc",
    "/private/var/db/timezone",
  ]

  public static func profile(_ launch: NoodletLaunch, toolchain: String) -> String {
    let reads = system + [toolchain] + launch.readable + launch.writable
    var rules = [
      "(version 1)", "(deny default)", "(import \"system.sb\")", "(allow process-fork)",
      "(allow signal (target same-sandbox))", "(allow sysctl-read)",
      "(allow process-exec (literal \"/usr/bin/env\") (subpath \(quoted(toolchain))))",
      "(allow file-read-metadata)",
      "(allow file-read* file-map-executable\n  "
        + reads.map { "(subpath \(quoted(path($0))))" }.joined(separator: "\n  ") + ")",
      "(allow file-read* file-write-data file-ioctl (literal \"/dev/null\") (literal \"/dev/tty\") (subpath \"/dev/fd\"))",
      // Foundation stages atomic writes here, under a name no other process can list.
      "(allow file-read* file-write* (regex #\"^/private/var/folders/[^/]+/[^/]+/T/TemporaryItems(/NSIRD_swift-frontend_[^/]+(/.*)?)?$\"))",
      // AppKit, SwiftUI and the on-device frameworks reach many services. Each
      // one still checks this sandbox before it touches a file for the caller.
      "(allow mach-lookup)", "(allow ipc-posix-shm)", "(allow iokit-open)", "(allow network-outbound)",
    ]
    if !launch.writable.isEmpty {
      rules.append(
        "(allow file-write*\n  "
          + launch.writable.map { "(subpath \(quoted(path($0))))" }.joined(separator: "\n  ") + ")")
    }
    if launch.devices.contains("microphone") { rules.append("(allow device-microphone)") }
    if launch.devices.contains("camera") { rules.append("(allow device-camera)") }
    return rules.joined(separator: "\n")
  }

  /// Refuses anything but an Apple compiler working inside Applet's own storage.
  public static func process(_ launch: NoodletLaunch, within root: URL) throws -> Process {
    guard let toolchain = toolchains.first(where: { $0.value == launch.executable })?.key else {
      throw AppletError("Only the installed Apple Swift compiler may run confined.")
    }
    let base = path(root.path)
    for candidate in launch.readable + launch.writable + [launch.directory] {
      guard path(candidate).hasPrefix(base + "/") else {
        throw AppletError("Confined paths must stay inside Applet's storage.")
      }
    }
    // sandbox-exec is protected, so dyld variables only survive when set after it.
    let late = launch.environment.filter { $0.key.hasPrefix("DYLD_") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments =
      ["-p", profile(launch, toolchain: toolchain), "/usr/bin/env"]
      + late.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + [launch.executable]
      + launch.arguments
    process.environment = launch.environment.filter { !$0.key.hasPrefix("DYLD_") }
    process.currentDirectoryURL = URL(fileURLWithPath: launch.directory)
    return process
  }

  // Seatbelt matches the kernel's resolved spelling, such as /private/var.
  static func path(_ path: String) -> String {
    if let resolved = realpath(path, nil) {
      defer { free(resolved) }
      return String(cString: resolved)
    }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard url.path != "/" else { return "/" }
    let parent = Self.path(url.deletingLastPathComponent().path)
    return (parent == "/" ? "" : parent) + "/" + url.lastPathComponent
  }
  private static func quoted(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: try! encoder.encode(value), as: UTF8.self)
  }
}

/// Deliberately no executable of Applet's choosing. The host runs only an
/// installed Apple compiler, confined to paths inside Applet's storage.
@objc public protocol NoodletHostService {
  func launch(
    _ request: Data, input: FileHandle?, output: FileHandle, error: FileHandle,
    withReply reply: @escaping (String?) -> Void)
  func terminate(_ id: String)
}

@objc public protocol NoodletHostClient {
  func exited(_ id: String, status: Int32, signalled: Bool)
}
