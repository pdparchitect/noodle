import AppKit
import AppletBridge
import AppletCore
import CryptoKit
import NoodleLaunchChecks
import WebKit

/// Verification runs write their requests as command lines, `open --path X --mode headless`, and
/// send them straight to a runtime of their own, as Noodle does for the person using it.
@MainActor struct AppletCheckCommands {
  let runtime: AppletRuntime

  func call(_ input: [String], succeeds: Bool = true) async throws -> AppletResponse {
    var args = input
    var name = args.removeFirst()
    if name == "record", let step = args.first {
      name += "-" + step
      args.removeFirst()
    }
    guard let operation = AppletOperation(rawValue: name) else { throw AppletError("Unknown command \(name).") }
    var flags: [String: String] = [:]
    while !args.isEmpty {
      let key = args.removeFirst()
      flags[key] = key == "--test-clock" || args.isEmpty ? "true" : args.removeFirst()
    }
    func uuid(_ flag: String) -> UUID? { flags[flag].flatMap(UUID.init(uuidString:)) }
    func number(_ flag: String) -> Double? { flags[flag].flatMap(Double.init) }
    func integer(_ flag: String) -> Int? { flags[flag].flatMap { Int($0) } }
    var request = AppletRequest(operation, sessionID: uuid("--session"))
    request.noodletID = uuid("--id")
    request.path = flags["--path"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
    request.mode = flags["--mode"]
    request.testClock = flags["--test-clock"].map { $0 == "true" }
    request.frames = integer("--frames")
    request.text = flags["--text"]
    request.target = flags["--target"]
    request.x = number("--x"); request.y = number("--y")
    request.toX = number("--to-x"); request.toY = number("--to-y")
    request.duration = number("--duration")
    request.offset = integer("--offset")
    let response = await runtime.handle(request, identity: AppletBuildIdentity.current.noodleID)
    guard succeeds else {
      if response.error == nil { throw AppletError("Expected a refusal: \(input)") }
      return response
    }
    if let error = response.error {
      if let session = response.sessionID {
        let logs = await runtime.handle(AppletRequest(.logs, sessionID: session), identity: AppletBuildIdentity.current.noodleID)
        print(String((logs.text ?? "").suffix(8000)))
      }
      throw AppletError("\(input.joined(separator: " ")): \(error)")
    }
    if let output = flags["--output"], let artifact = response.artifactID {
      let url = URL(fileURLWithPath: output)
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw AppletError("Cannot create \(output).") }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      var offset = 0
      while true {
        var read = AppletRequest(.artifact, sessionID: response.sessionID)
        read.artifactID = artifact
        read.offset = offset
        let chunk = try await runtime.handle(read, identity: AppletBuildIdentity.current.noodleID).checked()
        guard let bytes = chunk.data, let next = chunk.offset else { throw AppletError("Invalid capture transfer.") }
        try handle.write(contentsOf: bytes)
        offset = next
        if chunk.done == true { break }
      }
    }
    return response
  }

  /// The JSON a script returned with `return`.
  func value(_ args: [String]) async throws -> Any? {
    let response = try await call(args)
    return try JSONSerialization.jsonObject(with: Data((response.value ?? "null").utf8), options: [.fragmentsAllowed])
  }
}

