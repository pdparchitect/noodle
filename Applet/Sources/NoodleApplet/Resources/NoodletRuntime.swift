import AppKit
import AVFAudio
import SwiftUI
import SpriteKit

/// Available to the noodlet's SwiftUI view. Data survives rebuilds and restarts.
public enum NoodletContext {
    public static let dataDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOODLET_DATA"]!)
    public static let packageDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOODLET_PACKAGE"]!)
    public static var isBackground: Bool { ProcessInfo.processInfo.environment["NOODLET_MODE"] != "foreground" }
    /// Kept in Applet's Keychain, separately for each noodlet.
    public static let secrets = NoodletSecrets()
    /// The only way to files outside the noodlet: the user picks them in Applet's dialog.
    public static let files = NoodletFiles()
    /// Play sound through this engine. It is heard in the foreground; out of sight it runs
    /// silently in real time. Either way a recording hears it, and nothing else.
    @MainActor public static var audioEngine: AVAudioEngine { NoodletSound.shared.engine }
}

/// The noodlet's audio engine and what a recording hears from it: interleaved 16-bit stereo
/// at 48 kHz, each piece timed from when the recording started.
@MainActor final class NoodletSound {
    private(set) static var current: NoodletSound?
    static var shared: NoodletSound {
        if let current { return current }
        let sound = NoodletSound()
        current = sound
        return sound
    }
    static let rate = 48000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let engine = AVAudioEngine()
    /// Without the audio output the engine would not start, so it renders itself at the pace a device would.
    private let offline = ProcessInfo.processInfo.environment["NOODLET_AUDIO"] != "device"
    private var timer: DispatchSourceTimer?
    private var clock: Double?, rendered = 0
    private let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    /// A recording may start before the noodlet first asks for its engine.
    private static var listening: Double?, emit: (([String: Any]) -> Void)?
    private var pending: [Int16] = [], pendingAt = 0.0
    private var converter: AVAudioConverter?
    private init() {
        guard offline else {
            if Self.listening != nil { tap() }
            return
        }
        do { try engine.enableManualRenderingMode(.offline, format: Self.format, maximumFrameCount: 4096) }
        catch { print("Sound cannot run out of sight: \(error.localizedDescription)"); return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { MainActor.assumeIsolated { NoodletSound.current?.render() } }
        timer.resume()
        self.timer = timer
    }
    private static var now: Double { ProcessInfo.processInfo.systemUptime }
    private func render() {
        guard engine.isRunning else { clock = nil; return }
        let now = Self.now
        if clock == nil { clock = now; rendered = 0 }
        let due = Int((now - clock!) * Self.rate)
        // A stall of more than a second is skipped, as a device would drop it.
        if due - rendered > Int(Self.rate) { rendered = due - 4096 }
        while rendered < due {
            let count = min(4096, due - rendered)
            let at = clock! + Double(rendered) / Self.rate
            guard (try? engine.renderOffline(AVAudioFrameCount(count), to: buffer)) == .success else { return }
            rendered += count
            hear(buffer, at: at)
        }
    }
    private func hear(_ buffer: AVAudioPCMBuffer, at time: Double) {
        guard let listening = Self.listening, let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength), right = buffer.format.channelCount > 1 ? 1 : 0
        // Sound after a pause starts a piece of its own, so it keeps its place.
        if !pending.isEmpty, abs(pendingAt + Double(pending.count / 2) / Self.rate - (time - listening)) > 0.005 { Self.emit?(take()) }
        if pending.isEmpty { pendingAt = time - listening }
        pending.reserveCapacity(pending.count + count * 2)
        for frame in 0..<count {
            pending.append(Int16(max(-1, min(1, channels[0][frame])) * 32767))
            pending.append(Int16(max(-1, min(1, channels[right][frame])) * 32767))
        }
        if pending.count >= Int(Self.rate) / 2 { Self.emit?(take()) }
    }
    private func take() -> [String: Any] {
        defer { pending = [] }
        return ["id": "sound", "at": pendingAt, "pcm": pending.withUnsafeBytes { Data($0) }.base64EncodedString()]
    }
    static func listen(_ emit: @escaping ([String: Any]) -> Void) {
        self.emit = emit
        listening = now
        current?.pending = []
        if let current, !current.offline { current.tap() }
    }
    private func tap() {
        // The mixer's output is the device's format, which the recording may not share.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4800, format: nil) { tapped, when in
            let time = AVAudioTime.seconds(forHostTime: when.hostTime)
            DispatchQueue.main.async { MainActor.assumeIsolated { NoodletSound.current?.convert(tapped, at: time) } }
        }
    }
    private func convert(_ tapped: AVAudioPCMBuffer, at time: Double) {
        if converter?.inputFormat != tapped.format { converter = AVAudioConverter(from: tapped.format, to: Self.format) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(tapped.frameLength) * Self.rate / tapped.format.sampleRate) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var supplied = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return tapped
        }
        // Host time is the machine's clock; systemUptime counts the same seconds.
        hear(output, at: time)
    }
    /// Ends listening and returns what was not yet sent.
    static func stopListening() -> [String: Any] {
        defer { listening = nil; emit = nil }
        guard let current else { return ["ok": true] }
        if !current.offline { current.engine.mainMixerNode.removeTap(onBus: 0) }
        current.converter = nil
        return current.pending.isEmpty ? ["ok": true] : current.take()
    }
}

