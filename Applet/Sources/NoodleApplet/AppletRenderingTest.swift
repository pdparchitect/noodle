import AppKit
import AppletBridge
import AppletCore
import WebKit

/// Explicit signed-app regression fixture with its own runtime and data.
/// Never connects to, closes or replaces the user's existing sessions.
@MainActor enum AppletRenderingTest {
  static func run() async throws {
    setbuf(stdout, nil)
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NoodleApplet/Rendering-\(UUID())")
    let suite = "RenderingTest.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
    let runtime = AppletRuntime(library: library, defaults: defaults)
    func clearWebsiteData() async {
      runtime.shutdown()
      for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("store.") {
        if let string = value as? String, let id = UUID(uuidString: string) {
          try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
      }
    }
    defer {
      runtime.shutdown()
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    func require(_ condition: Bool, _ message: String) throws {
      if !condition { throw AppletError(message) }
    }
    let commands = AppletCheckCommands(runtime: runtime)
    func call(_ args: [String], succeeds: Bool = true) async throws -> AppletResponse {
      try await commands.call(args, succeeds: succeeds)
    }
    func value(_ args: [String]) async throws -> [String: Any] {
      try await commands.value(args) as? [String: Any] ?? [:]
    }
    /// Watches a session as a paired device does, once its first picture has arrived.
    func watch(_ session: UUID) async throws -> SurfaceSocket {
      let (near, far) = try {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw AppletError("No socket pair") }
        return (SurfaceSocket(fd: fds[0], held: true), SurfaceSocket(fd: fds[1]))
      }()
      let streamed = await runtime.handle(
        AppletRequest(.surfaceStream, sessionID: session), identity: AppletBuildIdentity.current.noodleID, surface: near)
      near.start(with: try JSONEncoder().encode(streamed))
      try require(streamed.error == nil, "Live view refused: \(streamed.error ?? "")")
      let frame = await withTaskGroup(of: SurfacePacket?.self) { group in
        group.addTask {
          for await data in far.frames { if let packet = SurfacePacket.decode(data)?.first { return packet } }
          return nil
        }
        group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
      }
      try require(frame?.keyFrame == true, "A background noodlet sent no live view within 5 seconds")
      return far
    }
    do {
    let source = library.documents.appendingPathComponent("Animation.\(AppletBuildIdentity.current.fileExtension)")
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
    // A person watching from another device opens the noodlet in the background, never seen on this Mac.
    let watched = library.documents.appendingPathComponent("Watched.\(AppletBuildIdentity.current.fileExtension)")
    _ = try NoodletPackage.install([
      "noodlet.json": try JSONEncoder().encode(NoodletManifest(title: "Live view regression")),
      "index.html": Data("""
        <!doctype html><title>Live view</title>
        <style>body{margin:0;background:black}div,canvas{display:block;width:160px;height:120px}</style>
        <div style="background:#ff0000"></div><canvas id="c" width="160" height="120"></canvas>
        <script>requestAnimationFrame(()=>{const x=c.getContext('2d');x.fillStyle='#00ff00';x.fillRect(0,0,160,120);});
        window.ticks=0;(function tick(){ticks++;requestAnimationFrame(tick);})();</script>
        """.utf8)
    ], to: watched)
    library.scan()
    let watchedTarget = ["--id", try library.linkID(for: NoodletPackage(url: watched)).uuidString]
    // A runner with nothing else in front activates the app at launch, so only a change counts.
    let wasActive = NSApp.isActive
    let cold = try await call(["open", "--mode", "background"] + watchedTarget)
    guard let session = runtime.sessions[cold.sessionID!], let web = session.web else { throw AppletError("Background session missing") }
    let far = try await watch(cold.sessionID!)
    try await Task.sleep(for: .milliseconds(300))
    // What the live view captures, as it captures it.
    let picture = try await session.snapshot()
    let captured = NSBitmapImageRep(data: picture.tiffRepresentation!)!
    func pixels(_ y: ClosedRange<Double>, _ match: (NSColor) -> Bool) -> Int {
      var count = 0
      for py in stride(from: 0, to: captured.pixelsHigh, by: 2) {
        let point = Double(py) * picture.size.height / Double(captured.pixelsHigh)
        guard y.contains(point) else { continue }
        for px in stride(from: 0, to: min(captured.pixelsWide, Int(160 * Double(captured.pixelsWide) / picture.size.width)), by: 2) {
          if let color = captured.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB), match(color) { count += 1 }
        }
      }
      return count
    }
    let redShown = pixels(0...119) { $0.redComponent > 0.8 && $0.greenComponent < 0.2 }
    let greenShown = pixels(120...239) { $0.greenComponent > 0.8 && $0.redComponent < 0.2 }
    print("INFO watched background capture: static red \(redShown), animation-frame green \(greenShown)")
    try require(redShown > 500, "The live view of a background noodlet is blank")
    try require(greenShown > 500, "The live view of a background noodlet lacks what it drew in an animation frame")
    // A game draws every animation frame, so the page must keep getting them while watched.
    func ticks() async throws -> Int { Int(try await web.evaluate("return ticks")) ?? 0 }
    let ticksBefore = try await ticks()
    try await Task.sleep(for: .milliseconds(500))
    let ticksAfter = try await ticks()
    let visibility = try await web.evaluate("return document.visibilityState")
    print("INFO watched background animation: \(ticksAfter - ticksBefore) frames in 500 ms, visibility \(visibility)")
    try require(ticksAfter - ticksBefore >= 5, "A watched background noodlet stopped getting animation frames")
    try require(visibility == "\"visible\"", "A watched background noodlet is hidden from its own page")
    try require(web.window.alphaValue == 0, "A watched background noodlet became visible on this Mac")
    try require(web.window.ignoresMouseEvents, "A watched background noodlet takes clicks on this Mac")
    try require(wasActive || !NSApp.isActive, "A watched background noodlet took focus on this Mac")
    far.close()
    try await Task.sleep(for: .milliseconds(500))
    try require(!web.window.isVisible && web.window.alphaValue == 1, "The noodlet stayed on screen after the live view ended")
    try require(try await web.evaluate("return document.visibilityState") == "\"hidden\"", "The noodlet still counts as seen after the live view ended")
    _ = try await call(["close"] + watchedTarget)
    print("PASS live view: a noodlet opened only in the background draws for its viewer and stays out of sight on this Mac")
    // Watched after a person closed its window, as the phone does: the Hub opens it again in the background.
    // Only Noodle, for the person, brings a noodlet to the foreground.
    var foreground = AppletRequest(.open)
    foreground.noodletID = try library.linkID(for: NoodletPackage(url: watched))
    foreground.mode = "foreground"
    let shown = try await runtime.handle(foreground, identity: AppletBuildIdentity.current.noodleID).checked()
    guard let shownWeb = runtime.sessions[shown.sessionID!]?.web else { throw AppletError("Foreground session missing") }
    shownWeb.window.performClose(nil)
    try await Task.sleep(for: .milliseconds(300))
    try require(runtime.sessions[shown.sessionID!]?.state == "stopped", "Closing the window left the noodlet running")
    let reopened = try await call(["open", "--mode", "background"] + watchedTarget)
    guard let reopenedWeb = runtime.sessions[reopened.sessionID!]?.web else { throw AppletError("Reopened session missing") }
    let reopenedView = try await watch(reopened.sessionID!)
    try await Task.sleep(for: .milliseconds(300))
    let reopenedTicks = Int(try await reopenedWeb.evaluate("return ticks")) ?? 0
    try await Task.sleep(for: .milliseconds(500))
    let reopenedMoved = (Int(try await reopenedWeb.evaluate("return ticks")) ?? 0) - reopenedTicks
    let reopenedVisibility = try await reopenedWeb.evaluate("return document.visibilityState")
    print("INFO closed then watched: \(reopenedMoved) frames in 500 ms, visibility \(reopenedVisibility)")
    try require(reopenedMoved >= 5 && reopenedVisibility == "\"visible\"", "A noodlet watched after its window was closed does not animate")
    reopenedView.close()
    _ = try await call(["close"] + watchedTarget)
    print("PASS live view: a noodlet whose window was closed animates for its viewer")
    // A recording is watched too: a hidden page gets about one frame a second, and so did its video.
    let recorded = try await call(["open", "--mode", "background"] + watchedTarget)
    guard let recordedWeb = runtime.sessions[recorded.sessionID!]?.web else { throw AppletError("Recorded session missing") }
    let recordedTarget = watchedTarget + ["--session", recorded.sessionID!.uuidString]
    _ = try await call(["record", "start", "--duration", "5"] + recordedTarget)
    try await Task.sleep(for: .milliseconds(300))
    let recordedTicks = Int(try await recordedWeb.evaluate("return ticks")) ?? 0
    try await Task.sleep(for: .milliseconds(500))
    let recordedMoved = (Int(try await recordedWeb.evaluate("return ticks")) ?? 0) - recordedTicks
    let recordedVisibility = try await recordedWeb.evaluate("return document.visibilityState")
    print("INFO recorded background: \(recordedMoved) frames in 500 ms, visibility \(recordedVisibility)")
    try require(recordedMoved >= 5 && recordedVisibility == "\"visible\"", "A background noodlet does not animate while recorded")
    try require(recordedWeb.window.alphaValue == 0, "A recorded background noodlet became visible on this Mac")
    _ = try await call(["record", "stop", "--output", root.appendingPathComponent("recorded.mp4").path] + recordedTarget)
    try await Task.sleep(for: .milliseconds(500))
    try require(!recordedWeb.window.isVisible && recordedWeb.window.alphaValue == 1, "The noodlet stayed on screen after its recording ended")
    _ = try await call(["close"] + watchedTarget)
    print("PASS recording: a noodlet opened only in the background animates while recorded")
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
    print("PASS archived inspection error retains identity/state/mode without claiming a live view")
    print("PASS historical/headless targeting, native visibility, synthetic RAF/clock, cancellation/errors, Canvas/WebGL pixels, restart, exact close and test-data isolation")
    print("APPLET RENDERING TEST PASSED")
    } catch {
      await clearWebsiteData()
      throw error
    }
    await clearWebsiteData()
  }
}
