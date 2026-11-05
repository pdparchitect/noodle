import Foundation
import LocalMacCore

/// Coalesce consecutive motion, retaining the order of every button/key edge.
struct LocalMacInputQueue {
    private var events: [LocalMacInput] = []
    mutating func append(_ event: LocalMacInput) -> Bool {
        if event.kind == .reset {
            if let id = event.previewID {
                events.removeAll { $0.previewID == id }
                events.append(event)
            } else { events = [event] }
            return true
        }
        if event.kind == .move, events.last?.kind == .move,
           events.last?.previewID == event.previewID, events.last?.geometryID == event.geometryID {
            events[events.count - 1] = event; return true
        }
        guard events.count < 512 else {
            // Backpressure must release input, never silently lose a key-up.
            events = [LocalMacInput(.reset)]; return false
        }
        events.append(event); return true
    }
    mutating func next() -> LocalMacInput? { events.isEmpty ? nil : events.removeFirst() }
    mutating func remove(previewID: UUID) { events.removeAll { $0.previewID == previewID } }
    mutating func removeAll() { events.removeAll() }
}
