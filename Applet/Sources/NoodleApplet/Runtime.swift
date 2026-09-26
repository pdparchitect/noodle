import AppKit
import AppletBridge
import AppletCore

@MainActor final class AppletSession {
  let id = UUID(), package: NoodletPackage, owner: String, log: AppletLog, dataRoot: URL
  var lock: InstanceLock?
  var state = "starting", mode: String, revision: String
  var failure: String?
  let createdAt = Date()
  let testClock: Bool
  var isActive: Bool { ["starting", "building", "running"].contains(state) }
  /// Whether showing this session would still leave the user without the noodlet
  /// they asked for. A page's sound follows its window, but a native noodlet's
  /// confinement and a test session's data are both fixed when the process starts.
  var needsRelaunchToBeSeenAndHeard: Bool {
    if let native { return !native.audible }
    return dataRoot.lastPathComponent == "Testing"
  }
  let size: CGSize
  var web: WebRunner?, native: NativeRunner?, recording: AppletRecording?
  init(package: NoodletPackage, owner: String, mode: String, size: CGSize, root: URL,
       testClock: Bool = false) throws {
    self.package = package
    self.owner = owner
    self.mode = mode
    self.testClock = testClock
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
    guard state == "running" else {
      throw AppletError("Session \(id) (\(mode)) is \(state).", code: "session-not-running")
    }
    if let web { return try await web.snapshot() }
    if let native { return try await native.snapshot() }
    throw AppletError("The noodlet has no running view.")
  }
  /// Hands the noodlet's sound to the recording. A noodlet that cannot be heard
  /// still records a video; the log says why it has no sound.
  func listen(_ recording: AppletRecording) async {
    let sink: ([Int16], Double) -> Void = { [weak recording] samples, at in
      recording?.appendAudio(samples, at: at)
    }
    do {
      try await web?.listen(sink)
      try await native?.listen(sink)
    } catch { log.append("recording", "Recording without sound: \(error.localizedDescription)") }
  }
  func stopListening() async {
    do {
      try await web?.stopListening()
      try await native?.stopListening()
    } catch {
      log.append("recording", "The end of the sound may be missing: \(error.localizedDescription)")
    }
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
  /// The noodlet whose window is key, which File > Show in Finder reveals.
  @Published private(set) var frontPackage: NoodletPackage?
  private var server: AppletConnectionServer?
  private var artifacts: [UUID: (owner: String, url: URL)] = [:]
  /// Where a person watching an HTML noodlet remotely clicks and types, one per session.
  private var surfaceInjectors: [UUID: (view: NSView, injector: SurfaceEventInjector)] = [:]
  /// Live views of sessions. While one is watched, bots cannot drive that session.
  private var surfaceStreamers: [UUID: SurfaceStreamer] = [:]
  private var origins: [String: String]
  private var owners: [String: String]
  private let defaults: UserDefaults
  /// Returns why a noodlet may not use the permissions it declares. Replaced in tests.
  lazy var authorize: (NoodletPackage) async -> String? = { [defaults] in
    await AppletPermissions.authorize($0, defaults: defaults)
  }
  init(library: AppletLibrary, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.library = library
    origins =
      defaults.dictionary(forKey: "sourceOrigins") as? [String: String] ?? [:]
    owners =
      defaults.dictionary(forKey: "packageOwners") as? [String: String] ?? [:]
    for change in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      NotificationCenter.default.addObserver(forName: change, object: nil, queue: .main) { [weak self] note in
        let key = change == NSWindow.didBecomeKeyNotification
        MainActor.assumeIsolated {
          guard let self else { return }
          let package = self.package(showing: note.object as? NSWindow)
          if key { self.frontPackage = package } else if package != nil { self.frontPackage = nil }
        }
      }
    }
    // Play On lists the displays, and AirPlay adds and removes a TV while Applet runs.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
  }
  /// The running window a noodlet can play on another display, whichever runtime draws it.
  func castTarget(for key: String) -> NoodletCastTarget? {
    sessions.values.lazy.filter { $0.package.key == key }
      .compactMap { $0.web as NoodletCastTarget? ?? $0.native }.first
  }
  func package(showing window: NSWindow?) -> NoodletPackage? {
    guard let window else { return nil }
    return sessions.values.first { $0.web?.window === window }?.package
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
    var resolvedSession: AppletSession?
    var archivedResponse: AppletResponse?
    do {
      var request = input
      try request.validate()
      guard AppletBuildIdentity.current.clientIDs.contains(identity) else {
        throw AppletError("The caller belongs to a different Applet environment.", code: "environment-mismatch")
      }
      if let path = request.path, AppletBuildIdentity.document(URL(fileURLWithPath: path)) != .current {
        throw AppletError("Use a .\(AppletBuildIdentity.current.fileExtension) package in this environment.", code: "environment-mismatch")
      }
      if request.operation.isSurface, identity == AppletBuildIdentity.current.cliID {
        throw AppletError("Unknown command. Use --help.")
      }
      let owner =
        identity == AppletBuildIdentity.current.noodleID
        ? (request.owner ?? "local") : "local"
      request.owner = owner
      if let id = request.noodletID {
        let package = try library.package(for: id)
        guard owner == "local" || belongs(package, owner: owner) else {
          throw AppletError("This noodlet is unavailable to this caller.", code: "session-unavailable")
        }
        if let sessionID = request.sessionID {
          // A shared package grant must never become unrestricted local session access.
          let live = sessions[sessionID].map { $0.package.key == package.key }
          let saved = savedRecord(sessionID)
          guard live ?? (saved?.response.noodletID == id) else {
            throw AppletError("Session is unavailable for this noodlet.", code: "session-unavailable")
          }
        }
        request.path = package.url.path
        request.noodletID = nil
      }
      if request.operation == .typecheck {
        let sources = (request.files ?? [:]).filter { $0.key.hasSuffix(".swift") }
        guard !sources.isEmpty else { throw AppletError("Provide --path to a Swift file or folder.") }
        let result = try await NativeRunner.typecheck(sources, root: library.root)
        var response = AppletResponse()
        response.state = result.passed ? "valid" : "failed"
        response.text = result.diagnostics
        if !result.passed { response.error = "Typecheck failed. Read text for compiler diagnostics." }
        return response
      }
      if request.operation == .info {
        let package: NoodletPackage
        if let session = find(request, owner: owner) { package = session.package }
        else if let path = request.path {
          let url = URL(fileURLWithPath: origins[owner + "\0" + path] ?? path)
            .resolvingSymlinksInPath().standardizedFileURL
          library.scan()
          guard let entry = library.entries.first(where: { $0.package.url == url }),
                owner == "local" || belongs(entry.package, owner: owner) else {
            throw AppletError("Noodlet not registered. Validate the package first.")
          }
          package = entry.package
        } else { throw AppletError("Provide --id, --path, or --session for info.") }
        var response = try packageInfo(package)
        if let session = find(request, owner: owner) {
          response = status(session)
        }
        if request.includePreview == true {
          guard owner == "local", identity == AppletBuildIdentity.current.noodleID else {
            throw AppletError("Preview access is reserved for the Noodle interface.")
          }
          // A plain bookmark carries an ephemeral scope for cross-process handoff.
          // App-scoped persistent bookmarks belong to the creating application.
          response.previewBookmark = try package.url.bookmarkData(options: [],
            includingResourceValuesForKeys: nil, relativeTo: nil)
          if let cached = PreviewCache.file(for: package.url),
             let size = try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize,
             size <= 4 * 1_048_576 {
            response.data = try? Data(contentsOf: cached)
            response.mediaType = "image/png"
          }
        }
        return response
      }
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
        response.items = try library.entries.filter {
          owner == "local" || belongs($0.package, owner: owner)
        }.map { entry in
          let session = preferredSession(sessions.values.filter {
            $0.package.key == entry.id && (owner == "local" || $0.owner == owner)
          })
          var item = AppletItem(
            path: entry.package.url.path, title: entry.title,
            runtime: entry.package.manifest.runtime, sessionID: session?.id,
            state: session?.state)
          item.noodletID = try library.linkID(for: entry.package)
          item.url = item.noodletID.map(NoodletLink.url)
          return item
        }
        return response
      }
      if [.open, .build, .validate].contains(request.operation) {
        guard let path = request.path else {
          throw AppletError("Provide --path to a .\(AppletBuildIdentity.current.fileExtension) package.")
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
            "Imports/\(ownerKey(owner))/\(key).\(AppletBuildIdentity.current.fileExtension)")
          package = try NoodletPackage.install(files, to: destination)
          origins[owner + "\0" + path] = package.url.path
          defaults.set(origins, forKey: "sourceOrigins")
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
          defaults.set(owners, forKey: "packageOwners")
        }
        _ = try package.files()
        _ = try library.linkID(for: package)
        library.scan()
        if request.operation == .validate {
          var response = try packageInfo(package)
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
          resolvedSession = existing
          if request.operation == .open,
             (request.testClock ?? false) != existing.testClock
              || (request.mode == "headless") != (existing.dataRoot.lastPathComponent == "Testing") {
            throw AppletError("The live session uses different test data or clock settings. Close it before opening another mode.", code: "session-mode-conflict")
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
        if let id = request.sessionID,
          let record = savedRecord(id),
          owner == "local" || record.owner == owner
        {
          var response = record.response
          response.sessionID = id
          if ["running", "building", "starting"].contains(response.state ?? "") {
            response.state = "interrupted"
          }
          response.viewAvailable = false
          response.rendering = nil
          archivedResponse = response
          if request.operation == .logs {
            let (bytes, next) = try AppletLog(
              url: library.root.appendingPathComponent("Logs/\(id.uuidString).jsonl")
            ).read(offset: request.offset ?? 0)
            response.text = String(decoding: bytes, as: UTF8.self)
            response.offset = next
            response.done = true
          } else if request.operation != .status {
            let mode = response.mode.map { " (\($0))" } ?? ""
            response.error = "Session \(id)\(mode) is \(response.state ?? "archived") and has no live runtime. Open the noodlet to start a new session."
            response.errorCode = "session-not-running"
          }
          return response
        }
        throw AppletError("Session not found. Use list, then --session UUID or --id.", code: "session-not-found")
      }
      resolvedSession = session
      switch request.operation {
      case .surfaceFrame:
        let streamer = surfaceStreamers[session.id] ?? SurfaceStreamer { [weak session] in
          guard let session else { return nil }
          guard let picture = try await session.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AppletError("The noodlet cannot be shown.")
          }
          return (picture, session.size)
        }
        surfaceStreamers[session.id] = streamer
        var response = status(session)
        response.surfacePackets = SurfacePacket.encode(try streamer.read(after: request.surfaceAfter ?? 0))
        return response
      case .surfaceInput:
        try await deliver(request.surfaceInput!, to: session)
        return status(session)
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
        var start = request
        start.mode = request.mode ?? (session.dataRoot.lastPathComponent == "Testing" ? "headless" : session.mode)
        start.testClock = request.testClock ?? (start.mode == "headless" && session.testClock)
        try validateClock(start, package: session.package)
        session.stop()
        _ = status(session)
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
        session.mode = session.dataRoot.lastPathComponent == "Testing" ? "headless" : "background"
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
        await session.listen(recording)
        session.log.append("recording", "Started capture (MP4, 30 fps, with the noodlet's sound).")
        var response = status(session)
        response.text =
          "Recording started. Call record stop to finalize and retrieve the MP4."
        return response
      case .recordStop:
        guard let recording = session.recording else {
          throw AppletError("No recording is active.")
        }
        await session.stopListening()
        session.recording = nil
        try await recording.finish()
        var response = status(session)
        response.artifactID = register(recording.url, owner: owner)
        response.mediaType = "video/mp4"
        return response
      case .inspect, .eval, .click, .type, .key, .scroll, .drag, .step:
        guard surfaceStreamers[session.id]?.isWatched != true else {
          throw AppletError("A person is using this noodlet right now. Try again when they're done.", code: "session-busy")
        }
        guard session.state == "running" else {
          throw AppletError("Session \(session.id) (\(session.mode)) is \(session.state).", code: "session-not-running")
        }
        if request.operation == .step, !session.testClock {
          throw AppletError("step requires an HTML session opened with --mode headless --test-clock.", code: "unsupported-operation")
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
    } catch {
      var response = resolvedSession.map(status) ?? archivedResponse ?? AppletResponse()
      response.error = error.localizedDescription
      response.errorCode = (error as? AppletError)?.code
      return response
    }
  }
  private func savedRecord(_ id: UUID) -> SessionRecord? {
    guard let data = try? Data(contentsOf: library.root.appendingPathComponent("Sessions/\(id.uuidString).json")) else { return nil }
    return try? JSONDecoder().decode(SessionRecord.self, from: data)
  }
  private func ownerKey(_ owner: String) -> String { NoodletPackage.digest(Data(owner.utf8)) }
  private func packageInfo(_ package: NoodletPackage) throws -> AppletResponse {
    var response = AppletResponse()
    response.noodletID = try library.linkID(for: package)
    response.url = response.noodletID.map(NoodletLink.url)
    response.path = package.url.path
    response.title = package.manifest.title
    response.runtime = package.manifest.runtime
    response.permissions = AppletPermissions.status(package, defaults: defaults)
    response.state = "available"
    return response
  }
  /// What a person watching remotely did: real events in an HTML noodlet, the noodlet's own
  /// controls in a native one.
  private func deliver(_ input: SurfaceInput, to session: AppletSession) async throws {
    guard session.state == "running" else {
      throw AppletError("Session \(session.id) is \(session.state).", code: "session-not-running")
    }
    if let web = session.web {
      if surfaceInjectors[session.id]?.view !== web.web {
        surfaceInjectors[session.id] = (web.web, SurfaceEventInjector(view: web.web))
      }
      try surfaceInjectors[session.id]?.injector.deliver(input)
      return
    }
    guard let native = session.native else { throw AppletError("The noodlet has no view.") }
    var request = AppletRequest(.click, sessionID: session.id)
    switch input {
    case .pointer(.up, let x, let y, _): request.x = x; request.y = y
    case .pointer: return
    case .scroll(_, _, let dx, let dy): request = AppletRequest(.scroll, sessionID: session.id); request.toX = dx; request.toY = dy
    case .text(let text): request = AppletRequest(.type, sessionID: session.id); request.text = text
    case .key(let key):
      let names: [SurfaceInput.Key: String] = [.enter: "Enter", .tab: "Tab", .escape: "Escape", .backspace: "Backspace", .space: " ",
                                               .left: "ArrowLeft", .right: "ArrowRight", .up: "ArrowUp", .down: "ArrowDown"]
      request = AppletRequest(.key, sessionID: session.id); request.text = names[key]
    }
    _ = try await native.perform(request)
  }
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
      return preferredSession(sessions.values.filter {
        (owner == "local" || $0.owner == owner) && $0.package.url == url
      })
    }
    return nil
  }
  private func preferredSession(_ candidates: [AppletSession]) -> AppletSession? {
    candidates.sorted {
      if $0.isActive != $1.isActive { return $0.isActive }
      if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
      return $0.id.uuidString > $1.id.uuidString
    }.first
  }
  private func validateClock(_ request: AppletRequest, package: NoodletPackage) throws {
    if request.testClock == true, request.mode != "headless" || package.manifest.runtime != "html" {
      throw AppletError("--test-clock requires HTML and --mode headless.", code: "unsupported-operation")
    }
  }
  private func launch(_ package: NoodletPackage, request: AppletRequest, owner: String)
    async throws -> AppletResponse
  {
    try validateClock(request, package: package)
    let session = try AppletSession(
      package: package, owner: owner, mode: request.mode ?? "background",
      size: (package.manifest.window ?? NoodletWindowOptions()).size(
        width: request.width, height: request.height),
      root: library.root, testClock: request.testClock ?? false)
    sessions[session.id] = session
    session.log.append(
      "lifecycle",
      "Opening \(package.manifest.title) (\(package.manifest.runtime), \(session.mode)).")
    do {
      if request.operation != .build, let refusal = await authorize(package) {
        throw AppletError(refusal, code: "permission-denied")
      }
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
          defaults.string(forKey: storeKey).flatMap(UUID.init(uuidString:))
          ?? UUID()
        defaults.set(storeID.uuidString, forKey: storeKey)
        let runner = WebRunner(
          package: package, dataRoot: session.dataRoot, log: session.log,
          size: session.size, storeID: storeID,
          rememberFrame: session.mode != "headless" && request.width == nil && request.height == nil,
          testClock: session.testClock
        )
        runner.failed = { [weak self, weak session] message in
          guard let session else { return }
          session.stop()
          session.state = "failed"
          session.failure = message
          _ = self?.status(session)
          self?.objectWillChange.send()
        }
        runner.closed = { [weak self, weak session] in
          guard let session else { return }
          session.stop()
          _ = self?.status(session)
          self?.objectWillChange.send()
        }
        runner.castChanged = { [weak self] in self?.objectWillChange.send() }
        session.web = runner
        try await runner.start(foreground: session.mode == "foreground")
      } else {
        let runner = NativeRunner(
          package: package, dataRoot: session.dataRoot,
          buildRoot: library.root.appendingPathComponent(
            "Builds/\(session.id.uuidString)"), log: session.log)
        // Authorization already passed, so every declared permission is granted.
        runner.devices = package.manifest.permissions ?? []
        runner.castChanged = { [weak self] in self?.objectWillChange.send() }
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
        runner.exited = { [weak self, weak session, weak runner] code, signal in
          guard let session else { return }
          if session.state != "stopped" {
            session.state = code == 0 ? "stopped" : "failed"
            let reason = code == 0 ? nil : runner?.firstErrorLine
            let summary = "Native process \(signal ? "signal":"status") \(code)\(reason.map { ": \($0)" } ?? ".")"
            if code != 0 { session.failure = summary }
            session.log.append(signal ? "crash" : "exit", summary)
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
      if !cancelled { session.failure = error.localizedDescription }
      objectWillChange.send()
      var response = status(session)
      response.error = "\(error.localizedDescription) Session: \(session.id.uuidString)."
      return response
    }
  }
  func open(_ package: NoodletPackage) {
    Task {
      if let error = await openInForeground(package).error { self.error = error }
    }
  }
  /// The user clicking a noodlet asks to see and hear it. A session the agent left
  /// out of sight cannot be given the audio output or the user's data after the
  /// fact, so it makes way for one that starts in the foreground.
  func openInForeground(_ package: NoodletPackage) async -> AppletResponse {
    if let live = sessions.values.first(where: { $0.package.key == package.key && $0.isActive }),
      live.needsRelaunchToBeSeenAndHeard
    {
      live.log.append("lifecycle", "Closed to open this noodlet in the foreground.")
      live.stop()
      _ = status(live)
      objectWillChange.send()
    }
    var request = AppletRequest(.open)
    request.path = package.url.path
    request.mode = "foreground"
    request.owner = owners[package.key] ?? "local"
    return await handle(request, identity: AppletBuildIdentity.current.noodleID)
  }
  private func show(_ session: AppletSession) async throws {
    guard session.state == "running" else {
      throw AppletError("Session \(session.id) (\(session.mode)) is \(session.state).", code: "session-not-running")
    }
    if let web = session.web { web.show() }
    if let native = session.native { _ = try await native.perform(AppletRequest(.show)) }
    session.mode = "foreground"
  }
  private func status(_ session: AppletSession) -> AppletResponse {
    var response = (try? packageInfo(session.package)) ?? AppletResponse()
    response.sessionID = session.id
    response.state = session.state
    response.failure = session.failure
    response.mode = session.mode
    response.dataScope = session.dataRoot.lastPathComponent == "Testing" ? "test" : "user"
    response.testClock = session.testClock
    response.viewAvailable = session.state == "running" && (session.web != nil || session.native != nil)
    response.rendering = session.web?.rendering
    response.path = session.package.url.path
    response.capabilities =
      session.package.manifest.runtime == "html"
      ? [
        "inspect", "eval", "synthetic-input", "screenshot", "silent-video", "storage",
        "foreground-file-dialogs",
      ] : ["inspect", "native-input", "view-screenshot", "silent-video", "data-directory"]
    if session.testClock { response.capabilities?.append("step") }
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