public struct NoodletFiles: Sendable {
    /// A copy of the file the user chose, inside dataDirectory, or nil when cancelled.
    public func open() async throws -> URL? {
        guard let path = try await NoodletHost.call("files.open", [:]) as? String else { return nil }
        return NoodletContext.dataDirectory.appendingPathComponent(path)
    }
    /// Saves a file from dataDirectory where the user chooses. False when cancelled.
    public func save(_ path: String, suggestedName: String? = nil) async throws -> Bool {
        var arguments = ["name": path]
        if let suggestedName { arguments["value"] = suggestedName }
        return try await NoodletHost.call("files.save", arguments) as? Bool ?? false
    }
}

public struct NoodletSecrets: Sendable {
    public func get(_ name: String) async throws -> String? { try await NoodletHost.call("secrets.get", ["name": name]) as? String }
    public func set(_ name: String, _ value: String) async throws { _ = try await NoodletHost.call("secrets.set", ["name": name, "value": value]) }
    public func delete(_ name: String) async throws { _ = try await NoodletHost.call("secrets.delete", ["name": name]) }
    public func names() async throws -> [String] { try await NoodletHost.call("secrets.names", [:]) as? [String] ?? [] }
}

/// Requests from the noodlet to Applet, answered over the same pipe as its commands.
@MainActor enum NoodletHost {
    static var emit: (([String: Any]) -> Void)?
    private static var pending: [String: CheckedContinuation<Any, Error>] = [:]
    static func call(_ name: String, _ arguments: [String: Any]) async throws -> Any {
        guard let emit else { throw RuntimeError("Applet is not connected yet.") }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            emit(arguments.merging(["id": id, "call": name]) { _, new in new })
        }
    }
    static func resolve(_ reply: [String: Any]) {
        guard let id = reply["reply"] as? String, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = reply["error"] as? String { continuation.resume(throwing: RuntimeError(error)) }
        else { continuation.resume(returning: reply["value"] ?? NSNull()) }
    }
}

