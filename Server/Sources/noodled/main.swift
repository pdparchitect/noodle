import Foundation
import HubWire
import ServerCore
#if canImport(HubLink)
import HubLink
#endif

let usage = """
USAGE: noodled <command> [--config <path>]

COMMANDS:
  check            Reads the configuration and reports every problem in it.
  run              Serves devices until stopped.
  invite <user>    Prints a link that pairs one device for someone in the configuration.
                   --qr          Also draws the link's QR code, for a phone to scan.
                   --png <file>  Also saves the QR code as a PNG picture.

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

/// What stops the server and what the admin asks it, kept for as long as it runs.
nonisolated(unsafe) var stopping: [any DispatchSourceSignal] = []
nonisolated(unsafe) var control: ServerControl?

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
            let asked = ServerControl(hub: hub, data: configuration.data)
            try asked.start()
            control = asked
            print("noodled serves \(configuration.name) on port \(port), for \(configuration.users.count) \(configuration.users.count == 1 ? "user" : "users").")
            for signal in [SIGINT, SIGTERM] {
                Foundation.signal(signal, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
                source.setEventHandler {
                    asked.stop()
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
case "invite":
    var options = Array(arguments.dropFirst())
    let drawsCode = options.contains("--qr")
    options.removeAll { $0 == "--qr" }
    var picture: URL?
    if let index = options.firstIndex(of: "--png") {
        guard index + 1 < options.count else {
            FileHandle.standardError.write(Data("--png needs the file to save the QR code in.\n".utf8))
            exit(64)
        }
        picture = URL(fileURLWithPath: options[index + 1])
        options.removeSubrange(index...index + 1)
    }
    guard options.count == 1, !options[0].hasPrefix("--") else {
        FileHandle.standardError.write(Data("noodled invite needs the name of a user in the configuration.\n".utf8))
        exit(64)
    }
    let user = options[0]
    let configuration = loadConfiguration()
    do {
        let link = try ServerControl.invite(user, data: configuration.data)
        print("Send \(user) this link. It pairs one device and works for \(Int(LinkInvitation.lifetime / 60)) minutes:\n\n\(link)")
        if drawsCode || picture != nil {
            let code = try InvitationCode(link: link)
            if drawsCode { print("\nOr scan this with Noodle on \(user)'s phone:\n\n\(code.terminal)") }
            if let picture {
                // Whoever has the picture can pair a device, so only the admin may read it.
                guard FileManager.default.createFile(atPath: picture.path, contents: code.png(), attributes: [.posixPermissions: 0o600]) else {
                    print("Could not save the QR code to \(picture.path).")
                    exit(1)
                }
                print("\nThe QR code is in \(picture.path).")
            }
        }
    } catch {
        print(error.localizedDescription)
        exit(1)
    }
case "help", "--help", "-h", nil:
    print(usage)
default:
    FileHandle.standardError.write(Data("noodled has no command \(arguments[0]).\n\n\(usage)\n".utf8))
    exit(64)
}
