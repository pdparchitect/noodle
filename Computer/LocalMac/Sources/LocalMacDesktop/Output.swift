import Foundation
import LocalMacCore

final class Output {
    var onDisconnect: (@MainActor () -> Void)?
    private let queue = DispatchQueue(label: "LocalMac.output")
    private let frameLock = NSLock()
    private var pendingFrames: Set<UUID> = []
    private let desktopFrameID = UUID()
    func send(_ value: LocalMacReply, completion: (@MainActor () -> Void)? = nil) {
        let frameID = value.windowFrame?.previewID ?? desktopFrameID
        if value.frame {
            frameLock.lock()
            let accepted = pendingFrames.insert(frameID).inserted
            frameLock.unlock()
            if !accepted { return }
        }
        queue.async {
            defer {
                if value.frame {
                    self.frameLock.lock(); self.pendingFrames.remove(frameID); self.frameLock.unlock()
                }
            }
            do {
                try LocalMacWire.write(JSONEncoder().encode(value), to: .standardOutput)
                if let completion { DispatchQueue.main.async { completion() } }
            }
            catch { DispatchQueue.main.async { self.onDisconnect?() } }
        }
    }
}
