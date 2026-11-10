// Noodle Enterprise. Source-available under Enterprise/LICENSE, not Apache-2.0.
// Writes the Jamf schema, sample profile, published-keys ledger and the guide's key table from
// the key registry: swift run NoodleEnterpriseFiles
import Foundation
import NoodleEnterprise

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
do {
    try ManagedFiles.write(root: root)
    print("Wrote \(ManagedFiles.schemaPath), \(ManagedFiles.profilePath), \(ManagedFiles.ledgerPath) and the key table in \(ManagedFiles.guidePath).")
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
