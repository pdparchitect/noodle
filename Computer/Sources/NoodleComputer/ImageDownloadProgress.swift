import ComputerCore
import ContainerizationExtras
import Foundation

/// Registry callbacks are deltas from parallel layer downloads, not snapshots.
/// Cached blobs count as completed bytes too, so do not label their rate as network speed.
actor ImageDownloadProgress {
  private var received: Int64 = 0
  private var expected: Int64 = 0
  private var lastReport = Date.distantPast
  private let label: String
  private let report: @Sendable (String, TransferProgress?) async -> Void

  init(label: String, report: @escaping @Sendable (String, TransferProgress?) async -> Void) {
    self.label = label
    self.report = report
  }

  func update(_ events: [ProgressEvent]) async {
    var totalChanged = false
    for event in events {
      switch event {
      case .addSize(let bytes): received += bytes
      case .addTotalSize(let bytes):
        expected += bytes
        totalChanged = true
      case .addItems, .addTotalItems: break
      }
    }
    let now = Date()
    guard totalChanged || received >= expected || now.timeIntervalSince(lastReport) >= 0.25 else {
      return
    }
    lastReport = now
    await report(label, TransferProgress(received: received, expected: expected, elapsed: 0))
  }
}
