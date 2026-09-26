import CoreGraphics
import CoreText
import Foundation

/// A terminal as a surface: its latest output drawn as text, and keys as the bytes a shell expects.
public enum TerminalSurface {
    public static let columns = 110, rows = 34

    /// Output without colour and cursor codes.
    public static func plainText(_ output: Data) -> String {
        let text = String(decoding: output, as: UTF8.self)
        return text.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]|\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)|\u{1b}[()][0-9A-Za-z]|\u{1b}[=>]",
                                         with: "", options: .regularExpression)
    }

    /// The last screenful of `output`, and its size in points.
    public static func picture(_ output: Data) -> (image: CGImage, size: CGSize)? {
        var lines: [String] = []
        for line in plainText(output).replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            // A carriage return alone rewrites the line, as a progress bar does.
            let shown = String(line.split(separator: "\r", omittingEmptySubsequences: false).last ?? "")
            lines.append(String(shown.prefix(columns)))
        }
        lines = Array(lines.suffix(rows))
        let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        let advance = 7.83, lineHeight = 17.0, margin = 10.0
        let width = Int(Double(columns) * advance + margin * 2), height = Int(Double(rows) * lineHeight + margin * 2)
        let scale = 2
        guard let context = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0.92, alpha: 1)] as CFDictionary
        for (index, line) in lines.enumerated() {
            let typeset = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, line as CFString, attributes))
            context.textPosition = CGPoint(x: margin, y: Double(height) - margin - lineHeight * Double(index + 1) + 4)
            CTLineDraw(typeset, context)
        }
        guard let image = context.makeImage() else { return nil }
        return (image, CGSize(width: width, height: height))
    }

    /// What to write to the shell for a key or text; nil for pointer input, which a terminal ignores.
    public static func bytes(for input: SurfaceInput) -> Data? {
        switch input {
        case .text(let text): return Data(text.utf8)
        case .key(let key):
            let sequences: [SurfaceInput.Key: String] = [.enter: "\r", .tab: "\t", .escape: "\u{1b}", .backspace: "\u{7f}", .space: " ",
                                                         .up: "\u{1b}[A", .down: "\u{1b}[B", .right: "\u{1b}[C", .left: "\u{1b}[D"]
            return sequences[key].map { Data($0.utf8) }
        case .pointer, .scroll: return nil
        }
    }
}
