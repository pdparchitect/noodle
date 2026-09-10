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
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-preview-snapshot-ready.jpg")
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
