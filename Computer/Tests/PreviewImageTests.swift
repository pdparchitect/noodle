import AppKit
import SwiftUI

@main struct PreviewImageTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Red top-left, blue remainder: centering the crop would lose the red.
        for size in [NSSize(width: 900, height: 240), NSSize(width: 360, height: 900)] {
            let source = NSImage(size: size, flipped: false) { rect in
                NSColor.blue.setFill(); rect.fill()
                NSColor.red.setFill()
                NSRect(x: 0, y: size.height - 120, width: 120, height: 120).fill()
                return true
            }
            let renderer = ImageRenderer(content: ComputerPreviewImage(image: source, width: 360, height: 240))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  bitmap.pixelsWide == 720, bitmap.pixelsHigh == 480,
                  let origin = bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB),
                  let far = bitmap.colorAt(x: 710, y: 470)?.usingColorSpace(.deviceRGB),
                  origin.redComponent > 0.9, origin.blueComponent < 0.1,
                  far.blueComponent > 0.9, far.alphaComponent > 0.99 else {
                fputs("FAIL: top-left cover crop for \(size)\n", stderr); exit(1)
            }
            print("PASS: \(size) fills the card at Retina resolution, with top-left retained and no empty edges")
        }
    }
}
