import Foundation
@_exported import NoodleWallpaperCore

public struct ComputerAppearance: Codable, Equatable, Sendable {
    public var iconSymbol: String?
    public var iconColour = 0
    public var iconImage: Data?
    public var backgroundPreset: String?
    public var backgroundImage: Data?
    public var backgroundFilename: String?
    public var backgroundMediaKind: BackgroundMediaKind?
    /// Owned temporary import, retained across nested appearance/create sheets.
    /// Only the committed filename and kind are written to computer.json.
    public var backgroundFile: PreparedBackgroundFile? = nil
    public var terminalForeground = "FFFFFF"
    public var terminalBackground = "000000"
    public var terminalOpacity = 1.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case iconSymbol, iconColour, iconImage, backgroundPreset, backgroundImage
        case backgroundFilename, backgroundMediaKind
        case terminalForeground, terminalBackground, terminalOpacity
    }

    public var background: ConversationBackground {
        ConversationBackground(preset: backgroundPreset.flatMap(ConversationBackgroundPreset.init(rawValue:)),
            imageFilename: backgroundFile?.url.lastPathComponent ?? backgroundFilename ?? (backgroundImage == nil ? nil : "legacy"),
            mediaKind: backgroundFile?.kind ?? backgroundMediaKind)
    }

    public func backgroundURL(in directory: URL?) -> URL? {
        if let backgroundFile { return backgroundFile.url }
        guard let name = backgroundFilename, Self.validBackgroundFilename(name) else { return nil }
        return directory?.appendingPathComponent("Backgrounds", isDirectory: true).appendingPathComponent(name)
    }

    public static func validBackgroundFilename(_ name: String) -> Bool {
        name == (name as NSString).lastPathComponent &&
        UUID(uuidString: (name as NSString).deletingPathExtension) != nil &&
        ["jpg", "heic", "heif", "mov", "mp4", "m4v"].contains((name as NSString).pathExtension)
    }

    public func validate() throws {
        guard (0...5).contains(iconColour), terminalOpacity.isFinite,
              (0...1).contains(terminalOpacity),
              Self.validColour(terminalForeground), Self.validColour(terminalBackground),
              backgroundPreset.map({ ConversationBackgroundPreset(rawValue: $0) != nil }) ?? true,
              (iconImage?.count ?? 0) <= 2 * 1024 * 1024,
              (backgroundImage?.count ?? 0) <= 8 * 1024 * 1024 else {
            throw ComputerError("Invalid computer appearance settings.")
        }
        if let name = backgroundFilename, !Self.validBackgroundFilename(name) {
            throw ComputerError("Invalid computer background filename.")
        }
        if backgroundFile == nil {
            guard (backgroundFilename == nil) == (backgroundMediaKind == nil) else {
                throw ComputerError("Computer background media is missing its filename or type.")
            }
        }
    }

    private static func validColour(_ value: String) -> Bool {
        value.count == 6 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}
