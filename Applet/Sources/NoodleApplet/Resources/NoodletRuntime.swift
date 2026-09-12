import AppKit
import SwiftUI
import SpriteKit

/// Available to the noodlet's SwiftUI view. Data survives rebuilds and restarts.
public enum NoodletContext {
    public static let dataDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOODLET_DATA"]!)
    public static let packageDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOODLET_PACKAGE"]!)
    public static var isBackground: Bool { ProcessInfo.processInfo.environment["NOODLET_MODE"] != "foreground" }
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

@MainActor final class NoodletRuntimeDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var host: NSView!
    let prefix = ProcessInfo.processInfo.environment["NOODLET_PROTOCOL"]!
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
    func applicationDidFinishLaunching(_ notification: Notification) {
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
            let name = "Noodlet." + (env["NOODLET_WINDOW_KEY"] ?? "")
            window.setFrameUsingName(name); window.setFrameAutosaveName(name)
            let current = window.contentRect(forFrameRect: window.frame).size
            window.setContentSize(NSSize(width: min(max(current.width, window.contentMinSize.width), window.contentMaxSize.width), height: min(max(current.height, window.contentMinSize.height), window.contentMaxSize.height)))
        }
        if !NoodletContext.isBackground { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        emit(["id":"ready","value":"ready"])
        let prefix = self.prefix
        DispatchQueue.global().async {
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                Task { @MainActor [weak self] in self?.handle(command) }
            }
            // EOF also ends the child if its owner crashes or is killed.
            _ = prefix
            Darwin.exit(0)
        }
    }
    func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data((prefix + String(decoding: data, as: UTF8.self) + "\n").utf8))
    }
    func handle(_ command: [String: Any]) {
        let id = command["id"] as? String ?? "", op = command["operation"] as? String ?? ""
        do {
            var value: Any = ["ok":true]
            switch op {
            case "show": window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            case "hide": window.orderOut(nil)
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
