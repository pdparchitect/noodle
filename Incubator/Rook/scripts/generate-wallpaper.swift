import AppKit

// Build-only renderer. Never create an NSApplication or a window.
func fail(_ message: String) -> Never {
    fputs("Wallpaper generation failed: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: generate-wallpaper.swift AppSymbol.svg TEMPLATE.svg OUTPUT.png")
}
let symbolURL = URL(fileURLWithPath: CommandLine.arguments[1])
let templateURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])

do {
    // The symbol's parts go into every template group marked data-symbol, which gives them their own fill.
    let symbol = try XMLDocument(contentsOf: symbolURL, options: .nodeLoadExternalEntitiesNever)
    let template = try XMLDocument(contentsOf: templateURL, options: .nodeLoadExternalEntitiesNever)
    let parts = try symbol.nodes(forXPath: "//*[local-name()='g'][@id='symbol']/*[local-name()='path']")
    let targets = try template.nodes(forXPath: "//*[local-name()='g'][@data-symbol]").compactMap { $0 as? XMLElement }
    guard !parts.isEmpty, !targets.isEmpty, let root = template.rootElement(),
          let width = root.attribute(forName: "width")?.stringValue.flatMap(Int.init),
          let height = root.attribute(forName: "height")?.stringValue.flatMap(Int.init) else {
        fail("the symbol needs a g#symbol of paths and the template data-symbol groups and a pixel size")
    }
    for target in targets {
        target.removeAttribute(forName: "data-symbol")
        for part in parts {
            let copy = part.copy() as! XMLElement
            copy.removeAttribute(forName: "fill")
            target.addChild(copy)
        }
    }
    guard let image = NSImage(data: template.xmlData), image.isValid else { fail("could not read the composed SVG") }
    // Opaque: a wallpaper has no transparent pixels, so the PNG carries no alpha channel.
    guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fail("could not create a \(width)×\(height) canvas")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let rendered = canvas.makeImage(),
          let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
        fail("could not encode the PNG")
    }
    try png.write(to: outputURL, options: .atomic)
} catch {
    fail(error.localizedDescription)
}
