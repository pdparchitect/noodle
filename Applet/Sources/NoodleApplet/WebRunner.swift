import AppKit
import AppletBridge
import AppletCore
import NoodletRuntime
import ObjectiveC
import WebKit

/// A noodlet's page in its own window on this Mac: the shared runtime's page, with what only
/// Applet has around it — the window, muting, recording and casting.
@MainActor
final class WebRunner: NSObject, NoodletPageHost, NSWindowDelegate {
  let package: NoodletPackage
  let dataRoot: URL
  let log: AppletLog
  let page: NoodletPage
  var web: WKWebView { page.web }
  let window: NSWindow
  private let cast: NoodletCast
  var failed: ((String) -> Void)? {
    get { page.failed }
    set { page.failed = newValue }
  }
  var closed: (() -> Void)?
  private var stopped = false
  private var dragMonitor: Any?
  private var dragEvent: NSEvent?
  private(set) var rendering: AppletRenderingState?
  /// A noodlet the user cannot see must not be heard either.
  private(set) var muted = false
  /// Where the page's sound goes while a recording listens: interleaved stereo at
  /// AppletRecording.audioRate, and when it was heard.
  private var soundSink: (([Int16], Double) -> Void)?
  init(
    package: NoodletPackage, dataRoot: URL, log: AppletLog, size: CGSize, storeID: UUID,
    rememberFrame: Bool = true, testClock: Bool = false, secrets: AppletSecrets = .shared
  ) {
    self.package = package
    self.dataRoot = dataRoot
    self.log = log
    let resources = AppletResources.bundle.url(forResource: "Resources", withExtension: nil)!
    let animation = (try? String(contentsOf: resources.appendingPathComponent("Animation.js"), encoding: .utf8)) ?? ""
    page = NoodletPage(
      root: package.url, manifest: package.manifest,
      store: AppletDataStore(
        dataRoot: dataRoot, account: AppletSecrets.account(package, dataRoot: dataRoot), secrets: secrets),
      dataStore: WKWebsiteDataStore(forIdentifier: storeID), frame: CGRect(origin: .zero, size: size),
      features: ["files", "window"],
      // The person agreed to what the manifest declares before this page loaded.
      localNetwork: package.manifest.permissions?.contains("local-network") == true,
      log: { [log] in log.append($0, $1) }
    ) { configuration in
      configuration.preferences.inactiveSchedulingPolicy = .none
      configuration.userContentController.addUserScript(WKUserScript(
        source: "(() => { const synthetic = \(testClock);\n\(animation)\n})();",
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    // The person agreed to the manifest's permissions before this page loaded.
    page.declaredCapture = .grant
    let options = package.manifest.window ?? NoodletWindowOptions()
    window = WindowPresentation.make(options, size: size)
    cast = NoodletCast(window)
    super.init()
    page.host = self
    window.title = package.manifest.title
    window.isReleasedWhenClosed = false
    window.delegate = self
    if options.background != .opaque {
      web.underPageBackgroundColor = .clear
      // macOS WebKit still exposes page-background drawing through this guarded
      // SPI; underPageBackgroundColor alone only changes overscroll regions.
      if web.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
        web.setValue(false, forKey: "drawsBackground")
      } else {
        log.append("window", "This WebKit build does not support transparent page backgrounds.")
      }
    }
    WindowPresentation.apply(
      options, to: window, content: web, size: size, key: package.key, remember: rememberFrame)
    dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      if event.window === self?.window { self?.dragEvent = event }
      return event
    }
    if package.manifest.permissions?.contains("screen-capture") == true, !NoodletPage.supportsDisplayCapture {
      log.append("permissions", "This WebKit build does not support screen capture from HTML.")
    }
    if testClock {
      log.append("rendering", "Synthetic test clock: step advances main-page RAF and performance.now at 60 Hz; visibility is overridden. Timers, Date, media, workers and CSS animations retain native timing.")
    } else {
      log.append("rendering", "Native WebKit timing. Hidden pages may suspend animation frames or pause their own simulation; a capture does not establish visual readiness.")
    }
    web.configuration.userContentController.addUserScript(WKUserScript(
      source: (try? String(contentsOf: resources.appendingPathComponent("Sound.js"), encoding: .utf8)) ?? "",
      injectionTime: .atDocumentStart, forMainFrameOnly: true))
  }
  /// The page keeps its mute: WebKit still renders what a muted page plays, so a
  /// recording hears it while the Mac does not.
  func listen(_ sink: @escaping ([Int16], Double) -> Void) async throws {
    soundSink = sink
    _ = try await evaluate("return window.__noodletSound?.start() ?? false")
  }
  /// Returns once the page has handed over everything it played.
  func stopListening() async throws {
    defer { soundSink = nil }
    _ = try await evaluate("return await window.__noodletSound?.stop() ?? false")
  }
  var place: WindowPlace? {
    guard window.isVisible, window.alphaValue > 0 else { return nil }
    return WindowPlace(
      frame: window.frame, focused: NSApp.isActive && window.isKeyWindow, window: window.windowNumber)
  }
  /// A page taking another's place comes up once it has loaded, over the one it replaces.
  func start(foreground: Bool, in place: WindowPlace? = nil) async throws {
    setMuted(!foreground)
    if !foreground { log.append("audio", "Muted: a noodlet makes sound only while it is in the foreground.") }
    if foreground, let place {
      // WebKit draws only a window on screen, so the page loads hidden behind the one it replaces.
      window.setFrame(place.frame, display: false)
      window.order(.below, relativeTo: place.window)
    } else if foreground { show() }
    try await page.load()
    if foreground, let place { WindowPresentation.present(window, in: place) }
  }
  func show() {
    restoreSeen()
    setMuted(false)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func hide() {
    setMuted(true)
    window.orderOut(nil)
    if watched || recorded { presentUnseen() }
  }
  /// While a person watches from another device, or a recording runs, the page must draw as if
  /// seen, which WebKit only does for a window on screen, so a window the Mac does not show goes
  /// there transparent and out of the way. Its sound stays as it was.
  var watched = false {
    didSet { seenElsewhere(watched || recorded, was: oldValue || recorded) }
  }
  var recorded = false {
    didSet { seenElsewhere(watched || recorded, was: watched || oldValue) }
  }
  private func seenElsewhere(_ seen: Bool, was: Bool) {
    guard seen != was else { return }
    if seen, !window.isVisible { presentUnseen() }
    if !seen, window.alphaValue == 0 { window.orderOut(nil); restoreSeen() }
  }
  private func presentUnseen() {
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    // A transparent window at the back counts as occluded, which WebKit reports to the page as
    // hidden, and games stop drawing; with detection off the page is visible while ordered in.
    setOcclusionDetection(false)
    window.orderBack(nil)
    // Nothing on screen changes in a transparent window, so within a minute or two macOS takes
    // the app for idle: WebKit then halves the page's animation frames and lets its process nap,
    // and a game watched from a phone stutters. Taking the window off screen and straight back
    // counts as a change the page never sees, and a page that may not nap keeps its pace
    // through what that misses, such as the Mac's display going to sleep.
    setAppNap(false)
    stir()
  }
  private func restoreSeen() {
    stirring?.cancel()
    stirring = nil
    setAppNap(true)
    window.alphaValue = 1
    window.ignoresMouseEvents = false
    setOcclusionDetection(true)
  }
  /// How long the unseen window stays unchanged; macOS takes the app for idle after half a minute at the soonest.
  var stillAfter = Duration.seconds(20)
  /// Times the unseen window has been taken off screen and put back.
  private(set) var stirred = 0
  private var stirring: Task<Void, Never>?
  private func stir() {
    stirring?.cancel()
    stirring = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: self?.stillAfter ?? .zero)
        guard !Task.isCancelled, let self, self.window.alphaValue == 0 else { return }
        self.window.orderOut(nil)
        self.window.orderBack(nil)
        self.stirred += 1
      }
    }
  }
  private func setAppNap(_ enabled: Bool) {
    let selector = NSSelectorFromString("_setAppNapEnabled:")
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    guard let method = class_getInstanceMethod(WKPreferences.self, selector) else {
      if !enabled { log.append("rendering", "This WebKit build may let a noodlet watched from another device nap, which makes its live view stutter.") }
      return
    }
    unsafeBitCast(method_getImplementation(method), to: Setter.self)(web.configuration.preferences, selector, enabled)
  }
  private func setOcclusionDetection(_ enabled: Bool) {
    let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    guard let method = class_getInstanceMethod(WKWebView.self, selector) else {
      if !enabled { log.append("rendering", "This WebKit build reports a noodlet watched from another device as hidden to its page.") }
      return
    }
    unsafeBitCast(method_getImplementation(method), to: Setter.self)(web, selector, enabled)
  }
  /// Page muting is WebKit's own, so media elements and Web Audio go silent
  /// without pausing: a background noodlet keeps running, it just makes no sound.
  func setMuted(_ value: Bool) {
    guard value != muted else { return }
    muted = value
    let selector = NSSelectorFromString("_setPageMuted:")
    typealias PageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
    if let method = class_getInstanceMethod(WKWebView.self, selector) {
      // 1 is WebKit's audio-muted bit; capture stays with the manifest's permissions.
      unsafeBitCast(method_getImplementation(method), to: PageMuted.self)(web, selector, value ? 1 : 0)
    } else {
      // Older WebKit builds only offer the blunter instrument.
      web.setAllMediaPlaybackSuspended(value)
      log.append("audio", "This WebKit build cannot mute a page, so media playback is suspended instead.")
    }
  }
  func stop() {
    guard !stopped else { return }
    stopped = true
    stirring?.cancel()
    stirring = nil
    if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
    dragMonitor = nil
    dragEvent = nil
    // Whatever still holds the view, the page's sound and scripts end with the noodlet.
    setMuted(true)
    page.stop()
    window.close()
    window.contentView = nil
  }
  func windowWillClose(_ notification: Notification) { if !stopped { closed?() } }
  var castChanged: (() -> Void)? {
    get { cast.changed }
    set { cast.changed = newValue }
  }
  var canCast: Bool { cast.canCast }
  var isCasting: Bool { cast.isCasting }
  func play(on screen: NSScreen) {
    setMuted(false)
    cast.play(on: screen)
  }
  func bringBack() { cast.bringBack() }
  func windowDidFailToEnterFullScreen(_ window: NSWindow) { cast.bringBack() }
  func handleBridge(operation: String, body: [String: Any]) async -> (Any?, String?) {
    await page.handleBridge(operation: operation, body: body)
  }
  /// What the page asks of its window and its recording.
  func perform(_ operation: String, body: [String: Any]) async throws -> Any {
    switch operation {
    case "rendering":
      let data = try JSONSerialization.data(withJSONObject: body["state"] ?? [:])
      rendering = try JSONDecoder().decode(AppletRenderingState.self, from: data)
      return true
    case "dragWindow":
      guard window.isVisible, let event = dragEvent, event.window === window,
        ProcessInfo.processInfo.systemUptime - event.timestamp < 1 else {
        throw AppletError("Window dragging requires a current user mouse-down inside this noodlet.")
      }
      dragEvent = nil
      window.performDrag(with: event)
      return true
    case "window":
      return try WindowPresentation.perform(body["action"] as? String ?? "", on: window)
    case "sound":
      guard let sink = soundSink else { return false }
      guard let samples = AppletRecording.samples(body["pcm"]), let at = body["at"] as? Double
      else { throw AppletError("Sound must be base64 16-bit stereo within 2 MiB.") }
      sink(samples, at)
      return true
    default: throw NoodletPage.unknownOperation
    }
  }
  func evaluate(_ source: String) async throws -> String { try await page.evaluate(source) }
  func perform(_ request: AppletRequest) async throws -> String {
    if request.operation == .eval { return try await evaluate(request.text ?? "") }
    let bytes = try JSONEncoder().encode(request)
    let json = String(decoding: bytes, as: UTF8.self)
    return try await evaluate("return await window.__noodletControl(\(json));")
  }
  func snapshot() async throws -> NSImage { try await page.snapshot() }
}
