import AppKit
import AppletBridge
import AppletCore
import WebKit

/// Explicit signed-app regression fixture with its own runtime, data and socket.
/// Never connects to, closes or replaces the user's existing sessions.
@MainActor enum AppletRenderingTest {
  static func run() async throws {
    setbuf(stdout, nil)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Rendering-\(UUID())")
    let suite = "RenderingTest.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
    let runtime = AppletRuntime(library: library, defaults: defaults)
    let socket = try AppletConnection.socketURL().deletingLastPathComponent()
      .appendingPathComponent("t\(UUID().uuidString.prefix(6)).sock")
    let server = try AppletConnectionServer(socket: socket, team: AppletConnection.signingTeam()) { request, identity in
      await runtime.handle(request, identity: identity)
    }
    func clearWebsiteData() async {
      runtime.shutdown()
      for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("store.") {
        if let string = value as? String, let id = UUID(uuidString: string) {
          try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
      }
    }
    defer {
      withExtendedLifetime(server) {}
      runtime.shutdown()
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    func require(_ condition: Bool, _ message: String) throws {
      if !condition { throw AppletError(message) }
    }
    let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/noodlet")
    func call(_ args: [String], succeeds: Bool = true) async throws -> AppletResponse {
      let response = try await Task.detached {
        let process = Process(), pipe = Pipe()
        process.executableURL = cli
        process.arguments = args + ["--socket", socket.path]
        process.currentDirectoryURL = root
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let response = try JSONDecoder().decode(AppletResponse.self, from: data)
        if succeeds { return try response.checked() }
        guard process.terminationStatus == 1, response.error != nil else { throw AppletError("Expected CLI rejection: \(args)") }
        return response
      }.value
      return response
    }
    func value(_ args: [String]) async throws -> [String: Any] {
      let response = try await call(args)
      return try JSONSerialization.jsonObject(with: Data((response.value ?? "{}").utf8)) as? [String: Any] ?? [:]
    }
    do {
    let source = library.documents.appendingPathComponent("Animation.noodlet")
    _ = try NoodletPackage.install([
      "noodlet.json": try JSONEncoder().encode(NoodletManifest(title: "Animation regression")),
      "index.html": Data("""
        <!doctype html><title>RAF regression</title>
        <style>body{margin:0;background:black}canvas{display:block}</style>
        <canvas id="canvas" width="160" height="120"></canvas><canvas id="gpu" width="160" height="120"></canvas>
        <script>
        window.framesSeen=0;window.times=[];window.paused=false;
        window.ctx=canvas.getContext('2d');window.gl=gpu.getContext('webgl2');
        function draw(t){
          if(!document.hidden && !paused){framesSeen++;times.push([t,performance.now()]);
            ctx.fillStyle='#ff0000';ctx.fillRect(0,0,160,120);
            gl.clearColor(0,1,0,1);gl.clear(gl.COLOR_BUFFER_BIT);}
          requestAnimationFrame(draw);
        }
        requestAnimationFrame(draw);
        </script>
        """.utf8)
    ], to: source)
    library.scan()
    let packageID = try library.linkID(for: NoodletPackage(url: source)).uuidString
    let target = ["--id", packageID]
    for mode in ["background", "headless"] {
      let open = try await call(["open", "--mode", mode] + target)
      let exact = target + ["--session", open.sessionID!.uuidString]
      try require(open.mode == mode && open.testClock == false, "Incorrect normal mode")
      try await Task.sleep(for: .milliseconds(150))
      let observed = try await value(["eval", "--text", "return {hidden:document.hidden,frames:framesSeen};"] + exact)
      try require(observed["hidden"] as? Bool == true, "Normal hidden visibility was overridden")
      let status = try await call(["status"] + target)
      try require(status.sessionID == open.sessionID && status.rendering?.nativeVisibilityState == "hidden", "Normal link selection/diagnostics failed")
      _ = try await call(["step"] + exact, succeeds: false)
      _ = try await call(["close"] + exact)
    }
    let open = try await call(["open", "--mode", "headless", "--test-clock"] + target)
    let exact = target + ["--session", open.sessionID!.uuidString]
    try require(open.testClock == true && open.dataScope == "test", "Clock did not use test data")
    let selected = try await call(["status"] + target)
    try require(selected.sessionID == open.sessionID, "Historical session displaced new headless open")
    let initial = try await value(["eval", "--text", "return {frames:framesSeen,hidden:document.hidden,gl:!!gl};"] + exact)
    try require(initial["frames"] as? Int == 0 && initial["hidden"] as? Bool == false && initial["gl"] as? Bool == true, "Synthetic setup failed")
    _ = try await call(["step", "--frames", "60"] + exact)
    let frames = try await value(["eval", "--text", "return {frames:framesSeen,time:performance.now(),aligned:times.every(v=>v[0]===v[1])};"] + exact)
    try require(frames["frames"] as? Int == 60 && frames["aligned"] as? Bool == true, "RAF delivery/timestamps failed")
    try require(abs((frames["time"] as? Double ?? 0) - 1000) < 0.001, "Clock did not advance one second")
    let capture = root.appendingPathComponent("stepped.png")
    let shot = try await call(["screenshot", "--output", capture.path] + exact)
    try require(shot.rendering?.synthetic == true && shot.rendering?.animationFrameCount == 60, "Capture lost synthetic diagnostics")
    let bitmap = NSBitmapImageRep(data: try Data(contentsOf: capture))!
    var red = 0, green = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if color.redComponent > 0.8 && color.greenComponent < 0.2 { red += 1 }
        if color.greenComponent > 0.8 && color.redComponent < 0.2 { green += 1 }
      }
    }
    try require(red > 500 && green > 500, "Captured image lacks rendered Canvas/WebGL pixels: \(red)/\(green)")
    let afterShot = try await value(["eval", "--text", "return {frames:framesSeen};"] + exact)
    try require(afterShot["frames"] as? Int == 60, "Capture unexpectedly advanced test clock")
    _ = try await call(["eval", "--text", "paused=true;window.called=[];requestAnimationFrame(()=>{called.push('a');cancelAnimationFrame(cancelled);requestAnimationFrame(()=>called.push('next'));});let cancelled=requestAnimationFrame(()=>called.push('cancelled'));requestAnimationFrame(()=>{throw Error('fixture callback failure')});requestAnimationFrame(()=>called.push('sibling'));await noodle.storage.set('clock-marker',123);"] + exact)
    _ = try await call(["step", "--frames", "2"] + exact)
    let callbacks = try await value(["eval", "--text", "return {called,frames:framesSeen};"] + exact)
    try require(callbacks["called"] as? [String] == ["a", "sibling", "next"] && callbacks["frames"] as? Int == 60, "Callback cancellation, exceptions or game pause failed")
    _ = try await call(["open", "--mode", "background"] + target, succeeds: false)
    _ = try await call(["hide"] + exact)
    let restarted = try await call(["restart"] + exact)
    try require(restarted.testClock == true && restarted.sessionID != open.sessionID, "Restart lost clock or identity")
    let closed = try await call(["close"] + target)
    try require(closed.sessionID == restarted.sessionID, "Close targeted historical session")
    let latest = try await call(["status"] + target)
    try require(latest.sessionID == restarted.sessionID && latest.state == "stopped", "Stopped history selected wrong session")
    let normal = try await call(["open", "--mode", "background"] + target)
    let clean = try await value(["eval", "--text", "return {marker:await noodle.storage.get('clock-marker')};"] + target)
    try require(clean["marker"] is NSNull && normal.dataScope == "user", "Test data escaped into normal storage")
    _ = try await call(["close"] + target)
    // Model a provider restart: only durable records remain in this isolated runtime.
    runtime.sessions.removeAll()
    let archived = try await call(["inspect"] + exact, succeeds: false)
    try require(archived.errorCode == "session-not-running" && archived.sessionID == open.sessionID
      && archived.noodletID == open.noodletID && archived.state == "stopped"
      && archived.mode == "headless" && archived.dataScope == "test" && archived.testClock == true
      && archived.viewAvailable == false && archived.rendering == nil, "Archived inspection lost saved session metadata")
    let archivedStatus = try await call(["status"] + exact)
    try require(archivedStatus.sessionID == open.sessionID && archivedStatus.state == "stopped", "Archived status stopped working")
    print("PASS signed CLI: archived inspection error retains identity/state/mode without claiming a live view")
    print("PASS signed CLI: historical/headless targeting, native visibility, synthetic RAF/clock, cancellation/errors, Canvas/WebGL pixels, restart, exact close and test-data isolation")
    print("APPLET RENDERING TEST PASSED")
    } catch {
      await clearWebsiteData()
      throw error
    }
    await clearWebsiteData()
  }
}
