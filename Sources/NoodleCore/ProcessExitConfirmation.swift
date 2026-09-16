import Darwin
import Foundation

/// Killing a process is asynchronous. Wait for both the child and its process
/// group to disappear, without blocking the helper's session queue.
public enum ProcessExitConfirmation {
    public static func wait(process: Process?, groupID: Int32, queue: DispatchQueue,
                            completion: @escaping (Bool) -> Void) {
        wait(isStopped: {
            let result = kill(-groupID, 0)
            let groupGone = result == -1 && errno == ESRCH
            return groupGone && process?.isRunning != true
        }, now: { ProcessInfo.processInfo.systemUptime }, schedule: { delay, action in
            queue.asyncAfter(deadline: .now() + delay, execute: action)
        }, completion: completion)
    }

    static func wait(isStopped: @escaping () -> Bool, now: @escaping () -> TimeInterval,
                     schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
                     completion: @escaping (Bool) -> Void) {
        let deadline = now() + 5
        func check() {
            if isStopped() { completion(true) }
            else if now() >= deadline { completion(false) }
            else { schedule(0.1, check) }
        }
        check()
    }
}
