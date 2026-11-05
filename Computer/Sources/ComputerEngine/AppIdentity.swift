import ComputerBridge
import Foundation
import ProductIdentity

/// Who runs the computers, as people and bots are told: Noodle Computer in its own builds and for every
/// Noodle app, and the product's own name in another product's app that hosts the engine itself.
public enum ComputerAppIdentity {
    public static var name: String {
        if let build = ComputerBuildIdentity.identify(Bundle.main.bundleIdentifier) { return build.appName }
        return ProductIdentity.current == .noodle ? ComputerBuildIdentity.production.appName : ProductIdentity.current.name
    }

    /// The library's folder in Application Support, inside the app's own container.
    public static var libraryFolder: String {
        ProductIdentity.current == .noodle ? ComputerBuildIdentity.production.appName : "Computers"
    }

    /// Where the engine logs, and the prefix of its queues.
    public static var subsystem: String { ProductIdentity.current.identifier("computer") }
}
