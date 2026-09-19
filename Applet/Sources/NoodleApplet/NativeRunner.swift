import AppKit
import AppletBridge
import AppletCore

@MainActor final class NativeRunner {
  let package: NoodletPackage, dataRoot: URL, buildRoot: URL
  let log: AppletLog
  private var process: Process?
  private var input: Pipe?
  private var pending: [String: CheckedContinuation<String, Error>] = [:]
  private var ready = false
  private let buildControl = NativeProcessControl()
  private var interpreter: String?
  private var sdk: String?
  private var plugins: [String] = []
  private let startupError = NativeStartupError()
  /// The first line the native process wrote to standard error, which names
  /// an interpreter failure ahead of its symbol dump.
  var firstErrorLine: String? { startupError.line }
  private var moduleCache: URL {
    buildRoot.deletingLastPathComponent().appendingPathComponent("ModuleCache")
  }
  private let prefix = "NOODLET_\(UUID().uuidString)_"
  var exited: ((Int32, Bool) -> Void)?
  init(package: NoodletPackage, dataRoot: URL, buildRoot: URL, log: AppletLog) {
    self.package = package
    self.dataRoot = dataRoot
    self.buildRoot = buildRoot
    self.log = log
  }
  private static func runProcess(
    _ executable: String, _ arguments: [String], directory: URL, log: AppletLog,
    control: NativeProcessControl, timeout: TimeInterval = 150
  ) async throws {
    let outputURL = directory.appendingPathComponent("compiler-output.txt")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = output
    process.standardError = output
    var env = ProcessInfo.processInfo.environment
    env["CLANG_MODULE_CACHE_PATH"] =
      directory.deletingLastPathComponent().appendingPathComponent("ModuleCache").path
    env["SWIFT_MODULECACHE_PATH"] =
      directory.deletingLastPathComponent().appendingPathComponent("ModuleCache").path
    process.environment = env
    let reader = try CompilerOutput(url: outputURL, log: log)
    let polling = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    polling.schedule(deadline: .now(), repeating: .milliseconds(200))
    polling.setEventHandler { reader.drain() }
    polling.resume()
    try await withCheckedThrowingContinuation { continuation in
      let completion = CompilerCompletion(continuation)
      process.terminationHandler = { process in
        polling.cancel()
        try? output.close()
        reader.drain()
        control.clear(process)
        if process.terminationStatus == 0 {
          completion.finish(.success(()))
        } else {
          completion.finish(
            .failure(
              AppletError(
                "Build command failed (exit \(process.terminationStatus)). Inspect this session's logs for compiler diagnostics."
              )))
        }
      }
      do { try control.start(process) } catch {
        polling.cancel()
        try? output.close()
        completion.finish(.failure(error))
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        guard !completion.finished else { return }
        control.cancel()
        reader.drain()
        completion.finish(
          .failure(
            AppletError(
              "Compiler timed out after \(Int(timeout)) seconds. Inspect build logs.")
          ))
      }
    }
  }

