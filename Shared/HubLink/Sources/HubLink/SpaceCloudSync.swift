import CloudKit
import Foundation
#if os(macOS)
import Security
#endif

/// A space as one record in the person's private iCloud database, in a zone of its own, its contents encrypted.
public enum SpaceRecords {
    public static let recordType = "Space"
    public static let zoneID = CKRecordZone.ID(zoneName: "Spaces", ownerName: CKCurrentUserDefaultName)

    public static func recordID(for id: UUID) -> CKRecord.ID { CKRecord.ID(recordName: id.uuidString, zoneID: zoneID) }

    /// Over the fields iCloud last returned, when there are some, so saving it is a change rather than a conflict.
    public static func record(for space: CustomSpace, systemFields: Data?) -> CKRecord {
        let record = systemFields.flatMap(record(systemFields:)) ?? CKRecord(recordType: recordType, recordID: recordID(for: space.id))
        record.encryptedValues["name"] = space.name
        record.encryptedValues["members"] = try? JSONEncoder().encode(space.members)
        record.encryptedValues["pins"] = try? JSONEncoder().encode(space.pins)
        return record
    }

    public static func space(from record: CKRecord) -> CustomSpace? {
        guard record.recordType == recordType, let id = UUID(uuidString: record.recordID.recordName),
              let name: String = record.encryptedValues["name"] else { return nil }
        return CustomSpace(id: id, name: name, members: members(record.encryptedValues["members"]), pins: members(record.encryptedValues["pins"]))
    }

    public static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(systemFields: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    private static func members(_ data: Data?) -> [CustomSpace.Member] {
        data.flatMap { try? JSONDecoder().decode([CustomSpace.Member].self, from: $0) } ?? []
    }
}

/// Carries the spaces the person made between their devices through their own iCloud. When two devices change
/// the same space before hearing of each other, the one that sends last wins.
@MainActor public final class SpaceCloudSync: CKSyncEngineDelegate {
    private let list: SpaceList
    private let stateFile: URL
    private var stored: Stored
    private var engine: CKSyncEngine?

    private struct Stored: Codable {
        var engine: CKSyncEngine.State.Serialization?
        /// What iCloud last returned for each space, which the next save of it goes over.
        var systemFields: [UUID: Data] = [:]
    }

    /// Nil unless this app is signed with the iCloud container: CloudKit stops any app that is not,
    /// so tests and development builds of the Mac app never reach it.
    public static func ifEntitled(list: SpaceList, stateFile: URL) -> SpaceCloudSync? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
                as? [String], containers.contains(LinkPush.container) else { return nil }
        #endif
        return SpaceCloudSync(list: list, stateFile: stateFile)
    }

    private init(list: SpaceList, stateFile: URL) {
        self.list = list
        self.stateFile = stateFile
        stored = (try? JSONDecoder().decode(Stored.self, from: Data(contentsOf: stateFile))) ?? Stored()
        let engine = CKSyncEngine(CKSyncEngine.Configuration(database: CKContainer(identifier: LinkPush.container).privateCloudDatabase,
                                                             stateSerialization: stored.engine, delegate: self))
        self.engine = engine
        // The first time: the zone, and the spaces made before there was iCloud.
        if stored.engine == nil { sendEverything() }
        list.onChange = { [weak self] saved, deleted in self?.send(saved: saved, deleted: deleted) }
    }

    /// Asks iCloud for what the other devices changed, as when the app comes to the front.
    public func fetch() async {
        try? await engine?.fetchChanges()
    }

    private func send(saved: [UUID], deleted: [UUID]) {
        for id in deleted { stored.systemFields[id] = nil }
        engine?.state.add(pendingRecordZoneChanges: saved.map { .saveRecord(SpaceRecords.recordID(for: $0)) }
            + deleted.map { .deleteRecord(SpaceRecords.recordID(for: $0)) })
        save()
    }

    private func sendEverything() {
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SpaceRecords.zoneID))])
        send(saved: list.spaces.map(\.id), deleted: [])
    }

    private func save() {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(stored).write(to: stateFile, options: .atomic)
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            stored.engine = update.stateSerialization
            save()
        case .accountChange(let change):
            // The spaces stay on this device; signing in to iCloud carries them there.
            stored.systemFields = [:]
            save()
            if case .signIn = change.changeType { sendEverything() }
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == SpaceRecords.zoneID {
                stored.systemFields = [:]
                save()
                // Reset with the person's encryption keys: send them again. Otherwise the person deleted them.
                if deletion.reason == .encryptedDataReset {
                    sendEverything()
                } else {
                    list.applyRemote(saved: [], deleted: list.spaces.map(\.id))
                }
            }
        case .fetchedRecordZoneChanges(let changes):
            var saved: [CustomSpace] = []
            for modification in changes.modifications {
                guard let space = SpaceRecords.space(from: modification.record) else { continue }
                stored.systemFields[space.id] = SpaceRecords.systemFields(of: modification.record)
                saved.append(space)
            }
            let deleted = changes.deletions.compactMap { UUID(uuidString: $0.recordID.recordName) }
            for id in deleted { stored.systemFields[id] = nil }
            save()
            list.applyRemote(saved: saved, deleted: deleted)
        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                if let id = UUID(uuidString: record.recordID.recordName) { stored.systemFields[id] = SpaceRecords.systemFields(of: record) }
            }
            var again: [CKSyncEngine.PendingRecordZoneChange] = []
            var zoneMissing = false
            for failure in sent.failedRecordSaves {
                let recordID = failure.record.recordID
                guard let id = UUID(uuidString: recordID.recordName) else { continue }
                switch failure.error.code {
                case .serverRecordChanged:
                    // Another device saved it first: this one's goes again over theirs.
                    stored.systemFields[id] = failure.error.serverRecord.map(SpaceRecords.systemFields(of:))
                    again.append(.saveRecord(recordID))
                case .zoneNotFound:
                    zoneMissing = true
                    again.append(.saveRecord(recordID))
                case .unknownItem:
                    stored.systemFields[id] = nil
                    again.append(.saveRecord(recordID))
                default:
                    // Network and account trouble the engine retries by itself.
                    break
                }
            }
            if zoneMissing { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SpaceRecords.zoneID))]) }
            syncEngine.state.add(pendingRecordZoneChanges: again)
            save()
        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        var records: [CKRecord.ID: CKRecord] = [:]
        for case .saveRecord(let recordID) in pending {
            guard let id = UUID(uuidString: recordID.recordName), let space = list.space(id) else {
                // Deleted since: nothing to save.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                continue
            }
            records[recordID] = SpaceRecords.record(for: space, systemFields: stored.systemFields[id])
        }
        let ready = records
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending.filter {
            if case .saveRecord(let recordID) = $0 { ready[recordID] != nil } else { true }
        }) { ready[$0] }
    }
}
