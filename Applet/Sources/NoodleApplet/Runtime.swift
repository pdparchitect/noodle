import AppKit
import AppletBridge
import AppletCore

@MainActor final class AppletSession {
  let id = UUID(), package: NoodletPackage, owner: String, log: AppletLog, dataRoot: URL
  var lock: InstanceLock?
  var state = "starting", mode: String, revision: String
  let size: CGSize
  var web: WebRunner?, native: NativeRunner?, recording: AppletRecording?
  init(package: NoodletPackage, owner: String, mode: String, size: CGSize, root: URL) throws {
    self.package = package
    self.owner = owner
    self.mode = mode
    self.size = size
    revision = package.revision
    dataRoot = root.appendingPathComponent(
      "Data/\(package.key)/\(mode == "headless" ? "Testing" : "User")")
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    log = AppletLog(url: root.appendingPathComponent("Logs/\(id.uuidString).jsonl"))
    lock = try InstanceLock(
      location: package.url, directory: root.appendingPathComponent("Locks"))
  }
  func snapshot() async throws -> NSImage {
    if let web { return try await web.snapshot() }
    if let native { return try await native.snapshot() }
    throw AppletError("The noodlet has no running view.")
  }
  func stop() {
    recording?.cancel()
    recording = nil
    web?.stop()
    web = nil
    native?.stop()
    native = nil
    lock = nil
    state = "stopped"
    log.append("lifecycle", "Stopped.")
  }
}