  struct Toolchain { let frontend: String, sdk: String, plugins: [String] }
  // xcrun deliberately refuses App Sandbox. Invoke the installed compiler
  // and SDK directly; the compiler still inherits the app's containment.
  nonisolated static func toolchain() throws -> Toolchain {
    let toolchains: [(String, String)] = [
      (
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
      ),
      (
        "/Library/Developer/CommandLineTools/usr/bin/swiftc",
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
      ),
    ]
    guard
      let toolchain = toolchains.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.0)
          && FileManager.default.fileExists(atPath: $0.1)
      })
    else {
      throw AppletError(
        "Install Xcode in /Applications or Apple's Command Line Tools to compile Swift noodlets. HTML noodlets work without developer tools."
      )
    }
    let frontend = URL(fileURLWithPath: toolchain.0).deletingLastPathComponent()
      .appendingPathComponent("swift-frontend").path
    guard FileManager.default.isExecutableFile(atPath: frontend) else {
      throw AppletError("The installed Swift toolchain is incomplete.")
    }
    return Toolchain(
      frontend: frontend, sdk: toolchain.1,
      plugins: pluginArguments(compiler: toolchain.0, sdk: toolchain.1))
  }
  static let missingMacros =
    "This toolchain has no SwiftUI macro plugins. @State, @Entry and #Preview need Xcode in /Applications."
  // swiftc's driver adds the macro plugin search paths; swift-frontend does
  // not. SwiftUI's macros ship only with Xcode's platform, not Command Line Tools.
  nonisolated static func pluginArguments(compiler: String, sdk: String) -> [String] {
    let files = FileManager.default
    let usr = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent()
    let platform = URL(fileURLWithPath: sdk).deletingLastPathComponent().deletingLastPathComponent()
    var arguments: [String] = []
    for directory in ["lib/swift/host/plugins", "local/lib/swift/host/plugins"] {
      let path = usr.appendingPathComponent(directory).path
      if files.fileExists(atPath: path) { arguments += ["-plugin-path", path] }
    }
    let server = platform.appendingPathComponent("usr/bin/swift-plugin-server").path
    guard files.isExecutableFile(atPath: server) else { return arguments }
    // The compiler wraps the plugin server in sandbox-exec, which App Sandbox
    // refuses to nest. The server still inherits the app's containment.
    arguments.append("-disable-sandbox")
    for directory in ["usr/lib/swift/host/plugins", "usr/local/lib/swift/host/plugins"] {
      let path = platform.appendingPathComponent(directory).path
      if files.fileExists(atPath: path) {
        arguments += ["-external-plugin-path", "\(path)#\(server)"]
      }
    }
    return arguments
  }
  // Availability checks call compiler-rt, which the interpreter does not link.
  private static let availabilitySupport = """

    @_cdecl("__isPlatformVersionAtLeast")
    public func noodletIsPlatformVersionAtLeast(
      _ platform: UInt32, _ major: UInt32, _ minor: UInt32, _ patch: UInt32
    ) -> Int32 {
      ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(
          majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
    }
    @_cdecl("__isOSVersionAtLeast")
    public func noodletIsOSVersionAtLeast(_ major: Int32, _ minor: Int32, _ patch: Int32) -> Int32 {
      ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(
          majorVersion: Int(major), minorVersion: Int(minor), patchVersion: Int(patch))) ? 1 : 0
    }

    """

  /// Typechecks loose Swift sources as one module. No Noodlet view, import or session.
  static func typecheck(_ sources: [String: Data], root: URL) async throws -> (passed: Bool, diagnostics: String) {
    let toolchain = try toolchain()
    let directory = root.appendingPathComponent("Builds/Typecheck-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let names = sources.keys.sorted()
    for name in names {
      let url = directory.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try sources[name]!.write(to: url)
    }
    // Match swiftc: one file, or a main.swift, may hold top-level code.
    let script =
      names.contains { ($0 as NSString).lastPathComponent == "main.swift" }
      || (names.count == 1 && !String(decoding: sources[names[0]]!, as: UTF8.self).contains("@main"))
    var failure: String?
    do {
      try await runProcess(
        toolchain.frontend,
        [
          "-sdk", toolchain.sdk, "-typecheck", "-swift-version", "5", "-module-name", "Sources",
          "-module-cache-path", root.appendingPathComponent("Builds/ModuleCache").path,
        ] + (script ? [] : ["-parse-as-library"]) + toolchain.plugins + names,
        directory: directory, log: AppletLog(url: directory.appendingPathComponent("log.jsonl")),
        control: NativeProcessControl())
    } catch { failure = error.localizedDescription }
    let passed = failure == nil
    var diagnostics =
      (try? String(contentsOf: directory.appendingPathComponent("compiler-output.txt"), encoding: .utf8)) ?? ""
    if !passed, !toolchain.plugins.contains("-external-plugin-path") { diagnostics += missingMacros + "\n" }
    if let failure, diagnostics.isEmpty { diagnostics = failure + "\n" }
    return (passed, diagnostics)
  }

  func build() async throws {
    try FileManager.default.createDirectory(at: buildRoot, withIntermediateDirectories: true)
    let resources = AppletResources.bundle.url(forResource: "Resources", withExtension: nil)!
    let source = resources.appendingPathComponent("NoodletRuntime.swift")
    _ = try NoodletPackage.install(
      package.files(), to: buildRoot.appendingPathComponent("Package.\(AppletBuildIdentity.current.fileExtension)"))
    let toolchain = try Self.toolchain()
    interpreter = toolchain.frontend
    sdk = toolchain.sdk
    plugins = toolchain.plugins
    let files = try package.files().keys.filter { $0.hasSuffix(".swift") }.sorted().map {
      package.url.appendingPathComponent($0)
    }
    var combined = ""
    for file in files {
      let quoted = String(reflecting: file.path)
      combined +=
        "#sourceLocation(file: \(quoted), line: 1)\n"
        + (try String(contentsOf: file, encoding: .utf8)) + "\n#sourceLocation()\n"
    }
    combined += try String(contentsOf: resources.appendingPathComponent("WindowFocusGuard.swift"), encoding: .utf8) + "\n"
    combined += try String(contentsOf: source, encoding: .utf8).replacingOccurrences(
      of: "@main struct NoodletRuntime", with: "struct NoodletRuntime")
    combined += Self.availabilitySupport
    combined += "\nMainActor.assumeIsolated { NoodletRuntime.main() }\n"
    let program = buildRoot.appendingPathComponent("Program.swift")
    try combined.write(to: program, atomically: true, encoding: .utf8)
    log.append(
      "build",
      "Compiling \(files.count) Swift source file(s) with the installed Apple toolchain.")
    do {
      try await Self.runProcess(
        toolchain.frontend,
        [
          "-sdk", toolchain.sdk, "-typecheck", "-swift-version", "5", "-module-name",
          "NoodletCreation", "-module-cache-path", moduleCache.path,
        ] + plugins + [program.path], directory: buildRoot, log: log, control: buildControl)
    } catch {
      if !plugins.contains("-external-plugin-path") {
        log.append("build", Self.missingMacros)
      }
      throw error
    }
    log.append("build", "Build succeeded.")
  }
  func start(mode: String, size: CGSize, rememberFrame: Bool = true) async throws {
    let p = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    guard let interpreter, let sdk else {
      throw AppletError("Build the Swift noodlet before running it.")
    }
    // Evaluate in Apple's signed interpreter process. Generated source is
    // data, so App Sandbox never needs to bless a new executable on disk.
    let snapshot = buildRoot.appendingPathComponent("Package.\(AppletBuildIdentity.current.fileExtension)")
    p.executableURL = URL(fileURLWithPath: interpreter)
    p.currentDirectoryURL = snapshot
    p.arguments = [
      "-interpret", "-enable-objc-interop", "-module-name", "main", "-sdk", sdk,
      "-swift-version", "5", "-module-cache-path", moduleCache.path,
    ] + plugins + [buildRoot.appendingPathComponent("Program.swift").path]
    var env = ProcessInfo.processInfo.environment
    // Match swift-driver's interpreter environment so JIT symbol lookup
    // finds the system SwiftUI framework, including NSHostingView.
    env["DYLD_FRAMEWORK_PATH"] = "/System/Library/Frameworks"
    env["NOODLET_DATA"] = dataRoot.path
    env["NOODLET_PACKAGE"] = snapshot.path
    env["NOODLET_MODE"] = mode
    env["NOODLET_WIDTH"] = String(Int(size.width))
    env["NOODLET_HEIGHT"] = String(Int(size.height))
    env["NOODLET_TITLE"] = package.manifest.title
    env["NOODLET_WINDOW"] = String(
      decoding: try JSONEncoder().encode(package.manifest.window ?? NoodletWindowOptions()),
      as: UTF8.self)
    env["NOODLET_WINDOW_KEY"] = package.key
    env["NOODLET_REMEMBER_FRAME"] = rememberFrame && mode != "headless" ? "1" : "0"
    env["NOODLET_PROTOCOL"] = prefix
    p.environment = env
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = stderr
    let buffer = NativeLineBuffer()
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let lines = buffer.append(handle.availableData)
      Task { @MainActor in for line in lines { self?.receive(line) } }
    }
    let log = self.log
    let startupError = self.startupError
    stderr.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      let text = String(decoding: data, as: UTF8.self)
      startupError.record(text)
      log.append("stderr", text)
    }
    p.terminationHandler = { [weak self] p in
      Task { @MainActor in
        self?.failPending(
          AppletError(
            "Native process exited with \(p.terminationReason == .uncaughtSignal ? "signal" : "status") \(p.terminationStatus)."
          ))
        self?.exited?(p.terminationStatus, p.terminationReason == .uncaughtSignal)
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
      }
    }
    process = p
    input = stdin
    do { try p.run() } catch {
      log.append("launch", String(reflecting: error))
      throw error
    }
    for _ in 0..<1200 {
      if ready { return }
      if !p.isRunning {
        // Standard error is read on another queue and may trail the exit.
        try? await Task.sleep(for: .milliseconds(100))
        throw AppletError(
          "Native process failed during startup\(firstErrorLine.map { ": \($0)." } ?? ".") Inspect logs.")
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    stop()
    throw AppletError("Native view did not become ready within 60 seconds. Inspect logs.")
  }
  private func receive(_ line: String) {
    guard line.hasPrefix(prefix),
      let data = String(line.dropFirst(prefix.count)).data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = object["id"] as? String
    else {
      log.append("stdout", line)
      return
    }
    if id == "ready" {
      ready = true
      return
    }
    guard let callback = pending.removeValue(forKey: id) else { return }
    if let error = object["error"] as? String {
      callback.resume(throwing: AppletError(error))
    } else {
      let value =
        (try? JSONSerialization.data(
          withJSONObject: object["value"] ?? NSNull(),
          options: [.fragmentsAllowed, .sortedKeys])) ?? Data("null".utf8)
      callback.resume(returning: String(decoding: value, as: UTF8.self))
    }
  }
  func perform(_ request: AppletRequest) async throws -> String {
    guard let process, process.isRunning, let input else {
      throw AppletError("Native process is not running.")
    }
    let id = request.id.uuidString
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      do {
        try input.fileHandleForWriting.write(
          contentsOf: JSONEncoder().encode(request) + Data([10]))
      } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(20))
        self?.pending.removeValue(forKey: id)?.resume(
          throwing: AppletError(
            "Native operation timed out. The noodlet may be blocked; terminate or restart it."
          ))
      }
    }
  }
  func snapshot() async throws -> NSImage {
    _ = try await perform(AppletRequest(.screenshot))
    let path = dataRoot.appendingPathComponent(".capture.png")
    guard let image = NSImage(contentsOf: path) else {
      throw AppletError("Native screenshot could not be decoded.")
    }
    return image
  }
  func stop() {
    buildControl.cancel()
    if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    try? input?.fileHandleForWriting.close()
    input = nil
    failPending(AppletError("Noodlet terminated."))
  }
  private func failPending(_ error: Error) {
    let callbacks = pending.values
    pending.removeAll()
    for c in callbacks { c.resume(throwing: error) }
  }
  deinit {
    buildControl.cancel()
    if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    try? FileManager.default.removeItem(at: buildRoot)
  }
}

