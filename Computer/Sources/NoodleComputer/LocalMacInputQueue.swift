import LocalMacCore

/// Coalesce consecutive motion, retaining the order of every button/key edge.
struct LocalMacInputQueue {
    private var events: [LocalMacInput] = []
    mutating func append(_ event: LocalMacInput) -> Bool {
        if event.kind == .reset { events = [event]; return true }
        if event.kind == .move, events.last?.kind == .move {
            events[events.count - 1] = event; return true
        }
        guard events.count < 512 else {
            // Backpressure must release input, never silently lose a key-up.
            events = [LocalMacInput(.reset)]; return false
        }
        events.append(event); return true
    }
    mutating func next() -> LocalMacInput? { events.isEmpty ? nil : events.removeFirst() }
    mutating func removeAll() { events.removeAll() }
}
