import AppletBridge
import BrowserBridge
import ComputerBridge
import Foundation

/// A link to something live a companion keeps: a browser tab, a computer or a noodlet. Every
/// one is shared, stored, mirrored and opened the same way: as the URL of a link attachment.
public enum CompanionLink: Equatable, Sendable {
    case browser(UUID, tab: UUID?)
    case computer(UUID, terminal: UUID?, view: String?)
    case noodlet(UUID)

    public init?(_ url: URL) {
        if let id = NoodletLink.id(in: url) { self = .noodlet(id) }
        else if let target = BrowserLink.target(in: url) { self = .browser(target.browser, tab: target.tab) }
        else if let target = ComputerLink.target(in: url) { self = .computer(target.computer, terminal: target.terminal, view: target.view) }
        else { return nil }
    }

    /// The link in this app's build.
    public var url: URL {
        switch self {
        case .browser(let id, let tab): BrowserLink.url(browser: id, tab: tab)
        case .computer(let id, let terminal, let view): ComputerLink.url(computer: id, terminal: terminal, view: view)
        case .noodlet(let id): NoodletLink.url(for: id)
        }
    }

    /// The same link written canonically, keeping its build.
    public static func canonical(_ url: URL) -> URL? {
        if let noodlet = NoodletLink.canonical(url) { return noodlet }
        if let build = BrowserLink.build(in: url), let target = BrowserLink.target(in: url) {
            return BrowserLink.url(browser: target.browser, tab: target.tab, build: build)
        }
        if let build = ComputerLink.build(in: url), let target = ComputerLink.target(in: url) {
            return ComputerLink.url(computer: target.computer, terminal: target.terminal, view: target.view, build: build)
        }
        return nil
    }
}

/// What a companion link shows in chat: its label and the last picture taken, never live state.
public struct LinkCard: Codable, Hashable, Sendable {
    public static let maximumImageBytes = 550_000
    public var title: String
    /// The page's address, or the terminal's last output.
    public var detail: String?
    /// A JPEG snapshot from when it was shared.
    public var image: Data?
    public var symbol: String?
    public var colour: Int?
    public var icon: Data?
    public var capturedAt: Date?

    public init(title: String, detail: String? = nil, image: Data? = nil, symbol: String? = nil, colour: Int? = nil,
                icon: Data? = nil, capturedAt: Date? = nil) {
        self.title = String(title.prefix(300))
        self.detail = detail.map { String($0.suffix(2000)) }
        self.image = image
        self.symbol = symbol
        self.colour = colour
        self.icon = icon
        self.capturedAt = capturedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
    }

    public var isValid: Bool {
        (image?.count ?? 0) <= Self.maximumImageBytes && (icon?.count ?? 0) <= 65_536 && !title.isEmpty
    }
}
