import Foundation
import ServerCore

let usage = """
USAGE: noodled <command> [--config <path>]

COMMANDS:
  check    Reads the configuration and reports every problem in it.

OPTIONS:
  --config <path>    The configuration file (default: /etc/noodled/noodled.yaml).
"""

var arguments = Array(CommandLine.arguments.dropFirst())
var configuration = URL(fileURLWithPath: "/etc/noodled/noodled.yaml")
if let index = arguments.firstIndex(of: "--config") {
    guard index + 1 < arguments.count else {
        FileHandle.standardError.write(Data("--config needs the path to a configuration file.\n".utf8))
        exit(64)
    }
    configuration = URL(fileURLWithPath: arguments[index + 1])
    arguments.removeSubrange(index...index + 1)
}

switch arguments.first {
case "check":
    do {
        let loaded = try ServerConfiguration(contentsOf: configuration)
        let problems = loaded.problems()
        guard problems.isEmpty else {
            print("\(configuration.path) has \(problems.count == 1 ? "a problem" : "\(problems.count) problems"):")
            problems.forEach { print("  \($0)") }
            exit(1)
        }
        let plans = loaded.plans.count, users = loaded.users.count
        print("\(configuration.path) is ready: \(plans) \(plans == 1 ? "plan" : "plans"), \(users) \(users == 1 ? "user" : "users").")
    } catch {
        print("\(configuration.path): \(error.localizedDescription)")
        exit(1)
    }
case "help", "--help", "-h", nil:
    print(usage)
default:
    FileHandle.standardError.write(Data("noodled has no command \(arguments[0]).\n\n\(usage)\n".utf8))
    exit(64)
}
