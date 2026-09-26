import SwiftUI

/// The Noodle wordmark as one pen stroke, which the first screen writes on as the website does.
///
/// The strokes are the website's wordmark paths, in its 3819 × 851 box, in the order a hand
/// would write them.
struct Wordmark: Shape {
    /// How much of the stroke has been written, from nothing to the whole word.
    var progress: Double = 1

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static let pen: CGFloat = 128
    static let bounds = CGRect(x: 0, y: 119, width: 3819, height: 851)

    static let strokes = [
        "M64,906 L64,569 C64,444.18 165.18,343 290,343 C414.82,343 516,444.18 516,569 L516,818 C516,913 583,910 643,899",
        "M1096.5,343 C941.03,343 815,469.03 815,624.5 C815,779.97 941.03,906 1096.5,906 C1251.97,906 1378,779.97 1378,624.5 C1378,469.03 1251.97,343 1096.5,343",
        "M1831.5,343 C1676.03,343 1550,469.03 1550,624.5 C1550,779.97 1676.03,906 1831.5,906 C1986.97,906 2113,779.97 2113,624.5 C2113,469.03 1986.97,343 1831.5,343",
        "M2566.5,343 C2411.03,343 2285,469.03 2285,624.5 C2285,779.97 2411.03,906 2566.5,906 C2721.97,906 2848,779.97 2848,624.5 C2848,469.03 2721.97,343 2566.5,343",
        "M2848,183 L2848,906",
        "M3020,183 L3020,906",
        "M3192,624.5 L3755,624.5 C3755,469.03 3628.97,343 3473.5,343 C3318.03,343 3192,469.03 3192,624.5 C3192,779.97 3318.03,906 3473.5,906 C3569.89,906 3614.25,877.85 3681.81,821.55",
    ]

    /// The whole word in design units. The strokes use only absolute M, L and C commands.
    static let skeleton: Path = {
        var path = Path()
        for stroke in strokes {
            var command: Character = "M"
            var numbers: [CGFloat] = []
            func flush() {
                let points = stride(from: 0, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
                switch command {
                case "M": points.first.map { path.move(to: $0) }
                case "L": points.forEach { path.addLine(to: $0) }
                case "C" where points.count == 3: path.addCurve(to: points[2], control1: points[0], control2: points[1])
                default: break
                }
                numbers = []
            }
            for token in stroke.split(whereSeparator: { $0 == " " || $0 == "," }) {
                if let letter = token.first, letter.isLetter {
                    flush()
                    command = letter
                    if let number = Double(token.dropFirst()) { numbers.append(number) }
                } else if let number = Double(token) {
                    numbers.append(number)
                }
            }
            flush()
        }
        return path
    }()

    func path(in rect: CGRect) -> Path {
        let scale = Self.scale(in: rect)
        guard scale > 0 else { return Path() }
        let width = Self.bounds.width * scale, height = Self.bounds.height * scale
        let transform = CGAffineTransform(translationX: rect.midX - width / 2, y: rect.midY - height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -Self.bounds.minX, y: -Self.bounds.minY)
        let full = Self.skeleton.applying(transform)
        return progress >= 1 ? full : full.trimmedPath(from: 0, to: max(0, progress))
    }

    /// The pen width for a word drawn into `rect`.
    static func lineWidth(in rect: CGRect) -> CGFloat { pen * scale(in: rect) }

    private static func scale(in rect: CGRect) -> CGFloat {
        min(rect.width / bounds.width, rect.height / bounds.height)
    }
}
