import AppKit
import AppletBridge
import AppletCore

@MainActor final class NativeRunner {
  let package: NoodletPackage, dataRoot: URL, buildRoot: URL
  let log: AppletLog
  var secrets = AppletSecrets.shared
  /// Granted manifest permissions, which the confinement has to admit as well.
  var devices: [String] = []
  /// Only a visible noodlet may raise Applet's file dialogs.
  private var foreground = false
  /// A noodlet the user cannot see must not be heard. The confinement decides this
  /// when the process starts, so a noodlet launched out of sight stays silent for
  /// its whole run and has to start again to be heard.
  private(set) var audible = false
  nonisolated static func audible(mode: String) -> Bool { mode == "foreground" }
  private var process: ConfinedProcess?
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
  private var root: URL { buildRoot.deletingLastPathComponent().deletingLastPathComponent() }
  /// Frameworks keep caches and window frames under the home directory. The
  /// noodlet's own one lives beside its data, never in Applet's.
  private var home: URL {
    root.appendingPathComponent("Homes/\(package.key)/\(dataRoot.lastPathComponent)")
  }
  // Applet's environment names its container. A confined process starts clean.
  private static func environment(home: URL) -> [String: String] {
    var env = ProcessInfo.processInfo.environment.filter {
      ["PATH", "LANG", "USER", "LOGNAME", "__CF_USER_TEXT_ENCODING"].contains($0.key) || $0.key.hasPrefix("LC_")
    }
    env["HOME"] = home.path
    env["CFFIXED_USER_HOME"] = home.path
    env["TMPDIR"] = home.appendingPathComponent("tmp").path
    return env
  }
  private let prefix = "NOODLET_\(UUID().uuidString)_"
  var exited: ((Int32, Bool) -> Void)?
  init(package: NoodletPackage, dataRoot: URL, buildRoot: URL, log: AppletLog) {
    self.package = package
    self.dataRoot = dataRoot
    self.buildRoot = buildRoot
    self.log = log
  }
  /// The compiler runs no noodlet code, so it may fill the shared module cache.
  private static func runProcess(
    _ executable: String, _ arguments: [String], directory: URL, log: AppletLog,
    control: NativeProcessControl, timeout: TimeInterval = 150
  ) async throws {
    let outputURL = directory.appendingPathComponent("compiler-output.txt")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    let cache = directory.deletingLastPathComponent().appendingPathComponent("ModuleCache")
    let scratch = directory.appendingPathComponent("Home")
    for folder in [cache, scratch.appendingPathComponent("tmp")] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    var env = environment(home: scratch)
    env["CLANG_MODULE_CACHE_PATH"] = cache.path
    env["SWIFT_MODULECACHE_PATH"] = cache.path
    let process = ConfinedProcess(
      NoodletLaunch(
        executable: executable, arguments: arguments, environment: env, directory: directory.path,
        readable: [], writable: [directory.path, cache.path]),
      root: directory.deletingLastPathComponent().deletingLastPathComponent())
    process.output = output
    process.error = output
    let reader = try CompilerOutput(url: outputURL, log: log)
    let polling = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    polling.schedule(deadline: .now(), repeating: .milliseconds(200))
    polling.setEventHandler { reader.drain() }
    polling.resume()
    try await withCheckedThrowingContinuation { continuation in
      let completion = CompilerCompletion(continuation)
      process.terminationHandler = { [weak process] status, _ in
        polling.cancel()
        try? output.close()
        reader.drain()
        if let process { control.clear(process) }
        if status == 0 {
          completion.finish(.success(()))
        } else {
          completion.finish(
            .failure(
              AppletError(
                "Build command failed (exit \(status)). Inspect this session's logs for compiler diagnostics."
              )))
        }
      }
      Task {
        do { try await control.start(process) } catch {
          polling.cancel()
          try? output.close()
          completion.finish(.failure(error))
        }
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
    try await warm(combined, toolchain: toolchain)
    log.append("build", "Build succeeded.")
  }
  private func interpreterArguments(_ program: URL, sdk: String) -> [String] {
    [
      "-interpret", "-enable-objc-interop", "-module-name", "main", "-sdk", sdk,
      "-swift-version", "5", "-module-cache-path", moduleCache.path,
    ] + plugins + [program.path]
  }
  /// Module names the source imports, whatever attributes or kinds decorate them.
  nonisolated static func imports(_ source: String) -> [String] {
    let kinds: Set<Substring> = ["struct", "class", "enum", "protocol", "typealias", "func", "let", "var"]
    var modules = Set<String>()
    for line in source.split(whereSeparator: { $0.isNewline || $0 == ";" }) {
      var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })[...]
      while words.first?.hasPrefix("@") == true { words = words.dropFirst() }
      guard words.first == "import" else { continue }
      words = words.dropFirst()
      if let kind = words.first, kinds.contains(kind) { words = words.dropFirst() }
      guard let module = words.first?.split(separator: ".").first,
        module.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
      else { continue }
      modules.insert(String(module))
    }
    return modules.sorted()
  }
  // The interpreter keeps Clang modules under a different hash than -typecheck,
  // and a running noodlet may not write the cache it shares with the others.
  // Interpreting the import lines alone fills it without running noodlet code.
  private func warm(_ source: String, toolchain: Toolchain) async throws {
    let program = buildRoot.appendingPathComponent("Imports.swift")
    try Self.imports(source).map { "#if canImport(\($0))\nimport \($0)\n#endif\n" }.joined()
      .write(to: program, atomically: true, encoding: .utf8)
    try await Self.runProcess(
      toolchain.frontend, interpreterArguments(program, sdk: toolchain.sdk), directory: buildRoot,
      log: log, control: buildControl)
  }
  func start(mode: String, size: CGSize, rememberFrame: Bool = true) async throws {
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    guard let interpreter, let sdk else {
      throw AppletError("Build the Swift noodlet before running it.")
    }
    // Evaluate in Apple's signed interpreter process. Generated source is
    // data, so App Sandbox never needs to bless a new executable on disk.
    let snapshot = buildRoot.appendingPathComponent("Package.\(AppletBuildIdentity.current.fileExtension)")
    for folder in [dataRoot, home.appendingPathComponent("tmp")] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    foreground = mode == "foreground"
    audible = Self.audible(mode: mode)
    if !audible {
      log.append("audio", "Silent: a noodlet started outside the foreground has no audio output, and AVAudioEngine cannot start there. Restart it with --mode foreground for sound.")
    }
    var env = Self.environment(home: home)
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
    env["NOODLET_REMEMBER_FRAME"] = rememberFrame && mode != "headless" ? "1" : "0"
    env["NOODLET_PROTOCOL"] = prefix
    // The noodlet reads its build and the module cache and writes only its own
    // data and home. Nothing else of Applet's, or the user's, is in reach.
    let p = ConfinedProcess(
      NoodletLaunch(
        executable: interpreter,
        arguments: interpreterArguments(buildRoot.appendingPathComponent("Program.swift"), sdk: sdk),
        environment: env, directory: snapshot.path, readable: [buildRoot.path, moduleCache.path],
        writable: [dataRoot.path, home.path], devices: devices, audible: Self.audible(mode: mode)),
      root: root)
    p.input = stdin.fileHandleForReading
    p.output = stdout.fileHandleForWriting
    p.error = stderr.fileHandleForWriting
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
    p.terminationHandler = { [weak self] status, signalled in
      Task { @MainActor in
        self?.failPending(
          AppletError("Native process exited with \(signalled ? "signal" : "status") \(status)."))
        self?.exited?(status, signalled)
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
      }
    }
    process = p
    input = stdin
    do { try await p.run() } catch {
      log.append("launch", String(reflecting: error))
      throw error
    }
    // The child holds its own copies. Keeping these open would hide its exit.
    try? stdin.fileHandleForReading.close()
    try? stdout.fileHandleForWriting.close()
    try? stderr.fileHandleForWriting.close()
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
    // The noodlet asking the host. Only this noodlet's pipe reaches here, so the
    // account is the host's, never one the noodlet names.
    if let call = object["call"] as? String {
      let name = object["name"] as? String, value = object["value"] as? String
      Task {
        var reply: [String: Any] = ["reply": id]
        do {
          if call.hasPrefix("secrets.") {
            reply["value"] = try secrets.perform(
              String(call.dropFirst("secrets.".count)), name: name, value: value,
              account: AppletSecrets.account(package, dataRoot: dataRoot))
          } else if call == "files.open" {
            reply["value"] = try await openFile() ?? NSNull()
          } else if call == "files.save" {
            reply["value"] = try await saveFile(name ?? "", suggested: value)
          } else {
            throw AppletError("Unknown host call.")
          }
        } catch { reply["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: reply) {
          try? input?.fileHandleForWriting.write(contentsOf: data + Data([10]))
        }
      }
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
  // A confined noodlet cannot raise a file dialog. Applet asks the user for it
  // and hands over a copy inside the noodlet's data, so only the chosen file moves.
  private func openFile() async throws -> String? {
    guard foreground else { throw AppletError("File dialogs require foreground mode.") }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    NSApp.activate(ignoringOtherApps: true)
    guard await panel.begin() == .OK, let file = panel.url else { return nil }
    let access = file.startAccessingSecurityScopedResource()
    defer { if access { file.stopAccessingSecurityScopedResource() } }
    let relative = "Selected/\(UUID().uuidString)/\(file.lastPathComponent)"
    let copy = try NoodletPackage.child(relative, in: dataRoot)
    try FileManager.default.createDirectory(
      at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: file, to: copy)
    return relative
  }
  private func saveFile(_ relative: String, suggested: String?) async throws -> Bool {
    guard foreground else { throw AppletError("File dialogs require foreground mode.") }
    let source = try NoodletPackage.child(relative, in: dataRoot)
    guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      throw AppletError("Save a regular file from the noodlet's data directory.")
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = URL(fileURLWithPath: suggested ?? relative).lastPathComponent
    NSApp.activate(ignoringOtherApps: true)
    guard await panel.begin() == .OK, let file = panel.url else { return false }
    let access = file.startAccessingSecurityScopedResource()
    defer { if access { file.stopAccessingSecurityScopedResource() } }
    try Data(contentsOf: source).write(to: file, options: .atomic)
    return true
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
    // A link here would have Applet read a file the noodlet itself cannot.
    let path = try NoodletPackage.child(".capture.png", in: dataRoot)
    guard let image = NSImage(contentsOf: path) else {
      throw AppletError("Native screenshot could not be decoded.")
    }
    return image
  }
  func stop() {
    buildControl.cancel()
    process?.kill()
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
    process?.kill()
    try? FileManager.default.removeItem(at: buildRoot)
  }
}

private final class NativeProcessControl: @unchecked Sendable {
  private let lock = NSLock()
  private var process: ConfinedProcess?, cancelled = false
  func start(_ process: ConfinedProcess) async throws {
    try lock.withLock {
      guard !cancelled else { throw AppletError("Build cancelled.") }
      self.process = process
    }
    try await process.run()
    // Cancelled while the host was starting it.
    if lock.withLock({ cancelled }) { process.kill() }
  }
  func clear(_ process: ConfinedProcess) {
    lock.withLock { if self.process === process { self.process = nil } }
  }
  func cancel() {
    let running = lock.withLock {
      cancelled = true
      return process
    }
    running?.kill()
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
