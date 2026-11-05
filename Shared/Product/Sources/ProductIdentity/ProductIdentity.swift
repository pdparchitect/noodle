import Foundation

/// The product an app belongs to, for code more than one product shares: what it calls itself, and the
/// identifier its own identifiers derive from, such as log subsystems and folders outside its container.
///
/// An app is recognised by its Bundle ID, which its code signature seals, so the product cannot change
/// while it runs. Each product's apps and helpers share its identifier as their prefix: Noodle, Noodle
/// Hub, Noodle Computer and their helpers are all Noodle.
public struct ProductIdentity: Equatable, Hashable, Sendable {
    /// What the product calls itself to people and to its bots.
    public let name: String
    /// The production app's Bundle ID; every app and helper of the product starts with it.
    public let identifier: String

    public init(name: String, identifier: String) {
        self.name = name
        self.identifier = identifier
    }

    public static let noodle = ProductIdentity(name: "Noodle", identifier: "com.pdparchitect.noodle")
    public static let pion = ProductIdentity(name: "Pion", identifier: "com.pdparchitect.pion")
    public static let known: [ProductIdentity] = [.noodle, .pion]

    /// The product a Bundle ID belongs to. Anything else, such as a test runner or a command-line build
    /// without a bundle, is Noodle, as all of this code was before it was shared.
    public static func identify(_ bundleIdentifier: String?) -> ProductIdentity {
        guard let bundleIdentifier else { return .noodle }
        return known.first { bundleIdentifier == $0.identifier || bundleIdentifier.hasPrefix($0.identifier + ".") } ?? .noodle
    }

    /// The product of this process.
    public static let current = identify(Bundle.main.bundleIdentifier)

    /// An identifier of this product's own, such as a log subsystem: the product's identifier, then `suffix`.
    public func identifier(_ suffix: String) -> String { identifier + "." + suffix }
}
