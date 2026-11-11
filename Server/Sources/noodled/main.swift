import Foundation
import ServerCore
#if canImport(HubLink)
import HubLink
#endif

let usage = """
USAGE: noodled <command> [--config <path>]

COMMANDS:
  check    Reads the configuration and reports every problem in it.
  run      Serves devices until stopped.

OPTIONS:
  --config <path>    The configuration file (default: /etc/noodled/noodled.yaml).
"""

var arguments = Array(CommandLine.arguments.dropFirst())
var configurationFile = URL(fileURLWithPath: "/etc/noodled/noodled.yaml")
if let index = arguments.firstIndex(of: "--config") {
    guard index + 1 < arguments.count else {
        FileHandle.standardError.write(Data("--config needs the path to a configuration file.\n".utf8))
        exit(64)
    }
    configurationFile = URL(fileURLWithPath: arguments[index + 1])
    arguments.removeSubrange(index...index + 1)
}

/// What stops the server, kept for as long as it runs.
nonisolated(unsafe) var stopping: [any DispatchSourceSignal] = []

/// The configuration, or the reasons it cannot be used, printed before exiting.
func loadConfiguration() -> ServerConfiguration {
    do {
        let configuration = try ServerConfiguration(contentsOf: configurationFile)
        let problems = configuration.problems()
        guard problems.isEmpty else {
            print("\(configurationFile.path) has \(problems.count == 1 ? "a problem" : "\(problems.count) problems"):")
            problems.forEach { print("  \($0)") }
            exit(1)
        }
        return configuration
    } catch {
        print("\(configurationFile.path): \(error.localizedDescription)")
        exit(1)
    }
}

switch arguments.first {
case "check":
    let configuration = loadConfiguration()
    #if os(Linux)
    if let problem = HarnessSandbox().problem() {
        print(problem)
        exit(1)
    }
    #endif
    let plans = configuration.plans.count, users = configuration.users.count
    print("\(configurationFile.path) is ready: \(plans) \(plans == 1 ? "plan" : "plans"), \(users) \(users == 1 ? "user" : "users").")
case "run":
    let configuration = loadConfiguration()
    #if os(Linux)
    if let problem = HarnessSandbox().problem() {
        print("noodled could not start: \(problem)")
        exit(1)
    }
    let listen = QUICListener.listen(certificates: configuration.data.appendingPathComponent("Link/Certificates", isDirectory: true))
    #else
    let listen = LinkServer.listen
    #endif
    Task { @MainActor in
        do {
            let hub = try ServerHub(configuration: configuration, listen: listen)
            await hub.start()
            guard case .listening(let port) = hub.link.state else {
                print("noodled could not start: \(hub.link.state)")
                exit(1)
            }
            print("noodled serves \(configuration.name) on port \(port), for \(configuration.users.count) users.")
            for signal in [SIGINT, SIGTERM] {
                Foundation.signal(signal, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
                source.setEventHandler {
                    hub.stop()
                    exit(0)
                }
                source.resume()
                stopping.append(source)
            }
        } catch {
            print("noodled could not start: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
case "help", "--help", "-h", nil:
    print(usage)
default:
    FileHandle.standardError.write(Data("noodled has no command \(arguments[0]).\n\n\(usage)\n".utf8))
    exit(64)
}
