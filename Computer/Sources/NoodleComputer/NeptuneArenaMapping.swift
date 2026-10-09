/// Bookkeeping for asynchronous VZ maps. Device resets keep a live mapping, but
/// stopping the VM invalidates it and every completion from that VM run.
struct NeptuneArenaMapping {
    private(set) var isReady = false
    private var ticket: UInt64 = 0
    private var pending: UInt64?

    mutating func begin() -> UInt64? {
        guard !isReady, pending == nil else { return nil }
        ticket &+= 1
        pending = ticket
        return ticket
    }

    @discardableResult mutating func complete(_ token: UInt64, succeeded: Bool) -> Bool {
        guard pending == token else { return false }
        pending = nil
        isReady = succeeded
        return true
    }

    mutating func stopped() {
        isReady = false
        pending = nil
    }
}
