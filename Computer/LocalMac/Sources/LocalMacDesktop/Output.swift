import Foundation
import LocalMacCore

final class Output {
    var onDisconnect: (@MainActor () -> Void)?
    private let queue = DispatchQueue(label: "LocalMac.output")
    private let frameSlot = DispatchSemaphore(value: 1)
    func send(_ value: LocalMacReply, completion: (@MainActor () -> Void)? = nil) {
        if value.frame, frameSlot.wait(timeout: .now()) != .success { return }
        queue.async {
            defer { if value.frame { self.frameSlot.signal() } }
            do {
                try LocalMacWire.write(JSONEncoder().encode(value), to: .standardOutput)
                if let completion { DispatchQueue.main.async { completion() } }
            }
            catch { DispatchQueue.main.async { self.onDisconnect?() } }
        }
    }
}
