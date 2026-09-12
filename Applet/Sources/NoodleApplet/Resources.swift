import Foundation

enum AppletResources {
    static let bundle: Bundle = {
        if let resources = Bundle.main.resourceURL,
            let bundled = Bundle(
                url: resources.appendingPathComponent("NoodleApplet_NoodleApplet.bundle"))
        {
            return bundled
        }
        return Bundle.module
    }()
}