/// The signed app's runtime checks: interaction, logs, persistence, captures, network and
/// termination, in a runtime, data and library of their own. `server` is a local HTTP
/// server the run starts, since the sandboxed app cannot listen itself; see scripts/smoke.py.
@MainActor enum AppletSmokeTest {
  static func run(server: String) async throws {
    setbuf(stdout, nil)
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NoodleApplet/Smoke-\(UUID())")
    let suite = "SmokeTest.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
    let runtime = AppletRuntime(library: library, defaults: defaults)
    let commands = AppletCheckCommands(runtime: runtime)
    defer {
      runtime.shutdown()
      for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("store.") {
        if let string = value as? String, let id = UUID(uuidString: string) {
          Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        }
      }
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    func require(_ condition: Bool, _ message: String) throws {
      if !condition { throw AppletError(message) }
    }
    func call(_ args: String..., succeeds: Bool = true) async throws -> AppletResponse { try await commands.call(args, succeeds: succeeds) }
    func value(_ args: String...) async throws -> Any? { try await commands.value(args) }
    func package(_ name: String, _ source: String, manifest: NoodletManifest? = nil) throws -> URL {
      let url = library.documents.appendingPathComponent("\(name).\(AppletBuildIdentity.current.fileExtension)")
      _ = try NoodletPackage.install([
        "noodlet.json": try JSONEncoder().encode(manifest ?? NoodletManifest(title: "Applet smoke \(name)")),
        "index.html": Data(source.utf8),
      ], to: url)
      library.scan()
      return url
    }

    let html = try package("HTML", """
      <!doctype html><title>Smoke</title>
      <style>body{background:#123456;color:white;font:30px system-ui}button{padding:25px}</style>
      <button id="go" onclick="this.textContent='Clicked';console.log('clicked')">Start</button>
      <canvas id="canvas" width="300" height="120"></canvas>
      <script>const ctx=canvas.getContext('2d');let t=0;setInterval(()=>{ctx.fillStyle=`hsl(${t++*5},80%,60%)`;ctx.fillRect(0,0,300,120)},80);console.log('ready');</script>
      """)
    var session = try await call("open", "--path", html.path, "--mode", "headless").sessionID!.uuidString
    let alias = library.documents.appendingPathComponent("Alias.\(AppletBuildIdentity.current.fileExtension)")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: html)
    try require(try await call("open", "--path", alias.path, "--mode", "headless").sessionID?.uuidString == session,
                "A link to an open noodlet started a second copy")
    _ = try await call("click", "--session", session, "--target", "#go")
    try require(try await value("eval", "--session", session, "--text", "return go.textContent;") as? String == "Clicked", "Click failed")
    try require(try await call("logs", "--session", session).text?.contains("clicked") == true, "Console output missing from logs")
    _ = try await call("eval", "--session", session, "--text", "await noodle.storage.set('test',42); return true;")
    _ = try await call("eval", "--session", session, "--text", "await noodle.data.write('../escape','bad');", succeeds: false)
    _ = try await call("eval", "--session", session, "--text", "setTimeout(()=>{throw Error('smoke exception')},0); return true;")
    try await Task.sleep(for: .milliseconds(200))
    try require(try await call("logs", "--session", session).text?.contains("smoke exception") == true, "Uncaught exception missing from logs")
    let png = root.appendingPathComponent("web.png"), mp4 = root.appendingPathComponent("web.mp4")
    _ = try await call("screenshot", "--session", session, "--output", png.path)
    try require(try Data(contentsOf: png).starts(with: [0x89, 0x50, 0x4E, 0x47]), "Screenshot is not a PNG")
    _ = try await call("record", "start", "--session", session, "--duration", "2")
    try await Task.sleep(for: .milliseconds(2200))
    _ = try await call("record", "stop", "--session", session, "--output", mp4.path)
    try require((try mp4.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 1000, "Recording is empty")
    session = try await call("restart", "--session", session).sessionID!.uuidString
    try require(try await value("eval", "--session", session, "--text", "return await noodle.storage.get('test');") as? Int == 42,
                "Stored value lost across restart")
    // Each part on its own, so a failure says which one WebKit left out.
    let site = try await value("eval", "--session", session, "--text", """
      return JSON.stringify([location.protocol, isSecureContext, crossOriginIsolated, typeof SharedArrayBuffer,
                             await fetch('index.html').then(r => r.status, e => String(e))]);
      """) as? String
    try require(site == #"["noodlet-package:",true,true,"function",200]"#,
                "The package is not served as an isolated site of its own: \(site ?? "no answer")")
    _ = try await call("terminate", "--session", session)
    try require(try await call("status", "--session", session).state == "stopped", "Terminated session still running")
    print("PASS HTML interaction, logs, persistence, isolated package site, canonical lock, PNG and MP4")

    var manifest = NoodletManifest(title: "Network test")
    manifest.permissions = ["local-network"]
    manifest.window = try JSONDecoder().decode(NoodletWindowOptions.self, from: Data("""
      {"type":"floating","background":"translucent","width":320,"height":350,"minWidth":260,"minHeight":300,
       "maxWidth":480,"maxHeight":520,"resizable":false,"rememberFrame":true}
      """.utf8))
    let api = try package("Network", "<title>Network test</title><h1>API</h1>", manifest: manifest)
    // Agreed to as the person would, without the question that would hold a headless run.
    defaults.set(["local-network"], forKey: "permissions.\(try NoodletPackage(url: api).key)")
    let network = try await call("open", "--path", api.path, "--mode", "headless").sessionID!.uuidString
    func json(_ path: String) -> String { String(decoding: try! JSONEncoder().encode(server + path), as: UTF8.self) }
    let fetched = try await value("eval", "--session", network, "--text", "return await (await fetch(\(json("/data")))).json();")
    try require((fetched as? [String: Any])?["cors"] as? String == "native" && (fetched as? [String: Any])?["value"] as? Int == 42,
                "Native GET failed: \(String(describing: fetched))")
    let posted = try await value("eval", "--session", network, "--text",
      "const r=await noodle.fetch(\(json("/echo")),{method:'POST',headers:{'X-Test':'no-preflight'},body:new Uint8Array([0,128,255])}); return {status:r.status,bytes:[...new Uint8Array(await r.arrayBuffer())]};")
    try require((posted as? [String: Any])?["status"] as? Int == 201 && (posted as? [String: Any])?["bytes"] as? [Int] == [0, 128, 255],
                "Binary POST failed: \(String(describing: posted))")
    try require(try await value("eval", "--session", network, "--text", "return (await fetch(\(json("/redirect")))).redirected;") as? Bool == true,
                "Redirect not followed")
    try require(try await value("eval", "--session", network, "--text",
      "try { await fetch(\(json("/slow")),{signal:AbortSignal.timeout(100)}); return 'missed'; } catch(e) { return e.name; }") as? String == "AbortError",
                "Abort did not cancel the request")
    let local = try await call("open", "--path", html.path, "--mode", "headless").sessionID!.uuidString
    let denied = try await call("eval", "--session", local, "--text", "return await fetch(\(json("/data")));", succeeds: false)
    try require(denied.error?.contains("local-network") == true, "A noodlet without the permission reached the local network")
    _ = try await call("terminate", "--session", local)
    let viewport = (try await value("inspect", "--session", network) as? [String: Any])?["viewport"] as? [String: Any]
    try require(viewport?["width"] as? Int == 320 && viewport?["height"] as? Int == 350, "Manifest viewport ignored: \(String(describing: viewport))")
    _ = try await call("terminate", "--session", network)
    print("PASS native CORS-free GET, binary POST, redirects, abort, network denial and manifest viewport")

    // Termination must break an outstanding unresponsive WebKit operation.
    let hung = try await call("open", "--path", html.path, "--mode", "headless").sessionID!.uuidString
    let blocked = Task { try await commands.call(["eval", "--session", hung, "--text", "while(true) {}"], succeeds: false) }
    try await Task.sleep(for: .milliseconds(500))
    _ = try await call("terminate", "--session", hung)
    let ended = try await withThrowingTaskGroup(of: Bool.self) { group in
      group.addTask { _ = try await blocked.value; return true }
      group.addTask { try await Task.sleep(for: .seconds(10)); return false }
      let first = try await group.next() ?? false
      group.cancelAll()
      return first
    }
    try require(ended, "Terminating did not end blocked JavaScript")
    print("PASS termination of blocked JavaScript")
    print("APPLET SMOKE TEST PASSED")
  }
}
