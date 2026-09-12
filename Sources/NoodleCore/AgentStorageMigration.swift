import Foundation

/// Legacy flat workspace -> storage version 1. Keep this migration isolated so
/// it can be retired after the release feed enforces the migration milestone.
/// Only the app runs migrations, before loading bots or starting any harness.
// TODO(0.14.0): Remove this legacy migrator after verifying that upgrades pass
// through the published 0.13.0 migration release. Keep storage-version validation,
// the 0.13.0 update milestone, and guidance for manual upgrades from older layouts.
enum AgentStorageMigration {
    static let journalName = ".noodle-migration.json"
    private enum Phase: String, Codable { case collect, runtime, install }
    private struct Journal: Codable {
        let version: Int
        let staging: String
        let entries: [String]
        var phase: Phase
    }

    @discardableResult
    static func migrate(_ layout: AgentStorageLayout, afterMove: (() throws -> Void)? = nil) throws -> Bool {
        let manager = FileManager.default
        try AgentStorageLayout.requireDirectory(layout.package)
        let journalURL = layout.package.appendingPathComponent(journalName)
        if AgentStorageLayout.exists(layout.package.appendingPathComponent(AgentStorageLayout.markerName)) {
            try layout.validate()
            // The last atomic write committed the migration; a crash may have
            // left its journal behind. No workspace contents need moving again.
            if AgentStorageLayout.exists(journalURL) { try manager.removeItem(at: journalURL) }
            return false
        }
        try AgentStorageLayout.requireFile(layout.configuration)
        var journal: Journal
        if AgentStorageLayout.exists(journalURL) {
            try AgentStorageLayout.requireFile(journalURL)
            journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            guard journal.version == 1, journal.staging.hasPrefix(".noodle-migrate-"),
                  UUID(uuidString: String(journal.staging.dropFirst(".noodle-migrate-".count))) != nil,
                  Set(journal.entries).count == journal.entries.count,
                  journal.entries.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") &&
                      !["agent.json", journalName, AgentStorageLayout.markerName, journal.staging].contains($0) }) else {
                throw AgentStorageError("The bot's storage migration journal is invalid. Its files have been left in place.")
            }
        } else {
            let entries = try manager.contentsOfDirectory(atPath: layout.package.path)
                .filter { $0 != "agent.json" }.sorted()
            journal = Journal(version: 1, staging: ".noodle-migrate-" + UUID().uuidString.lowercased(),
                              entries: entries, phase: .collect)
            try save(journal, to: journalURL)
        }
        let staging = layout.package.appendingPathComponent(journal.staging, isDirectory: true)
        if journal.phase == .collect {
            if !AgentStorageLayout.exists(staging) { try manager.createDirectory(at: staging, withIntermediateDirectories: false) }
            try AgentStorageLayout.requireDirectory(staging)
            for entry in journal.entries {
                try move(layout.package.appendingPathComponent(entry), to: staging.appendingPathComponent(entry))
                try afterMove?()
            }
            journal.phase = .runtime
            try save(journal, to: journalURL)
        }
        if journal.phase == .runtime {
            try AgentStorageLayout.requireDirectory(staging)
            if !AgentStorageLayout.exists(layout.runtime) { try manager.createDirectory(at: layout.runtime, withIntermediateDirectories: false) }
            try AgentStorageLayout.requireDirectory(layout.runtime)
            let oldState = staging.appendingPathComponent(".agents")
            if AgentStorageLayout.exists(oldState) {
                try AgentStorageLayout.requireDirectory(oldState)
                for provider in HarnessProvider.allCases {
                    for extended in [false, true] {
                        let target = layout.sessionState(provider: provider, extendedAccess: extended)
                        for suffix in ["", ".unfinished"] {
                            let source = oldState.appendingPathComponent(target.lastPathComponent + suffix)
                            let destination = layout.runtime.appendingPathComponent(target.lastPathComponent + suffix)
                            if AgentStorageLayout.exists(source) || AgentStorageLayout.exists(destination) {
                                if AgentStorageLayout.exists(source) { try AgentStorageLayout.requireFile(source) }
                                try move(source, to: destination)
                                // A legacy workspace could contain another hard
                                // link to this inode. Give app-owned state its own
                                // file before the workspace becomes writable.
                                try AtomicFile.write(Data(contentsOf: destination), to: destination)
                                try afterMove?()
                            }
                        }
                    }
                }
            }
            journal.phase = .install
            try save(journal, to: journalURL)
        }
        if journal.phase == .install {
            try move(staging, to: layout.workspace)
            try afterMove?()
            try AtomicFile.write(Data(contentsOf: layout.configuration), to: layout.configuration)
            try layout.markCurrent()
            try layout.validate()
            try manager.removeItem(at: journalURL)
        }
        return true
    }

    private static func save(_ journal: Journal, to url: URL) throws {
        try AgentStorageLayout.writeState(journal, to: url)
    }

    private static func move(_ source: URL, to destination: URL) throws {
        if AgentStorageLayout.exists(source) {
            guard !AgentStorageLayout.exists(destination) else {
                throw AgentStorageError("Storage migration found conflicting files at \(source.lastPathComponent). Nothing was overwritten.")
            }
            try FileManager.default.moveItem(at: source, to: destination)
        } else if !AgentStorageLayout.exists(destination) {
            throw AgentStorageError("Storage migration could not find \(source.lastPathComponent). Restore the missing file before retrying.")
        }
    }
}
