import ComputerBridge

enum ComputerAppIdentity {
    static var name: String { ComputerBuildIdentity.current.appName }
}