private final class NativeProcessControl: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?, cancelled = false
  func start(_ process: Process) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { throw AppletError("Build cancelled.") }
    try process.run()
    self.process = process
  }
  func clear(_ process: Process) {
    lock.lock()
    defer { lock.unlock() }
    if self.process === process { self.process = nil }
  }
  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
    if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }
}

private final class NativeStartupError: @unchecked Sendable {
  private let lock = NSLock()
  private var first: String?
  var line: String? {
    lock.lock()
    defer { lock.unlock() }
    return first
  }
  func record(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    guard first == nil else { return }
    first = text.split(whereSeparator: \.isNewline).lazy
      .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
      .map { String($0.prefix(300)) }
  }
}

private final class CompilerCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
  var finished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return continuation == nil
  }
  func finish(_ result: Result<Void, Error>) {
    lock.lock()
    let callback = continuation
    continuation = nil
    lock.unlock()
    callback?.resume(with: result)
  }
}
private final class CompilerOutput: @unchecked Sendable {
  private let lock = NSLock(), reader: FileHandle, log: AppletLog
  init(url: URL, log: AppletLog) throws {
    reader = try FileHandle(forReadingFrom: url)
    self.log = log
  }
  func drain() {
    lock.lock()
    defer { lock.unlock() }
    while let data = try? reader.read(upToCount: 16384), !data.isEmpty {
      log.append("build", String(decoding: data, as: UTF8.self))
    }
  }
  deinit { try? reader.close() }
}

private final class NativeLineBuffer: @unchecked Sendable {
  let lock = NSLock()
  var bytes = Data()
  func append(_ data: Data) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    bytes.append(data)
    var lines: [String] = []
    if data.isEmpty && !bytes.isEmpty {
      lines.append(String(decoding: bytes, as: UTF8.self))
      bytes.removeAll()
      return lines
    }
    while let end = bytes.firstIndex(of: 10) {
      lines.append(String(decoding: bytes[..<end], as: UTF8.self))
      bytes.removeSubrange(...end)
    }
    if bytes.count > 1_048_576 {
      lines.append(String(decoding: bytes, as: UTF8.self))
      bytes.removeAll()
    }
    return lines
  }
}
