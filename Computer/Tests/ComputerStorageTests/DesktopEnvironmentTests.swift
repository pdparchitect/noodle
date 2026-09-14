import XCTest
@testable import NoodleComputer

final class DesktopEnvironmentTests: XCTestCase {
    func testDerivedImageDefaultsArePreserved() {
        let defaults = ["DESKTOP_TITLE=Team Workspace", "DESKTOP_BROWSER_AUTOSTART=0",
                        "DESKTOP_BROWSER_URL=file:///opt/team/index.html", "GTK_THEME=Team",
                        "XAUTHORITY=/run/desktop/Xauthority", "TEAM_SETTING=enabled"]
        let environment = ContainerComputer.desktopEnvironment(imageEnvironment: defaults, password: "fresh-password")
        for value in defaults { XCTAssertTrue(environment.contains(value), value) }
        XCTAssertTrue(environment.contains("NOODLE_DESKTOP_PASSWORD=fresh-password"))
    }

    func testImageCannotReplaceNativeTransportOrCredentials() {
        let environment = ContainerComputer.desktopEnvironment(imageEnvironment: [
            "HOME=/root", "DISPLAY=:99", "DESKTOP_PORT=9999", "PATH=/untrusted",
            "NOODLE_DESKTOP_PASSWORD=stale", "DESKTOP_PASSWORD=stale", "DESKTOP_PASSWORD_FILE=/stale"
        ], password: "fresh-password")
        let values = Dictionary(uniqueKeysWithValues: environment.map { entry in
            let pair = entry.split(separator: "=", maxSplits: 1)
            return (String(pair[0]), String(pair[1]))
        })
        XCTAssertEqual(values["HOME"], "/home/agent")
        XCTAssertEqual(values["DISPLAY"], ":1")
        XCTAssertEqual(values["DESKTOP_PORT"], "6901")
        XCTAssertEqual(values["NOODLE_DESKTOP_PASSWORD"], "fresh-password")
        XCTAssertNil(values["DESKTOP_PASSWORD"])
        XCTAssertNil(values["DESKTOP_PASSWORD_FILE"])
        XCTAssertNotEqual(values["PATH"], "/untrusted")
    }

    func testLegacyImageKeepsItsSessionPaths() {
        let defaults = ["XAUTHORITY=/run/launcher-desktop/Xauthority",
                        "G_RESOURCE_OVERLAYS=/org/gtk/libgtk=/usr/share/launcher-desktop/gtk-overlay"]
        let environment = ContainerComputer.desktopEnvironment(imageEnvironment: defaults, password: "fresh-password")
        for value in defaults { XCTAssertTrue(environment.contains(value)) }
    }
}
