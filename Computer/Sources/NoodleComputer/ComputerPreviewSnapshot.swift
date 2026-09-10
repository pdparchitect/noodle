import AppKit
import WebKit

/// Best-effort historical thumbnail, never a readiness signal for agent work.
/// A failed/slow page yields nil so Noodle can show its normal computer-icon card.
@MainActor enum ComputerPreviewSnapshot {
    static func capture(_ view: WKWebView, desktop: Bool, timeout: TimeInterval = 8,
                        valid: () -> Bool = { true }) async -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, min(timeout, 8))
        var lastLayout: String?
        var settledSince = ProcessInfo.processInfo.systemUptime
        while valid(), !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            let layout: String? = await bounded(until: min(deadline, ProcessInfo.processInfo.systemUptime + 1)) { finish in
                view.evaluateJavaScript(readinessScript(desktop: desktop)) { value, _ in finish(value as? String) }
            }
            guard valid(), !Task.isCancelled else { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            if view.isLoading || layout == nil || layout != lastLayout {
                lastLayout = view.isLoading ? nil : layout
                settledSince = now
            } else if now - settledSince >= 0.6, now < deadline {
                let configuration = WKSnapshotConfiguration()
                configuration.snapshotWidth = 560
                configuration.afterScreenUpdates = true
                let snapshot: NSImage? = await bounded(until: min(deadline, now + 1.5)) { finish in
                    view.takeSnapshot(with: configuration) { image, _ in finish(image) }
                }
                guard valid(), !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                // Navigation or guest resize may have started while WebKit captured.
                let current: String? = await bounded(until: min(deadline, ProcessInfo.processInfo.systemUptime + 0.5)) { finish in
                    view.evaluateJavaScript(readinessScript(desktop: desktop)) { value, _ in finish(value as? String) }
                }
                if valid(), !Task.isCancelled, !view.isLoading, current == layout,
                   ProcessInfo.processInfo.systemUptime < deadline,
                   let snapshot, isUseful(snapshot),
                   let tiff = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                   let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]), jpeg.count <= 512_000 {
                    return jpeg
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    static func readinessScript(desktop: Bool) -> String {
        """
        (() => {
          if (document.readyState !== 'complete' || !document.body || innerWidth < 100 || innerHeight < 100) return null;
          const visible = e => {
            const r = e.getBoundingClientRect(), s = getComputedStyle(e);
            return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 &&
              r.top < innerHeight && r.left < innerWidth && s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
          };
          if (document.fonts && document.fonts.status !== 'loaded') return null;
          if ([...document.images].slice(0, 512).some(e => visible(e) && !e.complete)) return null;
          if ([...document.querySelectorAll('[aria-busy="true"], [role="progressbar"], progress')].slice(0, 512).some(visible)) return null;
          const canvases = [...document.querySelectorAll('canvas')].slice(0, 32).filter(visible);
          if (\(desktop ? "true" : "false") && (!document.documentElement.classList.contains('noVNC_connected') ||
              !canvases.some(c => c.width > 100 && c.height > 100))) return null;
          return JSON.stringify([location.href, innerWidth, innerHeight,
            canvases.map(c => [c.width, c.height]), document.body.innerText.slice(0, 2048)]);
        })()
        """
    }

    /// Ignore outer desktop chrome and low-contrast wallpaper when looking for
    /// useful content. A connected remote desktop can still contain a loading
    /// terminal; its thin border and tiny spinner must not pass this check.
    static func isUseful(_ image: NSImage) -> Bool {
        guard image.size.width >= 100, image.size.height >= 100,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 96,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 128, height: 96).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 96), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = bitmap.bitmapData else { return false }
        var red: [Int] = [], green: [Int] = [], blue: [Int] = []
        // Bitmap rows run top-to-bottom: skip menu/window title bars and borders.
        for y in 14..<90 {
            for x in 10..<118 {
                let pixel = bytes + y * bitmap.bytesPerRow + x * 4
                red.append(Int(pixel[0])); green.append(Int(pixel[1])); blue.append(Int(pixel[2]))
            }
        }
        let middle = red.count / 2
        let baseline = (red.sorted()[middle], green.sorted()[middle], blue.sorted()[middle])
        let foreground = red.indices.filter {
            max(abs(red[$0] - baseline.0), abs(green[$0] - baseline.1), abs(blue[$0] - baseline.2)) >= 48
        }.count
        return foreground >= max(6, red.count / 300)
    }

    /// WebKit callbacks can stall when hidden or terminating. Do not allow them
    /// to extend the preview deadline; late callbacks are ignored exactly once.
    private static func bounded<T>(until deadline: TimeInterval,
                                   start: (@escaping (T?) -> Void) -> Void) async -> T? {
        await withCheckedContinuation { continuation in
            var finished = false
            let finish: (T?) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { finish(nil) }
            start(finish)
        }
    }
}
