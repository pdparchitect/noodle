import ComputerBridge

public enum ComputerAppIdentity {
    public static var name: String { ComputerBuildIdentity.current.appName }
}