@main struct NoodletRuntime {
    @MainActor static func main() {
        setbuf(stdout, nil); setbuf(stderr, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = NoodletRuntimeDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class NoodletRuntimeDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var cast: NoodletCast!
    var host: NSView!
    let prefix = ProcessInfo.processInfo.environment["NOODLET_PROTOCOL"]!
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowFocusGuard.shared.start()
        let env = ProcessInfo.processInfo.environment
        let size = NSSize(width: Double(env["NOODLET_WIDTH"] ?? "900") ?? 900, height: Double(env["NOODLET_HEIGHT"] ?? "620") ?? 620)
        let options = (env["NOODLET_WINDOW"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String:Any]) ?? [:]
        if options["type"] as? String == "preview" {
            let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false; panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = false
            window = panel
        } else {
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        }
        window.title = env["NOODLET_TITLE"] ?? "Noodlet"; window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Noodlet().frame(maxWidth: .infinity, maxHeight: .infinity))
        hosting.sizingOptions = []
        host = hosting; host.frame = CGRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        if options["resizable"] as? Bool == false { window.styleMask.remove(.resizable) }
        if ["floating", "preview"].contains(options["type"] as? String ?? "") { window.level = .floating; window.collectionBehavior.insert(.fullScreenAuxiliary) }
        if options["titlebar"] as? Bool == false || options["type"] as? String == "preview" { window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.styleMask.insert(.fullSizeContentView); window.isMovableByWindowBackground = true }
        let background = options["background"] as? String ?? "opaque"
        if background != "opaque" { window.isOpaque = false; window.backgroundColor = .clear }
        if background == "translucent" {
            let effect = NSVisualEffectView(frame: host.bounds)
            effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
            effect.addSubview(host); window.contentView = effect
        } else { window.contentView = host }
        if options["titlebar"] as? Bool == false || options["type"] as? String == "preview", let container = window.contentView {
            let drag = NoodletTitlebarDragView(); drag.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(drag, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([drag.topAnchor.constraint(equalTo:container.topAnchor), drag.leadingAnchor.constraint(equalTo:container.leadingAnchor, constant:options["type"] as? String == "preview" ? 28 : 78), drag.trailingAnchor.constraint(equalTo:container.trailingAnchor), drag.heightAnchor.constraint(equalToConstant:30)])
        }
        window.contentMinSize = NSSize(width: CGFloat(options["minWidth"] as? Int ?? 120), height: CGFloat(options["minHeight"] as? Int ?? 120))
        window.contentMaxSize = NSSize(width: CGFloat(options["maxWidth"] as? Int ?? 4096), height: CGFloat(options["maxHeight"] as? Int ?? 4096))
        window.setContentSize(size); window.center()
        if options["rememberFrame"] as? Bool == true && env["NOODLET_REMEMBER_FRAME"] == "1" {
            // Frame autosave writes user defaults, which a confined noodlet has none of.
            let store = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("WindowFrame")
            if let saved = try? String(contentsOf: store, encoding: .utf8) { window.setFrame(from: saved) }
            for change in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
                NotificationCenter.default.addObserver(forName: change, object: window, queue: .main) { note in
                    MainActor.assumeIsolated { try? (note.object as? NSWindow)?.frameDescriptor.write(to: store, atomically: false, encoding: .utf8) }
                }
            }
            let current = window.contentRect(forFrameRect: window.frame).size
            window.setContentSize(NSSize(width: min(max(current.width, window.contentMinSize.width), window.contentMaxSize.width), height: min(max(current.height, window.contentMinSize.height), window.contentMaxSize.height)))
        }
        cast = NoodletCast(window)
        cast.changed = { [weak self] in self.map { $0.emit(["id":"cast","value":$0.cast.isCasting]) } }
        if !NoodletContext.isBackground { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        NoodletHost.emit = { [weak self] in self?.emit($0) }
        // In front, the noodlet's own process owns the menu bar, not Applet.
        let appMenu = NSMenu(), fileMenu = NSMenu(title: "File"), bar = NSMenu()
        appMenu.addItem(withTitle: "Quit \(window.title)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        fileMenu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "").target = self
        fileMenu.delegate = self
        for menu in [appMenu, fileMenu] { bar.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu }
        NSApp.mainMenu = bar
        emit(["id":"ready","value":"ready"])
        let prefix = self.prefix
        DispatchQueue.global().async { [weak self] in
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                Task { @MainActor [weak self] in self?.handle(command) }
            }
            // EOF also ends the child if its owner crashes or is killed.
            _ = prefix
            Darwin.exit(0)
        }
    }
    // The noodlet runs from a snapshot; only Applet knows where its package lives.
    @objc func showInFinder() { Task { _ = try? await NoodletHost.call("package.reveal", [:]) } }
    // Displays come and go with AirPlay, so Play On is rebuilt each time the File menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        if cast.isCasting {
            menu.addItem(withTitle: "Bring Back to This Mac", action: #selector(bringBack), keyEquivalent: "").target = self
        } else if cast.canCast {
            let screens = NSMenu()
            for (index, screen) in NSScreen.screens.enumerated() {
                let item = screens.addItem(withTitle: screen.localizedName, action: #selector(playOn(_:)), keyEquivalent: "")
                item.target = self; item.tag = index
            }
            if !NSScreen.screens.isEmpty { screens.addItem(.separator()) }
            let add = screens.addItem(withTitle: "Add TV or Display…", action: #selector(addDisplay), keyEquivalent: "")
            add.target = self; add.toolTip = "Use an Apple TV or AirPlay TV as a separate display."
            menu.addItem(withTitle: "Play On", action: nil, keyEquivalent: "").submenu = screens
        }
    }
    @objc func playOn(_ item: NSMenuItem) { if NSScreen.screens.indices.contains(item.tag) { cast.play(on: NSScreen.screens[item.tag]) } }
    @objc func bringBack() { cast.bringBack() }
    // A confined noodlet cannot open System Settings; Applet does it.
    @objc func addDisplay() { Task { _ = try? await NoodletHost.call("displays.add", [:]) } }
    func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data((prefix + String(decoding: data, as: UTF8.self) + "\n").utf8))
    }
    func handle(_ command: [String: Any]) {
        if command["reply"] != nil { NoodletHost.resolve(command); return }
        let id = command["id"] as? String ?? "", op = command["operation"] as? String ?? ""
        do {
            var value: Any = ["ok":true]
            switch op {
            case "show": window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            case "hide": window.orderOut(nil)
            case "cast":
                let display = (command["display"] as? NSNumber)?.uint32Value
                guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }) else { throw RuntimeError("That display is no longer connected.") }
                cast.play(on: screen)
            case "bring-back": cast.bringBack()
            case "record-start": NoodletSound.listen { [weak self] in self?.emit($0) }
            case "record-stop": value = NoodletSound.stopListening()
            case "close", "terminate": emit(["id":id,"value":["ok":true]]); NSApp.terminate(nil); return
            case "inspect":
                var controls: [[String: Any]] = []
                func walk(_ node: Any, depth: Int) {
                    guard depth < 16, controls.count < 500, let element = node as? NSAccessibilityProtocol else { return }
                    let frame = element.accessibilityFrame()
                    controls.append(["role":element.accessibilityRole()?.rawValue ?? "unknown", "label":element.accessibilityLabel() ?? "", "frame":["x":frame.origin.x,"y":frame.origin.y,"width":frame.width,"height":frame.height]])
                    if let children = element.accessibilityChildren() { for child in children { walk(child, depth: depth + 1) } }
                }
                walk(host as Any, depth: 0)
                value = ["title":window.title,"elements":controls,"viewport":["width":host.bounds.width,"height":host.bounds.height]]
            case "click", "drag", "scroll", "key", "type":
                let x = command["x"] as? Double ?? host.bounds.midX, y = command["y"] as? Double ?? host.bounds.midY
                let point = NSPoint(x:x,y:host.bounds.height-y)
                func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
                    guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {return}
                    if window.isVisible {window.sendEvent(event);return}
                    func sprite(_ view:NSView)->SKView? {if let sk=view as? SKView,sk.bounds.contains(sk.convert(point,from:nil)){return sk};return view.subviews.compactMap(sprite).first}
                    if let scene=sprite(host)?.scene {
                        switch type {case .leftMouseDown:scene.mouseDown(with:event);case .leftMouseUp:scene.mouseUp(with:event);case .leftMouseDragged:scene.mouseDragged(with:event);default:break}
                        return
                    }
                    let target=host.hitTest(host.convert(point,from:nil)) ?? host!
                    if let button=target as? NSButton {if type == .leftMouseUp {button.performClick(nil)};return}
                    switch type {case .leftMouseDown:target.mouseDown(with:event);case .leftMouseUp:target.mouseUp(with:event);case .leftMouseDragged:target.mouseDragged(with:event);default:break}
                }
                if op == "click" || op == "drag" {
                    mouse(.leftMouseDown,point)
                    if op == "drag" { mouse(.leftMouseDragged,NSPoint(x:command["toX"] as? Double ?? x,y:host.bounds.height-(command["toY"] as? Double ?? y))) }
                    mouse(.leftMouseUp,op == "drag" ? NSPoint(x:command["toX"] as? Double ?? x,y:host.bounds.height-(command["toY"] as? Double ?? y)) : point)
                } else if op == "type" {
                    guard let client = window.firstResponder as? NSTextInputClient else { throw RuntimeError("Focus an editable native control before typing.") }
                    client.insertText(command["text"] as? String ?? "", replacementRange:NSRange(location:NSNotFound,length:0))
                } else if op == "key" {
                    let key = command["text"] as? String ?? "Enter"
                    let keys: [String:(String,UInt16)] = ["Enter":("\r",36),"Escape":("\u{1b}",53),"Space":(" ",49),"Tab":("\t",48),"ArrowLeft":("\u{f702}",123),"ArrowRight":("\u{f703}",124),"ArrowDown":("\u{f701}",125),"ArrowUp":("\u{f700}",126)]
                    let pair = keys[key] ?? (key,0)
                    for type in [NSEvent.EventType.keyDown,.keyUp] {
                        if let event = NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:pair.0,charactersIgnoringModifiers:pair.0,isARepeat:false,keyCode:pair.1) { window.sendEvent(event) }
                    }
                } else {
                    throw RuntimeError("Native scroll injection is not supported by this runtime. Use the noodlet's controls.")
                }
            case "screenshot":
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw RuntimeError("The native view cannot be captured offscreen.") }
                host.cacheDisplay(in:host.bounds,to:bitmap)
                let canvas = NSImage(size: host.bounds.size)
                canvas.lockFocus()
                window.backgroundColor.setFill(); host.bounds.fill()
                bitmap.draw(in: host.bounds)
                func compositeSprites(_ view: NSView) throws {
                    if let sk = view as? SKView, let scene = sk.scene {
                        if !window.isVisible { scene.update(ProcessInfo.processInfo.systemUptime) }
                        guard let cg = sk.texture(from: scene)?.cgImage() else { throw RuntimeError("SpriteKit cannot capture this scene offscreen.") }
                        var frame = sk.convert(sk.bounds, to: host)
                        if host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
                        NSImage(cgImage: cg, size: frame.size).draw(in: frame)
                    } else {
                        for child in view.subviews { try compositeSprites(child) }
                    }
                }
                do { try compositeSprites(host) } catch { canvas.unlockFocus(); throw error }
                canvas.unlockFocus()
                guard let tiff = canvas.tiffRepresentation, let image = NSBitmapImageRep(data: tiff) else { throw RuntimeError("Native screenshot composition failed.") }
                guard let png = image.representation(using:.png,properties:[:]) else { throw RuntimeError("PNG encoding failed.") }
                // The host supplies this private destination; noodlets never choose another session's output.
                let output = NoodletContext.dataDirectory.appendingPathComponent(".capture.png")
                try png.write(to:output,options:.atomic); value = ["path":output.path]
            default: throw RuntimeError("Unsupported native operation: \(op)")
            }
            emit(["id":id,"value":value])
        } catch { emit(["id":id,"error":error.localizedDescription]) }
    }
}
struct RuntimeError: LocalizedError { let message: String; init(_ text: String) { message=text }; var errorDescription: String? { message } }

@MainActor final class NoodletTitlebarDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with:event) }
}
