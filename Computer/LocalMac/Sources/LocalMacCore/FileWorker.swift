import Foundation

/// Filesystem calls can wait for macOS folder consent. Keep them off the capture
/// and input queue, while serializing transfers and rechecking the account session.
public final class LocalMacFileWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LocalMac.account.files")
    private let lock = NSLock()
    private var pending = 0
    private var closed = false
    private let home: String
    private let verify: () throws -> Void
    private var store: LocalMacFileStore?
    public init(home: String, verify: @escaping () throws -> Void) { self.home = home; self.verify = verify }

    public func handle(_ request: LocalMacRequest) async throws -> LocalMacReply {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !closed, pending < 16 else {
                lock.unlock()
                continuation.resume(throwing: LocalMacError("Account file access is unavailable or busy. Retry after the current operation finishes."))
                return
            }
            pending += 1; lock.unlock()
            queue.async {
                defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
                do {
                    self.lock.lock(); let closed = self.closed; self.lock.unlock()
                    guard !closed else { throw LocalMacError("Account file access has closed.") }
                    try self.verify(); try request.validate()
                    if self.store == nil { self.store = try LocalMacFileStore(home: self.home) }
                    continuation.resume(returning: try self.perform(request, files: self.store!))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func close(completion: @escaping () -> Void = {}) {
        lock.lock(); closed = true; lock.unlock()
        queue.async { self.store?.close(); self.store = nil; completion() }
    }
    private func perform(_ request: LocalMacRequest, files: LocalMacFileStore) throws -> LocalMacReply {
        var response = LocalMacReply(id: request.id)
        switch request.operation {
        case .fileHome: response.homeDirectory = files.homeDirectory
        case .fileList: response.files = try files.list(request.path ?? "")
        case .fileStat: response.files = [try files.statFile(request.path ?? "")]
        case .fileRead:
            response.data = try files.read(request.path ?? "", version: request.version ?? "", offset: request.offset ?? 0)
            response.offset = (request.offset ?? 0) + Int64(response.data!.count)
        case .fileUploadOpen:
            response.transferID = try files.beginUpload(request.path ?? "", size: request.size ?? -1)
        case .fileWrite, .fileUploadCommit, .fileUploadCancel:
            guard let id = request.transferID else { throw LocalMacError("Missing file transfer identifier.") }
            if request.operation == .fileWrite { response.offset = try files.write(id, offset: request.offset ?? -1, data: request.data ?? Data()) }
            else if request.operation == .fileUploadCommit { try files.commit(id) }
            else { files.cancel(id) }
        case .fileMkdir: try files.mkdir(request.path ?? "")
        case .fileRemove: try files.remove(request.path ?? "")
        case .fileRename: try files.rename(request.path ?? "", to: request.destination ?? "")
        case .fileCopy: try files.copy(request.path ?? "", version: request.version ?? "", to: request.destination ?? "")
        default: throw LocalMacError("Not an account file operation.")
        }
        return response
    }
}
