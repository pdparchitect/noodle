import Foundation

/// Headless signed fixture. Uses only temporary sockets, never a real app group,
/// user library, Launch Services, or UI. Compile alongside AppletBridge sources.
@main struct ConnectionIsolation {
    static func main() async {
        do {
            let args = CommandLine.arguments
            if args[1] == "identity" {
                print(AppletBuildIdentity.current.rawValue)
                return
            }
            let socket = URL(fileURLWithPath: args[2]), team = args[3]
            if args[1] == "server" {
                let server = try AppletConnectionServer(socket: socket, team: team) { _, identity in
                    var response = AppletResponse(); response.text = identity; return response
                }
                try await Task.sleep(for: .seconds(30))
                withExtendedLifetime(server) {}
            } else {
                let provider = args.count > 4 ? args[4] : AppletConnection.providerID
                let result = try await AppletConnection.call(.init(.list), socket: socket, team: team, providerID: provider).checked()
                print(result.text ?? "missing peer")
            }
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
