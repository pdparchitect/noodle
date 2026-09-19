import AppletBridge
import AppletCore
import Foundation

/// A compiler or native noodlet under NoodletConfinement. The signed bundle asks
/// its host service; an unbundled build has no App Sandbox and confines directly.
final class ConfinedProcess: @unchecked Sendable {
  let launch: NoodletLaunch
  private let root: URL
  var input: FileHandle?
  var output = FileHandle.nullDevice
  var error = FileHandle.nullDevice
  var terminationHandler: (@Sendable (Int32, Bool) -> Void)?
  private let lock = NSLock()
  private var running = false
  private var local: Process?

  init(_ launch: NoodletLaunch, root: URL) {
    self.launch = launch
    self.root = root
  }
  var isRunning: Bool { lock.withLock { running } }

  func run() async throws {
    lock.withLock { running = true }
    do {
      if NoodletHostConnection.service != nil {
        try await NoodletHostConnection.shared.launch(self)
      } else if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil {
        let process = try NoodletConfinement.process(launch, within: root)
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        process.terminationHandler = { [weak self] process in
          self?.finish(process.terminationStatus, process.terminationReason == .uncaughtSignal)
        }
        try process.run()
        lock.withLock { local = process }
      } else {
        throw AppletError("Native noodlets need Applet's confinement service. Reinstall Noodle Applet.")
      }
    } catch {
      lock.withLock { running = false }
      throw error
    }
  }
  func kill() {
    guard isRunning else { return }
    if let local = lock.withLock({ local }) {
      if Darwin.kill(-local.processIdentifier, SIGKILL) != 0 { Darwin.kill(local.processIdentifier, SIGKILL) }
    } else {
      NoodletHostConnection.shared.terminate(launch.id)
    }
  }
  fileprivate func finish(_ status: Int32, _ signalled: Bool) {
    let wasRunning = lock.withLock {
      defer { running = false }
      return running
    }
    if wasRunning { terminationHandler?(status, signalled) }
  }
}

private final class NoodletHostConnection: NSObject, NoodletHostClient, @unchecked Sendable {
  static let shared = NoodletHostConnection()
  static let service = Bundle(
    url: Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/NoodletHost.xpc"))?.bundleIdentifier
  private let lock = NSLock()
  private var connection: NSXPCConnection?
  private var processes: [String: ConfinedProcess] = [:]

  private func proxy(_ failure: @escaping (Error) -> Void) -> NoodletHostService? {
    let connection = lock.withLock {
      if let connection { return connection }
      let created = NSXPCConnection(serviceName: Self.service ?? "")
      created.remoteObjectInterface = NSXPCInterface(with: NoodletHostService.self)
      created.exportedInterface = NSXPCInterface(with: NoodletHostClient.self)
      created.exportedObject = self
      // The host kills its children when the connection drops.
      created.interruptionHandler = { [weak self] in self?.lost() }
      created.invalidationHandler = { [weak self] in self?.lost() }
      created.resume()
      connection = created
      return created
    }
    return connection.remoteObjectProxyWithErrorHandler(failure) as? NoodletHostService
  }
  private func lost() {
    let (dropped, orphans) = lock.withLock {
      defer {
        connection = nil
        processes.removeAll()
      }
      return (connection, Array(processes.values))
    }
    dropped?.invalidate()
    for process in orphans { process.finish(SIGKILL, true) }
  }
  func launch(_ process: ConfinedProcess) async throws {
    let request = try JSONEncoder().encode(process.launch)
    lock.withLock { processes[process.launch.id] = process }
    do {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        guard let proxy = proxy({ continuation.resume(throwing: $0) }) else {
          return continuation.resume(throwing: AppletError("Applet's confinement service is unavailable."))
        }
        proxy.launch(request, input: process.input, output: process.output, error: process.error) { failure in
          if let failure { continuation.resume(throwing: AppletError(failure)) } else { continuation.resume() }
        }
      }
    } catch {
      lock.withLock { _ = processes.removeValue(forKey: process.launch.id) }
      throw error
    }
  }
  func terminate(_ id: String) { proxy { _ in }?.terminate(id) }
  func exited(_ id: String, status: Int32, signalled: Bool) {
    lock.withLock { processes.removeValue(forKey: id) }?.finish(status, signalled)
  }
}
