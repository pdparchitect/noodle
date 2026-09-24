import AppKit

// Compares every PNG of a freshly generated iconset with the committed one. Rendering differs a
// little between macOS versions, so a few slightly different edge pixels pass; a changed symbol does not.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard CommandLine.arguments.count == 3 else { fail("usage: compare-icons.swift GENERATED.iconset COMMITTED.appiconset") }
let generated = URL(fileURLWithPath: CommandLine.arguments[1]), committed = URL(fileURLWithPath: CommandLine.arguments[2])
let names = try FileManager.default.contentsOfDirectory(atPath: generated.path).filter { $0.hasSuffix(".png") }.sorted()
guard !names.isEmpty else { fail("No icons were generated in \(generated.path)") }

func pixels(_ url: URL) -> (width: Int, height: Int, bytes: [UInt8]) {
    guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("Missing or unreadable icon: \(url.path)")
    }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image.width, image.height, bytes)
}

for name in names {
    let fresh = pixels(generated.appendingPathComponent(name)), kept = pixels(committed.appendingPathComponent(name))
    guard fresh.width == kept.width, fresh.height == kept.height else { fail("\(name) has the wrong size in \(committed.path)") }
    var differing = 0
    for pixel in 0..<(fresh.width * fresh.height) {
        let channels = (pixel * 4)..<(pixel * 4 + 4)
        if channels.contains(where: { abs(Int(fresh.bytes[$0]) - Int(kept.bytes[$0])) > 8 }) { differing += 1 }
    }
    if differing * 200 > fresh.width * fresh.height {
        fail("\(committed.path)/\(name) no longer matches its AppSymbol.svg; regenerate it with scripts/verify-icons.sh --update")
    }
}
print("\(committed.lastPathComponent) matches its AppSymbol.svg")
