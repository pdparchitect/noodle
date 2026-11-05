import AppKit

/// Best-effort historical thumbnail, never a readiness signal for agent work.
/// A desktop that is still starting yields nil so Noodle can show its normal computer-icon card.
@MainActor public enum ComputerPreviewSnapshot {
    public static func capture(timeout: TimeInterval = 8, valid: () -> Bool = { true },
                        frame: () async throws -> CGImage) async -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, min(timeout, 8))
        while valid(), !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            if let image = try? await frame() {
                guard valid(), !Task.isCancelled else { return nil }
                let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                if isUseful(picture), let data = encode(picture) { return data }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    static func encode(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let source = NSBitmapImageRep(data: tiff),
              source.pixelsWide > 0, source.pixelsHigh > 0 else { return nil }
        var candidates: [NSBitmapImageRep] = []
        for limit in [1440, 1080, 720] {
            let scale = min(1, Double(limit) / Double(max(source.pixelsWide, source.pixelsHigh)))
            let width = max(1, Int(Double(source.pixelsWide) * scale))
            let height = max(1, Int(Double(source.pixelsHigh) * scale))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            let rect = NSRect(x: 0, y: 0, width: width, height: height)
            NSColor.black.setFill(); rect.fill()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            if let png = bitmap.representation(using: .png, properties: [:]), png.count <= 512_000 { return png }
            candidates.append(bitmap)
        }
        for bitmap in candidates {
            for quality in [0.92, 0.85] {
                if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
                   jpeg.count <= 512_000 { return jpeg }
            }
        }
        return nil
    }

    /// Ignore outer desktop chrome and low-contrast wallpaper when looking for
    /// useful content. A started desktop can still contain a loading
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
}
