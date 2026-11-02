import Foundation
import Surface

public struct NoodletManifest: Codable, Sendable, Equatable {
  public var version: Int
  public var title: String
  public var runtime: String
  public var entry: String
  public var summary: String?
  public var symbol: String?
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
  /// Web sites the page may show in its frames, each an https origin such as
  /// https://player.vimeo.com. The page itself always stays on its package.
  public var embeds: [String]?
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
    /// On the Hub that keeps it, shown live, such as one that does heavy work.
    case hub
  }
  public static let knownCategories = [
    "games", "productivity", "utilities", "developer", "data",
    "creativity", "media", "writing", "learning", "lifestyle",
  ]
  public static let knownPermissions = ["microphone", "camera", "speech-recognition", "screen-capture", "local-network"]
  /// Each permission as a question names it.
  public static let permissionNames = [
    "microphone": "the microphone", "camera": "the camera", "speech-recognition": "speech recognition",
    "screen-capture": "screen recording", "local-network": "devices on your local network",
  ]
  /// Each permission as a list of them shows it.
  public static let permissionTitles = [
    "microphone": "Microphone", "camera": "Camera", "speech-recognition": "Speech Recognition",
    "screen-capture": "Screen Recording", "local-network": "Local Network",
  ]
  /// Content rules that keep a page's own loads off the device it runs on and the network it is
  /// on, for one not allowed local-network. They match the address as written, after WebKit
  /// writes an IPv4 address the usual way; a name for a local address gets past them.
  public static let localNetworkRules: String = {
    let hosts = [
      "localhost[:/]", "[^/]*\\.localhost[:/]", "[^/]*\\.local[:/]", "[^/]*@", "\\[",
      "127\\.", "10\\.", "0\\.", "192\\.168\\.", "169\\.254\\.", "172\\.1[6-9]\\.", "172\\.2[0-9]\\.", "172\\.3[01]\\.",
      "100\\.6[4-9]\\.", "100\\.[7-9][0-9]\\.", "100\\.1[01][0-9]\\.", "100\\.12[0-7]\\.", "198\\.1[89]\\.",
      "22[4-9]\\.", "2[3-5][0-9]\\.",
    ]
    let rules = hosts.map { ["trigger": ["url-filter": "^[a-z]+://" + $0], "action": ["type": "block"]] }
    return String(decoding: try! JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
  }()
  public init(
    title: String, runtime: String = "html", entry: String = "index.html",
    summary: String? = nil, symbol: String? = nil
  ) {
    version = 1
    self.title = title
    self.runtime = runtime
    self.entry = entry
    self.summary = summary
    self.symbol = symbol
  }
  enum CodingKeys: String, CodingKey {
    case version, title, runtime, entry, summary, symbol, window, permissions, category, controls, layout, runs, theme
    case display, orientation, backgroundColor, embeds
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    title = try c.decode(String.self, forKey: .title)
    runtime = try c.decode(String.self, forKey: .runtime)
    entry = try c.decode(String.self, forKey: .entry)
    summary = try c.decodeIfPresent(String.self, forKey: .summary)
    symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
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
    embeds = try c.decodeIfPresent([String].self, forKey: .embeds)
  }
  /// The sites it embeds as a person reads them: their hosts, with a port other than 443.
  public var embeddedSites: [String] {
    (embeds ?? []).compactMap(Self.embedOrigin).map { String($0.dropFirst("https://".count)) }
  }
  /// Whether its page may show `url` in a frame.
  public func mayEmbed(_ url: URL) -> Bool { Self.mayEmbed(url, in: embeds ?? []) }
  /// Whether `url` belongs to one of the sites `embeds` lists, by scheme, host and port, whatever
  /// its path. A wildcard or a path never matches: each listed site is a whole https origin.
  public static func mayEmbed(_ url: URL, in embeds: [String]) -> Bool {
    guard let origin = origin(of: url) else { return false }
    return embeds.contains { embedOrigin($0) == origin }
  }
  /// `url`'s https origin as embeds are compared: its host in lower case, and its port unless 443.
  private static func origin(of url: URL) -> String? {
    guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), isSiteName(host) else { return nil }
    return "https://" + host + (url.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? "")
  }
  /// An embeds entry as the origin it names, or nil unless it is a whole https site: no user,
  /// path, query, fragment or wildcard.
  private static func embedOrigin(_ entry: String) -> String? {
    guard let url = URL(string: entry), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path)
    else { return nil }
    return origin(of: url)
  }
  /// A host as a name or address, with nothing that could stand for more than one.
  private static func isSiteName(_ host: String) -> Bool {
    !host.isEmpty && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
  }
  /// Says plainly what is wrong with an embeds entry that is not a whole https site.
  private static func checkEmbed(_ entry: String) throws {
    let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
    let shown = entry.prefix(80)
    guard !text.isEmpty else { throw AppletError("An embed is empty. Use a site such as https://player.vimeo.com.") }
    let scheme = text.range(of: "://").map { text[..<$0.lowerBound].lowercased() }
    guard scheme == "https" else {
      let rest = text.range(of: "://").map { text[$0.upperBound...] } ?? Substring(text)
      let site = rest.prefix { !"/?#".contains($0) }
      throw AppletError("Embed \(shown) must use https, such as https://\(site.prefix(80)).")
    }
    if text.contains("*") {
      throw AppletError("Embed \(shown) cannot use a wildcard. List each site, such as https://player.vimeo.com.")
    }
    guard embedOrigin(entry) == nil else { return }
    if let url = URL(string: text), let host = url.host?.lowercased(), isSiteName(host) {
      let port = url.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? ""
      throw AppletError("Embed \(shown) is not a whole site. List only https://\(host)\(port).")
    }
    throw AppletError("Embed \(shown) is not a site. Use one such as https://player.vimeo.com.")
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
    for entry in embeds ?? [] { try Self.checkEmbed(entry) }
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
