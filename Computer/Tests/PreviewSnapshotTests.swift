import AppKit
import WebKit

/// Standalone AppKit/WebKit checks: no guest, network, user library or visible window.
@main struct PreviewSnapshotTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await run()
            exit(0)
        }
        app.run()
    }

    @MainActor static func run() async {
        func require(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            print("PASS: \(message)")
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        defer { web.stopLoading(); window.close() }
        func load(_ body: String) {
            web.loadHTMLString("<html><head><style>html,body{margin:0;width:100%;height:100%;background:black;color:white;font:36px sans-serif}</style></head><body>\(body)</body></html>", baseURL: nil)
        }
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

        load("""
            <div id="content" aria-busy="true">Loading…</div>
            <script>setTimeout(()=>{content.removeAttribute('aria-busy');content.style='height:100%;background:linear-gradient(90deg,#123b66 50%,#e7b74a 50%)';content.textContent='READY: delayed content';},750)</script>
            """)
        var began = now()
        let delayed = await ComputerPreviewSnapshot.capture(web, desktop: false, timeout: 5)
        require(delayed != nil && now() - began >= 1.2, "wait for delayed content and settling before capture")
        if let delayed {
            require(delayed.starts(with: [137, 80, 78, 71]), "text/UI snapshots prefer lossless PNG")
            let bitmap = NSBitmapImageRep(data: delayed)!
            require(bitmap.pixelsWide >= 1024 && bitmap.pixelsWide <= 1440,
                    "capture retains viewport detail instead of a 560-point thumbnail")
            require(abs(Double(bitmap.pixelsWide) / Double(bitmap.pixelsHigh) - 4.0 / 3) < 0.01,
                    "encoding preserves desktop proportions")
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-preview-snapshot-ready.png")
            try! delayed.write(to: output)
        }
        require(!window.isVisible, "snapshot does not show or activate a window")

        let backgroundWeb = WKWebView(frame: web.frame)
        backgroundWeb.loadHTMLString("<html><body style='margin:0;height:100vh;background:linear-gradient(90deg,#123b66 50%,#e7b74a 50%)'>Background provider</body></html>", baseURL: nil)
        let background = await ComputerPreviewSnapshot.capture(backgroundWeb, desktop: false, timeout: 3)
        require(background != nil && backgroundWeb.window == nil, "background provider captures with no host window")

        load("""
            <canvas id="screen" width="1024" height="768"></canvas>
            <script>setTimeout(()=>{document.documentElement.classList.add('noVNC_connected');const ctx=document.getElementById('screen').getContext('2d');ctx.fillStyle='#235b70';ctx.fillRect(0,0,1024,768);ctx.fillStyle='#f0b840';ctx.fillRect(100,100,700,400);},750)</script>
            """)
        began = now()
        let desktop = await ComputerPreviewSnapshot.capture(web, desktop: true, timeout: 5)
        require(desktop != nil && now() - began >= 1.2, "wait for connected desktop canvas and painted frame")

        load("""
            <style>body{background:#272727!important}canvas{position:absolute;top:160px;left:0;width:100%;height:300px}</style>
            <canvas id="screen" width="1024" height="768"></canvas>
            <script>document.documentElement.classList.add('noVNC_connected');const ctx=document.getElementById('screen').getContext('2d');ctx.fillStyle='#0000ff';ctx.fillRect(0,0,1024,768);ctx.fillStyle='#00ff00';ctx.fillRect(50,50,200,200);</script>
            """)
        let letterboxed = await ComputerPreviewSnapshot.capture(web, desktop: true, timeout: 3)
        require(letterboxed != nil, "letterboxed remote desktop produces a snapshot")
        let pixels = NSBitmapImageRep(data: letterboxed!)!
        require(pixels.pixelsWide == 1024 && pixels.pixelsHigh == 768,
                "desktop capture uses native framebuffer proportions, not stretched CSS dimensions")
        let corner = pixels.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        require(corner.blueComponent > 0.95 && corner.redComponent < 0.05,
                "grey browser letterboxing is excluded from the saved image")
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<pixels.pixelsHigh { for x in 0..<pixels.pixelsWide {
            let c = pixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            if c.greenComponent > 0.95 && c.blueComponent < 0.05 { xs.append(x); ys.append(y) }
        } }
        require(xs.max()! - xs.min()! == 199 && ys.max()! - ys.min()! == 199,
                "native desktop squares remain square despite browser stretching")

        load("<div aria-busy='true'>Loading forever</div>")
        began = now()
        let busy = await ComputerPreviewSnapshot.capture(web, desktop: false, timeout: 0.7)
        require(busy == nil && now() - began < 1.2, "busy display returns fallback within timeout")

        load("")
        let blank = await ComputerPreviewSnapshot.capture(web, desktop: false, timeout: 1.5)
        require(blank == nil, "blank completed page returns icon fallback")

        load("<canvas width='1024' height='768'></canvas>")
        let disconnected = await ComputerPreviewSnapshot.capture(web, desktop: true, timeout: 0.7)
        require(disconnected == nil, "canvas alone does not imply desktop connection")

        load("""
            <div style="position:absolute;inset:6% 4% 0;border:1px solid white;background:radial-gradient(#18181e,#08080b)"><span style="position:absolute;top:50%;left:50%;font-size:12px">]</span></div>
            """)
        let spinner = await ComputerPreviewSnapshot.capture(web, desktop: false, timeout: 1.5)
        require(spinner == nil, "remote window border, dark wallpaper and tiny spinner are not ready content")

        load("""
            <div style="position:absolute;inset:6% 4% 0;border:1px solid white;background:radial-gradient(#18181e,#08080b)"><pre style="margin:50px 20px;font:16px monospace">agent@computer /workspace $ ls
            documents  projects  hello.txt
            agent@computer /workspace $</pre></div>
            """)
        let terminal = await ComputerPreviewSnapshot.capture(web, desktop: false, timeout: 3)
        require(terminal != nil, "real terminal text on dark desktop remains useful")
        if let terminal {
            require(terminal.starts(with: [137, 80, 78, 71]), "desktop terminal text is stored without JPEG artifacts")
            try! terminal.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-preview-terminal-quality.png"))
        }

        // Deterministic incompressible content exercises the byte cap and JPEG fallback.
        let noise = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var seed: UInt32 = 7
        for y in 0..<noise.pixelsHigh { for x in 0..<noise.pixelsWide {
            let pixel = noise.bitmapData! + y * noise.bytesPerRow + x * 4
            for channel in 0..<3 { seed = seed &* 1664525 &+ 1013904223; pixel[channel] = UInt8(truncatingIfNeeded: seed >> 24) }
            pixel[3] = 255
        } }
        let noiseImage = NSImage(size: NSSize(width: 1600, height: 1200)); noiseImage.addRepresentation(noise)
        let encodedNoise = ComputerPreviewSnapshot.encode(noiseImage)
        require(encodedNoise != nil && encodedNoise!.count <= 512_000, "detailed images stay under the existing wire limit")
        require(encodedNoise!.starts(with: [255, 216]), "oversized PNG uses bounded high-quality JPEG fallback")
        let small = NSImage(size: NSSize(width: 200, height: 150))
        small.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 200, height: 150).fill(); small.unlockFocus()
        let smallSource = NSBitmapImageRep(data: small.tiffRepresentation!)!
        let smallEncoded = NSBitmapImageRep(data: ComputerPreviewSnapshot.encode(small)!)!
        require(smallEncoded.pixelsWide == smallSource.pixelsWide, "small images are never artificially upscaled")
        if CommandLine.arguments.count == 2, let observed = NSImage(contentsOfFile: CommandLine.arguments[1]) {
            require(!ComputerPreviewSnapshot.isUseful(observed), "reject the loading frame captured from the real desktop")
        }

        load("<div style='height:100%;background:linear-gradient(90deg,red,blue)'>Removed computer</div>")
        var valid = true
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(200)); valid = false }
        let removed = await ComputerPreviewSnapshot.capture(web, desktop: false, timeout: 3) { valid }
        require(removed == nil, "computer removal cancels pending capture")

        load("<div aria-busy='true'>Loading forever</div>")
        let task = Task { @MainActor in await ComputerPreviewSnapshot.capture(web, desktop: false, timeout: 5) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        require(await task.value == nil, "cancelled request does not produce a snapshot")

        print("SNAPSHOT TESTS PASSED")
    }
}