@MainActor final class AppletRuntime: ObservableObject {
  let library: AppletLibrary
  @Published var sessions: [UUID: AppletSession] = [:]
  @Published var error: String?
  private var server: AppletConnectionServer?
  private var artifacts: [UUID: (owner: String, url: URL)] = [:]
  private var origins: [String: String]
  private var owners: [String: String]
  init(library: AppletLibrary) {
    self.library = library
    origins =
      UserDefaults.standard.dictionary(forKey: "sourceOrigins") as? [String: String] ?? [:]
    owners =
      UserDefaults.standard.dictionary(forKey: "packageOwners") as? [String: String] ?? [:]
  }
  func startServer() {
    for entry in library.entries {
      let thumbnail = library.root.appendingPathComponent("Thumbnails/\(entry.id).png")
      if let data = try? Data(contentsOf: thumbnail) {
        try? PreviewCache.save(data, for: entry.package.url)
      }
    }
    do {
      server = try AppletConnectionServer(
        socket: AppletConnection.socketURL(), team: AppletConnection.signingTeam()
      ) { [weak self] request, identity in
        await self?.handle(request, identity: identity)
          ?? AppletResponse(error: "Noodle Applet is shutting down.")
      }
    } catch { self.error = error.localizedDescription }
  }
  func handle(_ input: AppletRequest, identity: String) async -> AppletResponse {
    do {
      var request = input
      try request.validate()
      let owner =
        identity == "com.pdparchitect.noodle" || identity == "com.pdparchitect.noodle.local"
        ? (request.owner ?? "local") : "local"
      request.owner = owner
      if request.operation == .artifact {
        guard let id = request.artifactID, let artifact = artifacts[id],
          owner == "local" || artifact.owner == owner
        else { throw AppletError("Artifact is unavailable to this caller.") }
        let reader = try FileHandle(forReadingFrom: artifact.url)
        defer { try? reader.close() }
        let offset = request.offset ?? 0
        try reader.seek(toOffset: UInt64(offset))
        let data = try reader.read(upToCount: 1_048_576) ?? Data()
        let size = try artifact.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var response = AppletResponse()
        response.data = data
        response.offset = offset + data.count
        response.done = offset + data.count >= size
        return response
      }
      if request.operation == .list {
        library.scan()
        var response = AppletResponse()
        response.items = library.entries.filter {
          owner == "local" || belongs($0.package, owner: owner)
        }.map { entry in
          let session = sessions.values.first {
            $0.package.key == entry.id
              && ["starting", "building", "running"].contains($0.state)
          }
          return AppletItem(
            path: entry.package.url.path, title: entry.title,
            runtime: entry.package.manifest.runtime, sessionID: session?.id,
            state: session?.state)
        }
        return response
      }
      if [.open, .build, .validate].contains(request.operation) {
        guard let path = request.path else {
          throw AppletError("Provide --path to a .noodlet package.")
        }
        let package: NoodletPackage
        let canonical = URL(fileURLWithPath: origins[owner + "\0" + path] ?? path)
          .resolvingSymlinksInPath().standardizedFileURL
        if let entry = library.entries.first(where: { $0.package.url == canonical }),
          owner == "local" || belongs(entry.package, owner: owner)
        {
          if let files = request.files, origins[owner + "\0" + path] != nil {
            package = try NoodletPackage.install(files, to: canonical)
          } else {
            package = try NoodletPackage(url: canonical)
          }
        } else if let files = request.files {
          let key = NoodletPackage.digest(Data((owner + "\0" + path).utf8))
          let destination = library.documents.appendingPathComponent(
            "Imports/\(ownerKey(owner))/\(key).noodlet")
          package = try NoodletPackage.install(files, to: destination)
          origins[owner + "\0" + path] = package.url.path
          UserDefaults.standard.set(origins, forKey: "sourceOrigins")
        } else {
          let canonical = URL(fileURLWithPath: origins[owner + "\0" + path] ?? path)
            .resolvingSymlinksInPath().standardizedFileURL
          package = try NoodletPackage(url: canonical)
          guard library.entries.contains(where: { $0.package.url == canonical }),
            owner == "local" || belongs(package, owner: owner)
          else {
            throw AppletError(
              "Package is outside this caller's library. Send package files or open it through the app."
            )
          }
        }
        if owners[package.key] == nil {
          owners[package.key] = owner
          UserDefaults.standard.set(owners, forKey: "packageOwners")
        }
        _ = try package.files()
        if request.operation == .validate {
          var response = AppletResponse()
          response.path = package.url.path
          response.state = "valid"
          return response
        }
        if let existing = sessions.values.first(where: {
          $0.package.key == package.key
            && ["starting", "building", "running"].contains($0.state)
        }) {
          guard owner == "local" || existing.owner == owner else {
            throw AppletError("This package is already running for another caller.")
          }
          if request.mode == "foreground" { try await show(existing) }
          var response = status(existing)
          if existing.revision != package.revision {
            response.text =
              "Source changed. Use restart to rebuild and reload the live instance."
          }
          return response
        }
        return try await launch(
          package, request: request,
          owner: owner == "local" ? (owners[package.key] ?? owner) : owner)
      }
      guard let session = find(request, owner: owner) else {
        if [.status, .logs].contains(request.operation), let id = request.sessionID,
          let saved = try? Data(
            contentsOf: library.root.appendingPathComponent(
              "Sessions/\(id.uuidString).json")),
          let record = try? JSONDecoder().decode(SessionRecord.self, from: saved),
          owner == "local" || record.owner == owner
        {
          var response = record.response
          if ["running", "building", "starting"].contains(response.state ?? "") {
            response.state = "interrupted"
          }
          if request.operation == .logs {
            let (bytes, next) = try AppletLog(
              url: library.root.appendingPathComponent("Logs/\(id.uuidString).jsonl")
            ).read(offset: request.offset ?? 0)
            response.text = String(decoding: bytes, as: UTF8.self)
            response.offset = next
            response.done = true
          }
          return response
        }
        throw AppletError("Session not found. Use list, then --session UUID or --path.")
      }
      switch request.operation {
      case .status: return status(session)
      case .logs:
        let (data, next) = try session.log.read(offset: request.offset ?? 0)
        var response = status(session)
        response.text = String(decoding: data, as: UTF8.self)
        response.offset = next
        response.done = ["stopped", "failed", "built"].contains(session.state)
        return response
      case .close, .terminate:
        session.stop()
        objectWillChange.send()
        return status(session)
      case .restart:
        session.stop()
        var start = request
        start.mode = request.mode ?? session.mode
        start.width = request.width ?? Int(session.size.width)
        start.height = request.height ?? Int(session.size.height)
        return try await launch(
          NoodletPackage(url: session.package.url), request: start, owner: session.owner)
      case .show:
        try await show(session)
        return status(session)
      case .hide:
        if let web = session.web { web.hide() }
        if let native = session.native {
          _ = try await native.perform(AppletRequest(.hide))
        }
        session.mode = "background"
        return status(session)
      case .screenshot, .present:
        let image = try await session.snapshot()
        let url = try save(image, session: session)
        var response = status(session)
        response.artifactID = register(url, owner: owner)
        response.mediaType = "image/png"
        response.width = Int(image.size.width)
        response.height = Int(image.size.height)
        response.text = session.package.manifest.title
        return response
      case .recordStart:
        guard session.recording == nil else {
          throw AppletError("Recording is already active.")
        }
        let directory = library.root.appendingPathComponent("Captures")
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true)
        let recording = try AppletRecording(
          url: directory.appendingPathComponent("\(UUID().uuidString).mp4"),
          size: session.size)
        recording.start(
          snapshot: { [weak session] in
            guard let session else { throw AppletError("Session ended.") }
            return try await session.snapshot()
          }, duration: request.duration ?? 30)
        session.recording = recording
        session.log.append("recording", "Started capture (silent MP4, up to 12 fps).")
        var response = status(session)
        response.text =
          "Recording started. Call record stop to finalize and retrieve the MP4."
        return response
      case .recordStop:
        guard let recording = session.recording else {
          throw AppletError("No recording is active.")
        }
        session.recording = nil
        try await recording.finish()
        var response = status(session)
        response.artifactID = register(recording.url, owner: owner)
        response.mediaType = "video/mp4"
        return response
      case .inspect, .eval, .click, .type, .key, .scroll, .drag:
        guard session.state == "running" else {
          throw AppletError("Session is \(session.state). Restart it first.")
        }
        let result: String
        if let web = session.web {
          result = try await web.perform(request)
        } else if let native = session.native {
          result = try await native.perform(request)
        } else {
          throw AppletError("No runner is attached.")
        }
        var response = status(session)
        response.value = result
        return response
      default: throw AppletError("Operation is not valid for this session.")
      }
    } catch { return AppletResponse(error: error.localizedDescription) }
  }
  private func ownerKey(_ owner: String) -> String { NoodletPackage.digest(Data(owner.utf8)) }
  private func belongs(_ package: NoodletPackage, owner: String) -> Bool {
    package.url.path.hasPrefix(
      library.documents.appendingPathComponent("Imports/\(ownerKey(owner))").path + "/")
  }
  private func find(_ request: AppletRequest, owner: String) -> AppletSession? {
    if let id = request.sessionID {
      return sessions[id].flatMap { owner == "local" || $0.owner == owner ? $0 : nil }
    }
    if let path = request.path {
      let url = URL(fileURLWithPath: origins[owner + "\0" + path] ?? path)
        .resolvingSymlinksInPath().standardizedFileURL
      return sessions.values.filter {
        (owner == "local" || $0.owner == owner) && $0.package.url == url
      }.sorted { $0.state == "running" && $1.state != "running" }.first
    }
    return nil
  }
  private func launch(_ package: NoodletPackage, request: AppletRequest, owner: String)
    async throws -> AppletResponse
  {
    let session = try AppletSession(
      package: package, owner: owner, mode: request.mode ?? "background",
      size: (package.manifest.window ?? NoodletWindowOptions()).size(
        width: request.width, height: request.height),
      root: library.root)
    sessions[session.id] = session
    session.log.append(
      "lifecycle",
      "Opening \(package.manifest.title) (\(package.manifest.runtime), \(session.mode)).")
    do {
      if package.manifest.runtime == "html" {
        if request.operation == .build {
          session.state = "built"
          session.lock = nil
          session.native = nil
          return status(session)
        }
        let storeKey =
          "store.\(package.key).\(session.mode == "headless" ? "test" : "user")"
        let storeID =
          UserDefaults.standard.string(forKey: storeKey).flatMap(UUID.init(uuidString:))
          ?? UUID()
        UserDefaults.standard.set(storeID.uuidString, forKey: storeKey)
        let runner = WebRunner(
          package: package, dataRoot: session.dataRoot, log: session.log,
          size: session.size, storeID: storeID,
          rememberFrame: session.mode != "headless" && request.width == nil && request.height == nil
        )
        runner.failed = { [weak self, weak session] message in
          guard let session else { return }
          session.stop()
          session.state = "failed"
          _ = self?.status(session)
          self?.objectWillChange.send()
        }
        runner.closed = { [weak self, weak session] in
          guard let session else { return }
          session.stop()
          _ = self?.status(session)
          self?.objectWillChange.send()
        }
        session.web = runner
        try await runner.start(foreground: session.mode == "foreground")
      } else {
        let runner = NativeRunner(
          package: package, dataRoot: session.dataRoot,
          buildRoot: library.root.appendingPathComponent(
            "Builds/\(session.id.uuidString)"), log: session.log)
        session.native = runner
        session.state = "building"
        _ = status(session)
        objectWillChange.send()
        try await runner.build()
        guard session.state != "stopped" else { throw AppletError("Build cancelled.") }
        if request.operation == .build {
          session.state = "built"
          session.lock = nil
          session.native = nil
          return status(session)
        }
        runner.exited = { [weak self, weak session] code, signal in
          guard let session else { return }
          if session.state != "stopped" {
            session.state = code == 0 ? "stopped" : "failed"
            session.log.append(
              signal ? "crash" : "exit",
              "Native process \(signal ? "signal":"status") \(code).")
            session.lock = nil
          }
          _ = self?.status(session)
          self?.objectWillChange.send()
        }
        try await runner.start(
          mode: session.mode, size: session.size,
          rememberFrame: request.width == nil && request.height == nil)
      }
      session.state = "running"
      session.log.append("lifecycle", "Ready.")
      library.remember(package)
      objectWillChange.send()
      Task { [weak self, weak session] in
        try? await Task.sleep(for: .milliseconds(500))
        if let self, let session, session.state == "running",
          let image = try? await session.snapshot()
        {
          _ = try? self.save(image, session: session)
        }
      }
      return status(session)
    } catch {
      let cancelled = session.state == "stopped"
      session.log.append("error", error.localizedDescription)
      session.stop()
      session.state = cancelled ? "stopped" : "failed"
      objectWillChange.send()
      var response = status(session)
      response.error = "\(error.localizedDescription) Session: \(session.id.uuidString)."
      return response
    }
  }
  func open(_ package: NoodletPackage) {
    Task {
      var request = AppletRequest(.open)
      request.path = package.url.path
      request.mode = "foreground"
      request.owner = owners[package.key] ?? "local"
      let result = await handle(request, identity: "com.pdparchitect.noodle")
      if let error = result.error { self.error = error }
    }
  }
  private func show(_ session: AppletSession) async throws {
    if let web = session.web { web.show() }
    if let native = session.native { _ = try await native.perform(AppletRequest(.show)) }
    session.mode = "foreground"
  }
  private func status(_ session: AppletSession) -> AppletResponse {
    var response = AppletResponse()
    response.sessionID = session.id
    response.state = session.state
    response.path = session.package.url.path
    response.capabilities =
      session.package.manifest.runtime == "html"
      ? [
        "inspect", "eval", "synthetic-input", "screenshot", "silent-video", "storage",
        "foreground-file-dialogs",
      ] : ["inspect", "native-input", "view-screenshot", "silent-video", "data-directory"]
    let directory = library.root.appendingPathComponent("Sessions")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(
      SessionRecord(owner: session.owner, response: response))
    {
      try? data.write(
        to: directory.appendingPathComponent("\(session.id.uuidString).json"),
        options: .atomic)
    }
    return response
  }
  private func save(_ image: NSImage, session: AppletSession) throws -> URL {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { throw AppletError("PNG encoding failed.") }
    let dir = library.root.appendingPathComponent("Captures")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(UUID().uuidString).png")
    try png.write(to: url, options: .atomic)
    let thumbs = library.root.appendingPathComponent("Thumbnails")
    try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
    try png.write(
      to: thumbs.appendingPathComponent("\(session.package.key).png"), options: .atomic)
    try PreviewCache.save(png, for: session.package.url)
    for (source, destination) in origins where destination == session.package.url.path {
      if let path = source.split(separator: "\0", maxSplits: 1).last {
        try? PreviewCache.save(png, for: URL(fileURLWithPath: String(path)))
      }
    }
    objectWillChange.send()
    return url
  }
  private func register(_ url: URL, owner: String) -> UUID {
    let id = UUID()
    artifacts[id] = (owner, url)
    return id
  }
  func shutdown() {
    for session in sessions.values {
      session.stop()
      _ = status(session)
    }
  }
}
private struct SessionRecord: Codable {
  let owner: String
  var response: AppletResponse
}
