import Foundation
import SuperBotCore

let result = MessengerCLI.run()

if !result.standardOutput.isEmpty,
   let data = result.standardOutput.data(using: .utf8) {
    try? FileHandle.standardOutput.write(contentsOf: data)
}

if !result.standardError.isEmpty,
   let data = result.standardError.data(using: .utf8) {
    try? FileHandle.standardError.write(contentsOf: data)
}

exit(result.exitCode)
