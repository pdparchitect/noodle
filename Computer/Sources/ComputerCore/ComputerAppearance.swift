import Foundation

public struct ComputerAppearance: Codable, Equatable, Sendable {
    public var iconSymbol: String?
    public var iconColour = 0
    public var iconImage: Data?
    public var backgroundPreset: String?
    public var backgroundImage: Data?
    public var terminalForeground = "FFFFFF"
    public var terminalBackground = "000000"
    public var terminalOpacity = 1.0

    public init() {}

    public func validate() throws {
        guard (0...5).contains(iconColour), terminalOpacity.isFinite,
              (0...1).contains(terminalOpacity),
              Self.validColour(terminalForeground), Self.validColour(terminalBackground),
              [nil, "sunset", "ocean", "forest", "dusk"].contains(backgroundPreset),
              (iconImage?.count ?? 0) <= 2 * 1024 * 1024,
              (backgroundImage?.count ?? 0) <= 8 * 1024 * 1024 else {
            throw ComputerError("Invalid computer appearance settings.")
        }
    }

    private static func validColour(_ value: String) -> Bool {
        value.count == 6 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}
