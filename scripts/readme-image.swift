// The pieces of a README screenshot, for scripts/readme-shots.sh.
// `backdrop ART OUT [WIDTH HEIGHT]` draws an app's artwork filling the frame, blurred until only its light remains and
// brightened, as the picture scripts/scenario.sh --background puts behind the window.
// `round IN OUT WIDTH` scales a shot to WIDTH pixels and rounds its corners, as the README images are.
import AppKit
import CoreImage

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func load(_ path: String) -> CGImage {
    guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fail("Could not read an image at \(path).")
    }
    return image
}

func save(_ image: CGImage, to path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else {
        fail("Could not write \(path).")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("Could not write \(path).") }
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "backdrop" where arguments.count == 4 || arguments.count == 6:
    let art = CIImage(cgImage: load(arguments[2]))
    let width = arguments.count == 6 ? Double(arguments[4]) ?? 3200 : 3200
    let height = arguments.count == 6 ? Double(arguments[5]) ?? 2000 : 2000
    // A little larger than the frame, so the blur has artwork to draw on at every edge.
    let fill = max(width / art.extent.width, height / art.extent.height) * 1.1
    let glow = art.clampedToExtent()
        .transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        .applyingGaussianBlur(sigma: width / 28)
        .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2.2])
        .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
        .transformed(by: CGAffineTransform(translationX: -(art.extent.width * fill - width) / 2,
                                           y: -(art.extent.height * fill - height) / 2))
    guard let image = CIContext().createCGImage(glow, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
        fail("Could not draw the backdrop.")
    }
    save(image, to: arguments[3])
case "round" where arguments.count == 5:
    let shot = load(arguments[2])
    guard let width = Int(arguments[4]), width > 0 else { fail("WIDTH is a number of pixels.") }
    let height = Int((Double(width) * Double(shot.height) / Double(shot.width)).rounded())
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("Could not draw the shot.") }
    let radius = Double(width) * 0.022
    context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.interpolationQuality = .high
    context.draw(shot, in: CGRect(x: 0, y: 0, width: width, height: height))
    save(context.makeImage()!, to: arguments[3])
default:
    fail("Usage: readme-image.swift backdrop ART OUT [WIDTH HEIGHT] | round IN OUT WIDTH")
}
