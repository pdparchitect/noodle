import Foundation

enum BrowserResources {
    static let bundle = resolve(in: .main)

    static func resolve(in application: Bundle) -> Bundle {
        // SwiftPM's native accessor can look beside the app or in the build tree.
        // Packaged apps keep their resources inside the signed sandbox boundary.
        if let resources = application.resourceURL,
           let bundled = Bundle(url: resources.appendingPathComponent("NoodleBrowser_NoodleBrowser.bundle")) {
            return bundled
        }
        return Bundle.module
    }
}
