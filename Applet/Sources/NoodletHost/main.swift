import AppletCore
import Foundation

// Runs outside App Sandbox only so it can confine native noodlets more tightly
// than Applet itself. It accepts Applet alone and starts nothing but the compiler.
private enum Host {
  static func value(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }
  static var requirement: String? {
    guard let applet = value("NoodleAppletIdentifier"), let team = value("NoodleSigningTeam"), team.count == 10,
      team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) })
    else { return nil }
    return "anchor apple generic and identifier \"\(applet)\" and certificate leaf[subject.OU] = \"\(team)\""
  }
  static var storage: URL? {
    guard let applet = value("NoodleAppletIdentifier"), let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir
    else { return nil }
    return URL(fileURLWithPath: String(cString: home), isDirectory: true).appendingPathComponent(
      "Library/Containers/\(applet)/Data/Library/Application Support/NoodleApplet", isDirectory: true)
  }
}

private final class HostSession: NSObject, NoodletHostService, @unchecked Sendable {
  private let lock = NSLock()
  private var processes: [String: Process] = [:]
  private weak var connection: NSXPCConnection?
  init(connection: NSXPCConnection) { self.connection = connection }

  func launch(
    _ request: Data, input: FileHandle?, output: FileHandle, error: FileHandle,
    withReply reply: @escaping (String?) -> Void
  ) {
    do {
      guard let storage = Host.storage else { throw CocoaError(.fileNoSuchFile) }
      let launch = try JSONDecoder().decode(NoodletLaunch.self, from: request)
      let process = try NoodletConfinement.process(launch, within: storage)
      process.standardInput = input ?? FileHandle.nullDevice
      process.standardOutput = output
      process.standardError = error
      process.terminationHandler = { [weak self] process in
        self?.lock.withLock { _ = self?.processes.removeValue(forKey: launch.id) }
        (self?.connection?.remoteObjectProxy as? NoodletHostClient)?.exited(
          launch.id, status: process.terminationStatus, signalled: process.terminationReason == .uncaughtSignal)
      }
      try lock.withLock {
        try process.run()
        processes[launch.id] = process
      }
      reply(nil)
    } catch { reply(error.localizedDescription) }
  }
  func terminate(_ id: String) {
    lock.withLock { processes[id] }.map(Self.kill)
  }
  func stop() {
    lock.withLock { Array(processes.values) }.forEach(Self.kill)
  }
  // Foundation gives each child its own group, which takes its descendants too.
  private static func kill(_ process: Process) {
    guard process.isRunning else { return }
    if Darwin.kill(-process.processIdentifier, SIGKILL) != 0 { Darwin.kill(process.processIdentifier, SIGKILL) }
  }
}

private final class HostDelegate: NSObject, NSXPCListenerDelegate {
  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier == getuid(), let requirement = Host.requirement else { return false }
    connection.setCodeSigningRequirement(requirement)
    connection.exportedInterface = NSXPCInterface(with: NoodletHostService.self)
    connection.remoteObjectInterface = NSXPCInterface(with: NoodletHostClient.self)
    let session = HostSession(connection: connection)
    connection.exportedObject = session
    connection.invalidationHandler = { session.stop() }
    connection.interruptionHandler = { session.stop() }
    connection.resume()
    return true
  }
}

private let delegate = HostDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
