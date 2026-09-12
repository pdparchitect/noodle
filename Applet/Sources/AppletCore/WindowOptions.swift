import AppletBridge
import Foundation

public struct NoodletWindowOptions: Codable, Sendable {
  public enum Kind: String, Codable, Sendable { case standard, floating, preview }
  public enum Background: String, Codable, Sendable { case opaque, translucent, transparent }
  public var type: Kind = .standard
  public var background: Background = .opaque
  public var resizable = true
  public var rememberFrame = false
  public var titlebar = true
  public var width: Int?
  public var height: Int?
  public var minWidth: Int?
  public var minHeight: Int?
  public var maxWidth: Int?
  public var maxHeight: Int?
  public init() {}
  enum CodingKeys: String, CodingKey {
    case type, background, resizable, rememberFrame, titlebar, width, height, minWidth, minHeight,
      maxWidth, maxHeight
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    type = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .standard
    background = try c.decodeIfPresent(Background.self, forKey: .background) ?? .opaque
    resizable = try c.decodeIfPresent(Bool.self, forKey: .resizable) ?? true
    rememberFrame = try c.decodeIfPresent(Bool.self, forKey: .rememberFrame) ?? false
    titlebar = try c.decodeIfPresent(Bool.self, forKey: .titlebar) ?? true
    width = try c.decodeIfPresent(Int.self, forKey: .width)
    height = try c.decodeIfPresent(Int.self, forKey: .height)
    minWidth = try c.decodeIfPresent(Int.self, forKey: .minWidth)
    minHeight = try c.decodeIfPresent(Int.self, forKey: .minHeight)
    maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth)
    maxHeight = try c.decodeIfPresent(Int.self, forKey: .maxHeight)
  }
  public func validate() throws {
    for value in [width, height, minWidth, minHeight, maxWidth, maxHeight].compactMap({ $0 }) {
      guard (120...4096).contains(value) else {
        throw AppletError("Window dimensions must be between 120 and 4096 points.")
      }
    }
    guard (minWidth ?? 120) <= (maxWidth ?? 4096), (minHeight ?? 120) <= (maxHeight ?? 4096) else {
      throw AppletError("Window minimum dimensions cannot exceed maximum dimensions.")
    }
    if let width, !((minWidth ?? 120)...(maxWidth ?? 4096)).contains(width) {
      throw AppletError("Window width is outside its minimum and maximum.")
    }
    if let height, !((minHeight ?? 120)...(maxHeight ?? 4096)).contains(height) {
      throw AppletError("Window height is outside its minimum and maximum.")
    }
  }
  public func size(width requestedWidth: Int? = nil, height requestedHeight: Int? = nil) -> CGSize {
    CGSize(
      width: CGFloat(min(max(requestedWidth ?? width ?? 900, minWidth ?? 120), maxWidth ?? 4096)),
      height: CGFloat(
        min(max(requestedHeight ?? height ?? 620, minHeight ?? 120), maxHeight ?? 4096)))
  }
}
