import AppKit

// Build-only renderer. Never create an NSApplication or a window.
func fail(_ message: String) -> Never {
    fputs("Icon generation failed: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: generate-icon.swift AppSymbol.svg TEMPLATE.svg OUTPUT.iconset")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let templateURL = URL(fileURLWithPath: CommandLine.arguments[2])
let destination = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
let iconURL = sourceURL.deletingLastPathComponent().appendingPathComponent("AppIcon.svg")

do {
    // Inline vector layers so the full icon has no dependency on external SVG
    // links, and every renderer sees exactly the same composed artwork.
    let document = try XMLDocument(contentsOf: sourceURL, options: .nodeLoadExternalEntitiesNever)
    let template = try XMLDocument(contentsOf: templateURL, options: .nodeLoadExternalEntitiesNever)
    guard sourceURL != iconURL,
          let root = document.rootElement(), root.name == "svg",
          let templateRoot = template.rootElement(), templateRoot.name == "svg",
          let viewBox = root.attribute(forName: "viewBox")?.stringValue,
          viewBox == templateRoot.attribute(forName: "viewBox")?.stringValue,
          let backgroundID = root.attribute(forName: "data-icon-background")?.stringValue,
          let background = templateRoot.elements(forName: "defs").first?
            .elements(forName: "g").first(where: { $0.attribute(forName: "id")?.stringValue == backgroundID }) else {
        fail("symbol must have the template's viewBox and a valid data-icon-background")
    }
    root.removeAttribute(forName: "data-icon-background")
    root.insertChild(background.copy() as! XMLNode, at: 0)
    root.insertChild(XMLNode.comment(withStringValue:
        "Generated from AppSymbol.svg and AppIconTemplate.svg; edit those sources.") as! XMLNode, at: 0)
    for title in root.elements(forName: "title") {
        title.stringValue = title.stringValue?.replacingOccurrences(of: " symbol", with: " app icon")
    }
    let iconData = document.xmlData(options: .nodePrettyPrint)
    guard let source = NSImage(data: iconData), source.isValid,
          source.size.width > 0, source.size.width == source.size.height else {
        fail("could not render the composed SVG for \(sourceURL.path)")
    }
    source.cacheMode = .never

    var images: [(String, Data)] = []
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                fail("could not create a \(pixels)px rendering context")
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                        from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                fail("could not encode the \(pixels)px icon")
            }
            images.append(("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png", png))
        }
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try iconData.write(to: iconURL, options: .atomic)
    for (filename, png) in images {
        try png.write(to: destination.appendingPathComponent(filename), options: .atomic)
    }
    // README and other PNG consumers use the same generated 1024px artwork.
    try images.last!.1.write(to: iconURL.deletingPathExtension().appendingPathExtension("png"), options: .atomic)
} catch {
    fail(error.localizedDescription)
}
