import Foundation
import Surface

public struct NoodletManifest: Codable, Sendable, Equatable {
  public var version: Int
  public var title: String
  public var runtime: String
  public var entry: String
  public var summary: String?
  public var symbol: String?
  public var network: Bool
  public var window: NoodletWindowOptions?
  /// Protected resources the user is asked about before the noodlet starts.
  public var permissions: [String]?
  /// Groups the noodlet under one library sidebar category; untagged noodlets appear only in All.
  public var category: String?
  /// The keys a game listens for, shown as a controller to people watching on a phone.
  public var controls: Gamepad?
  /// What the page is laid out for; none means a desktop window.
  public var layout: Layout?
  /// Where it works best when opened from another device; none means either.
  public var runs: Placement?
  /// The look its page sees; none follows the device's appearance.
  public var theme: Theme?
  /// How it presents itself, as in a web app's manifest; none is a web page.
  public var display: Display?
  /// Which way a phone shows it; none turns with the phone.
  public var orientation: Orientation?
  /// A hex colour shown until the page paints its own, such as while it loads.
  public var backgroundColor: String?
  public enum Layout: String, Codable, Sendable, CaseIterable {
    /// A window with a pointer, which a phone shows at desktop width.
    case desktop
    /// A phone's touch screen.
    case phone
    /// Any size.
    case adaptive
  }
  public enum Theme: String, Codable, Sendable, CaseIterable {
    case system, light, dark
  }
  public enum Display: String, Codable, Sendable, CaseIterable {
    /// A web page: it scrolls and zooms, and its text can be selected.
    case browser
    /// An app: it fits its view, without page scrolling, zoom, text selection or long-press menu.
    case standalone
    /// An app that also takes the whole screen, with the device's and Noodle's bars out of the way.
    case fullscreen
    /// Whether it fits its view as an app does.
    public var fitsView: Bool { self != .browser }
  }
  public enum Orientation: String, Codable, Sendable, CaseIterable {
    case any, portrait, landscape
  }
  public enum Placement: String, Codable, Sendable, CaseIterable {
    /// On the device it is opened on, such as a noodlet that picks the phone's files or uses its camera.
    case device
    /// On the Hub that keeps it, shown live, such as one that reaches the Hub's own network.
    case hub
  }
  public static let knownCategories = [
    "games", "productivity", "utilities", "developer", "data",
    "creativity", "media", "writing", "learning", "lifestyle",
  ]
  public static let knownPermissions = ["microphone", "camera", "speech-recognition", "screen-capture"]
  public init(
    title: String, runtime: String = "html", entry: String = "index.html",
    summary: String? = nil, symbol: String? = nil, network: Bool = false
  ) {
    version = 1
    self.title = title
    self.runtime = runtime
    self.entry = entry
    self.summary = summary
    self.symbol = symbol
    self.network = network
  }
  enum CodingKeys: String, CodingKey {
    case version, title, runtime, entry, summary, symbol, network, window, permissions, category, controls, layout, runs, theme
    case display, orientation, backgroundColor
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    title = try c.decode(String.self, forKey: .title)
    runtime = try c.decode(String.self, forKey: .runtime)
    entry = try c.decode(String.self, forKey: .entry)
    summary = try c.decodeIfPresent(String.self, forKey: .summary)
    symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
    network = try c.decodeIfPresent(Bool.self, forKey: .network) ?? false
    window = try c.decodeIfPresent(NoodletWindowOptions.self, forKey: .window)
    permissions = try c.decodeIfPresent([String].self, forKey: .permissions)
    category = try c.decodeIfPresent(String.self, forKey: .category)
    controls = try c.decodeIfPresent(Gamepad.self, forKey: .controls)
    layout = try Self.hint(.layout, in: c, known: "desktop, phone or adaptive")
    runs = try Self.hint(.runs, in: c, known: "device or hub")
    theme = try Self.hint(.theme, in: c, known: "system, light or dark")
    display = try Self.hint(.display, in: c, known: "browser, standalone or fullscreen")
    orientation = try Self.hint(.orientation, in: c, known: "any, portrait or landscape")
    backgroundColor = try c.decodeIfPresent(String.self, forKey: .backgroundColor)
    // Only a hex colour: it goes into the page's style as it is.
    if let colour = backgroundColor, !Self.isHexColour(colour) {
      throw AppletError("Unknown backgroundColor \(colour.prefix(40)). Use a hex colour such as #1d1d1f.")
    }
  }
  public static func isHexColour(_ text: String) -> Bool {
    let digits = text.dropFirst()
    return text.first == "#" && [3, 6].contains(digits.count) && digits.allSatisfy(\.isHexDigit)
  }
  /// A hint the manifest names, refusing a value it does not know with what it may be instead.
  private static func hint<Hint: RawRepresentable<String>>(
    _ key: CodingKeys, in c: KeyedDecodingContainer<CodingKeys>, known: String
  ) throws -> Hint? {
    guard let value = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
    guard let hint = Hint(rawValue: value) else {
      throw AppletError("Unknown \(key.rawValue) \(value.prefix(40)). Use \(known).")
    }
    return hint
  }
  /// Whether the Hub may stream it to another device. Everything a noodlet can ask for, the
  /// camera, microphone and screen, belongs to the device showing it; streamed from the Hub it
  /// would get the Hub's, so one that asks runs on the device.
  public var streams: Bool { (permissions ?? []).isEmpty }
  /// Where it runs when opened from another device: where the person last chose, else where its
  /// bot said, else on the device, unless only the device can run it.
  public func placement(chosen: Placement?) -> Placement {
    streams ? chosen ?? runs ?? .device : .device
  }
  public func validate() throws {
    try window?.validate()
    do { try controls?.validate() } catch let error as Gamepad.Invalid { throw AppletError(error.message) }
    for permission in permissions ?? [] where !Self.knownPermissions.contains(permission) {
      throw AppletError("Unknown permission \(permission.prefix(40)). Use \(Self.knownPermissions.joined(separator: ", ")).")
    }
    if let category, !Self.knownCategories.contains(category) {
      throw AppletError("Unknown category \(category.prefix(40)). Use \(Self.knownCategories.joined(separator: ", ")).")
    }
    guard version == 1 else { throw AppletError("Unsupported noodlet version \(version).") }
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200
    else { throw AppletError("A noodlet needs a title of 1–200 characters.") }
    guard runtime == "html" else { throw AppletError("Runtime must be html.") }
    try NoodletPath.validate(entry)
    guard entry.hasSuffix(".html") else { throw AppletError("The entry must be an .html file.") }
  }
}
